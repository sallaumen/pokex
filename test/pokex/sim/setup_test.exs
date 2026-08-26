defmodule Pokex.Sim.SetupTest do
  use ExUnit.Case, async: false

  alias Pokex.Sim.Setup
  alias Pokex.Sim.World

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-sim-setup-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Pokex.TestHome.restore()
      File.rm_rf!(tmp)
    end)

    :ok
  end

  test "nothing saved means the defaults, not an error" do
    assert Setup.read() == %{}
  end

  test "what he calibrates survives a restart, which is the whole point of calibrating" do
    Setup.write(%{mob_hp: 480, ms_per_tile: 290, damage_spread_pct: 25})

    saved = Setup.read()

    assert saved.mob_hp == 480
    assert saved.ms_per_tile == 290
    assert saved.damage_spread_pct == 25
  end

  test "a band per key goes to disk and comes back as a tuple" do
    Setup.write(%{skill_damage: %{"3" => {28, 41}}})

    assert Setup.read().skill_damage == %{"3" => {28, 41}}
  end

  test "the marked combo rides along with the rest" do
    Setup.write(%{kill_combo: ["3", "4", "5"]})

    assert Setup.read().kill_combo == ["3", "4", "5"]
  end

  # The whitelist is the point: `own_row?` is an open measurement between him and
  # a live reading, and a stray key in this file silently redefining it would
  # make a scenario answer about a different world while still calling itself by
  # name.
  test "a knob that is not his to set is dropped, not merged" do
    Setup.write(%{mob_hp: 300, own_row?: true})

    saved = Setup.read()

    assert saved.mob_hp == 300
    refute Map.has_key?(saved, :own_row?)
  end

  # `nest_size` used to be on the wrong side of that line, for the right reason:
  # it PINS every scenario's pile at once. It moved on 2026-08-26 because that
  # is exactly the crank he asked for — "a meta é ver quanto inimigo a gente
  # consegue surrar ao mesmo tempo... sem limites pra chegar no máximo de mortos
  # por minuto". The danger did not go away, it got a label on the form instead.
  test "a pilha fixa É dele pra mexer, apesar de valer pra todo cenário" do
    Setup.write(%{nest_size: 12, nest_radius: 2, respawn_ms: 15_000})

    saved = Setup.read()

    assert saved.nest_size == 12
    assert saved.nest_radius == 2
    assert saved.respawn_ms == 15_000
  end

  @tag :capture_log
  test "a corrupt file loses the calibration and not the simulator" do
    File.write!(Setup.path(), "isso não é json {{{")

    assert Setup.read() == %{}
  end

  test "junk values are ignored one by one, so one bad field does not sink the rest" do
    File.write!(Setup.path(), JSON.encode!(%{"mob_hp" => 250, "ms_per_tile" => "rápido"}))

    saved = Setup.read()

    assert saved.mob_hp == 250
    refute Map.has_key?(saved, :ms_per_tile)
  end

  test "what he saves is what the world runs on" do
    Setup.write(%{mob_hp: 250, mob_ms_per_tile: 999})
    knobs = Setup.read()

    world = World.new(route(), knobs: Map.merge(knobs, %{nest_size: 1, nest_radius: 0}))

    assert hd(world.mobs).max_hp == 250
    assert world.knobs.mob_ms_per_tile == 999
  end

  defp route do
    %Pokex.Bots.Cavebot.Route{
      name: "setup",
      waypoints:
        for {x, y, z} <- [{100, 200, 5}, {110, 200, 5}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: 2_000,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end
end
