defmodule Pokex.Bots.Capture do
  @moduledoc """
  Serializes screen captures so no two run at once, and keeps a very short
  decoded-frame cache for bursty duplicate reads.

  MEASURED on Lucas's machine (2 displays): ONE `screencapture` is ~0.28s, but several running
  CONCURRENTLY balloon to 2-4s EACH — macOS `screencapture` contends badly on the display grab.
  The workers each grabbing their own region in parallel (fishing's glow + combat's battle +
  the skill bar + the panel poll) was the real cause of the jittery, slow sample rate — NOT the
  number of processes. Routing every capture through this one GenServer means only one
  screencapture is ever in flight, so each stays ~0.28s and the cadence is steady.

  Read-only, off the Body's input path (captures never touched the Body). `grab/3` and `frame/3`
  fall back to a DIRECT capture when the broker isn't running, so unit tests need nothing extra.
  """
  use GenServer

  alias Pokex.Bots.{Capture.ScreenCaptureKit, Perf}
  alias Pokex.Rig
  alias Pokex.Vision.Frame
  require Logger

  @default_cache_ttl_ms 75
  @default_sck_start_retries 2
  @default_sck_start_retry_sleep_ms 500
  @default_sck_capture_retries 2
  @default_sck_retry_sleep_ms 75
  @default_sck_recover_interval_ms 5_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Serialized screen capture — `{:ok, path} | {:error, reason}`. Blocks the caller until its turn
  comes and its capture completes (each ~0.28s alone), so concurrent callers queue instead of
  fighting over the display. Direct (unserialized) when the broker isn't started.
  """
  def grab(region, filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> timed_capture_path(:direct, region, filename)
      pid -> GenServer.call(pid, {:grab, region, filename, requested_at}, :infinity)
    end
  end

  @doc """
  Full-screen capture of the SAME display the capture backend films — `{:ok, path}`.

  Calibration/diagnostic screenshots must show exactly what production frames
  see. With ScreenCaptureKit up, the helper's ready metadata names the game
  display's full region (and even a mid-call CLI fallback then uses that region
  in global coordinates — still the right monitor). Only without SCK at all do
  we fall back to `screencapture -m`, which on a multi-monitor setup can film
  the wrong display.
  """
  def screen(filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> guard_capture(fn -> Rig.impl().capture_screen() end)
      pid -> GenServer.call(pid, {:screen, filename, requested_at}, :infinity)
    end
  end

  @doc """
  `screen/2` plus the FILMED display's size in SCREEN POINTS — `{:ok, path, {w, h}}`.

  The only honest denominator for a screenshot's scale. The window server's
  desktop bounds are the union of EVERY monitor (measured 2026-08-04 with two
  displays: 4952×1989 for a 3440×1440 screenshot), so dividing by them scaled
  each marked point by 1.44 and the rod landed on dry rock below the character.
  A single display makes the two coincide, which is why it passed before.

  Measured here, inside the one turn that takes the capture, so the backend
  cannot flip between the two answers: SCK names the display in its ready
  metadata, and even a mid-call CLI fallback reuses that region, so
  `pixels / points` stays the true scale. Only a broker with no SCK at all
  needs the 100-point probe — served by the same CLI, in the same turn.

  Separate from `screen/2` on purpose: that probe is a whole extra capture
  (~0.28s, serialized with every other reader), and the panel/x-ray/thumbnail
  screenshots throw the measurement away.
  """
  def screen_with_points(filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> cli_screen_with_points(filename)
      pid -> GenServer.call(pid, {:screen_with_points, filename, requested_at}, :infinity)
    end
  end

  @doc """
  The filmed display's size in POINTS without taking a capture — `{:ok, {w, h}}`
  or `:unknown`. `:unknown` means "no proof", never "the screen changed".
  """
  def display_points(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> :unknown
      pid -> GenServer.call(pid, :display_points, :infinity)
    end
  end

  @impl true
  def init(opts) do
    sck = Keyword.get(opts, :screen_capture_kit, ScreenCaptureKit)
    # Sweep helper zombies from previous runs BEFORE starting ours: each orphan holds a live
    # SCStream that loads the SCK daemon until new stream starts time out (the 2026-07-10
    # death spiral). Real backend only — test fakes have no OS processes to sweep.
    if sck == ScreenCaptureKit, do: ScreenCaptureKit.kill_orphans()
    {backend, start_recoverable?} = start_backend(opts, sck)
    sck_recoverable? = start_recoverable? and sck_recoverable?(sck)
    sck_recover_interval_ms = sck_recover_interval_ms(opts)

    {:ok,
     %{
       backend: backend,
       sck: sck,
       sck_opts: opts,
       sck_recoverable?: sck_recoverable?,
       sck_recover_at: initial_sck_recover_at(backend, sck_recoverable?, sck_recover_interval_ms),
       sck_recover_interval_ms: sck_recover_interval_ms,
       sck_recover_backoff_ms: sck_recover_interval_ms,
       recovering?: false,
       sck_capture_retries:
         non_neg_int(
           Keyword.get(
             opts,
             :sck_capture_retries,
             Application.get_env(
               :pokex,
               :sck_capture_retries,
               @default_sck_capture_retries
             )
           ),
           @default_sck_capture_retries
         ),
       sck_retry_sleep_ms:
         non_neg_int(
           Keyword.get(
             opts,
             :sck_retry_sleep_ms,
             Application.get_env(
               :pokex,
               :sck_retry_sleep_ms,
               @default_sck_retry_sleep_ms
             )
           ),
           @default_sck_retry_sleep_ms
         ),
       cache: %{},
       cache_ttl_ms:
         Keyword.get(
           opts,
           :cache_ttl_ms,
           Application.get_env(:pokex, :capture_cache_ttl_ms, @default_cache_ttl_ms)
         ),
       # QUARANTINED regions: requested off-screen (game window moved since
       # calibration). The helper answers the same error forever — each attempt
       # cost retries + fallback + killing the HEALTHY SCK (fallback_backend),
       # drowning the whole broker. Key = the exact region; recalibrating makes
       # a new key and it heals on its own.
       impossible_regions: %{},
       # regions that already rang the siren — repeats become log lines, not alarms
       regioes_alarmadas: MapSet.new(),
       starvation_alarm_at: nil
     }}
  end

  @doc """
  Serialized capture plus PNG decode. Returns a `%Frame{}` and caches it briefly by region.

  This is the preferred API for workers that immediately decode the PNG anyway. It avoids
  duplicate ExPng work when fishing/combat/panel all ask for the same skill-bar region in the
  same burst, while keeping the domain-specific pixel analysis in each worker.
  """
  def frame(region, filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> direct_frame(region, filename)
      pid -> GenServer.call(pid, {:frame, region, filename, requested_at}, :infinity)
    end
  end

  @doc """
  `frame/3` plus the PATH of the PNG it decoded — `{:ok, frame, path}`.

  The file on disk IS the frame that was analysed. The mini-game diagnostics
  keep evidence frames and refresh the live preview by COPYING that file, so
  the picture Lucas looks at is exactly the picture the code read: no second
  capture (which would show a DIFFERENT moment) and no re-encoding.
  """
  def frame_with_path(region, filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> direct_frame_with_path(region, filename)
      pid -> GenServer.call(pid, {:frame_with_path, region, filename, requested_at}, :infinity)
    end
  end

  @doc """
  Serialized capture plus PNG decode, bypassing the short decoded-frame cache.

  Use this only for guard reads where a just-triggered screen transition must not
  reuse a frame captured a few milliseconds earlier.
  """
  def frame_uncached(region, filename, server \\ __MODULE__) do
    requested_at = now()

    case GenServer.whereis(server) do
      nil -> direct_frame(region, filename)
      pid -> GenServer.call(pid, {:frame_uncached, region, filename, requested_at}, :infinity)
    end
  end

  @doc "Which capture backend is live right now (panel diagnostics)."
  def backend_info(server \\ __MODULE__) do
    case GenServer.whereis(server) do
      nil -> %{backend: :rig, recovering?: false}
      _pid -> GenServer.call(server, :backend_info)
    end
  end

  # The capture runs INSIDE handle_call, so the GenServer processes one at a time — that IS the
  # serialization. A slow capture only delays the next queued capture, never the Body/panic path.
  # Records the wait the CALLER felt in the queue — before, only backend time was
  # measured, and the invisible wait is exactly what drowned live combat (logs
  # 2026-07-29: fishing ticking at 2-6s, "no post-Tab frame" every cycle). Queue
  # depth at service time rides along: high wait + deep queue = too much demand;
  # high wait + shallow queue = slow backend. Baseline in /diagnostics and exports.
  defp note_wait(state, filename, requested_at) do
    wait_ms = now() - requested_at
    Perf.record("capture.espera:#{filename}", wait_ms)
    {:message_queue_len, depth} = Process.info(self(), :message_queue_len)
    Perf.record("capture.fila:#{filename}", depth)
    maybe_starvation_alarm(state, wait_ms)
  end

  # Queue starvation was INVISIBLE outside /diagnostics: live, fishing took ~7s to
  # see a bite and nobody knew WHY (logs 2026-07-30). Waits above the ceiling raise
  # a panel/journal alarm — rate-limited, because in a drowned queue EVERY request
  # exceeds the ceiling and one alarm per capture would be a continuous siren.
  @starvation_wait_ms 3_000
  @starvation_alarm_gap_ms 60_000

  defp maybe_starvation_alarm(state, wait_ms) when wait_ms >= @starvation_wait_ms do
    last = state.starvation_alarm_at

    if last == nil or now() - last >= @starvation_alarm_gap_ms do
      alarm(
        "⏳ captura saturada: um pedido esperou #{Float.round(wait_ms / 1000, 1)}s na fila — " <>
          "os bots estão reagindo com atraso (SCK caído? região impossível? demanda demais?)"
      )

      %{state | starvation_alarm_at: now()}
    else
      state
    end
  end

  defp maybe_starvation_alarm(state, _wait_ms), do: state

  # Same alarm funnel as the workers: the panel (sound/anti-spam) and journal
  # subscribe to "game" and handle {:rule_alarm, _}.
  defp alarm(text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:rule_alarm, :capture, text})

  @impl true
  def handle_call({:grab, region, filename, requested_at}, _from, state) do
    state = note_wait(state, filename, requested_at)
    record_queue(:grab, filename, requested_at)
    key = {:path, region, filename}

    case cached(state, key) do
      {:ok, path, state} ->
        Perf.count("capture.cache_hit.path:#{filename}")
        {:reply, {:ok, path}, state}

      :miss ->
        case capture_path(state, region, filename) do
          {{:ok, path}, state} -> {:reply, {:ok, path}, put_cache(state, key, path)}
          {error, state} -> {:reply, error, prune_cache(state)}
        end
    end
  end

  def handle_call({:screen, filename, requested_at}, _from, state) do
    record_queue(:screen, filename, requested_at)

    case screen_region(state) do
      {:ok, region} ->
        {reply, state} = capture_path(state, region, filename)
        {:reply, reply, prune_cache(state)}

      :unknown ->
        {:reply, guard_capture(fn -> Rig.impl().capture_screen() end), state}
    end
  end

  def handle_call({:screen_with_points, filename, requested_at}, _from, state) do
    record_queue(:screen, filename, requested_at)

    case screen_region(state) do
      {:ok, {_x, _y, w, h} = region} ->
        {reply, state} = capture_path(state, region, filename)
        {:reply, with({:ok, path} <- reply, do: {:ok, path, {w, h}}), prune_cache(state)}

      :unknown ->
        {:reply, cli_screen_with_points(filename), state}
    end
  end

  def handle_call(:display_points, _from, state) do
    case screen_region(state) do
      {:ok, {_x, _y, w, h}} -> {:reply, {:ok, {w, h}}, state}
      :unknown -> {:reply, :unknown, state}
    end
  end

  def handle_call({:frame, region, filename, requested_at}, _from, state) do
    state = note_wait(state, filename, requested_at)
    record_queue(:frame, filename, requested_at)
    key = {:frame, region}

    case cached(state, key) do
      {:ok, frame, state} ->
        Perf.count("capture.cache_hit.frame:#{filename}")
        {:reply, {:ok, frame}, state}

      :miss ->
        case frame_from_backend(state, region, filename) do
          {{:ok, %Frame{} = frame}, state} ->
            {:reply, {:ok, frame}, put_cache(state, key, frame)}

          {error, state} ->
            {:reply, error, prune_cache(state)}
        end
    end
  end

  def handle_call({:frame_with_path, region, filename, requested_at}, _from, state) do
    state = note_wait(state, filename, requested_at)
    record_queue(:frame_with_path, filename, requested_at)
    key = {:frame_path, region}

    case cached(state, key) do
      {:ok, {frame, path}, state} ->
        Perf.count("capture.cache_hit.frame_path:#{filename}")
        {:reply, {:ok, frame, path}, state}

      :miss ->
        case frame_and_path_from_backend(state, region, filename) do
          {{:ok, %Frame{} = frame, path}, state} ->
            {:reply, {:ok, frame, path}, put_cache(state, key, {frame, path})}

          {error, state} ->
            {:reply, error, prune_cache(state)}
        end
    end
  end

  def handle_call({:frame_uncached, region, filename, requested_at}, _from, state) do
    state = note_wait(state, filename, requested_at)
    record_queue(:frame_uncached, filename, requested_at)
    {reply, state} = frame_from_backend(state, region, filename)
    {:reply, reply, prune_cache(state)}
  end

  def handle_call(:backend_info, _from, state) do
    backend =
      case state.backend do
        {:screen_capture_kit, _b} -> :screen_capture_kit
        _other -> :rig
      end

    {:reply, %{backend: backend, recovering?: state.recovering?}, state}
  end

  @impl true
  def handle_info({_port, {:exit_status, _status}}, state), do: {:noreply, state}

  def handle_info({_port, {:data, _line}}, state), do: {:noreply, state}

  # Result of an async recovery Task (see maybe_recover_sck): the Task already transferred the
  # port to us, so we just adopt (or reschedule) — none of this ran on a capture's handle_call.
  def handle_info({:sck_recovery_result, {:ok, backend}}, state) do
    Logger.info("ScreenCaptureKit capture backend recovered")

    {:noreply,
     %{
       state
       | backend: {:screen_capture_kit, backend},
         recovering?: false,
         sck_recover_at: nil,
         sck_recover_backoff_ms: state.sck_recover_interval_ms,
         # A fresh SCK may see another display/scale — give every quarantined
         # region ONE new chance (still off-screen = one cheap roundtrip
         # re-quarantines it).
         impossible_regions: %{}
     }}
  end

  def handle_info({:sck_recovery_result, {:error, {:disabled, _reason}}}, state) do
    {:noreply, %{state | recovering?: false, sck_recoverable?: false, sck_recover_at: nil}}
  end

  def handle_info({:sck_recovery_result, {:error, reason}}, state) do
    Logger.info("ScreenCaptureKit capture backend still unavailable: #{inspect(reason)}")
    state = %{state | recovering?: false}

    if retryable_sck_start_error?(reason),
      do: {:noreply, schedule_sck_recovery(state)},
      else: {:noreply, %{state | sck_recoverable?: false, sck_recover_at: nil}}
  end

  def handle_info({:sck_recovery_result, other}, state) do
    Logger.info("ScreenCaptureKit capture backend still unavailable: #{inspect(other)}")
    {:noreply, schedule_sck_recovery(%{state | recovering?: false})}
  end

  # Defining our own handle_info clauses replaces GenServer's default log-and-ignore, so an
  # unexpected message would otherwise crash the broker (dropping every queued capture). Keep the
  # broker resilient with an explicit catch-all.
  def handle_info(_message, state), do: {:noreply, state}

  defp direct_frame(region, filename) do
    with {:ok, path} <- timed_capture_path(:direct, region, filename) do
      timed_decode(path, filename, region)
    end
  end

  defp direct_frame_with_path(region, filename) do
    with {:ok, path} <- timed_capture_path(:direct, region, filename),
         {:ok, frame} <- timed_decode(path, filename, region) do
      {:ok, frame, path}
    end
  end

  defp frame_and_path_from_backend(state, region, filename) do
    case capture_path(state, region, filename) do
      {{:ok, path}, state} ->
        case timed_decode(path, filename, region) do
          {:ok, frame} -> {{:ok, frame, path}, state}
          error -> {error, state}
        end

      {error, state} ->
        {error, state}
    end
  end

  defp frame_from_backend(state, region, filename) do
    with {{:ok, path}, state} <- capture_path(state, region, filename) do
      {timed_decode(path, filename, region), state}
    end
  end

  defp capture_path(%{backend: {:screen_capture_kit, backend}} = state, region, filename) do
    case state.impossible_regions do
      %{^region => reason} ->
        # Quarantine: don't even touch the helper. Before, EVERY tick of this feed
        # paid retries + CLI fallback (~1.5s) and took the SCK down — one feed's
        # bad region drowned all the others.
        Perf.count("capture.regiao_impossivel:#{filename}")
        {{:error, {:screen_capture_kit, reason}}, state}

      _no_quarantine ->
        path = Path.join(Pokex.Home.captures_dir(), Path.basename(filename))

        started_at = now()

        case capture_with_sck(state, backend, region, path, filename) do
          {:ok, path} ->
            Perf.record("capture.backend.sck:#{filename}", now() - started_at)
            {{:ok, path}, state}

          {:error, {:screen_capture_kit, reason}} = error when is_binary(reason) ->
            Perf.record("capture.backend.sck_error:#{filename}", now() - started_at)

            after_sck_error(state, region, filename, reason, error)

          {:error, reason} ->
            Perf.record("capture.backend.sck_error:#{filename}", now() - started_at)

            Logger.warning(
              "ScreenCaptureKit capture failed; falling back to screencapture: #{inspect(reason)}"
            )

            fallback = fallback_backend(state)
            {timed_capture_path(:fallback, region, filename), fallback}
        end
    end
  end

  defp capture_path(state, region, filename) do
    # Recovery is async (see maybe_recover_sck), so the backend stays :rig for THIS capture —
    # we never block a capture waiting for SCK to come back.
    state = maybe_recover_sck(state)
    {timed_capture_path(:rig, region, filename), state}
  end

  defp timed_capture_path(kind, region, filename) do
    started_at = now()
    result = guard_capture(fn -> Rig.impl().capture(region, filename) end)
    Perf.record("capture.backend.#{kind}:#{filename}", now() - started_at)
    result
  end

  # A raise from the capture backend must NOT take this broker down. The feeds
  # tick against this GenServer forever; in tests the Rig.Fake Agent they read
  # through dies with the test that created it, so a tick landing in the window
  # between tests hit a dead Agent and raised. An unguarded raise crashed the
  # broker, and 4 crashes inside the supervisor's 5s restart window took the
  # WHOLE app down mid-suite — the source of the order-dependent flakiness. The
  # feeds already treat {:error, _} as a failed tick (`tick_failed`), so a dead
  # backend becomes one skipped frame instead of a cascade.
  defp guard_capture(fun) do
    fun.()
  rescue
    error -> {:error, {:capture_backend, {:error, Exception.message(error)}}}
  catch
    kind, reason -> {:error, {:capture_backend, {kind, reason}}}
  end

  # The frame is stamped with the scale THIS capture implies (pixels per point),
  # so no consumer has to trust a scale persisted when another backend was live.
  defp timed_decode(path, filename, region) do
    started_at = now()
    result = Frame.from_png_file(path)
    Perf.record("capture.decode:#{filename}", now() - started_at)

    case result do
      {:ok, frame} -> {:ok, Frame.with_scale(frame, region_width(region))}
      error -> error
    end
  end

  defp region_width({_x, _y, w, _h}), do: w
  defp region_width(_other), do: nil

  defp record_queue(kind, filename, requested_at),
    do: Perf.record("capture.queue.#{kind}:#{filename}", now() - requested_at)

  defp screen_region(%{backend: {:screen_capture_kit, backend}, sck: sck}),
    do: sck.display_region(backend)

  defp screen_region(_state), do: :unknown

  # No SCK metadata: `screencapture -m` answers in PIXELS and never says which
  # display it filmed. A region probe through the SAME CLI gives its pixels per
  # point, so the screenshot's own size converts to points. Both captures happen
  # in this one call — the async SCK recovery cannot slip between them and pair a
  # points answer with a pixels one (the 2026-08-03 half-screen bug).
  @probe_points 100

  defp cli_screen_with_points(filename) do
    with {:ok, path} <- guard_capture(fn -> Rig.impl().capture_screen() end) do
      {:ok, path, cli_points(path, filename)}
    end
  end

  defp cli_points(screen_path, filename) do
    with {:ok, {px_w, px_h}} <- Frame.png_dimensions(screen_path),
         ratio when ratio > 0 <- cli_pixels_per_point(filename) do
      {round(px_w / ratio), round(px_h / ratio)}
    else
      _unmeasurable -> nil
    end
  end

  defp cli_pixels_per_point(filename) do
    region = {0, 0, @probe_points, @probe_points}

    with {:ok, path} <- guard_capture(fn -> Rig.impl().capture(region, "points_#{filename}") end),
         {:ok, {probe_px, _h}} <- Frame.png_dimensions(path) do
      probe_px / @probe_points
    else
      _unmeasurable -> 0
    end
  end

  defp capture_with_sck(state, backend, region, path, filename) do
    do_capture_with_sck(state, backend, region, path, filename, state.sck_capture_retries)
  end

  defp do_capture_with_sck(state, backend, region, path, filename, retries_left) do
    sck = state.sck

    case sck.capture(backend, region, path) do
      {:ok, path} ->
        {:ok, path}

      {:error, reason} when retries_left > 0 ->
        # Only retry a CLEAN application error (the helper answered ok:false, so the line-based
        # protocol is still in sync). A timeout / closed port / partial line means the stream is
        # DESYNCED: retrying on the same port would read the previous request's orphaned response
        # as this one's (a crop of the wrong region), so bail immediately and let the broker fall
        # back + tear the port down instead.
        if sck_retryable_capture_error?(reason) do
          Perf.count("capture.backend.sck_retry:#{filename}")

          Logger.warning(
            "ScreenCaptureKit capture failed; retrying before fallback " <>
              "(#{retries_left} left): #{inspect(reason)}"
          )

          retry_capture_with_sck(state, backend, region, path, filename, retries_left)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp retry_capture_with_sck(state, backend, region, path, filename, retries_left) do
    if state.sck_retry_sleep_ms > 0, do: Process.sleep(state.sck_retry_sleep_ms)
    do_capture_with_sck(state, backend, region, path, filename, retries_left - 1)
  end

  # A "clean" capture error is one where the helper answered on-protocol (ok:false with a string
  # reason, e.g. "no frame available yet") — safe to retry on the same warm port. Anything else
  # (:timeout, :port_closed, a bad/partial response) means the stream is broken/desynced, so we do
  # NOT retry the same port.
  #
  # EXCEPT a stopped stream: SCK never resumes one (-3805 "connection interrupted" on screen
  # lock/sleep/display change is terminal), so the helper is a zombie that will answer the same
  # error forever. Retrying only delays the real cure — fall back NOW and let the scheduled
  # recovery start a fresh helper.
  defp sck_retryable_capture_error?({:screen_capture_kit, reason}) when is_binary(reason),
    do: not String.contains?(reason, "stream stopped") and not region_impossible_reason?(reason)

  defp sck_retryable_capture_error?(_reason), do: false

  # The helper validates geometry and answers "outside frame" when the region falls
  # off the display — an error that NEVER changes on its own (only recalibration or
  # a display change fix it). String from OUR native helper, stable protocol.
  defp region_impossible_reason?(reason), do: String.contains?(reason, "outside frame")

  # DETERMINISTIC geometry error: the region is (partially) off-screen — the game
  # window moved since calibration. The SCK is HEALTHY; killing it
  # (fallback_backend) or trying the CLI just produces garbage more slowly.
  # Quarantine + alarm: the fix is human (recalibrate), not retry.
  defp after_sck_error(state, region, filename, reason, error) do
    if region_impossible_reason?(reason) do
      {error, quarantine_region(state, region, filename, reason)}
    else
      Logger.warning(
        "ScreenCaptureKit capture failed; falling back to screencapture: #{inspect({:screen_capture_kit, reason})}"
      )

      {timed_capture_path(:fallback, region, filename), fallback_backend(state)}
    end
  end

  defp quarantine_region(state, region, filename, reason) do
    text =
      "🖥️ captura de #{filename} impossível: #{reason} — a janela do jogo mudou de lugar? " <>
        "Recalibre. Parei de tentar essa região (recalibrar ou o SCK reiniciar liberam)."

    # Siren ONCE per region per process lifetime. SCK recovery clears
    # impossible_regions on purpose (re-probing is right), but each re-probe of
    # the SAME broken region re-rang the alarm — 12 identical sirens in one
    # afternoon (journal 2026-07-30). Repeats become a log line instead.
    state =
      if MapSet.member?(state.regioes_alarmadas, region) do
        Phoenix.PubSub.broadcast(Pokex.PubSub, "game", {:game_log, :macro, text})
        state
      else
        alarm(text)
        %{state | regioes_alarmadas: MapSet.put(state.regioes_alarmadas, region)}
      end

    %{state | impossible_regions: Map.put(state.impossible_regions, region, reason)}
  end

  defp start_backend(opts, sck) do
    case start_sck_backend(opts, sck, sck_start_retries(opts)) do
      {:ok, backend} ->
        {{:screen_capture_kit, backend}, true}

      {:error, {:disabled, _reason}} ->
        {:rig, false}

      {:error, reason} ->
        if Application.get_env(:pokex, :capture_backend, :auto) in [
             :screen_capture_kit,
             "screen_capture_kit"
           ] do
          Logger.error("ScreenCaptureKit capture backend unavailable: #{inspect(reason)}")
        else
          Logger.info("ScreenCaptureKit capture backend unavailable: #{inspect(reason)}")
        end

        {:rig, retryable_sck_start_error?(reason)}
    end
  end

  defp start_sck_backend(opts, sck, retries_left) do
    case sck.start(opts) do
      {:ok, backend} ->
        {:ok, backend}

      {:error, {:disabled, _reason}} = error ->
        error

      {:error, reason} = error ->
        if retries_left > 0 and retryable_sck_start_error?(reason) do
          Perf.count("capture.backend.sck_start_retry")

          Logger.warning(
            "ScreenCaptureKit capture backend start failed; retrying " <>
              "(#{retries_left} left): #{inspect(reason)}"
          )

          retry_sck_start(opts, sck, retries_left)
        else
          error
        end

      error ->
        error
    end
  end

  defp retry_sck_start(opts, sck, retries_left) do
    sleep_ms = sck_start_retry_sleep_ms(opts)
    if sleep_ms > 0, do: Process.sleep(sleep_ms)
    start_sck_backend(opts, sck, retries_left - 1)
  end

  defp retryable_sck_start_error?(:timeout), do: true

  defp retryable_sck_start_error?({:not_ready, reason}) when is_binary(reason),
    do: not sck_permission_error?(reason)

  defp retryable_sck_start_error?({:not_ready, _reason}), do: true
  defp retryable_sck_start_error?({:bad_ready_response, _response}), do: true
  defp retryable_sck_start_error?({:bad_json, _line, _reason}), do: true
  defp retryable_sck_start_error?({:partial_line, _line}), do: true
  defp retryable_sck_start_error?({:exit_status, _status}), do: true
  defp retryable_sck_start_error?(_reason), do: false

  defp sck_permission_error?(reason) do
    reason = String.downcase(reason)

    String.contains?(reason, "tcc") or String.contains?(reason, "declined") or
      String.contains?(reason, "not authorized") or String.contains?(reason, "permission")
  end

  defp sck_start_retries(opts) do
    non_neg_int(
      Keyword.get(
        opts,
        :sck_start_retries,
        Application.get_env(:pokex, :sck_start_retries, @default_sck_start_retries)
      ),
      @default_sck_start_retries
    )
  end

  defp sck_start_retry_sleep_ms(opts) do
    non_neg_int(
      Keyword.get(
        opts,
        :sck_start_retry_sleep_ms,
        Application.get_env(
          :pokex,
          :sck_start_retry_sleep_ms,
          @default_sck_start_retry_sleep_ms
        )
      ),
      @default_sck_start_retry_sleep_ms
    )
  end

  defp sck_recover_interval_ms(opts) do
    non_neg_int(
      Keyword.get(
        opts,
        :sck_recover_interval_ms,
        Application.get_env(:pokex, :sck_recover_interval_ms, @default_sck_recover_interval_ms)
      ),
      @default_sck_recover_interval_ms
    )
  end

  defp sck_recoverable?(sck) when sck != ScreenCaptureKit, do: true

  defp sck_recoverable?(_sck) do
    Application.get_env(:pokex, :capture_backend, :auto) in [
      :auto,
      :screen_capture_kit,
      "auto",
      "screen_capture_kit"
    ]
  end

  defp initial_sck_recover_at(:rig, true, interval_ms), do: now() + interval_ms
  defp initial_sck_recover_at(_backend, _recoverable?, _interval_ms), do: nil

  # Kick off SCK recovery WITHOUT blocking the broker. The real start (open port + wait_ready,
  # possibly a swiftc compile — up to ~20s) runs in a spawned Task, so captures keep flowing on
  # the :rig fallback meanwhile instead of head-of-line-blocking behind a slow re-init inside a
  # handle_call. The Task transfers the port to the broker and reports via {:sck_recovery_result,
  # _}; `recovering?` guards against launching two at once.
  defp maybe_recover_sck(
         %{backend: :rig, sck_recoverable?: true, recovering?: false, sck_recover_at: at} = state
       )
       when is_integer(at) do
    if now() >= at do
      spawn_sck_recovery(state)
      %{state | recovering?: true, sck_recover_at: nil}
    else
      state
    end
  end

  defp maybe_recover_sck(state), do: state

  defp spawn_sck_recovery(state) do
    owner = self()
    opts = state.sck_opts
    sck = state.sck
    # ONE start attempt per recovery cycle (boot keeps its retries). Each attempt grabs the
    # display, so in-attempt retries multiply the window where a live `screencapture` fallback
    # contends with SCK and balloons to many seconds; the exponential backoff between CYCLES is
    # what earns extra attempts now.
    retries = 0

    spawn(fn ->
      result =
        try do
          started = start_sck_backend(opts, sck, retries)
          # The Task owns any freshly-opened port; hand it to the broker before we exit, or the
          # port would be closed along with this process.
          with {:ok, backend} <- started, do: connect_backend(backend, owner)
          started
        catch
          kind, reason -> {:error, {:recovery_crashed, kind, reason}}
        end

      send(owner, {:sck_recovery_result, result})
    end)
  end

  defp connect_backend(%ScreenCaptureKit{port: port}, owner) when is_port(port) do
    Port.connect(port, owner)
  rescue
    ArgumentError -> :ok
  end

  defp connect_backend(_backend, _owner), do: :ok

  defp fallback_backend(%{backend: {:screen_capture_kit, backend}, sck: sck} = state) do
    sck.stop(backend)

    state
    |> Map.put(:backend, :rig)
    |> Map.put(:sck_recover_backoff_ms, state.sck_recover_interval_ms)
    |> schedule_sck_recovery()
  end

  defp fallback_backend(state), do: state

  # Each SCK start attempt grabs the display and CONTENDS with the live `screencapture` CLI
  # fallback at the OS level — measured on Lucas's machine: captures ballooned from ~0.3s to
  # 8-16s while recovery re-fired every fixed 5s. So failed recoveries back off exponentially
  # (base interval → ×2 per failure, capped) instead of poisoning the fallback path forever; a
  # successful recovery (or a fresh fall-back from a working SCK) resets the backoff to base.
  @sck_recover_backoff_max_ms 60_000

  defp schedule_sck_recovery(%{sck_recoverable?: true} = state) do
    %{
      state
      | sck_recover_at: now() + state.sck_recover_backoff_ms,
        sck_recover_backoff_ms: min(state.sck_recover_backoff_ms * 2, @sck_recover_backoff_max_ms)
    }
  end

  defp schedule_sck_recovery(state), do: %{state | sck_recover_at: nil}

  defp cached(%{cache_ttl_ms: ttl} = state, _key) when ttl in [nil, 0], do: cache_miss(state)

  defp cached(state, key) do
    now = now()

    case Map.get(state.cache, key) do
      {value, captured_at} when now - captured_at <= state.cache_ttl_ms ->
        {:ok, value, prune_cache(state, now)}

      _ ->
        cache_miss(state)
    end
  end

  defp cache_miss(_state), do: :miss

  defp put_cache(%{cache_ttl_ms: ttl} = state, _key, _value) when ttl in [nil, 0],
    do: %{state | cache: %{}}

  defp put_cache(state, key, value) do
    now = now()
    state = prune_cache(state, now)
    %{state | cache: Map.put(state.cache, key, {value, now})}
  end

  defp prune_cache(state, now \\ now()) do
    if state.cache_ttl_ms in [nil, 0] do
      %{state | cache: %{}}
    else
      do_prune_cache(state, now)
    end
  end

  defp do_prune_cache(state, now) do
    cache =
      Map.reject(state.cache, fn {_key, {_value, captured_at}} ->
        now - captured_at > state.cache_ttl_ms
      end)

    %{state | cache: cache}
  end

  defp now, do: System.monotonic_time(:millisecond)

  defp non_neg_int(value, _default) when is_integer(value) and value >= 0, do: value
  defp non_neg_int(_value, default), do: default
end
