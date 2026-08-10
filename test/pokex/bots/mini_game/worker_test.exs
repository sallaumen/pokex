defmodule Pokex.Bots.MiniGame.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.MiniGame.Worker
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Rig.Fake
  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup %{tmp_dir: tmp} do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :home_dir)
      WorldState.forget(:mini_game)
    end)

    SettingsStash.stash!(
      mini_game_tick_ms: 20,
      mini_game_enter_streak: 1,
      mini_game_exit_streak: 1,
      mini_game_min_confidence: 0.6,
      mini_game_min_dark_ratio: 0.34,
      mini_game_play_tick_ms: 20,
      mini_game_min_toggle_ms: 0,
      # This file's play tests are about the PILOT flying the capsule, which is
      # no longer the default: :manual_assist is. The manual-assist tests at the
      # bottom pin the safe default itself.
      mini_game_mode: "auto"
    )

    # put mid-test by these tests — must restore too
    SettingsStash.stash_keys!([
      :mini_game_anchor_tolerance,
      :mini_game_no_capsule_exit_ticks,
      :mini_game_max_game_ms,
      :mini_game_mode,
      :mini_game_manual_alert_ms
    ])

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 220,
      screen_h: 220,
      water_point: {100, 100},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 20, 20},
      # Hand-marked region rules (2026-07-30): without one the search becomes a CENTRAL box
      # inside the arena — these tests draw the game across the WHOLE arena, so they mark
      # it as the strip (as real calibration does).
      mini_game_region: {0, 0, 220, 220},
      neutral_point: {100, 100}
    })

    %{tmp: tmp}
  end

  @tag :tmp_dir
  test "announces enter and exit transitions on the panel topic", %{tmp: tmp} do
    game = png!(tmp, "mini-game.png", true)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game_log, :macro, enter_log}, 1_000
    assert enter_log =~ "detectado"

    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  # Field hang 2026-07-20: after a WIN the overlay closed but a >=60-row dark column behind
  # the strip kept reading as a track, so the exit streak never fired. The capsule's blue
  # pokes out on virtually every real tick (measured 86/86 frames) — present readings with
  # NO blue for N consecutive ticks mean the overlay is functionally gone.
  @tag :tmp_dir
  test "a lingering fake track WITHOUT the capsule ends the game (the post-win hang)", %{
    tmp: tmp
  } do
    Settings.put(:mini_game_no_capsule_exit_ticks, 3)

    game = png!(tmp, "mini-game.png", true)
    fishy_world = play_png!(tmp, "fishy-world.png", fish: 100..131, capsule: nil)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}, {:ok, fishy_world}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})
    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  # Backstop for any unseen wedge: no real game lasts minutes — a "game" that does is a
  # stuck reading.
  test "a game that outlives the hard duration cap is force-ended", %{tmp: tmp} do
    Settings.put(:mini_game_max_game_ms, 1)

    game = png!(tmp, "mini-game.png", true)
    playing = play_png!(tmp, "playing.png", fish: 100..131, capsule: 140..160)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}, {:ok, playing}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})
    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  # Real geometry: the game draws the bar ~40px right of the sprite — the seeded anchor
  # tolerance must absorb the offset.
  test "enters the game when the bar sits right of the character, like the real overlay", %{
    tmp: tmp
  } do
    game = png_with_bar_at!(tmp, "offset-game.png", 144..156)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  describe "a cadência do piloto (o intervalo é PRAZO, não soneca)" do
    @tag :tmp_dir
    test "jogando, o trabalho do tick é DESCONTADO do próximo sono" do
      SettingsStash.stash!(mini_game_play_tick_ms: 80)
      agora = System.monotonic_time(:millisecond)

      # um tick que levou ~60ms deve dormir ~20, não 80: era o trabalho+intervalo
      # que fazia 149ms/observação (6,7 fps) no trace de 2026-08-05
      delay = Worker.next_delay(%{in_game?: true}, agora - 60)
      assert delay in 15..25

      # trabalho mais longo que o intervalo não vira sono negativo aqui — o piso
      # de reschedule/2 é quem decide o mínimo
      assert Worker.next_delay(%{in_game?: true}, agora - 500) <= 0
    end

    @tag :tmp_dir
    test "vigiando, a soneca é cheia — ele DISPUTA a fila com pesca e batalha" do
      SettingsStash.stash!(mini_game_tick_ms: 150, mini_game_play_tick_ms: 80)
      agora = System.monotonic_time(:millisecond)

      assert Worker.next_delay(%{in_game?: false}, agora - 60) == 150
    end
  end

  @tag :tmp_dir
  test "sem faixa marcada o vigia fica CEGO e declarado — e marcar religa sem restart", %{
    tmp: tmp
  } do
    # o palpite de região morreu (2026-08-05: caixa ancorada leu tronco + flores
    # azuis como minigame num spot rochoso e flapou 1×/s segurando a frota):
    # sem faixa, NADA é capturado e o motivo é dito uma vez
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | mini_game_region: nil})

    game = png!(tmp, "mini-game.png", true)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)

    # o aviso sai UMA vez, como macro...
    assert_receive {:mini_game_log, :macro, msg}, 1_000
    assert msg =~ "sem faixa do minigame"
    refute_receive {:mini_game_log, :macro, _}, 200

    # ...nada é capturado e o jogo JAMAIS "entra" (o flap era isto)
    refute_receive {:mini_game, %{state: :playing}}, 200
    refute Enum.any?(Pokex.Rig.Fake.calls(), &match?({:capture, _, "mini_game.png"}, &1))

    # marcar a faixa religa o vigia SEM restart: a calibração é relida no tick
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | mini_game_region: {0, 0, 220, 220}})

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  @tag :tmp_dir
  test "a dedicated mini_game_region owns the watch: that region is captured and searched whole",
       %{tmp: tmp} do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | mini_game_region: {140, 20, 60, 180}})

    game = png!(tmp, "mini-game.png", true)
    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    assert {:capture, {140, 20, 60, 180}, "mini_game.png"} in Fake.calls()
  end

  @tag :tmp_dir
  # Tolerance tight enough that only the calibrated anchor (not the arena center) can
  # accept the offset bar — proves the worker prefers calibration.player_point.
  test "anchors the bar search at the CALIBRATED player point when one is saved", %{tmp: tmp} do
    Settings.put(:mini_game_anchor_tolerance, 20)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | player_point: {150, 110}})

    game = png_with_bar_at!(tmp, "calibrated-game.png", 144..156)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  @tag :tmp_dir
  test "publishes the :mini_game fact on the blackboard across enter, exit and halt", %{tmp: tmp} do
    game = png!(tmp, "mini-game.png", true)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}, {:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    refute Pokex.Perception.mini_game_playing?()

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> Pokex.Perception.mini_game_playing?() end)

    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000
    wait_for(fn -> not Pokex.Perception.mini_game_playing?() end)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> Pokex.Perception.mini_game_playing?() end)
    assert :ok = Worker.halt(worker)
    refute Pokex.Perception.mini_game_playing?()
  end

  @tag :tmp_dir
  test "plays: fish above the capsule -> holds Space (key_down, never Body)", %{tmp: tmp} do
    game = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    wait_for(fn -> {:key_down, "space"} in Fake.calls() end)

    # a faixa de jogo encolhe pra 70..150 em x (centro da barra 110) e mantém a
    # ALTURA MARCADA À MÃO inteira. Cortar a cauda por `bar.y2` vale só pra
    # região DERIVADA (ver Player.strip_bottom): no campo, 2026-08-10, esse
    # corte parou a faixa antes do fim da barra real — peixe e cápsula moraram
    # no pedaço invisível até o jogo se declarar encerrado sozinho.
    assert {:capture, {70, 0, 80, 220}, "mini_game_strip.png"} in Fake.calls()
  end

  # The entry guard sends a preventive key_up before the first tick — the proven release
  # must come AFTER the key_down.
  @tag :tmp_dir
  test "plays: fish drops below the capsule -> releases Space", %{tmp: tmp} do
    hold = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
    release = play_png!(tmp, "release.png", fish: 170..184, capsule: 120..134)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, hold}, {:ok, hold}, {:ok, release}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    wait_for(&released_after_holding?/0)
  end

  @tag :tmp_dir
  test "leaving the game always releases Space, even if already released", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert {:key_up, "space"} in Fake.calls()
  end

  @tag :tmp_dir
  test "re-running the worker mid-game releases Space (panel Start while playing)", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Fake.calls() end)

    assert :ok = Worker.run(worker)
    assert {:key_up, "space"} in Fake.calls()
  end

  @tag :tmp_dir
  test "a finished game writes a complete evidence bundle to exports", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    calm = png!(tmp, "calm.png", false)

    captures = List.duplicate({:ok, game}, 8) ++ [{:ok, calm}]
    {:ok, _} = Fake.start_link(%{capture: captures})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 2_000

    assert [bundle] = Path.wildcard(Path.join([tmp, "exports", "mini_game-*"]))

    summary = bundle |> Path.join("summary.json") |> File.read!() |> JSON.decode!()

    assert summary["mode"] == "auto"
    assert summary["ticks"] >= 5
    assert summary["exit_reason"] == "exit_streak"
    assert is_number(summary["duration_ms"])
    assert is_number(summary["capture_ms"]["p95"])
    assert is_number(summary["tick_ms"]["p50"])
    assert is_number(summary["error_mean"])
    assert summary["key_down"] + summary["key_up"] > 0
    assert [_entry_release | _] = summary["safety_key_ups"]

    samples =
      bundle
      |> Path.join("samples.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert length(samples) == summary["samples_recorded"]

    assert Enum.all?(samples, fn sample ->
             is_number(sample["cap_ms"]) and is_number(sample["tick_ms"]) and
               is_number(sample["dark_px"]) and is_number(sample["blue_px"]) and
               is_boolean(sample["hold"]) and is_binary(sample["read"])
           end)

    readable = Enum.filter(samples, &(&1["read"] == "ok"))
    assert readable != []

    assert Enum.all?(readable, fn sample ->
             is_number(sample["fish_y"]) and is_number(sample["bar_y"]) and
               is_number(sample["fish_aim"]) and is_number(sample["fish_vy"]) and
               is_number(sample["bar_vy"]) and is_number(sample["top"]) and
               is_number(sample["bottom"]) and is_boolean(sample["accepted"]) and
               sample["bar_source"] in ["blue", "fish"]
           end)

    frames = Path.wildcard(Path.join([bundle, "frames", "*.png"]))
    assert frames != []
    assert length(frames) < length(samples)
    assert Enum.any?(frames, &(Path.basename(&1) =~ "first"))
    assert Enum.any?(frames, &(Path.basename(&1) =~ "last"))
  end

  @tag :tmp_dir
  test "halt while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Fake.calls() end)

    assert :ok = Worker.halt(worker)
    assert {:key_up, "space"} in Fake.calls()
  end

  @tag :tmp_dir
  test "a capture failure while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} =
      Fake.start_link(%{capture: [{:ok, game}, {:ok, game}, {:error, :boom}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Fake.calls() end)

    wait_for(&released_after_holding?/0)
  end

  describe "manual assist (the safe default)" do
    setup do
      Settings.put(:mini_game_mode, "manual_assist")
      :ok
    end

    @tag :tmp_dir
    test "never presses Space — the human plays, the bot only watches", %{tmp: tmp} do
      game = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
      {:ok, _} = Fake.start_link(%{capture: List.duplicate({:ok, game}, 30)})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

      Process.sleep(300)

      refute {:key_down, "space"} in Fake.calls()
      assert :ok = Worker.halt(worker)
      refute {:key_down, "space"} in Fake.calls()
    end

    @tag :tmp_dir
    test "entering releases Space preventively, before the first play tick", %{tmp: tmp} do
      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      {:ok, _} = Fake.start_link(%{capture: List.duplicate({:ok, game}, 10)})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
      wait_for(fn -> {:key_up, "space"} in Fake.calls() end)

      calls = Fake.calls()
      release = Enum.find_index(calls, &(&1 == {:key_up, "space"}))

      strip =
        Enum.find_index(calls, fn
          {:capture, _region, "mini_game_strip.png"} -> true
          _other -> false
        end)

      assert release != nil
      assert strip == nil or release < strip
    end

    @tag :tmp_dir
    test "holds the peers through the :mini_game fact and frees them on exit", %{tmp: tmp} do
      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      calm = png!(tmp, "calm.png", false)

      {:ok, _} =
        Fake.start_link(%{capture: List.duplicate({:ok, game}, 6) ++ [{:ok, calm}]})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
      wait_for(fn -> Pokex.Perception.mini_game_playing?() end)

      assert_receive {:mini_game, %{state: :watching, transition: :left}}, 2_000
      wait_for(fn -> not Pokex.Perception.mini_game_playing?() end)
      assert Pokex.Perception.mini_game_gate() == :ok
    end

    @tag :tmp_dir
    test "alerts, and keeps alerting while the game waits", %{tmp: tmp} do
      Settings.put(:mini_game_manual_alert_ms, 30)

      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      {:ok, _} = Fake.start_link(%{capture: List.duplicate({:ok, game}, 30)})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)

      assert_receive {:mini_game_alert, %{mode: :manual_assist, text: text}}, 1_000
      assert text =~ "aguardando resolução manual"
      assert_receive {:mini_game_alert, _repeat}, 1_000

      assert %{awaiting_manual?: true, mode_label: "assistência manual"} = Worker.status(worker)
      assert :ok = Worker.halt(worker)
    end

    @tag :tmp_dir
    test "records a full bundle for a game played by hand", %{tmp: tmp} do
      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      calm = png!(tmp, "calm.png", false)

      {:ok, _} =
        Fake.start_link(%{capture: List.duplicate({:ok, game}, 8) ++ [{:ok, calm}]})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :watching, transition: :left}}, 2_000

      assert [bundle] = Path.wildcard(Path.join([tmp, "exports", "mini_game-*"]))
      summary = bundle |> Path.join("summary.json") |> File.read!() |> JSON.decode!()

      assert summary["mode"] == "manual_assist"
      assert summary["key_down"] == 0
      assert summary["ticks"] >= 5
      assert is_number(summary["error_mean"])
    end
  end

  @tag :tmp_dir
  test "auto mode does not raise the manual alert", %{tmp: tmp} do
    Settings.put(:mini_game_manual_alert_ms, 10)
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    {:ok, _} = Fake.start_link(%{capture: List.duplicate({:ok, game}, 20)})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    refute_receive {:mini_game_alert, _payload}, 200
    assert %{awaiting_manual?: false, mode: :auto} = Worker.status(worker)
  end

  defp released_after_holding? do
    calls = Fake.calls()

    case Enum.find_index(calls, &(&1 == {:key_down, "space"})) do
      nil -> false
      down -> calls |> Enum.drop(down) |> Enum.any?(&(&1 == {:key_up, "space"}))
    end
  end

  defp wait_for(fun, tries \\ 100) do
    cond do
      fun.() ->
        :ok

      tries == 0 ->
        flunk("condition never became true; calls: #{inspect(Fake.calls())}")

      true ->
        Process.sleep(10)
        wait_for(fun, tries - 1)
    end
  end

  defp png!(dir, name, with_bar?),
    do: Pokex.PngFixtures.mini_game_scene!(dir, name, bar_x: if(with_bar?, do: 104..116))

  defp png_with_bar_at!(dir, name, bar_x_range),
    do: Pokex.PngFixtures.mini_game_scene!(dir, name, bar_x: bar_x_range)

  defp play_png!(dir, name, opts),
    do:
      Pokex.PngFixtures.mini_game_scene!(dir, name,
        fish: Keyword.fetch!(opts, :fish),
        capsule: Keyword.fetch!(opts, :capsule)
      )
end
