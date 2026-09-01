defmodule Pokex.Bots.Engine.SituationTest do
  @moduledoc """
  The shared tactical picture: what is TRUE, before anybody decides anything.

  Every rule here answers a sentence he said on 2026-08-17, and the picture is
  deliberately honest about not knowing — `nil` is a legal answer, and telling
  "the screen is empty" apart from "I cannot see the screen" is the whole point
  of this module existing.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Situation

  @config %{engage_from: 3}

  # His battle panel as the located layout reads it: one row per creature, with
  # the name read by glyphs against the Pokédex.
  defp battle(names, opts \\ []) do
    detail =
      names
      |> Enum.with_index()
      |> Enum.map(fn {name, row} ->
        %{row: row, name: name, hp_pct: 1.0, shiny?: false}
      end)

    %{
      enemies: Enum.to_list(0..(length(names) - 1)//1),
      enemies_detail: detail,
      locked?: Keyword.get(opts, :locked?, false),
      locked_row: nil
    }
  end

  # The same panel WITHOUT a located layout: rows are counted, names are not
  # readable. `enemies_detail` comes back empty (interpret.ex:120).
  defp nameless(count) do
    %{
      enemies: Enum.to_list(0..(count - 1)//1),
      enemies_detail: [],
      locked?: false,
      locked_row: nil
    }
  end

  defp inputs(overrides \\ %{}) do
    Map.merge(
      %{
        battle: battle(~w(Venonat Paras Venomoth)),
        own_hp: 90,
        own_out?: true,
        own_name: "Vespiquen",
        ready_keys: ~w(3 4 5 6 7 8 9),
        damage_keys: ~w(3 4 5 6 7 8 9),
        prev: nil
      },
      overrides
    )
  end

  describe "counting what is on the screen" do
    test "counts the rows the battle panel shows" do
      picture = Situation.build(inputs(), @config, 1_000)

      assert picture.rows == 3
      assert picture.enemies == 3
    end

    # "lembrando de não contar o próprio, porque o meu é o primeiro sempre da
    # tela de batalha" (2026-08-17). Whether his pokémon appears at all is the
    # measurement this PR exists to settle — so the picture SUBTRACTS it when it
    # recognises it, and says so.
    test "does not count his own pokémon among the enemies" do
      picture =
        inputs(%{battle: battle(~w(Vespiquen Venonat Paras Venomoth))})
        |> Situation.build(@config, 1_000)

      assert picture.rows == 4
      assert picture.enemies == 3
      assert picture.own_row_seen? == true
    end

    # team.json says "Shiny Vileplume"; the panel reads "Vileplume" (his capture
    # of 11/08 22:14). A prefix must never make the bot count itself as an enemy.
    test "recognises his own pokémon even when the panel drops the Shiny prefix" do
      picture =
        inputs(%{battle: battle(~w(Vileplume Venonat)), own_name: "Shiny Vileplume"})
        |> Situation.build(@config, 1_000)

      assert picture.enemies == 1
      assert picture.own_row_seen? == true
    end

    test "says so when his pokémon is NOT among the rows" do
      picture = Situation.build(inputs(), @config, 1_000)
      assert picture.own_row_seen? == false
    end

    # Without a located layout there are no names, so the own row cannot be
    # identified. The count stays RAW and the unknown is stated — a guessed
    # subtraction here is the difference between attacking and walking away.
    test "with no names readable, the count is raw and the own row is unknown" do
      picture =
        inputs(%{battle: nameless(4)})
        |> Situation.build(@config, 1_000)

      assert picture.rows == 4
      assert picture.enemies == 4
      assert picture.own_row_seen? == nil
      assert picture.named == []
    end

    # "não vale nem atacar" below the ruler (R1).
    test "three enemies is worth fighting; two is not" do
      assert Situation.build(inputs(), @config, 1_000).worth_fighting? == true

      picture =
        inputs(%{battle: battle(~w(Venonat Paras))})
        |> Situation.build(@config, 1_000)

      assert picture.worth_fighting? == false
    end
  end

  describe "not seeing the screen" do
    # An empty screen and an unreadable screen are the same pixels to a counter
    # and opposite facts to a decision. `nil` is the honest answer.
    test "a missing battle reading is nil, never zero" do
      picture =
        inputs(%{battle: nil})
        |> Situation.build(@config, 1_000)

      assert picture.rows == nil
      assert picture.enemies == nil
      assert picture.worth_fighting? == false
      assert picture.blind? == true
    end

    test "an empty battle list is zero, and not blind" do
      picture =
        inputs(%{battle: %{enemies: [], enemies_detail: [], locked?: false, locked_row: nil}})
        |> Situation.build(@config, 1_000)

      assert picture.enemies == 0
      assert picture.blind? == false
    end
  end

  describe "is the pile still walking in" do
    test "a count that rose is growing, and the clock restarts" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{battle: battle(~w(Venonat Paras Venomoth Oddish)), prev: before})
        |> Situation.build(@config, 1_600)

      assert picture.growing? == true
      assert picture.stable_for_ms == 0
    end

    test "a count that held still measures how long it has held" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{prev: before})
        |> Situation.build(@config, 2_800)

      assert picture.growing? == false
      assert picture.stable_for_ms == 1_800
    end

    # A death shrinks the list, and a pile that is dying is not a pile still
    # arriving — the settle clock must not restart on it.
    test "a count that fell is not growing, and does not restart the clock" do
      before = Situation.build(inputs(), @config, 1_000)

      picture =
        inputs(%{battle: battle(~w(Venonat)), prev: before})
        |> Situation.build(@config, 2_800)

      assert picture.growing? == false
      assert picture.stable_for_ms == 1_800
    end

    test "the first reading of a hunt has no history and starts its own clock" do
      picture = Situation.build(inputs(), @config, 5_000)

      assert picture.growing? == false
      assert picture.stable_for_ms == 0
    end
  end

  describe "cooldowns" do
    # The revive is worth most when the cooldowns are already gone (R3), so the
    # picture has to be able to say that they are.
    #
    # ACABOU É ACABOU (27/08). Era "metade ou menos", cravado: com sete teclas
    # de dano o revive saía com TRÊS na mão. "Ele usa muito ressurect à toa (…)
    # a gente tem que usar todas as skills, para depois usar um ressurect,
    # porque ele tem um certo custo que não é de graça."
    test "uma tecla de dano ainda pronta NÃO é barra gasta" do
      picture =
        inputs(%{ready_keys: ~w(9)})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == false
    end

    test "com a barra inteira em cooldown, aí sim" do
      picture =
        inputs(%{ready_keys: []})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == true
    end

    # O knob existe porque a folga de UMA tecla pode se pagar quando a que
    # sobrou é a mais fraca da barra — e isso se mede.
    test "a folga é ajustável, e é o que decide" do
      picture =
        inputs(%{ready_keys: ~w(9)})
        |> Situation.build(Map.put(@config, :spent_keys_left, 1), 1_000)

      assert picture.spent? == true
    end

    test "a full bar is not spent" do
      assert Situation.build(inputs(), @config, 1_000).spent? == false
    end

    test "no skill-bar reading is an unknown, not a false" do
      picture =
        inputs(%{ready_keys: nil})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == nil
    end

    test "a pokémon with no damage keys classified cannot be spent" do
      picture =
        inputs(%{damage_keys: [], ready_keys: []})
        |> Situation.build(@config, 1_000)

      assert picture.spent? == nil
    end
  end

  defp picture_of(names, opts \\ []) do
    Situation.build(
      %{
        battle: battle(names),
        own_name: Keyword.get(opts, :own_name, "Vespiquen"),
        own_out?: Keyword.get(opts, :own_out?, true),
        ready_keys: [],
        damage_keys: []
      },
      @config,
      1_000
    )
  end

  describe "the own row when its name cannot be read" do
    test "discounts the first unreadable row when the pokemon is on the field" do
      picture = picture_of([nil, "Meganium", "Meganium"])

      assert picture.rows == 3
      assert picture.enemies == 2
      assert picture.own_row_seen? == :unnamed
    end

    test "keeps the named list consistent with the discounted count" do
      picture = picture_of([nil, "Meganium", "Meganium"])

      assert length(picture.named) == picture.enemies
      refute Enum.any?(picture.named, &(&1.name == nil))
    end

    test "discounts only one unreadable row, not every one of them" do
      assert picture_of([nil, nil, "Meganium"]).enemies == 2
    end

    test "prefers the name when a row does match it" do
      picture = picture_of(["Vespiquen", "Meganium", nil])

      assert picture.enemies == 2
      assert picture.own_row_seen? == true
    end

    test "takes nothing away when every row is legible and none is his" do
      picture = picture_of(["Meganium", "Meganium", "Tangela"])

      assert picture.enemies == 3
      assert picture.own_row_seen? == false
    end

    test "takes nothing away when his pokemon is not on the field" do
      picture = picture_of([nil, "Meganium", "Meganium"], own_out?: false)

      assert picture.enemies == 3
      assert picture.own_row_seen? == false
    end

    # The exact reading his hunt filed 12 times while opening the area on it.
    test "his hunt of 2026-08-18 would have read two, not three" do
      refute picture_of([nil, "Meganium", "Meganium"]).worth_fighting?
    end
  end

  # O CHEFE, POR NOME. `heavy?` é o gatilho da postura de chefe do cérebro —
  # e ele fura a régua (`worth_fighting?`) porque um chefe sozinho vale a luta
  # que cinco bichos comuns valem.
  describe "o chefe pelo tempo de matar (grit)" do
    # "Ele tem o mesmo nome que os outros pokémons" (31/08): o nome não separa
    # chefe de comum. O que separa é a pilha ENGOLIR skills sem soltar corpo —
    # medido na noite fraca de 31/08: máximo 4 entregas por pilha (p99 = 3),
    # e um chefe 10× engole o dobro em dois giros da barra.
    @grit_config %{engage_from: 3, boss_grit: 6}

    defp tick(prev, over),
      do: Situation.build(inputs(Map.put(over, :prev, prev)), @grit_config, 1_000)

    test "tecla de dano que saiu da barra soma; a que ficou pronta não" do
      p1 = tick(nil, %{battle: battle(~w(a b c)), ready_keys: ~w(3 4 5)})
      assert p1.grit == 0

      p2 = tick(p1, %{battle: battle(~w(a b c)), ready_keys: ~w(5)})
      assert p2.grit == 2, "3 e 4 saíram da barra com a pilha de pé"
      assert p2.heavy? == false
    end

    test "tecla que NÃO é de dano não conta — o ciclo stun+revive não infla o medidor" do
      p1 = tick(nil, %{battle: battle(~w(a b c)), ready_keys: ~w(1 3), damage_keys: ~w(3)})
      p2 = tick(p1, %{battle: battle(~w(a b c)), ready_keys: [], damage_keys: ~w(3)})
      assert p2.grit == 1, "só a 3 é dano; a 1 (controle) saiu e não conta"
    end

    test "um corpo caindo DESCONTA o preço de um kill, não zera" do
      p1 = tick(nil, %{battle: battle(~w(a b c)), ready_keys: ~w(3 4 5 6 7 8)})
      p2 = tick(p1, %{battle: battle(~w(a b c)), ready_keys: []})
      assert p2.grit == 6

      p3 = tick(p2, %{battle: battle(~w(a b)), ready_keys: []})
      assert p3.grit == 2, "6 entregues − 4 do corpo que caiu"
    end

    test "tela limpa zera; barra ilegível segura o que tem sem somar" do
      p1 = tick(nil, %{battle: battle(~w(a b c)), ready_keys: ~w(3 4 5)})
      p2 = tick(p1, %{battle: battle(~w(a b c)), ready_keys: []})
      p3 = tick(p2, %{battle: battle(~w(a b c)), ready_keys: nil})
      assert p3.grit == 3, "cego não soma nem esquece"

      p4 = tick(p3, %{battle: battle([]), ready_keys: nil})
      assert p4.grit == 0
    end

    test "cruzar o knob declara chefe e LATCHA até a pilha zerar" do
      p1 = tick(nil, %{battle: battle(~w(a b c)), ready_keys: ~w(3 4 5 6 7 8)})
      p2 = tick(p1, %{battle: battle(~w(a b c)), ready_keys: []})
      assert p2.heavy? == true, "6 entregues ≥ knob 6"
      assert p2.heavy_latch? == true

      # o F4 devolve a barra e um comum cai do lado: o grit desconta,
      # mas a declaração fica — chefe não vira comum no meio da luta
      p3 = tick(p2, %{battle: battle(~w(a b)), ready_keys: ~w(3 4 5 6 7 8)})
      assert p3.grit == 2
      assert p3.heavy? == true, "o latch segura a postura"

      p4 = tick(p3, %{battle: battle([]), ready_keys: ~w(3 4 5 6 7 8)})
      assert p4.heavy? == false, "pilha zerada solta o latch"
    end

    test "knob 0 desliga: só o nome declara" do
      p1 =
        Situation.build(
          inputs(%{battle: battle(~w(a b c)), ready_keys: ~w(3 4 5 6 7 8)}),
          %{engage_from: 3},
          1_000
        )

      p2 =
        Situation.build(
          inputs(%{battle: battle(~w(a b c)), ready_keys: [], prev: p1}),
          %{engage_from: 3},
          1_000
        )

      assert p2.grit == 6
      assert p2.heavy? == false
    end

    test "chefe declarado vale a luta mesmo abaixo da régua" do
      p1 = tick(nil, %{battle: battle(~w(a b)), ready_keys: ~w(3 4 5 6 7 8)})
      p2 = tick(p1, %{battle: battle(~w(a b)), ready_keys: []})
      assert p2.heavy? == true
      assert p2.worth_fighting? == true, "2 < engage_from 3, mas chefe fura a régua"
    end
  end

  # O ESPECIAL PELA COR — e ele é UM só: "o shiny É o chefe (…) nesse jogo o
  # que tô chamando de chefe são os shinies" (01/09). Uma regra ensinada liga a
  # postura inteira; não há um segundo tipo de bicho especial pra distinguir.
  describe "o especial (shiny) pela cor" do
    test "a cor vista liga heavy? e fura a régua sozinha" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(Electrode)), own_out?: true, especial?: true}),
          %{engage_from: 3},
          1_000
        )

      assert picture.heavy? == true, "o shiny É o chefe: postura inteira"
      assert picture.worth_fighting? == true, "um shiny sozinho vale a luta"
    end

    test "sem a cor, um bicho abaixo da régua segue sendo bicho" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(Electrode)), own_out?: true, especial?: false}),
          %{engage_from: 3},
          1_000
        )

      assert picture.heavy? == false
      assert picture.worth_fighting? == false
    end

    test "canal ausente é especial nenhum — nenhuma bancada antiga ganha postura" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(Electrode)), own_out?: true}),
          %{engage_from: 3},
          1_000
        )

      assert picture.heavy? == false
    end
  end

  describe "o chefe na foto" do
    @chefe_config %{engage_from: 3, boss_names: "Chefe, Boss X"}

    test "uma linha com nome de chefe liga heavy? e fura a régua" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(chefe)), own_out?: true}),
          @chefe_config,
          1_000
        )

      assert picture.heavy? == true
      assert picture.worth_fighting? == true, "um chefe sozinho vale a luta"
    end

    test "a comparação ignora caso e espaços da lista" do
      picture =
        Situation.build(
          inputs(%{battle: battle(["BOSS X"]), own_out?: true}),
          @chefe_config,
          1_000
        )

      assert picture.heavy? == true
    end

    test "sem nome na lista, bicho comum é bicho comum" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(Venonat)), own_out?: true}),
          @chefe_config,
          1_000
        )

      assert picture.heavy? == false
    end

    test "lista vazia desliga a postura — nenhum cenário antigo ganha chefe" do
      picture =
        Situation.build(
          inputs(%{battle: battle(~w(chefe)), own_out?: true}),
          %{engage_from: 3},
          1_000
        )

      assert picture.heavy? == false
    end

    test "cego não tem chefe: nil de linhas é nil de postura" do
      picture = Situation.build(inputs(%{battle: nil}), @chefe_config, 1_000)

      assert picture.heavy? == false
    end
  end
end
