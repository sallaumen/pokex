defmodule Pokex.Bots.ShinyReadinessTest do
  @moduledoc """
  The four steps between him and a shiny, in the order they have to happen —
  and the two that only make the catch worse.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.ShinyReadiness
  alias Pokex.SettingsStash
  alias Pokex.Vision.ColorRules

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    :persistent_term.erase({ColorRules, :cache})
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(
      shiny_guard_enabled: false,
      engine_capture_hold_ms: 6_000,
      ball_key: "f1",
      ball_types: [%{"key" => "f1", "name" => "Poké Ball"}, %{"key" => "f3", "name" => "Ultra"}],
      # a REALIDADE dele: a única regra de bola é de um pokémon de água da rota
      # de pesca, e nenhum shiny de caverna casa com ela
      ball_rules: [%{"key" => "f1", "trigger" => %{"kind" => "species", "value" => "Krabby"}}]
    )

    :ok
  end

  defp teach(name \\ "Electrode shiny") do
    {:ok, %{"slug" => slug}} =
      ColorRules.add(%{
        "name" => name,
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
        "min_px" => 50
      })

    slug
  end

  defp keys(steps), do: Enum.map(steps, & &1.key)

  test "with nothing taught the first step is teaching the colour" do
    check = ShinyReadiness.check()

    refute ShinyReadiness.ready?(check)
    assert keys(check.gaps) == [:no_rule]
    assert [%{href: "/calibration", link: "ensinar a cor"}] = check.gaps
    assert check.armed == []
    # one step at a time: no point naming the ball for a shiny that cannot be seen
    assert check.notes == []
  end

  test "a rule saved and never proven asks for the floor, by name" do
    teach()

    check = ShinyReadiness.check()

    assert keys(check.gaps) == [:unproven]
    assert hd(check.gaps).text =~ "Electrode shiny"
    assert hd(check.gaps).link == "medir o chão"
  end

  test "a proven rule switched off asks to switch it on" do
    slug = teach()
    :ok = ColorRules.mark_proven(slug, 3)
    :ok = ColorRules.set_enabled(slug, false)

    assert keys(ShinyReadiness.check().gaps) == [:disabled]
  end

  test "the colour ready and the guard off is the last blocking step" do
    slug = teach()
    :ok = ColorRules.mark_proven(slug, 3)

    check = ShinyReadiness.check()

    assert keys(check.gaps) == [:guard_off]
    assert hd(check.gaps).href == "/config/editores"
    assert check.armed == ["Electrode shiny"]
  end

  test "guard armed over a proven rule is ready, and says whose colour it watches" do
    slug = teach()
    :ok = ColorRules.mark_proven(slug, 3)
    Pokex.Settings.put(:shiny_guard_enabled, true)

    check = ShinyReadiness.check()

    assert ShinyReadiness.ready?(check)
    assert check.armed == ["Electrode shiny"]
  end

  # The two that cost a shiny instead of losing it.
  test "ready but with the default ball and no hold, both notes are raised" do
    slug = teach()
    :ok = ColorRules.mark_proven(slug, 3)
    Pokex.Settings.put(:shiny_guard_enabled, true)
    Pokex.Settings.put(:engine_capture_hold_ms, 0)

    check = ShinyReadiness.check()

    assert ShinyReadiness.ready?(check)
    assert keys(check.notes) == [:default_ball, :no_hold]
    assert hd(check.notes).text =~ "Poké Ball"
  end

  test "a ball rule naming the shiny clears the ball note" do
    slug = teach()
    :ok = ColorRules.mark_proven(slug, 3)
    Pokex.Settings.put(:shiny_guard_enabled, true)

    Pokex.Settings.put(:ball_rules, [
      %{"key" => "f3", "trigger" => %{"kind" => "species", "value" => "Electrode shiny"}}
    ])

    assert ShinyReadiness.check().notes == []
  end
end
