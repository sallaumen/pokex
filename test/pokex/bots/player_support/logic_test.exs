defmodule Pokex.Bots.PlayerSupport.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.PlayerSupport.Logic

  # prev_hp_pct defaults to 0 (previous read agreed it's low) so the threshold/cooldown tests
  # exercise their own rule; the consecutive-reads guard has its own dedicated tests.
  defp input(overrides) do
    %{
      hp_pct: 100,
      prev_hp_pct: 0,
      threshold_pct: 50,
      enabled?: true,
      cooldown_ms: 60_000,
      last_rescue_at: nil,
      now: 10_000
    }
    |> Map.merge(Map.new(overrides))
  end

  describe "decide/1" do
    test "holds while HP is at or above the rescue threshold" do
      assert Logic.decide(input(hp_pct: 100)) == :hold
      assert Logic.decide(input(hp_pct: 50)) == :hold
    end

    test "rescues the first time HP drops below the threshold" do
      assert Logic.decide(input(hp_pct: 49)) == :rescue
      assert Logic.decide(input(hp_pct: 10)) == :rescue
    end

    test "an unknown HP reading never rescues (fail-safe: don't burn a revive on nil)" do
      assert Logic.decide(input(hp_pct: nil)) == :hold
    end

    test "the toggle disables the rescue entirely" do
      assert Logic.decide(input(hp_pct: 5, enabled?: false)) == :hold
    end

    test "the protection cooldown blocks a second combo within the window" do
      # last combo at 10_000; now 40_000 → only 30s elapsed of a 60s cooldown
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 40_000)) == :hold
    end

    test "the combo fires again once the cooldown has fully elapsed" do
      # exactly 60s later → allowed
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 70_000)) == :rescue
      assert Logic.decide(input(hp_pct: 5, last_rescue_at: 10_000, now: 200_000)) == :rescue
    end

    test "one garbage frame never burns a revive: the PREVIOUS read must agree it's low" do
      # first-ever low read (prev nil) or a low read right after a high one → hold
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: nil)) == :hold
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: 90)) == :hold
      # two consecutive lows → rescue
      assert Logic.decide(input(hp_pct: 5, prev_hp_pct: 40)) == :rescue
    end
  end

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

  describe "combo/1" do
    test "builds the recall → max-revive-on-photo → release → recentre sequence" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40
      }

      assert Logic.combo(config) == [
               {:press, "q"},
               {:wait, 40},
               {:move, {70, 934}},
               {:wait, 40},
               {:press, "shift+q"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {1457, 666}}
             ]
    end

    test "com stun_steps: o stun vem ANTES do recall, na MESMA lista atômica" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40,
        stun_steps: [{:press, "1"}, {:wait, 500}, {:press, "2"}]
      }

      assert Logic.combo(config) == [
               {:press, "1"},
               {:wait, 500},
               {:press, "2"},
               # a cola entre o stun e o recall
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {70, 934}},
               {:wait, 40},
               {:press, "shift+q"},
               {:wait, 40},
               {:press, "q"},
               {:wait, 40},
               {:move, {1457, 666}}
             ]
    end

    test "stun_steps vazio não adiciona cola — sequência idêntica ao modo direto" do
      config = %{
        rescue_key: "q",
        max_revive_key: "shift+q",
        photo_point: {70, 934},
        neutral_point: {1457, 666},
        step_ms: 40
      }

      assert Logic.combo(Map.put(config, :stun_steps, [])) == Logic.combo(config)
    end
  end

  describe "stun_prefix/2" do
    @stun_steps [{:skill, "1"}, {:wait, 500}, {:skill, "2"}, {:wait, 500}]

    test "leitura indisponível (nil): aperta tudo às cegas — nunca segura o resgate" do
      assert Logic.stun_prefix(@stun_steps, nil) ==
               {[{:press, "1"}, {:wait, 500}, {:press, "2"}, {:wait, 500}], []}
    end

    test "só as skills PRONTAS entram; as em cooldown são puladas e NOMEADAS" do
      assert Logic.stun_prefix(@stun_steps, ["2", "3"]) ==
               {[{:wait, 500}, {:press, "2"}, {:wait, 500}], ["1"]}
    end

    test "nenhuma pronta: sobram só as esperas, todas as skills nomeadas no pulo" do
      assert {actions, ["1", "2"]} = Logic.stun_prefix(@stun_steps, [])
      refute Enum.any?(actions, &match?({:press, _}, &1))
    end

    test "um passo que não é skill/espera é ignorado — jamais derruba um resgate" do
      # a elegibilidade filtra antes; isto é o cinto pro caso do combo mudar
      # entre a escolha e o disparo
      steps = [{:swap_member, "Jigglypuff"}, {:skill, "1"}]
      assert Logic.stun_prefix(steps, nil) == {[{:press, "1"}], []}
    end
  end
end
