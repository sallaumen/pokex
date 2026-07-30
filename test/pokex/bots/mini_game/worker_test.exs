defmodule Pokex.Bots.MiniGame.WorkerTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.MiniGame.Worker
  alias Pokex.Perception.WorldState
  alias Pokex.{Calibration, Settings, SettingsStash}

  setup %{tmp_dir: tmp} do
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
      arena_region: {0, 0, 220, 220},
      # A mão manda (2026-07-30): sem marcação, a busca vira uma caixa CENTRAL
      # dentro da arena — mas estes testes desenham o jogo na arena INTEIRA,
      # então a marcam como faixa (o que o Lucas faz na calibração real).
      mini_game_region: {0, 0, 220, 220},
      neutral_point: {100, 100}
    })

    %{tmp: tmp}
  end

  @tag :tmp_dir
  test "announces enter and exit transitions on the panel topic", %{tmp: tmp} do
    game = png!(tmp, "mini-game.png", true)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game_log, :macro, enter_log}, 1_000
    assert enter_log =~ "detectado"

    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  test "a lingering fake track WITHOUT the capsule ends the game (the post-win hang)", %{
    tmp: tmp
  } do
    # Real hang (2026-07-20): after a WIN the overlay closed, but the world
    # behind the strip held a >=60-row dark column — Track kept reading a
    # "track" + a clutter-fish, every tick came back :present, the exit streak
    # never fired and the whole bot stayed self-held until a manual Stop. The
    # capsule is the player's OWN presence: in real play its blue pokes out on
    # virtually every tick (measured 86/86 frames on the live traces), so
    # present readings WITHOUT any blue for N consecutive ticks mean the
    # overlay is functionally gone.
    Settings.put(:mini_game_no_capsule_exit_ticks, 3)

    game = png!(tmp, "mini-game.png", true)
    fishy_world = play_png!(tmp, "fishy-world.png", fish: 100..131, capsule: nil)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, fishy_world}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})
    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  test "a game that outlives the hard duration cap is force-ended", %{tmp: tmp} do
    # Backstop for ANY unseen wedge (same philosophy as hook_hold_max_ms): no
    # real game lasts minutes, so a "game" that does is a stuck reading — end
    # it and let the watcher re-enter if the overlay is genuinely back.
    Settings.put(:mini_game_max_game_ms, 1)

    game = png!(tmp, "mini-game.png", true)
    playing = play_png!(tmp, "playing.png", fish: 100..131, capsule: 140..160)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, playing}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})
    assert :ok = Worker.run(worker)

    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert :ok = Worker.halt(worker)
  end

  @tag :tmp_dir
  test "enters the game when the bar sits right of the character, like the real overlay", %{
    tmp: tmp
  } do
    # Real geometry: the game draws the bar ~40px right of the sprite. Player
    # anchor falls back to the arena center (110); the bar is at 144..156. The
    # seeded anchor tolerance must absorb the offset.
    game = png_with_bar_at!(tmp, "offset-game.png", 144..156)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  @tag :tmp_dir
  test "a dedicated mini_game_region owns the watch: that region is captured and searched whole",
       %{tmp: tmp} do
    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | mini_game_region: {140, 20, 60, 180}})

    game = png!(tmp, "mini-game.png", true)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    assert {:capture, {140, 20, 60, 180}, "mini_game.png"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "anchors the bar search at the CALIBRATED player point when one is saved", %{tmp: tmp} do
    # Tight tolerance so only the calibrated anchor (not the arena center) can
    # accept the offset bar — proves the worker prefers calibration.player_point.
    Settings.put(:mini_game_anchor_tolerance, 20)

    {:ok, calib} = Calibration.load()
    Calibration.save(%{calib | player_point: {150, 110}})

    game = png_with_bar_at!(tmp, "calibrated-game.png", 144..156)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
  end

  @tag :tmp_dir
  test "publishes the :mini_game fact on the blackboard across enter, exit and halt", %{tmp: tmp} do
    game = png!(tmp, "mini-game.png", true)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}, {:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    refute Pokex.Perception.mini_game_playing?()

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> Pokex.Perception.mini_game_playing?() end)

    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000
    wait_for(fn -> not Pokex.Perception.mini_game_playing?() end)

    # back in: halt must also clear the fact
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> Pokex.Perception.mini_game_playing?() end)
    assert :ok = Worker.halt(worker)
    refute Pokex.Perception.mini_game_playing?()
  end

  # --- the playing loop -------------------------------------------------------

  @tag :tmp_dir
  test "plays: fish above the capsule -> holds Space (key_down, never Body)", %{tmp: tmp} do
    game = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    # while playing, captures shrink to the armed strip around the bar
    # (bar center 110 in the 220pt arena -> strip 70..150, full height)
    assert {:capture, {70, 0, 80, 220}, "mini_game_strip.png"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "plays: fish drops below the capsule -> releases Space", %{tmp: tmp} do
    hold = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
    release = play_png!(tmp, "release.png", fish: 170..184, capsule: 120..134)

    # tick 1 watches+enters, tick 2 plays the hold strip, tick 3 the release
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, hold}, {:ok, hold}, {:ok, release}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    # The entry guard already sent one preventive key_up BEFORE the first tick,
    # so the release we are proving must be a LATER one — after the key_down.
    wait_for(&released_after_holding?/0)
  end

  @tag :tmp_dir
  test "leaving the game always releases Space, even if already released", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    calm = png!(tmp, "calm.png", false)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, calm}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :watching, transition: :left}}, 1_000

    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "re-running the worker mid-game releases Space (panel Start while playing)", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    assert :ok = Worker.run(worker)
    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "a finished game writes a complete evidence bundle to exports", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    calm = png!(tmp, "calm.png", false)

    # several play ticks (a bundle needs >= 5 samples), then the overlay vanishes
    captures = List.duplicate({:ok, game}, 8) ++ [{:ok, calm}]
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: captures})

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
    # the entry guard's preventive release is recorded, whatever it returned
    assert [_entry_release | _] = summary["safety_key_ups"]

    samples =
      bundle
      |> Path.join("samples.jsonl")
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)

    assert length(samples) == summary["samples_recorded"]

    # every tick carries its timing and its pixel evidence...
    assert Enum.all?(samples, fn sample ->
             is_number(sample["cap_ms"]) and is_number(sample["tick_ms"]) and
               is_number(sample["dark_px"]) and is_number(sample["blue_px"]) and
               is_boolean(sample["hold"]) and is_binary(sample["read"])
           end)

    # ...and a READABLE tick carries the full reading it flew on
    readable = Enum.filter(samples, &(&1["read"] == "ok"))
    assert readable != []

    assert Enum.all?(readable, fn sample ->
             is_number(sample["fish_y"]) and is_number(sample["bar_y"]) and
               is_number(sample["fish_aim"]) and is_number(sample["fish_vy"]) and
               is_number(sample["bar_vy"]) and is_number(sample["top"]) and
               is_number(sample["bottom"]) and is_boolean(sample["accepted"]) and
               sample["bar_source"] in ["blue", "fish"]
           end)

    # frames are EVIDENCE, not a screen recording: far fewer than one per tick
    frames = Path.wildcard(Path.join([bundle, "frames", "*.png"]))
    assert frames != []
    assert length(frames) < length(samples)
    assert Enum.any?(frames, &(Path.basename(&1) =~ "first"))
    assert Enum.any?(frames, &(Path.basename(&1) =~ "last"))
  end

  @tag :tmp_dir
  test "halt while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    assert :ok = Worker.halt(worker)
    assert {:key_up, "space"} in Pokex.Rig.Fake.calls()
  end

  @tag :tmp_dir
  test "a capture failure while holding releases Space", %{tmp: tmp} do
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)

    # tick 1 enters, tick 2 holds, tick 3 fails blind -> must release
    {:ok, _} =
      Pokex.Rig.Fake.start_link(%{capture: [{:ok, game}, {:ok, game}, {:error, :boom}]})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
    wait_for(fn -> {:key_down, "space"} in Pokex.Rig.Fake.calls() end)

    # a release AFTER the hold — not the entry guard's preventive one
    wait_for(&released_after_holding?/0)
  end

  describe "assistência manual (o padrão seguro)" do
    setup do
      Settings.put(:mini_game_mode, "manual_assist")
      :ok
    end

    @tag :tmp_dir
    test "never presses Space — Lucas plays, the bot only watches", %{tmp: tmp} do
      # A fish far above the capsule: in :auto this frame holds Space on the
      # very first play tick. Here it must never be pressed, no matter how long.
      game = play_png!(tmp, "hold.png", fish: 40..54, capsule: 100..114)
      {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 30)})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

      # let a good number of play ticks go by (20ms each in this suite)
      Process.sleep(300)

      refute {:key_down, "space"} in Pokex.Rig.Fake.calls()
      assert :ok = Worker.halt(worker)
      refute {:key_down, "space"} in Pokex.Rig.Fake.calls()
    end

    @tag :tmp_dir
    test "entering releases Space preventively, before the first play tick", %{tmp: tmp} do
      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 10)})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000
      wait_for(fn -> {:key_up, "space"} in Pokex.Rig.Fake.calls() end)

      calls = Pokex.Rig.Fake.calls()
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
        Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 6) ++ [{:ok, calm}]})

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
      {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 30)})

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
    test "records a full bundle for the game Lucas played by hand", %{tmp: tmp} do
      game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
      calm = png!(tmp, "calm.png", false)

      {:ok, _} =
        Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 8) ++ [{:ok, calm}]})

      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
      worker = start_supervised!({Worker, name: nil})

      assert :ok = Worker.run(worker)
      assert_receive {:mini_game, %{state: :watching, transition: :left}}, 2_000

      assert [bundle] = Path.wildcard(Path.join([tmp, "exports", "mini_game-*"]))
      summary = bundle |> Path.join("summary.json") |> File.read!() |> JSON.decode!()

      assert summary["mode"] == "manual_assist"
      assert summary["key_down"] == 0
      assert summary["ticks"] >= 5
      # the reading pipeline ran in full even though nothing was actuated
      assert is_number(summary["error_mean"])
    end
  end

  @tag :tmp_dir
  test "auto mode does not raise the manual alert", %{tmp: tmp} do
    Settings.put(:mini_game_manual_alert_ms, 10)
    game = play_png!(tmp, "game.png", fish: 40..54, capsule: 100..114)
    {:ok, _} = Pokex.Rig.Fake.start_link(%{capture: List.duplicate({:ok, game}, 20)})

    Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())
    worker = start_supervised!({Worker, name: nil})

    assert :ok = Worker.run(worker)
    assert_receive {:mini_game, %{state: :playing, transition: :entered}}, 1_000

    refute_receive {:mini_game_alert, _payload}, 200
    assert %{awaiting_manual?: false, mode: :auto} = Worker.status(worker)
  end

  defp released_after_holding? do
    calls = Pokex.Rig.Fake.calls()

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
        flunk("condition never became true; calls: #{inspect(Pokex.Rig.Fake.calls())}")

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
