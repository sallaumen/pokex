defmodule Pokex.Bots.Catcher.NarrationTest do
  @moduledoc """
  The catcher's sentences, judged without a GenServer.

  These are the lines he reads the next morning: `worker_test.exs` asserts
  several of them letter by letter through the live worker, and this file
  pins the same phrases at their source.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Narration

  describe "hold_reason/1" do
    setup do
      %{
        facts: %{
          mini_game?: false,
          still?: true,
          road_held?: true,
          screen_clear?: true,
          fight?: false,
          capture_enabled?: true
        }
      }
    end

    test "the mini-game comes first", %{facts: facts} do
      assert Narration.hold_reason(%{facts | mini_game?: true, fight?: true}) ==
               "mini-game em jogo"
    end

    test "a hunt with the road walking says so before the fight", %{facts: facts} do
      assert Narration.hold_reason(%{facts | still?: false, road_held?: false, fight?: true}) ==
               "andando — a bola sai quando a rota parar"
    end

    test "a hunt standing still with the living on screen waits for the list", %{facts: facts} do
      assert Narration.hold_reason(%{facts | still?: false, screen_clear?: false}) ==
               "bicho vivo na tela — a bola espera a lista zerar"
    end

    test "the fight", %{facts: facts} do
      assert Narration.hold_reason(%{facts | fight?: true}) == "esperando fim da luta"
    end

    # O portão que ficou fechado um dia inteiro sem dizer o nome (30/07).
    test "capture off names itself", %{facts: facts} do
      assert Narration.hold_reason(%{facts | capture_enabled?: false}) ==
               "captura DESLIGADA — só saque"
    end

    test "nothing holding", %{facts: facts} do
      refute Narration.hold_reason(facts)
    end

    # O modo Parado não olha pra estrada nem pra lista: lá a varredura manda.
    test "the still mode ignores the road and the list", %{facts: facts} do
      refute Narration.hunt_hold(%{facts | road_held?: false, screen_clear?: false})
    end
  end

  describe "cue/1" do
    test "a closed scan is the debug line" do
      assert {:debug, text} = Narration.cue(nil)
      assert text =~ "a varredura está fechada agora"
    end

    test "a round that closes without a corpse is the rule, not the news" do
      assert {:debug, "🎯 hora da bola — varri e não achei corpo nenhum no chão"} =
               Narration.cue(%{corpses: []})
    end

    test "every corpse admitted" do
      obs = obs_with(corpses: [{10, 10}], spots: [{10, 10}], spot_radius: 40)

      assert {:macro, "🎯 hora da bola — 1 corpo(s) no chão"} = Narration.cue(obs)
    end

    test "stains far from the fight name themselves" do
      obs = obs_with(corpses: [{10, 10}], spots: [{900, 900}], spot_radius: 40)

      assert {:macro, text} = Narration.cue(obs)
      assert text =~ "1 mancha(s) com cor de corpo, nenhuma onde o olho viu um bicho de pé"
    end

    test "part admitted, part not" do
      obs = obs_with(corpses: [{10, 10}, {900, 900}], spots: [{10, 10}], spot_radius: 40)

      assert {:macro, text} = Narration.cue(obs)
      assert text =~ "1 corpo(s) onde um bicho estava de pé (1 mancha(s) longe da luta, sem bola)"
    end
  end

  describe "scan/1" do
    test "blindness survives a restart" do
      assert {:macro, "🔎 cego: sem calibração"} =
               Narration.scan(%{scanning?: false, reason: :no_calibration})
    end

    test "the routine line carries the best candidate's distance to the threshold" do
      assert {:debug, text} =
               Narration.scan(%{
                 scanning?: true,
                 windows: 12,
                 region: {0, 0, 300, 200},
                 best: %{name: "Golem", score: 0.71, point: {40, 50}},
                 threshold: 0.8
               })

      assert text == "🔎 varri 12 janelas (300×200) · melhor: Golem 0.71 ✗ em 40,50 (limiar 0.80)"
    end

    test "an empty library says so" do
      assert {:debug, text} = Narration.scan(%{scanning?: true, windows: 3, best: nil})
      assert text =~ "acervo vazio"
    end

    test "no reading, no line" do
      assert Narration.scan(nil) == nil
      assert Narration.scan(%{}) == nil
    end
  end

  describe "falls/1 and anchor_ball/2" do
    test "the fall is the line he looks for when the ball did not go out" do
      assert ["🎯 Shiny Golem caiu em 100,200 — a barra sumiu; a bola vai lá na hora da bola"] =
               Narration.falls([%{name: "Shiny Golem", screen: {100, 200}}])
    end

    test "the anchor's ball says how old the body is" do
      candidate = %{name: "Shiny Golem", point: {100, 200}, fallen_at: 1_000}

      assert Narration.anchor_ball(candidate, 4_500) ==
               "🌟 bola na âncora do Shiny Golem em 100,200 — caiu há 3s"
    end
  end

  describe "recognized/1" do
    # Dois caminhos, duas contas: a foto sabe semelhança, a cor sabe pixels.
    test "the photo's likeness" do
      assert Narration.recognized(%{name: "Golem", score: 0.91}) == "🎯 Golem reconhecido (91%)"
    end

    test "the colour's pixels" do
      assert Narration.recognized(%{name: "Golem", px: 1_200}) ==
               "🎯 Golem reconhecido pela cor (1200 px)"
    end

    test "neither" do
      assert Narration.recognized(%{name: "Golem"}) == "🎯 Golem reconhecido"
    end
  end

  describe "corpse_library/1" do
    test "an empty library is a siren, not a whisper" do
      assert {:alarm, text} = Narration.corpse_library(0)
      assert text =~ "acervo de corpos VAZIO"
    end

    # "N pokémon ensinados", não "N corpos" — foi lido como "10 corpos na tela".
    test "a taught library counts species, not corpses on screen" do
      assert {:log, "🎯 mira pronta — 10 pokémon ensinado(s) no acervo da calibração"} =
               Narration.corpse_library(10)
    end
  end

  defp obs_with(fields) do
    Enum.into(fields, %{scanning?: true, known: %{}, captured_at: 0})
  end
end
