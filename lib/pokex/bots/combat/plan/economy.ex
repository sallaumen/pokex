defmodule Pokex.Bots.Combat.Plan.Economy do
  @moduledoc """
  A ROTA BARATA: Tab, uma tecla de alvo único, um respiro, e a área só se ainda
  precisar.

  "Esse modo será usado em rotas básicas, contra inimigos mais fracos,
  priorizando baixo consumo e um comportamento simples" (Lucas, 01/09).

  ## Por que o alvo único volta a existir aqui

  Ele está desligado no bot desde 29/08 — "skills de alvo único não funcionam
  mais, de propósito; a meta é só usarmos skills em área". Essa frase é sobre a
  DUNGEON dele, onde a área é o que mata: contra bicho fraco, gastar a área é
  gastar o cooldown caro num alvo que uma tecla barata resolve.

  Então quem decide não é mais um ajuste global: é o modo. `single_target` fica
  para o `Plan.Standard`, que é o bot como ele estava.

  ## "Ainda é necessário" sem inventar memória

  O plano é puro e não sabe se a lista encolheu. O que ele sabe é a BARRA — e
  ela responde a mesma pergunta por outro caminho: se a tecla barata está em
  cooldown, ela já saiu e não resolveu. Aí sim a área.

  O respiro entre as duas é o `skill_burst_every_ms`, que já é exatamente isso:
  o intervalo entre duas rajadas. Uma tecla por vez (`combat_skill_burst_size`)
  é o que faz a segunda ser uma decisão nova em vez de um pacote.

  ## O que este modo NÃO faz

  Nada de mobada, régua, recuo ou reset — isso é a camada de knobs do modo
  (`HuntMode.engine_overrides/1`), não uma regra escrita aqui. O revive de
  emergência e o do caído continuam intactos: um modo decide como se luta,
  nunca se o personagem está protegido.
  """

  @behaviour Pokex.Bots.Combat.Plan

  alias Pokex.Bots.Combat.Loadout

  # A ABERTURA É A BARATA PRIMEIRO. Sem a régua da mobada não há "pilha que vale
  # a área": há um bicho na frente, e ele merece a tecla mais barata que existe.
  @impl true
  def opening(loadout, ctx), do: single(loadout, ctx) ++ area(loadout)

  @impl true
  def sustained(loadout, ctx) do
    case prontas(single(loadout, ctx), ctx) do
      [] -> prontas(area(loadout), ctx)
      baratas -> baratas
    end
  end

  @impl true
  def small(loadout, ctx), do: loadout |> opening(ctx) |> Enum.take(1)

  # O ALVO ÚNICO É DO MODO, não do ajuste global: é a tecla que este modo existe
  # pra gastar.
  @impl true
  def single(%Loadout{single: single}, _ctx), do: single
  def single(_no_loadout, _ctx), do: []

  @impl true
  def crowd(%Loadout{crowd: crowd}, _ctx), do: crowd
  def crowd(_no_loadout, _ctx), do: []

  # `spent?` mede contra as duas: o modo gasta as duas.
  @impl true
  def damage_keys(%Loadout{aoe: aoe, single: single}, _ctx), do: aoe ++ single
  def damage_keys(_no_loadout, _ctx), do: []

  # "Tab volta a ser permitido" — e aqui ele é a primeira metade do fluxo, não
  # uma opção: sem alvo travado a tecla de alvo único não tem em quem bater.
  @impl true
  def tab?(_ctx), do: true

  defp area(%Loadout{aoe: aoe}), do: aoe
  defp area(_no_loadout), do: []

  # Leitura ausente é CEGA, e cega aperta: segurar dano por causa de uma barra
  # que ninguém conseguiu ler é o pior lado de errar — a mesma regra que o
  # `Plan.Standard` já segue.
  defp prontas(keys, ctx) do
    case Map.get(ctx, :ready_keys) do
      nil -> keys
      ready -> Enum.filter(keys, &(&1 in ready))
    end
  end
end
