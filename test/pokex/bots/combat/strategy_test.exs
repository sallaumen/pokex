defmodule Pokex.Bots.Combat.StrategyTest do
  @moduledoc """
  Which keys the fight presses, and in what order.

  Every rule here is one he stated on 2026-08-11, and each test is written so
  that breaking the rule breaks the test — the point of moving the decision out
  of a hand-written `skill_keys` list is that the reasoning becomes arguable.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Combat.{Loadout, Strategy}

  # His Shiny Vileplume as he classified it: aura on 1, control on 2, area on
  # 3..6, and a single-target on 7.
  defp vileplume do
    Loadout.resolve("Shiny Vileplume", %{
      "1" => :buffs,
      "2" => :crowd,
      "3" => :aoe,
      "4" => :aoe,
      "5" => :aoe,
      "6" => :aoe,
      "7" => :single
    })
  end

  describe "opening a pile that has just finished gathering" do
    # "quando termina o período de mobar, ele vai começar sempre usando as
    # skills em área"
    test "area comes first, always — the gathering only exists for this" do
      assert Strategy.opening(vileplume()) == ~w(3 4 5 6 7)
    end

    # The crowd is why the hunt walked the whole blue stretch; the battle list
    # at that instant may still be catching up with what is walking in.
    test "even reading ONE enemy, the opening still leads with area" do
      assert Strategy.skill_order(vileplume(), opening?: true, enemies: 1) == ~w(3 4 5 6 7)
    end
  end

  describe "counting what is on screen" do
    # "poderíamos contar a quantidade de inimigos, e ir usando as skills single
    # target primeiro com poucos inimigos e guardar para mobar em inimigos
    # maiores" — the fishing case, where nothing is ever gathered.
    test "one enemy: single-target first, area behind it" do
      assert Strategy.skill_order(vileplume(), enemies: 1) == ~w(7 3 4 5 6)
    end

    test "a crowd: area first, without any gathering needed" do
      assert Strategy.skill_order(vileplume(), enemies: 5) == ~w(3 4 5 6 7)
    end

    test "the threshold is the number, not a feeling — and it is configurable" do
      assert Strategy.skill_order(vileplume(), enemies: 2, aoe_from: 3) == ~w(7 3 4 5 6)
      assert Strategy.skill_order(vileplume(), enemies: 3, aoe_from: 3) == ~w(3 4 5 6 7)
      assert Strategy.skill_order(vileplume(), enemies: 2, aoe_from: 2) == ~w(3 4 5 6 7)
    end

    test "with nothing said about the crowd it assumes ONE — the cautious read" do
      assert Strategy.skill_order(vileplume(), []) == ~w(7 3 4 5 6)
    end
  end

  describe "what the fight must never press" do
    # The rule that protects the auto-revive: the control skill has to survive
    # the fight to be there when the recall needs the stun.
    test "the control key is in NO order, in any situation" do
      for opts <- [[enemies: 1], [enemies: 9], [opening?: true]] do
        refute "2" in Strategy.skill_order(vileplume(), opts)
      end

      assert Strategy.reserved(vileplume()) == ["2"]
    end

    # Not because they are useless — because they answer to moments this
    # function does not own: the middle of the huddle, and a health bar.
    test "the aura and the heal are not in the attack order either" do
      loadout =
        Loadout.resolve("Gardevoir", %{"1" => :buffs, "3" => :aoe, "8" => :heal})

      order = Strategy.skill_order(loadout, enemies: 4)

      assert order == ["3"]
      refute "1" in order
      refute "8" in order
    end
  end

  describe "when there is nothing to go on" do
    # nil is what makes every consumer fall back to the global key list, which
    # is exactly the behaviour that existed before any of this.
    test "no loadout answers an empty order, never a crash" do
      assert Strategy.skill_order(nil, enemies: 3) == []
      assert Strategy.opening(nil) == []
      assert Strategy.reserved(nil) == []
    end

    # nil means "he classified NOTHING". A pokémon with only a control and a
    # heal is classified — it just has nothing to fight with, which is the
    # fight's question (`attacks?/1`) and not the same one a scheduled aura asks.
    test "only reserved and reactive keys: a loadout, but nothing to attack with" do
      loadout = Loadout.resolve("Gogoat", %{"2" => :crowd, "8" => :heal})

      refute Loadout.attacks?(loadout)
      assert Strategy.skill_order(loadout, enemies: 4) == []
      assert loadout.crowd == ["2"]

      assert Loadout.resolve("Gogoat", %{}) == nil
    end
  end

  describe "reading the loadout out loud" do
    test "it names the pokémon and what it brings" do
      assert Loadout.describe(vileplume()) ==
               "Shiny Vileplume · área 3+4+5+6 · alvo único 7 · aura de dano 1"
    end

    test "no choice says so, instead of an empty line" do
      assert Loadout.describe(nil) == "sem pokémon escolhido"
    end
  end

  describe "a aura de dano, quando ela está pronta" do
    # "usar a aura 2 quando disponível e se for usar outras skills usar elas
    # depois" (26/08). Uma aura que multiplica dano e sai DEPOIS do dano não
    # multiplicou nada.
    test "pronta, ela lidera — e o resto da ordem não muda" do
      assert Strategy.skill_order(vileplume(), enemies: 5, aura_ready?: true) == ~w(1 3 4 5 6 7)
      assert Strategy.skill_order(vileplume(), enemies: 1, aura_ready?: true) == ~w(1 7 3 4 5 6)
    end

    test "sem ninguém dizer que está pronta, a rajada é a de sempre" do
      # O "quando disponível" não é decoração: com o intervalo dele em 500ms,
      # uma tecla em cooldown na frente da rajada custa meio segundo de dano.
      assert Strategy.skill_order(vileplume(), enemies: 5) == ~w(3 4 5 6 7)
    end

    test "a abertura também aceita a condição" do
      assert Strategy.opening(vileplume()) == ~w(3 4 5 6 7)
      assert Strategy.opening(vileplume(), aura_ready?: true) == ~w(1 3 4 5 6 7)
    end
  end

  describe "a aura de DEFESA, quando o bolo justifica" do
    defp dugtrio do
      Loadout.resolve("Dugtrio", %{
        "1" => :crowd,
        "2" => :buffs,
        "3" => :shield,
        "4" => :aoe,
        "5" => :aoe,
        "6" => :single
      })
    end

    # ELA ERA PROIBIDA AQUI, por uma leitura minha de 26/08 ("uma
    # invulnerabilidade gasta a cada abertura é uma invulnerabilidade que não
    # existe quando ele precisa"). Ele desmentiu isso olhando a caçada em 27/08:
    # "a de defesa vale sempre que tem já uns 2 pokémons atacando ele pelo
    # menos". Quem sabe se são dois é quem chama; aqui ela entra quando mandarem.
    test "por conta própria ela não sai — nem pronta a aura de dano, nem com pilha" do
      refute "3" in Strategy.skill_order(dugtrio(), enemies: 9, aura_ready?: true)
      refute "3" in Strategy.opening(dugtrio(), aura_ready?: true)
      refute "3" in Strategy.skill_order(dugtrio(), enemies: 1)
    end

    # Escudo primeiro: ele é sobre SOBREVIVER à salva que vem, e a aura de dano
    # multiplica o que sai atrás dela.
    test "mandada, ela lidera até a aura de dano" do
      assert Strategy.skill_order(dugtrio(), enemies: 9, shield_ready?: true) == ~w(3 4 5 6)

      assert Strategy.skill_order(dugtrio(),
               enemies: 9,
               aura_ready?: true,
               shield_ready?: true
             ) == ~w(3 2 4 5 6)
    end

    test "ela segue reservada da rajada comum — e dá pra PROVAR" do
      assert "3" in Strategy.reserved(dugtrio())
      assert "1" in Strategy.reserved(dugtrio())
    end

    test "a aura de dano do mesmo pokémon continua liderando quando pronta" do
      assert Strategy.skill_order(dugtrio(), enemies: 9, aura_ready?: true) == ~w(2 4 5 6)
    end

    test "quem responde se o escudo está pronto é a barra lida" do
      assert Loadout.shield_ready?(dugtrio(), ~w(3 4))
      refute Loadout.shield_ready?(dugtrio(), ~w(4 5))
      refute Loadout.shield_ready?(dugtrio(), nil)
    end
  end

  describe "quem decide se a aura está pronta" do
    # A barra vem de `Perception.ready_skills/1`, que responde `nil` quando a
    # leitura está velha ou não existe. Falhar fechado é o lado barato: uma
    # rajada que pula uma aura pronta perde um multiplicador; uma que lidera com
    # a aura em cooldown perde `combat_skill_gap_ms` de dano toda vez, e o dele
    # está em 500ms.
    test "leitura velha responde NÃO, nunca um chute" do
      refute Loadout.aura_ready?(vileplume(), nil)
    end

    test "pronta é a aura DESTE pokémon estar na barra lida" do
      assert Loadout.aura_ready?(vileplume(), ~w(1 3 4))
      refute Loadout.aura_ready?(vileplume(), ~w(3 4 5))
    end

    test "um pokémon sem aura nenhuma nunca está com a aura pronta" do
      sem_aura = Loadout.resolve("Sem aura", %{"3" => :aoe, "7" => :single})

      refute Loadout.aura_ready?(sem_aura, ~w(1 2 3))
    end
  end

  describe "gastar o mínimo pra matar" do
    # "Se ele se identificar aqui com a skill 4 sozinha, ele já mata. Ele não
    # precisa ficar usando 4, 5, 6 sempre. Ele pode usar só 4, esperar um
    # pouquinho. Se não matar, usa 5" (26/08).
    @dano %{"3" => 40.0, "4" => 40.0, "5" => 40.0, "6" => 20.0}

    test "uma tecla que já cobre a vida é a única que sai" do
      assert Strategy.enough(~w(3 4 5 6), @dano, 35.0) == ~w(3)
    end

    test "duas quando uma não basta" do
      assert Strategy.enough(~w(3 4 5 6), @dano, 75.0) == ~w(3 4)
    end

    test "a ordem inteira quando nem ela basta" do
      assert Strategy.enough(~w(3 4 5 6), @dano, 500.0) == ~w(3 4 5 6)
    end

    test "cobrir EXATAMENTE ainda inclui a tecla que cobriu" do
      # Um bicho em 40% com uma tecla de 40% morre com ela; parar antes seria
      # deixá-lo em pé com a barra gasta.
      assert Strategy.enough(~w(3 4 5 6), @dano, 40.0) == ~w(3)
    end

    test "uma tecla SEM número medido nunca é a última" do
      # Cortar por uma estimativa que não existe é a pior troca desta caçada:
      # o monstro fica em pé e a barra fica gasta. Sem número ela conta como
      # zero, então a rajada continua até uma tecla medida cobrir.
      sem = %{"5" => 40.0}

      assert Strategy.enough(~w(3 4 5 6), sem, 35.0) == ~w(3 4 5)
    end

    test "sem dano medido NENHUM, a ordem sai inteira" do
      # Quem não mediu não economiza — é o comportamento de sempre.
      assert Strategy.enough(~w(3 4 5 6), %{}, 35.0) == ~w(3 4 5 6)
    end

    test "sem saber a vida do alvo, a ordem sai inteira" do
      assert Strategy.enough(~w(3 4 5 6), @dano, nil) == ~w(3 4 5 6)
    end

    test "a ordem é preservada: cortar não é reordenar" do
      assert Strategy.enough(~w(6 3 4), @dano, 55.0) == ~w(6 3)
    end

    test "uma ordem vazia continua vazia" do
      assert Strategy.enough([], @dano, 100.0) == []
    end
  end
end
