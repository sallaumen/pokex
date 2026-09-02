defmodule Pokex.Bots.PlayerSupport.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.PlayerSupport.Logic

  describe "potion_wanted?/1" do
    defp potion_input(overrides) do
      %{
        hp_pct: 100,
        prev_hp_pct: 0,
        threshold_pct: 70,
        enabled?: true,
        cooldown_ms: 10_000,
        last_potion_at: nil,
        now: 50_000
      }
      |> Map.merge(Map.new(overrides))
    end

    test "wants a potion the first time HP drops below the potion threshold" do
      assert Logic.potion_wanted?(potion_input(hp_pct: 69))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30))
    end

    test "holds at or above the threshold, on nil HP, or when disabled" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 70))
      refute Logic.potion_wanted?(potion_input(hp_pct: 100))
      refute Logic.potion_wanted?(potion_input(hp_pct: nil))
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, enabled?: false))
    end

    test "the heal-channel cooldown blocks a second sip within the window" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, last_potion_at: 45_000, now: 50_000))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30, last_potion_at: 40_000, now: 50_000))
    end

    test "one garbage frame never chugs a potion: the previous read must agree" do
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: nil))
      refute Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: 95))
      assert Logic.potion_wanted?(potion_input(hp_pct: 30, prev_hp_pct: 60))
    end
  end

  # "Quando o pokémon chega abaixo de 85% da HP quer dizer que já tem gente
  # batendo nele o suficiente e vale usar o buff de defesa" (02/09).
  # A aura ANTES da corrente: só com a pilha fechando, ligada, e fora do cooldown.
  describe "mob_shield_wanted?/1" do
    @pilha %{
      enabled?: true,
      phase: :bunching,
      cooldown_ms: 3_000,
      last_shield_at: nil,
      now: 10_000
    }

    test "com a pilha fechando e a aura fora do cooldown, quer" do
      assert Logic.mob_shield_wanted?(@pilha)
      assert Logic.mob_shield_wanted?(%{@pilha | last_shield_at: 6_000})
    end

    test "fora do bunching, desligada ou esfriando, não quer" do
      refute Logic.mob_shield_wanted?(%{@pilha | phase: :travelling})
      refute Logic.mob_shield_wanted?(%{@pilha | phase: :engaged})
      refute Logic.mob_shield_wanted?(%{@pilha | phase: nil})
      refute Logic.mob_shield_wanted?(%{@pilha | enabled?: false})
      refute Logic.mob_shield_wanted?(%{@pilha | last_shield_at: 8_000})
    end
  end

  describe "shield_wanted?/1" do
    @escudo %{
      hp_pct: 80,
      prev_hp_pct: 82,
      threshold_pct: 85,
      enabled?: true,
      cooldown_ms: 3_000,
      last_shield_at: nil,
      now: 10_000
    }

    test "duas leituras abaixo de 85 pedem a aura" do
      assert Logic.shield_wanted?(@escudo)
    end

    test "uma leitura só não pede — um quadro ruim não gasta cooldown" do
      refute Logic.shield_wanted?(%{@escudo | prev_hp_pct: 95})
    end

    test "acima do limiar, ou desligada, não pede" do
      refute Logic.shield_wanted?(%{@escudo | hp_pct: 90})
      refute Logic.shield_wanted?(%{@escudo | enabled?: false})
    end

    test "o anti-spam segura a segunda dentro do cooldown" do
      refute Logic.shield_wanted?(%{@escudo | last_shield_at: 8_500})
      assert Logic.shield_wanted?(%{@escudo | last_shield_at: 6_000})
    end
  end

  describe "revive/1" do
    test "one press is the whole revive" do
      assert Logic.revive(%{rescue_key: "f4", step_ms: 40}) == [:still, {:press, "f4"}]
    end

    test "with stun_steps: the stun comes first, in the same atomic list" do
      config = %{
        rescue_key: "f4",
        step_ms: 40,
        stun_steps: [{:press, "1"}, {:wait, 500}, {:press, "2"}]
      }

      assert Logic.revive(config) == [
               :still,
               {:press, "1"},
               {:wait, 500},
               {:press, "2"},
               {:wait, 40},
               {:press, "f4"}
             ]
    end

    test "the settle rides between the stun and the key, never after it" do
      config = %{
        rescue_key: "f4",
        step_ms: 40,
        settle_ms: 800,
        stun_steps: [{:press, "1"}]
      }

      assert Logic.revive(config) == [
               :still,
               {:press, "1"},
               {:wait, 40},
               {:wait, 800},
               {:press, "f4"}
             ]
    end

    test "empty stun_steps adds no glue and no settle to wait for" do
      config = %{rescue_key: "f4", step_ms: 40, stun_steps: [], settle_ms: 0}

      assert Logic.revive(config) == [:still, {:press, "f4"}]
    end
  end

  describe "stun_prefix/2" do
    @stun_steps [{:skill, "1"}, {:wait, 500}, {:skill, "2"}, {:wait, 500}]

    test "unavailable reading (nil): presses everything blind — never holds the rescue" do
      assert Logic.stun_prefix(@stun_steps, nil) ==
               {[{:press, "1"}, {:wait, 500}, {:press, "2"}, {:wait, 500}], []}
    end

    test "only READY skills go in; the ones on cooldown are skipped and named" do
      assert Logic.stun_prefix(@stun_steps, ["2", "3"]) ==
               {[{:wait, 500}, {:press, "2"}, {:wait, 500}], ["1"]}
    end

    test "none ready: only the waits remain, every skill named in the skip" do
      assert {actions, ["1", "2"]} = Logic.stun_prefix(@stun_steps, [])
      refute Enum.any?(actions, &match?({:press, _}, &1))
    end

    # Eligibility filters earlier; this is the seatbelt for a combo changing between the
    # selection and the firing.
    test "a step that is not skill/wait is ignored — it never crashes a rescue" do
      steps = [{:swap_member, "Jigglypuff"}, {:skill, "1"}]
      assert Logic.stun_prefix(steps, nil) == {[{:press, "1"}], []}
    end
  end

  # "se não tem mais outras skills pra usar, pra tentar dar aquele último dano,
  # daí recolhe" (Lucas, 2026-08-14): a stun that never fired must not end with
  # the field emptied and the hand still full.
  describe "the last card, when the stun refused to go out" do
    @kit %{crowd: ["1", "2"], aoe: ["3"], single: ["4"], heal: ["8"], buffs: ["5"]}

    # O ALVO ÚNICO SAIU DA ESCALAÇÃO em 29/08: "skills de alvo único não
    # funcionam mais, de propósito". Uma tecla que o jogo ignora não protege
    # recolhida nenhuma — gasta o corpo e o cooldown e deixa a pilha acordada.
    # Quem tem alvo único que machuca liga a regra e ela volta (último teste).
    test "control first, then area — e o alvo único fica de fora" do
      assert Logic.last_resort_keys(@kit, [], nil) == ["1", "2", "3"]
    end

    test "what was already pressed is not pressed again" do
      assert Logic.last_resort_keys(@kit, ["1", "2"], nil) == ["3"]
    end

    test "cooling keys are dropped against the bar" do
      assert Logic.last_resort_keys(@kit, ["1"], ["2", "4"]) == ["2"]
    end

    # Same fail-open rule as the stun prefix: in this exact moment a blind
    # press beats no press at all.
    test "no bar reading presses everything that is left" do
      assert Logic.last_resort_keys(@kit, ["1"], nil) == ["2", "3"]
    end

    test "com a regra ligada, o alvo único volta pro fim da fila" do
      assert Logic.last_resort_keys(@kit, [], nil, true) == ["1", "2", "3", "4"]
    end

    test "heal and buffs are never the last card — other rungs own those" do
      keys = Logic.last_resort_keys(@kit, [], nil)

      refute "8" in keys
      refute "5" in keys
    end

    test "an empty hand is an empty list, never a crash" do
      assert Logic.last_resort_keys(nil, [], nil) == []
      assert Logic.last_resort_keys(%{crowd: ["1"]}, ["1"], nil) == []
      assert Logic.last_resort_keys(@kit, [], []) == []
    end
  end

  # "se o pokémon morrer naturalmente, a gente tem que saber lidar com o fluxo"
  # (Lucas, 2026-08-14). A dead pokémon has no bar to read — the window itself
  # changes shape — so death is read from the TRAJECTORY of the last bar seen.
  describe "reading a death off the vanished bar" do
    defp faint(overrides) do
      Map.merge(
        %{
          enabled?: true,
          unreadable_streak: 2,
          last_seen_hp: 10,
          faint_below_pct: 35,
          cooldown_ms: 15_000,
          last_faint_at: nil,
          now: 0
        },
        Map.new(overrides)
      )
    end

    test "a low bar that vanishes for two reads is a death" do
      assert Logic.fainted?(faint([]))
    end

    test "one unreadable frame is never a death" do
      refute Logic.fainted?(faint(unreadable_streak: 1))
    end

    # The covered-window case: a healthy bar does not stop being healthy
    # because someone put a browser in front of the game.
    test "a HEALTHY bar that vanishes is a window, not a death" do
      refute Logic.fainted?(faint(last_seen_hp: 100))
      refute Logic.fainted?(faint(last_seen_hp: 36))
    end

    # Never seeing it alive is "no pokémon out", which is not something to
    # spend a revive on.
    test "with no live reading behind it, nothing fires" do
      refute Logic.fainted?(faint(last_seen_hp: nil))
    end

    test "the toggle and the cooldown both hold it" do
      refute Logic.fainted?(faint(enabled?: false))
      refute Logic.fainted?(faint(last_faint_at: 0, now: 14_999))
      assert Logic.fainted?(faint(last_faint_at: 0, now: 15_000))
    end
  end
end
