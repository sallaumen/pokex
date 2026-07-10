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

  @impl true
  def init(opts) do
    sck = Keyword.get(opts, :screen_capture_kit, ScreenCaptureKit)
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
         )
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
  @impl true
  def handle_call({:grab, region, filename, requested_at}, _from, state) do
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

  def handle_call({:frame, region, filename, requested_at}, _from, state) do
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

  def handle_call({:frame_uncached, region, filename, requested_at}, _from, state) do
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
         sck_recover_backoff_ms: state.sck_recover_interval_ms
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
      timed_decode(path, filename)
    end
  end

  defp frame_from_backend(state, region, filename) do
    with {{:ok, path}, state} <- capture_path(state, region, filename) do
      {timed_decode(path, filename), state}
    end
  end

  defp capture_path(%{backend: {:screen_capture_kit, backend}} = state, region, filename) do
    path = Path.join(Pokex.Home.captures_dir(), Path.basename(filename))

    started_at = now()

    case capture_with_sck(state, backend, region, path, filename) do
      {:ok, path} ->
        Perf.record("capture.backend.sck:#{filename}", now() - started_at)
        {{:ok, path}, state}

      {:error, reason} ->
        Perf.record("capture.backend.sck_error:#{filename}", now() - started_at)

        Logger.warning(
          "ScreenCaptureKit capture failed; falling back to screencapture: #{inspect(reason)}"
        )

        fallback = fallback_backend(state)
        {timed_capture_path(:fallback, region, filename), fallback}
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
    result = Rig.impl().capture(region, filename)
    Perf.record("capture.backend.#{kind}:#{filename}", now() - started_at)
    result
  end

  defp timed_decode(path, filename) do
    started_at = now()
    result = Frame.from_png_file(path)
    Perf.record("capture.decode:#{filename}", now() - started_at)
    result
  end

  defp record_queue(kind, filename, requested_at),
    do: Perf.record("capture.queue.#{kind}:#{filename}", now() - requested_at)

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

          if state.sck_retry_sleep_ms > 0, do: Process.sleep(state.sck_retry_sleep_ms)
          do_capture_with_sck(state, backend, region, path, filename, retries_left - 1)
        else
          {:error, reason}
        end

      {:error, reason} ->
        {:error, reason}
    end
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
    do: not String.contains?(reason, "stream stopped")

  defp sck_retryable_capture_error?(_reason), do: false

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

          sleep_ms = sck_start_retry_sleep_ms(opts)
          if sleep_ms > 0, do: Process.sleep(sleep_ms)
          start_sck_backend(opts, sck, retries_left - 1)
        else
          error
        end

      error ->
        error
    end
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
