defmodule Pokex.Bots.MiniGame.Worker do
  @moduledoc """
  Watches the arena for the fishing mini-game overlay.

  On entry it PLAYS through `MiniGame.Player` (the engine owning strip capture,
  pilot decisions, actuation and the physics trace); on exit it releases Space
  and keeps the panel informed. This module is lifecycle only — streaks, the
  blackboard fact, guards. It coordinates with NOBODY directly: peers hold
  themselves on the `:mini_game` fact this worker publishes, and resume when it
  clears (or goes stale — a crash here can never strand them).

  Detection runs ONLY on this worker's own watch tick. Every tick publishes the
  `:mini_game` fact on the WorldState blackboard — the Body and combat gate their
  inputs on it (`Pokex.Perception.mini_game_gate/0`) with a lock-free ETS read,
  so an input never blocks on this worker's mailbox or pays a screencapture.
  """
  use GenServer

  require Logger

  alias Pokex.Bots.Capture
  alias Pokex.Bots.MiniGame.Detector
  alias Pokex.Bots.MiniGame.Mode
  alias Pokex.Bots.MiniGame.Player
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "mini_game"
  # Per-tick diagnostics go on their own topic: the panel must not re-render at
  # the 80ms play cadence just because a diagnostics page is open somewhere.
  @diag_topic "mini_game_diag"
  @default_counters %{detections: 0, clears: 0, failures: 0}

  def topic, do: @topic
  def diag_topic, do: @diag_topic

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      calib: nil,
      timer: nil,
      running?: false,
      in_game?: false,
      game_entered_at: nil,
      present_streak: 0,
      absent_streak: 0,
      confidence: 0.0,
      error: nil,
      counters: @default_counters,
      alerted_at: nil,
      play: Player.new()
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def run(server \\ __MODULE__), do: GenServer.call(server, :run)
  def halt(server \\ __MODULE__), do: GenServer.call(server, :halt)
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    # Space must never stay held: trapping exits guarantees terminate/2 runs on
    # supervisor shutdown, releasing the key.
    Process.flag(:trap_exit, true)
    {:ok, state}
  end

  @impl true
  def terminate(_reason, state) do
    if state.in_game? or Player.holding?(state.play), do: Player.safe_key_up()
    # a crashing worker must not leave a "playing" fact behind for its peers
    WorldState.put(:mini_game, %{playing?: false, confidence: 0.0}, now_ms())
    :ok
  end

  # The watcher is fishing gear. Outside the fishing mode there is no rod, no
  # capsule and nothing to watch — so a `run` there is answered by staying IDLE
  # (`:ok`, because a worker the mode does not want is not a failed start).
  # Without this the watcher would still pay a screen capture per tick against
  # the one serialized broker, competing with the feeds that ARE reading, over
  # something that cannot happen ("não existe o minigame fora da pesca", Lucas,
  # 2026-08-25).
  @impl true
  def handle_call(:run, _from, state) do
    if Pokex.Modes.watches_mini_game?(), do: do_run(state), else: {:reply, :ok, state}
  end

  def handle_call(:halt, _from, state) do
    # A halt mid-game still ENDS a game: the evidence is worth keeping, and it
    # is the only bundle a Lucas-interrupted match would ever produce.
    if state.in_game?, do: log_export(Player.export(state.play, :halted))

    state =
      %{state | play: Player.force_release(state.play)}
      |> cancel_timer()
      |> Map.merge(%{
        running?: false,
        in_game?: false,
        present_streak: 0,
        absent_streak: 0,
        confidence: 0.0,
        error: nil,
        alerted_at: nil
      })

    publish_fact(state)
    broadcast(state)
    {:reply, :ok, state}
  end

  def handle_call(:status, _from, state), do: {:reply, snapshot(state), state}

  defp do_run(state) do
    case Calibration.load() do
      {:ok, calib} ->
        # re-run mid-game (panel Start while playing) must not strand a held
        # Space: the merge below forgets in_game?/play, so release FIRST.
        state =
          %{state | play: Player.release_if_holding(state.play)}
          |> cancel_timer()
          |> Map.merge(%{
            calib: calib,
            running?: true,
            in_game?: false,
            present_streak: 0,
            absent_streak: 0,
            confidence: 0.0,
            error: nil,
            play: Player.new()
          })

        publish_fact(state)
        broadcast(state)
        {:reply, :ok, reschedule(state, 0)}

      {:error, reason} ->
        {:reply, {:error, ["calibração ilegível: #{inspect(reason)}"]}, state}
    end
  end

  @impl true
  def handle_info(:tick, %{running?: false} = state), do: {:noreply, state}

  def handle_info(:tick, state) do
    started_at = System.monotonic_time(:millisecond)
    {state, transition} = if state.in_game?, do: play_tick(state), else: watch_tick(state)

    # republished EVERY tick (not just on transitions) so the fact stays fresh —
    # readers fail open once it ages past mini_game_fact_max_age_ms
    publish_fact(state)
    if transition, do: broadcast(state, transition), else: :ok
    broadcast_diag(state)
    state = maybe_alert(state)

    {:noreply, reschedule(state, next_delay(state, started_at))}
  end

  # trap_exit is on for terminate/2; stray EXIT messages from unlinked helpers
  # must not crash the worker.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  # Jogando, o intervalo é um PRAZO, não uma soneca: dormir os
  # mini_game_play_tick_ms INTEIROS depois do trabalho fazia o período real
  # virar trabalho+intervalo. Medido no trace da partida de 2026-08-05
  # (`~/.pokex/exports/mini_game-*/summary.json`): tick 68ms de trabalho + 81ms
  # de sono = 149ms entre observações, 6,7 fps — o piloto pediu 12,5 e recebeu
  # metade, e no regime de visão lenta a cápsula oscila (o lab já mostrava isso
  # com o slider de FPS em 7). Descontando o trabalho, o período volta a ser o
  # que o seed promete.
  #
  # Só no modo JOGANDO: aí todos os outros feeds estão pausados pelo fato
  # :mini_game, então acelerar não disputa a fila de captura com ninguém. O
  # vigia (fora de jogo) mantém a soneca cheia de propósito — ele CONCORRE com
  # pesca, batalha e feeds, e a fome de captura é cara demais pra arriscar.
  @doc false
  def next_delay(%{in_game?: true}, started_at) do
    Settings.get(:mini_game_play_tick_ms) - (System.monotonic_time(:millisecond) - started_at)
  end

  def next_delay(_watching, _started_at), do: Settings.get(:mini_game_tick_ms)

  # Watching: capture the DEDICATED strip + Detector. On the enter edge the
  # bar geometry arms the playing-time capture strip. Without a hand-marked
  # strip there is nowhere honest to look — the watcher goes blind and says so.
  defp watch_tick(state) do
    case mini_game_region(state.calib) do
      nil -> no_strip_tick(state)
      region -> watch_strip(state, region)
    end
  end

  defp watch_strip(state, region) do
    case read_presence(state, region) do
      {:ok, reading} ->
        {state, transition} = apply_reading(state, reading)
        state = if transition == :entered, do: arm_strip(state, reading), else: state
        {state, transition}

      {:error, reason} ->
        mark_failure(state, reason)
    end
  end

  @no_strip_error "sem faixa do minigame marcada — vigia desligado (Calibração → Só o minigame)"

  # Sem faixa o vigia NÃO adivinha onde olhar: os dois palpites anteriores
  # falharam no campo (a caixa de meia-tela era "aquela área grandona"; a caixa
  # ancorada no personagem leu tronco escuro + flores azuis como "barra +
  # cápsula" num spot rochoso, 2026-08-05, flapando 1×/s e segurando a frota).
  # Cego E DECLARADO: o erro fica no pill, o aviso sai UMA vez, e a calibração
  # é relida a cada tick — marcar a faixa religa o vigia sem restart.
  defp no_strip_tick(state) do
    state =
      case Calibration.load() do
        {:ok, calib} -> %{state | calib: calib}
        _unreadable -> state
      end

    if mini_game_region(state.calib) do
      watch_tick(state)
    else
      state =
        if state.error == @no_strip_error do
          state
        else
          broadcast_log(:macro, "🎮 " <> @no_strip_error)
          %{state | error: @no_strip_error}
        end

      {state, nil}
    end
  end

  defp read_presence(state, region) do
    opts =
      [
        min_confidence: Settings.get(:mini_game_min_confidence),
        min_dark_ratio: Settings.get(:mini_game_min_dark_ratio)
      ]

    with {:ok, frame} <- Capture.frame(region, "mini_game.png") do
      {:ok, Detector.detect(frame, opts ++ anchor_opts(frame, state.calib, region))}
    end
  end

  # A DEDICATED mini-game region IS the bar's home: search all of it (anchor at
  # the crop center, tolerance the full half-width, no y gate). Without one,
  # anchor at the calibrated player point inside the arena crop, as before.
  defp anchor_opts(frame, %Calibration{mini_game_region: dedicated}, _region)
       when is_tuple(dedicated),
       do: [anchor_x: div(frame.width, 2), anchor_tolerance: div(frame.width, 2) + 1]

  defp anchor_opts(frame, calib, region) do
    [
      anchor_x: player_anchor_x(frame, calib, region),
      anchor_y: player_anchor_y(frame, calib, region),
      anchor_tolerance: anchor_tolerance(frame, region)
    ]
  end

  defp arm_strip(state, reading),
    do: %{
      state
      | play: Player.arm(state.play, state.calib, mini_game_region(state.calib), reading)
    }

  defp apply_reading(state, %Detector{} = reading) do
    state =
      state
      |> Map.put(:confidence, reading.confidence)
      |> Map.put(:error, nil)
      |> update_streaks(reading.present?)

    cond do
      not state.in_game? and state.present_streak >= Settings.get(:mini_game_enter_streak) ->
        enter_game(state)

      state.in_game? and state.absent_streak >= Settings.get(:mini_game_exit_streak) ->
        leave_game(state, :exit_streak)

      true ->
        {state, nil}
    end
  end

  defp update_streaks(state, true),
    do: %{state | present_streak: state.present_streak + 1, absent_streak: 0}

  defp update_streaks(state, false),
    do: %{state | present_streak: 0, absent_streak: state.absent_streak + 1}

  # The mode is resolved ONCE per game (in Player.arm/4, which also releases
  # Space): flipping the setting mid-match must not hand the keyboard to the
  # Pilot while Lucas is playing.
  defp enter_game(state) do
    state =
      state
      |> Map.put(:in_game?, true)
      |> Map.put(:game_entered_at, System.monotonic_time(:millisecond))
      |> Map.put(:play, Player.new())
      |> Map.put(:alerted_at, nil)
      |> update_in([:counters, :detections], &(&1 + 1))

    broadcast_log(:macro, "mini game detectado — workers se seguram pelo fato")
    {state, :entered}
  end

  defp leave_game(state, reason) do
    broadcast_summary(state, reason)
    warn_if_clipped(state.play)
    log_export(Player.export(state.play, reason))

    state =
      %{state | play: Player.force_release(state.play)}
      |> Map.put(:in_game?, false)
      |> Map.put(:game_entered_at, nil)
      |> Map.put(:alerted_at, nil)
      |> update_in([:counters, :clears], &(&1 + 1))

    broadcast_log(:macro, "mini game saiu (#{reason}) — workers retomam sozinhos")
    {state, :left}
  end

  # A game that ends because the READING ran out of frame is not a game that
  # ended: it hands the screen back to the other workers while the overlay is
  # still up (2026-08-10). The strip is the thing to fix, and only the human can
  # fix it — so it rings, in the mini-game sector, instead of dying in a counter.
  defp warn_if_clipped(play) do
    if Player.clipped?(play) do
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @topic,
        {:rule_alarm, :mini_game,
         "🎮 a faixa do minigame está CURTA — a barra encosta no fim do recorte, e peixe " <>
           "ou cápsula abaixo dela ficam invisíveis. Remarque em Calibração → Só o minigame."}
      )
    end
  end

  defp log_export({:ok, path, %{samples: samples, frames: frames}}),
    do:
      broadcast_log(
        :macro,
        "diagnóstico do mini game salvo (#{samples} ticks, #{frames} frames): #{path}"
      )

  defp log_export(:skip), do: :ok

  defp log_export({:error, reason}),
    do: Logger.warning("mini-game diagnostics export failed: #{inspect(reason)}")

  defp play_tick(state) do
    cond do
      game_over_cap?(state) ->
        # Backstop for ANY unseen wedge (same philosophy as hook_hold_max_ms):
        # no real game lasts minutes — a "game" that does is a stuck reading,
        # and a stuck in_game? self-holds the ENTIRE bot (2026-07-20 hang).
        broadcast_log(:macro, "mini game excedeu o teto de duração — encerrando à força")
        leave_game(state, :duration_cap)

      Player.armed?(state.play) ->
        state.play |> Player.tick() |> apply_play_result(state)

      true ->
        # Defensive: entered without a bar candidate — nothing to play from.
        leave_game(state, :not_armed)
    end
  end

  defp game_over_cap?(%{game_entered_at: entered_at}) when is_integer(entered_at),
    do: System.monotonic_time(:millisecond) - entered_at > Settings.get(:mini_game_max_game_ms)

  defp game_over_cap?(_state), do: false

  defp apply_play_result({:present, play}, state),
    do: {%{state | play: play, absent_streak: 0}, nil}

  defp apply_play_result({:blind, play}, state),
    do: {%{state | play: play, absent_streak: 0}, nil}

  defp apply_play_result({:absent, play}, state) do
    state = %{state | play: play, absent_streak: state.absent_streak + 1}

    if state.absent_streak >= Settings.get(:mini_game_exit_streak),
      do: leave_game(state, :exit_streak),
      else: {state, nil}
  end

  defp apply_play_result({:capture_error, reason, play}, state),
    do: mark_failure(%{state | play: play}, reason)

  defp mark_failure(state, reason) do
    state =
      state
      |> Map.put(:error, inspect(reason))
      |> update_in([:counters, :failures], &(&1 + 1))

    broadcast_log(:debug, "erro ao observar mini game: #{inspect(reason)}")
    {state, nil}
  end

  # One resolver for the whole app (the preview draws the SAME rect the worker
  # searches) — see Calibration.mini_game_region/1 for the precedence.
  defp mini_game_region(%Calibration{} = calib), do: Calibration.mini_game_region(calib)

  defp player_anchor_x(frame, calib, {rx, _ry, rw, _rh}) when rw > 0 do
    {px, _py} = Calibration.player_point(calib)
    round((px - rx) * frame.width / rw)
  end

  defp player_anchor_y(frame, calib, {_rx, ry, _rw, rh}) when rh > 0 do
    {_px, py} = Calibration.player_point(calib)
    round((py - ry) * frame.height / rh)
  end

  # The game draws the bar OFFSET (~40px right of the sprite), so the search window must be
  # wider than the sprite itself. Seeded in screen points; scaled to frame px like the anchor.
  defp anchor_tolerance(frame, {_rx, _ry, rw, _rh}) when rw > 0,
    do: round(Settings.get(:mini_game_anchor_tolerance) * frame.width / rw)

  # A mini-game nobody plays stalls the WHOLE session (every worker is held by
  # the :mini_game fact), and one chirp is easy to miss with the game window
  # unfocused — so the alert repeats until the overlay is gone.
  defp maybe_alert(%{in_game?: true} = state) do
    if Mode.alerts?(Player.mode(state.play)) and alert_due?(state) do
      broadcast_alert(state)
      %{state | alerted_at: now_ms()}
    else
      state
    end
  end

  defp maybe_alert(state), do: state

  defp alert_due?(%{alerted_at: nil}), do: true

  defp alert_due?(%{alerted_at: alerted_at}) do
    every_ms = Settings.get(:mini_game_manual_alert_ms)
    every_ms > 0 and now_ms() - alerted_at >= every_ms
  end

  defp broadcast_alert(state) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @topic,
      {:mini_game_alert, %{mode: Player.mode(state.play), text: manual_text()}}
    )
  end

  defp manual_text, do: "minigame aguardando resolução manual"

  defp snapshot(%{running?: false} = state), do: base_snapshot(state, :off)
  defp snapshot(%{in_game?: true} = state), do: base_snapshot(state, :playing)
  defp snapshot(state), do: base_snapshot(state, :watching)

  defp base_snapshot(state, worker_state) do
    mode = if state.in_game?, do: Player.mode(state.play), else: Mode.current()
    awaiting? = worker_state == :playing and Mode.alerts?(mode)

    %{
      state: worker_state,
      in_game?: state.in_game?,
      confidence: state.confidence,
      counters: state.counters,
      error: state.error,
      mode: mode,
      mode_label: Mode.label(mode),
      awaiting_manual?: awaiting?,
      manual_text: if(awaiting?, do: manual_text())
    }
  end

  defp broadcast(state, transition \\ nil) do
    snapshot =
      state
      |> snapshot()
      |> Map.put(:transition, transition)

    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:mini_game, snapshot})
  end

  defp broadcast_log(level, text),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:mini_game_log, level, text})

  # The per-tick diagnostic feed: the sample that was just recorded, plus the
  # version of the preview PNG on disk (which IS the frame that sample came
  # from). Only sent while a game is running.
  defp broadcast_diag(%{in_game?: true} = state) do
    case Player.last_sample(state.play) do
      nil ->
        :ok

      sample ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @diag_topic,
          {:mini_game_tick,
           %{
             sample: sample,
             mode: Player.mode(state.play),
             preview_version: Player.preview_version(state.play),
             preview_file: Player.preview_file()
           }}
        )
    end
  end

  defp broadcast_diag(_watching), do: :ok

  defp broadcast_summary(state, reason) do
    case Player.summary(state.play) do
      nil ->
        :ok

      summary ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @diag_topic,
          {:mini_game_summary, Map.put(summary, :exit_reason, reason)}
        )
    end
  end

  defp publish_fact(state) do
    WorldState.put(
      :mini_game,
      %{playing?: state.running? and state.in_game?, confidence: state.confidence},
      now_ms()
    )
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  defp reschedule(state, delay_ms) do
    state = cancel_timer(state)
    %{state | timer: Process.send_after(self(), :tick, max(delay_ms || 250, 10))}
  end

  defp cancel_timer(%{timer: nil} = state), do: state

  defp cancel_timer(%{timer: timer} = state) do
    Process.cancel_timer(timer)
    %{state | timer: nil}
  end
end
