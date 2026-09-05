defmodule Pokex.Bots.Combat.Plan.Standard do
  @moduledoc """
  The bot exactly as it fights today — the hand composed from what each key
  DOES (`Combat.Strategy`), area first on a crowd, the control kept for the
  revive.

  Not a degraded mode and not a legacy: it is the behaviour every measured
  night in this repo was taken on, and it stays the answer for any mode that
  has not asked for something else. Moving it here changed nothing — the
  characterization tests in `plan_test.exs` press the same keys these two
  callers pressed before, for the same inputs.
  """

  @behaviour Pokex.Bots.Combat.Plan

  alias Pokex.Bots.Combat.{Loadout, Strategy}

  @impl true
  def opening(loadout, ctx) do
    Strategy.opening(loadout,
      single_target?: single?(ctx),
      aura_ready?: Loadout.aura_ready?(loadout, ready_keys(ctx)),
      shield_ready?: shield_ready?(loadout, ctx)
    )
  end

  # A ROTAÇÃO SUSTENTADA, e ela filtra pela barra — ao contrário da abertura.
  # As duas listas parecem a mesma e não são: a engine lê `opening == []` como
  # "nenhum pokémon configurado pra lutar" e sai da luta, e filtrar lá derrubou
  # os mortos em 44% na bancada.
  @impl true
  def sustained(loadout, ctx) do
    Strategy.skill_order(loadout,
      enemies: enemies(ctx, 1),
      aoe_from: knob(ctx, :combat_aoe_from_enemies, 3),
      single_target?: single?(ctx),
      aura_ready?: Loadout.aura_ready?(loadout, ready_keys(ctx)),
      shield_ready?: shield_ready?(loadout, ctx),
      ready_keys: ready_keys(ctx)
    )
  end

  # A MÃO PEQUENA: a primeira tecla de dano, sem escudo e sem aura — o que uma
  # pilha que a régua já chamou de "não vale a área" merece.
  @impl true
  def small(loadout, ctx) do
    loadout
    |> Strategy.opening(single_target?: single?(ctx))
    |> Enum.take(1)
  end

  @impl true
  def single(loadout, ctx), do: Loadout.single_keys(loadout, single?(ctx))

  @impl true
  def crowd(%Loadout{crowd: crowd}, _ctx), do: crowd
  def crowd(_no_loadout, _ctx), do: []

  # Sem bolso: este modo já gasta o alvo único e o controle na rotação, então
  # não há tecla guardada pra emergência abrir.
  @impl true
  def reserve(_loadout, _ctx), do: []

  # O QUE ESTA CAÇADA GASTA PRA MATAR — e é sobre estas teclas que `spent?`
  # pergunta "acabou?". Uma tecla que o jogo ignora aqui dentro nunca esfria, e
  # `spent?` nunca fica verdadeiro: todo revive que depende dele morre calado.
  @impl true
  def damage_keys(nil, _ctx), do: []

  def damage_keys(loadout, ctx),
    do: loadout.aoe ++ Loadout.single_keys(loadout, single?(ctx))

  # DESLIGADO, medido em campo por ele: o alvo travado não muda o dano (só a
  # área machuca nesta dungeon) e move o pokémon pra cima do alvo, desmanchando
  # o bolo que a régua acabou de juntar. Quem quer Tab é o modo Econômico, e ele
  # o diz por si — não por um ajuste que podia contradizer o modo.
  @impl true
  def tab?(_ctx), do: false

  # Uma limpeza por luta, pelo mesmo motivo do Econômico: aqui a rotação
  # aperta a barra inteira tecla por tecla, e um prefixo em cada rajada
  # custaria mais respiro do que dano.
  @impl true
  def cure_policy(_ctx), do: :opening

  # --- lendo o contexto ------------------------------------------------------
  #
  # As duas metades do bot guardam os knobs com nomes diferentes — o cérebro
  # pelo nome da decisão (`single_target`), o combate pelo nome do ajuste
  # (`combat_single_target`) — então cada leitura aceita os dois. Unificar os
  # nomes é uma limpeza de outro dia; inventar um default aqui não é.
  defp single?(ctx) do
    knob(ctx, :single_target, nil) || knob(ctx, :combat_single_target, false) || false
  end

  defp shield_ready?(loadout, ctx) do
    quantos = enemies(ctx, nil)
    piso = knob(ctx, :shield_from, nil) || knob(ctx, :combat_shield_from_enemies, 2)

    is_integer(quantos) and quantos >= piso and
      Loadout.shield_ready?(loadout, ready_keys(ctx))
  end

  defp enemies(ctx, default) do
    case Map.get(ctx, :enemies, default) do
      nil -> default
      n -> n
    end
  end

  defp ready_keys(ctx), do: Map.get(ctx, :ready_keys)

  defp knob(ctx, key, default) do
    ctx |> Map.get(:config, %{}) |> Map.get(key, default)
  end
end
