defmodule Pokex.Bots.Combat.Plan.AutoCombo do
  @moduledoc """
  UMA TECLA, e o resto é esperar.

  "O jogo já está configurado para executar as skills ofensivas por meio de um
  único toque na tecla R. O bot não deve administrar ou pressionar
  individualmente as skills ofensivas nesse modo" (Lucas, 01/09).

  Então este plano responde a mesma tecla em toda pergunta de ataque — abertura,
  rotação e mão pequena — e deixa vazio tudo que seria uma segunda mão.

  ## O controle NÃO é nosso

  A corrente do cliente termina em controle: "os monstros que tiverem
  sobrevivido ainda estarão sob o efeito da skill de controle/stun". Gastar a
  tecla de controle por fora seria pagar duas vezes pelo mesmo sono e deixar o
  revive perigoso sem prefixo — a cadeia que matou o personagem em 28/08. Por
  isso `crowd/2` é `[]`: o cérebro não tem controle pra gastar, e o resgate
  também não vai prefixar nada.

  ## O que `spent?` mede continua sendo a BARRA

  `damage_keys/2` é o mesmo do modo comum, e é de propósito. A corrente gasta as
  skills DO POKÉMON: quando ela termina, elas estão em cooldown, e é exatamente
  por isso que o revive vale a pena — ele as devolve. Reportar `["r"]` aqui
  faria `spent?` falar de uma tecla que a barra não mostra, e todo revive que
  depende dele morreria em silêncio (o defeito do alvo único, 29/08).

  ## Quem impede a segunda prensa não é este módulo

  Este plano é puro: ele diz QUAL tecla, não QUANDO. A janela em que nada sai
  é `Combat.Combo`, consultada pela mão antes de cada prensa e pelo cérebro
  antes de cada revive.
  """

  @behaviour Pokex.Bots.Combat.Plan

  alias Pokex.Bots.Combat.{Combo, Plan}

  @impl true
  def opening(loadout, ctx), do: combo_key(loadout, ctx)

  # A ROTAÇÃO É A MESMA TECLA, e é ela que faz o ciclo repetir. A abertura sai
  # UMA vez, na borda em que o fogo libera; sem uma rotação que insista, o
  # segundo combo da luta nunca sairia. A cerca da janela é que recusa as
  # prensas que chegam cedo demais — oferecer sempre e recusar por fora é o que
  # faz a primeira tecla depois da janela sair na hora.
  @impl true
  def sustained(loadout, ctx), do: combo_key(loadout, ctx)

  # Não existe "mão pequena" numa tecla só: a corrente é indivisível.
  @impl true
  def small(loadout, ctx), do: combo_key(loadout, ctx)

  # "Não pressionar skills ofensivas individualmente."
  @impl true
  def single(_loadout, _ctx), do: []

  # O stun é a última metade da corrente, não uma tecla que o cérebro gasta.
  @impl true
  def crowd(_loadout, _ctx), do: []

  @impl true
  def damage_keys(loadout, ctx), do: Plan.Standard.damage_keys(loadout, ctx)

  # "Não usar Tab."
  @impl true
  def tab?(_ctx), do: false

  # A TECLA NÃO DEPENDE DO POKÉMON, e é isso que ela é: um atalho do CLIENTE,
  # como as posturas. Um pokémon sem skills classificadas ainda aperta a
  # corrente — o que ele perde é o ciclo do revive, que precisa da barra pra
  # saber que ela acabou. Tecla em branco é a única resposta vazia, e aí o
  # cérebro diz "nenhum pokémon configurado pra lutar" em voz alta.
  defp combo_key(_loadout, ctx) do
    key = Map.get(ctx, :combo_key) || Combo.key()

    if key == "", do: [], else: [key]
  end
end
