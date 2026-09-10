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
    # o fato do vigia é global e atravessa arquivos de teste
    :ets.delete(:pokex_world, :special)
    on_exit(fn -> Pokex.TestHome.restore() end)

    SettingsStash.stash!(
      shiny_guard_enabled: false,
      engine_capture_hold_ms: 6_000,
      ball_key: "f1",
      ball_types: [%{"key" => "f1", "name" => "Poké Ball"}, %{"key" => "f3", "name" => "Ultra"}]
      # a REALIDADE dele: a única regra de bola é de um pokémon de água da rota
      # de pesca, e nenhum shiny de caverna casa com ela
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

  # A QUARTA PORTEIRA. `armed/0` diz "ligada e provada"; o caçador ainda exige
  # que a prova seja DESTE quadro. Mexer no raio da busca aposenta todas as
  # provas de uma vez, o caçador passa a varrer com nenhuma regra, e este cartão
  # dizia "armado" a noite inteira.
  test "a proof measured on another frame is the step, not a green seal" do
    # com uma calibração de verdade a região tem um valor de verdade, e a prova
    # gravada noutra não casa com ela
    Pokex.Calibration.save(%Pokex.Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 40,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500},
      player_point: {500, 350}
    })

    slug = teach("Charizard preto")
    :ok = ColorRules.mark_proven(slug, 10, [], {0, 0, 10, 10}, 1.0)

    check = ShinyReadiness.check()

    refute ShinyReadiness.ready?(check)
    assert [%{key: :stale_proof, text: text, link: "medir o chão"}] = check.gaps
    assert text =~ "Charizard preto"
    assert text =~ "outro quadro"
  end

  # …e a mesma região com OUTRA ampliação também não serve: as caixas do HUD são
  # pixels do quadro e o chão é uma contagem, e os dois quadruplicam.
  test "the same region at another scale is not the same proof" do
    calib = %Pokex.Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 40,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500},
      player_point: {500, 350}
    }

    Pokex.Calibration.save(calib)
    {:ok, regiao} = Pokex.Bots.Catcher.SpotScan.region(calib)

    slug = teach("Charizard preto")
    :ok = ColorRules.mark_proven(slug, 10, [], regiao, 1.0)

    assert [%{key: :stale_proof}] = ShinyReadiness.check().gaps

    # provada na ampliação de agora, o passo sai da frente
    :ok = ColorRules.mark_proven(slug, 10, [], regiao, 2.0)
    assert [%{key: :guard_off}] = ShinyReadiness.check().gaps
  end

  # …E A AMPLIAÇÃO É A DA FOTO, não a da calibração. O backend de captura decide
  # a da foto, e usando a calibrada o cartão mandaria medir o chão pra sempre
  # enquanto a varredura corre feliz com a mesma prova.
  test "the scale that counts is the one the watcher's photo had" do
    calib = %Pokex.Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 40,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500},
      player_point: {500, 350}
    }

    Pokex.Calibration.save(calib)
    {:ok, regiao} = Pokex.Bots.Catcher.SpotScan.region(calib)

    slug = teach("Charizard preto")
    :ok = ColorRules.mark_proven(slug, 10, [], regiao, 1.0)

    # sem vigia rodando, o cartão só tem a calibrada (2.0) e recusa a prova
    assert [%{key: :stale_proof}] = ShinyReadiness.check().gaps

    # com o vigia dizendo que a foto dele veio a 1.0, a prova serve
    Pokex.Perception.WorldState.put(
      :special,
      %{especial?: false, vistos: [], scale: 1.0},
      System.monotonic_time(:millisecond)
    )

    assert [%{key: :guard_off}] = ShinyReadiness.check().gaps
  end

  # PROVADA, ARMADA E MUDA. O tom ensinado era do cenário, então o chão medido
  # subiu junto e o método deixou um gatilho que nenhum bicho alcança — 14,6
  # tiles de cor sólida. A regra dizia "provada" e o cartão dizia "a cor está
  # pronta" enquanto o caçador varria a noite sem chance de disparar.
  test "a trigger no creature can reach is the step, before the switch" do
    slug = teach("Charizard preto")
    :ok = ColorRules.update(slug, %{"min_px" => 332_835})
    :ok = ColorRules.mark_proven(slug, 110_945)

    check = ShinyReadiness.check()

    refute ShinyReadiness.ready?(check)
    assert [%{key: :unreachable, text: text, href: "/calibration"}] = check.gaps
    assert text =~ "Charizard preto"
    assert text =~ "tiles"
    assert text =~ "cenário"
  end

  test "one reachable rule is enough to move on to the switch" do
    muda = teach("Charizard preto")
    :ok = ColorRules.update(muda, %{"min_px" => 332_835})
    :ok = ColorRules.mark_proven(muda, 110_945)

    boa = teach("Electrode verde")
    :ok = ColorRules.update(boa, %{"min_px" => 900})
    :ok = ColorRules.mark_proven(boa, 300)

    assert [%{key: :guard_off}] = ShinyReadiness.check().gaps
  end

  test "with nothing taught the first step is teaching the colour" do
    check = ShinyReadiness.check()

    refute ShinyReadiness.ready?(check)
    assert keys(check.gaps) == [:no_rule]
    assert [%{href: "/calibration", link: "ensinar a cor"}] = check.gaps
    assert check.armed == []
    # one step at a time: no point naming the ball for a shiny that cannot be seen
    assert check.notes == []
  end

  # DUAS REGRAS, A CERTA PELO NOME. Com uma ligada sem prova e outra provada e
  # desligada, o passo era "ligar a regra" mas o nome era o da primeira da
  # lista — que já estava ligada.
  test "with two half-done rules the step names the one it is talking about" do
    proven = teach("Charizard preto")
    ColorRules.mark_proven(proven, 100)
    ColorRules.set_enabled(proven, false)
    teach("Electrode verde")

    check = ShinyReadiness.check()

    assert [%{key: :disabled, text: text, link: "ligar a regra"}] = check.gaps
    assert text =~ "Charizard preto"
    refute text =~ "Electrode verde"
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

  # A bola do shiny agora é escolhida NA ENTRADA do acervo, ao lado da foto que
  # o reconhece — não numa lista de regras à parte.
  test "the shiny choosing its own ball clears the ball note" do
    slug = teach()
    _ = slug
    :ok = ColorRules.mark_proven(slug, 3)
    Pokex.Settings.put(:shiny_guard_enabled, true)
    Pokex.Settings.put(:ball_types, [%{"key" => "f3", "name" => "Ultra"}])

    {:ok, 1} =
      Pokex.Bots.Catcher.CorpseLibrary.add("Electrode shiny", %Pokex.Vision.Frame{
        width: 4,
        height: 4,
        rgba: :binary.copy(<<40, 200, 190, 255>>, 16)
      })

    :ok = Pokex.Bots.Catcher.CorpseLibrary.set_ball("electrode-shiny", "f3")

    assert ShinyReadiness.check().notes == []
  end
end
