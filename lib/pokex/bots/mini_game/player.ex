defmodule Pokex.Bots.MiniGame.Player do
  @moduledoc """
  The engine for ONE mini-game: captures the armed bar strip, reads the track,
  records what it saw, and — only in `:auto` — asks the Pilot for a decision
  and holds/releases Space.

  Reading and acting are deliberately separate. Every mode runs the SAME read
  (Track + the fish plausibility gate + the velocity estimates) and records the
  same diagnostics; only `:auto` continues into `Pilot.decide/4` and the
  keyboard. That is what makes a game Lucas played by hand a first-class
  recording: identical numbers, no robot in the loop.

  Extracted from the Worker so the GenServer keeps only lifecycle — detection
  streaks, peer pause/resume, input guards. It talks to the Rig DIRECTLY (never
  Body): while in-game the Body guard blocks every other input, including the
  player's own.
  """

  require Logger

  alias Pokex.Bots.Capture
  alias Pokex.Bots.MiniGame.{Detector, Diag, Export, Mode, Pilot}
  alias Pokex.{Rig, Settings}

  # last_toggle_at nil = never toggled — the monotonic clock is NEGATIVE on
  # the BEAM, so a 0 sentinel would read as "toggled far in the future" and
  # mute the actuator forever.
  defstruct fish: [],
            capsule: [],
            holding?: false,
            last_toggle_at: nil,
            strip: nil,
            bar_width: 14,
            no_capsule_streak: 0,
            mode: :manual_assist,
            diag: nil,
            last_path: nil,
            preview_at: nil,
            preview_version: 0

  @type t :: %__MODULE__{}

  @observation_cap 4
  # Half-width (screen points) of the playing-time capture strip around the
  # bar: wide enough for the track + the fish poking past it, and ~8x cheaper
  # to capture and scan than the whole arena.
  @strip_half_pt 40
  # Folga vertical em volta da barra detectada: a cápsula encosta no fim dela, e
  # a eleição do Track pode variar uma ou duas linhas entre frames.
  @strip_margin_pt 10
  @strip_file "mini_game_strip.png"
  @preview_file "mini_game_preview.png"
  # Below this many samples a "game" is a detection blip, not a match — writing
  # a bundle for each would bury the real ones.
  @min_export_samples 5

  @spec new() :: t
  def new, do: %__MODULE__{}

  @spec holding?(t) :: boolean
  def holding?(%__MODULE__{holding?: holding?}), do: holding?

  @spec armed?(t) :: boolean
  def armed?(%__MODULE__{strip: strip}), do: strip != nil

  @spec mode(t) :: atom
  def mode(%__MODULE__{mode: mode}), do: mode

  @doc "The newest recorded tick — what a diagnostics page draws."
  @spec last_sample(t) :: map | nil
  def last_sample(%__MODULE__{diag: nil}), do: nil
  def last_sample(%__MODULE__{diag: diag}), do: Diag.last_sample(diag)

  @doc "Bumped whenever the preview PNG on disk was refreshed."
  @spec preview_version(t) :: non_neg_integer
  def preview_version(%__MODULE__{preview_version: version}), do: version

  @doc "Filename served under /captures for the preview of the analysed frame."
  @spec preview_file() :: String.t()
  def preview_file, do: @preview_file

  @doc "The per-game summary as it stands right now."
  @spec summary(t) :: map | nil
  def summary(%__MODULE__{diag: nil}), do: nil
  def summary(%__MODULE__{diag: diag}), do: Diag.summary(diag)

  @doc """
  Arm the capture strip from the ENTERING detection: the overlay never moves
  within one game, so the play loop can capture just a narrow strip around the
  bar — much cheaper than arena + Detector, which is what lets the play tick
  run at 80ms.

  This is also the entry guard: Space is released unconditionally before the
  first tick, in EVERY mode, and the attempt's result is recorded. A game that
  starts with a stuck key is unplayable by bot or by human.
  """
  @spec arm(t, Pokex.Calibration.t(), Pokex.Rig.region(), Detector.t()) :: t
  def arm(%__MODULE__{} = player, calib, {rx, ry, _rw, rh}, %Detector{bar: bar})
      when is_map(bar) do
    scale = calib.scale || 1.0
    center = rx + round(bar.x / scale)

    # A CAUDA abaixo da barra é cortada. O Track elege a barra pela maior corrida
    # de linhas ESCURAS e só procura o peixe DENTRO dela, então cada linha de
    # cenário que sobra na faixa é candidata a roubar a eleição. Enquanto a
    # região de detecção era uma caixa grandona colada na barra isso passava
    # batido; com a região derivada das âncoras (#151) sobravam ~235 linhas de
    # rocha escura abaixo da barra — o piloto ficou cego em 96% dos ticks
    # (no_fish 302/316 no trace de 2026-08-05), soltou o Espaço e a cápsula morou
    # no fundo.
    #
    # Só a cauda, de propósito: `bar.y2` é confiável (bate com o fim real da
    # barra no fixture e no trace), mas `bar.y1` NÃO — o detector às vezes elege
    # apenas o trecho ABAIXO da cápsula e reporta um topo bem depois do peixe.
    # Cortar por ele comeria justamente o que o piloto precisa ver. O topo da
    # região já é o personagem (#151), então sobra pouquíssimo cenário acima.
    bottom = clamp_int(ry + round(bar.y2 / scale) + @strip_margin_pt, ry + 1, ry + rh)

    strip = {max(center - @strip_half_pt, 0), ry, @strip_half_pt * 2, bottom - ry}
    mode = Mode.current()

    diag =
      Diag.new(
        mode: mode,
        started_at: System.monotonic_time(:millisecond),
        strip: strip,
        bar: bar,
        samples_max: Settings.get(:mini_game_diag_samples_max),
        frames_max: Settings.get(:mini_game_diag_frames_max)
      )
      |> Diag.record_key_up(safe_key_up())

    %{player | strip: strip, bar_width: bar.width, mode: mode, diag: diag}
  end

  def arm(player, _calib, _region, _reading), do: player

  @doc """
  One play tick: capture the strip, read it, record it, and — in `:auto` only —
  decide and actuate.

    * `{:present, player}` — overlay seen
    * `{:blind, player}` — track there but fish unreadable (released if holding)
    * `{:absent, player}` — overlay gone this tick (released if holding)
    * `{:capture_error, reason, player}` — blind tick, released if holding
  """
  @spec tick(t) :: {:present | :blind | :absent, t} | {:capture_error, term, t}
  def tick(%__MODULE__{strip: strip} = player) when strip != nil do
    # Stamped BEFORE the capture: observations must carry the CAPTURE time, so
    # the pilot's age_ms covers the real capture+decode latency and the
    # predictive extrapolation compensates it (the lab's "latencia" knob).
    captured_at = System.monotonic_time(:millisecond)

    case Capture.frame_with_path_uncached(strip, @strip_file) do
      {:ok, frame, path} ->
        capture_ms = System.monotonic_time(:millisecond) - captured_at
        play_frame(player, frame, path, captured_at, capture_ms)

      {:error, reason} ->
        # A blind tick must not leave Space held.
        player = release_if_holding(player)

        sample =
          captured_at
          |> timing(System.monotonic_time(:millisecond) - captured_at)
          |> Map.merge(%{
            read: :capture_error,
            reason: inspect(reason),
            hold: player.holding?,
            mode: player.mode
          })

        {:capture_error, reason, record(player, sample, nil)}
    end
  end

  defp clamp_int(v, lo, hi), do: v |> max(lo) |> min(hi)

  @doc "Release Space only when this player believes it is holding."
  @spec release_if_holding(t) :: t
  def release_if_holding(%__MODULE__{holding?: true} = player), do: force_release(player)
  def release_if_holding(player), do: player

  @doc """
  Unconditional key_up: `holding?` can desync from the OS (a failed key_down
  report, a crash between the Rig call and the state update), so exit paths
  always send the release. Bypasses the min-toggle floor — safety over pacing.
  """
  @spec force_release(t) :: t
  def force_release(%__MODULE__{} = player) do
    result = safe_key_up()
    diag = player.diag && Diag.record_key_up(player.diag, result)
    %{player | holding?: false, diag: diag}
  end

  @doc "Best-effort Space release for terminate paths (never raises)."
  @spec safe_key_up() :: term
  def safe_key_up do
    Rig.impl().key_up("space")
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  @doc """
  Close the recording and write this game's evidence bundle.

  Returns `{:ok, path, stats}`, `:skip` (too short to be a real game) or
  `{:error, reason}`.
  """
  @spec export(t, atom) :: {:ok, String.t(), map} | :skip | {:error, term}
  def export(%__MODULE__{diag: nil}, _exit_reason), do: :skip

  def export(%__MODULE__{diag: diag} = player, exit_reason) do
    if length(Diag.samples(diag)) < @min_export_samples do
      :skip
    else
      diag
      |> Diag.finish(exit_reason, png_reader(player.last_path))
      |> Export.write()
    end
  end

  defp play_frame(%__MODULE__{} = player, frame, path, captured_at, capture_ms) do
    bar = track_bar(player, frame)
    # The replay cannot read these frames without the geometry they were read
    # with, and that geometry only exists once a frame's width is known.
    player = %{player | diag: Diag.remember_track_bar(player.diag, bar)}
    observation = Diag.observe(frame, bar)

    case observation.read do
      :ok ->
        read_ok(player, observation, path, captured_at, capture_ms)

      :no_fish ->
        # Track still there, fish unreadable this frame: blind ticks fail SAFE
        # (release), but the overlay is present — not an exit signal.
        {:blind,
         observe_only(release_if_holding(player), observation, path, captured_at, capture_ms)}

      :no_track ->
        {:absent,
         observe_only(release_if_holding(player), observation, path, captured_at, capture_ms)}
    end
  end

  # Present readings with NO blue anywhere: without the capsule this is not our
  # overlay anymore — after a WIN the world behind the strip can hold a fake
  # dark "track" + clutter-fish forever (the 2026-07-20 hang: every tick read
  # present, the exit streak never fired, and the whole self-held bot froze). In
  # real play the capsule's blue pokes out on virtually every tick (measured
  # 86/86), so a streak of blue-less frames is an END signal, reported as
  # :absent for the worker's normal exit path.
  defp read_ok(player, %{bar_source: :fish} = observation, path, captured_at, capture_ms) do
    streak = player.no_capsule_streak + 1
    player = %{player | no_capsule_streak: streak}

    if streak >= Settings.get(:mini_game_no_capsule_exit_ticks) do
      {:absent,
       observe_only(release_if_holding(player), observation, path, captured_at, capture_ms)}
    else
      {:present, play_reading(player, observation, path, captured_at, capture_ms)}
    end
  end

  defp read_ok(player, observation, path, captured_at, capture_ms),
    do:
      {:present,
       play_reading(%{player | no_capsule_streak: 0}, observation, path, captured_at, capture_ms)}

  # A reading the pipeline cannot aim with (no track, no fish, exit streak):
  # record what was seen and nothing else.
  defp observe_only(player, observation, path, captured_at, capture_ms) do
    sample =
      observation
      |> Map.merge(timing(captured_at, capture_ms))
      |> Map.merge(%{hold: player.holding?, mode: player.mode})

    record(player, sample, path)
  end

  defp play_reading(player, observation, path, captured_at, capture_ms) do
    %{fish_y: fish_y, bar_y: bar_y, bar_source: bar_source} = observation

    # Fish readings pass the plausibility gate: a teleporting misread must not
    # re-aim the pilot (it flew the capsule to the track top while the real fish
    # sat at the bottom — live traces, 2026-07-20). `judge_target` is
    # `accept_target` plus the REASON, which is the single most useful thing a
    # diagnostic can carry.
    {verdict, fish} =
      Pilot.judge_target(player.fish, %{y: fish_y, at: captured_at},
        max_speed: Settings.get(:mini_game_fish_max_speed),
        reacquire_ms: Settings.get(:mini_game_fish_reacquire_ms)
      )

    fish = Enum.take(fish, -@observation_cap)
    capsule = push_observation(player.capsule, %{y: bar_y, at: captured_at, source: bar_source})
    player = %{player | fish: fish, capsule: capsule}

    aim = List.last(fish)
    capsule_vy = Pilot.capsule_velocity(capsule)
    {player, decision} = maybe_fly(player, fish, bar_y, capsule_vy, captured_at)

    sample =
      observation
      |> Map.merge(timing(captured_at, capture_ms))
      |> Map.merge(%{
        mode: player.mode,
        fish_aim: aim && aim.y,
        fish_vy: Pilot.target_velocity(fish),
        bar_vy: capsule_vy,
        accepted: verdict == :accepted,
        verdict: verdict_reason(verdict),
        hold: player.holding?,
        desired: decision[:desired],
        target: decision[:target_y],
        age_ms: decision[:age_ms]
      })

    record(player, sample, path)
  end

  # The ONLY branch that can touch the keyboard. In :manual_assist and
  # :diagnostic the Pilot is never even consulted — the read above already
  # produced everything the diagnostics need.
  defp maybe_fly(%__MODULE__{mode: :auto} = player, fish, bar_y, capsule_vy, captured_at) do
    # Decision time is NOW, observations carry capture time: age_ms > 0 is
    # exactly the capture latency the predictive pilot extrapolates over.
    now = System.monotonic_time(:millisecond)

    decision =
      Pilot.decide(
        %{
          pilot: :predictive,
          deadband_pct: Settings.get(:mini_game_deadband_pct),
          actuation_ms: Rig.impl().hold_latency_ms(),
          brake_up: Settings.get(:mini_game_brake_up),
          brake_down: Settings.get(:mini_game_brake_down)
        },
        fish,
        %{y: bar_y, vy: capsule_vy, pressing: player.holding?, at: captured_at},
        now
      )

    {actuate(player, decision.desired, now), decision}
  end

  defp maybe_fly(player, _fish, _bar_y, _capsule_vy, _captured_at), do: {player, %{}}

  defp verdict_reason(:accepted), do: :accepted
  defp verdict_reason({_outcome, reason}), do: reason

  defp timing(captured_at, capture_ms) do
    %{
      at: captured_at,
      cap_ms: capture_ms,
      tick_ms: System.monotonic_time(:millisecond) - captured_at
    }
  end

  # The bar sits at the strip's center; scale point-geometry to frame px.
  defp track_bar(%__MODULE__{strip: {_sx, _sy, sw, _sh}} = player, frame),
    do: %{x: round(@strip_half_pt * frame.width / sw), width: player.bar_width}

  defp push_observation(observations, observation),
    do: Enum.take(observations ++ [observation], -@observation_cap)

  defp actuate(%__MODULE__{holding?: desired} = player, desired, _now), do: player

  defp actuate(player, desired, now) do
    last = player.last_toggle_at

    if last != nil and now - last < Settings.get(:mini_game_min_toggle_ms) do
      player
    else
      apply_hold(desired)
      %{player | holding?: desired, last_toggle_at: now, diag: bump_actuation(player, desired)}
    end
  end

  defp bump_actuation(%{diag: nil}, _desired), do: nil
  defp bump_actuation(%{diag: diag}, desired), do: Diag.record_actuation(diag, desired)

  # A failed hold call desyncs holding? from the OS until the next
  # exit-boundary release — surface it instead of failing silently.
  defp apply_hold(desired) do
    result = if desired, do: Rig.impl().key_down("space"), else: Rig.impl().key_up("space")

    with {:error, reason} <- result do
      Logger.warning(
        "mini-game: espaço #{if desired, do: "down", else: "up"} falhou: #{inspect(reason)}"
      )

      result
    end
  end

  defp record(%__MODULE__{diag: nil} = player, _sample, _path), do: player

  defp record(player, sample, path) do
    diag = Diag.record(player.diag, sample, png_reader(path))
    refresh_preview(%{player | diag: diag, last_path: path || player.last_path}, path)
  end

  defp png_reader(nil), do: nil
  defp png_reader(path), do: fn -> File.read(path) end

  # The preview is a COPY of the file that was just analysed — never a second
  # capture, which would show a different moment and quietly turn the page into
  # a liar. Throttled, because a copy per 80ms tick is pure waste.
  defp refresh_preview(player, nil), do: player

  defp refresh_preview(player, path) do
    every_ms = Settings.get(:mini_game_preview_ms)
    now = System.monotonic_time(:millisecond)

    if every_ms > 0 and (player.preview_at == nil or now - player.preview_at >= every_ms) do
      case File.cp(path, preview_path()) do
        :ok -> %{player | preview_at: now, preview_version: player.preview_version + 1}
        {:error, _unwritable} -> %{player | preview_at: now}
      end
    else
      player
    end
  end

  defp preview_path, do: Path.join(Pokex.Home.captures_dir(), @preview_file)
end
