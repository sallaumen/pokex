defmodule Pokex.PerceptionTest do
  # async: false — reads the named global WorldState table.
  use ExUnit.Case, async: false

  alias Pokex.Perception
  alias Pokex.Perception.WorldState

  setup do
    # one shared blackboard: start from an empty world, never from the last test's
    WorldState.clear()

    on_exit(fn ->
      WorldState.forget(:minimap)
      WorldState.forget(:pokemon)
      WorldState.forget(:skill_bar)
    end)

    :ok
  end

  test "pokemon mirrors a fresh fact and fails open on stale/missing" do
    refute match?({:ok, _}, Perception.pokemon(10_000))

    WorldState.put(:pokemon, %{hp_pct: 62, readable?: true}, 10_000)
    assert Perception.pokemon(10_100) == {:ok, %{hp_pct: 62, readable?: true}}

    stale_at = 10_000 + Pokex.Settings.get(:pokemon_fact_max_age_ms) + 1
    assert Perception.pokemon(stale_at) == :unknown
  end

  test "minimap returns the fresh position and is :unknown when missing, nil or stale" do
    assert Perception.minimap(10_000) == :unknown

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, 10_000)
    assert Perception.minimap(10_100) == {:ok, %{pos: {337, 46_107, 4}}}

    WorldState.put(:minimap, %{pos: nil}, 10_200)
    assert Perception.minimap(10_300) == :unknown

    WorldState.put(:minimap, %{pos: {337, 46_107, 4}}, 10_000)
    stale_at = 10_000 + Pokex.Settings.get(:cavebot_minimap_fact_max_age_ms) + 1
    assert Perception.minimap(stale_at) == :unknown
  end

  test "ready_skills mirrors a fresh :skill_bar fact and is UNKNOWN on stale/missing" do
    assert Perception.ready_skills(10_000) == nil

    WorldState.put(:skill_bar, %{states: [:ready, :cooldown], ready_keys: ["1"]}, 10_000)
    assert Perception.ready_skills(10_100) == ["1"]

    WorldState.put(:skill_bar, %{states: nil, ready_keys: nil}, 10_200)
    assert Perception.ready_skills(10_300) == nil

    WorldState.put(:skill_bar, %{states: [:ready], ready_keys: ["1"]}, 10_000)
    stale_at = 10_000 + Pokex.Settings.get(:skill_bar_fact_max_age_ms) + 1
    assert Perception.ready_skills(stale_at) == nil
  end

  # …E POR QUÊ. `ready_skills/1` junta três causas num `nil`, e o conserto de
  # cada uma é diferente: só a terceira se conserta recalibrando. Em 12/09 o
  # alarme passou 5h05 mandando recalibrar sem nunca ter olhado qual era.
  test "skill_bar_gap separates the three ways the bar goes unread" do
    assert Perception.skill_bar_gap(10_000) == :never

    WorldState.put(:skill_bar, %{states: [:ready], ready_keys: ["1"]}, 10_000)
    assert Perception.skill_bar_gap(10_100) == :ok

    # veio quadro e o reconhecimento recusou, e ele diz quantos atalhos achou:
    # ZERO é "não estou olhando pra barra nenhuma" (a janela saiu do lugar),
    # poucos é uma barra que está ali e não se lê.
    WorldState.put(:skill_bar, %{states: nil, ready_keys: nil, labelled: 0, slots: 8}, 10_200)
    assert Perception.skill_bar_gap(10_300) == {:unreadable, 0, 8}

    WorldState.put(:skill_bar, %{states: nil, ready_keys: nil, labelled: 3, slots: 8}, 10_200)
    assert Perception.skill_bar_gap(10_300) == {:unreadable, 3, 8}

    # a leitura PRESTOU e envelheceu: o recorte está certo, a captura é que não
    # está dando conta — e aqui recalibrar não muda nada
    WorldState.put(:skill_bar, %{states: [:ready], ready_keys: ["1"]}, 10_000)
    ceiling = Pokex.Settings.get(:skill_bar_fact_max_age_ms)
    assert Perception.skill_bar_gap(10_000 + ceiling + 40) == {:stale, ceiling + 40}

    # uma leitura VELHA E RECUSADA continua sendo caso de recalibrar: o que
    # envelheceu não foi uma leitura boa.
    WorldState.put(:skill_bar, %{states: nil, ready_keys: nil, labelled: 2, slots: 8}, 10_000)
    assert Perception.skill_bar_gap(10_000 + ceiling + 40) == {:unreadable, 2, 8}
  end
end
