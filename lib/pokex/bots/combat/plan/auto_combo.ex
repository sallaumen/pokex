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
  # segundo combo da luta nunca sairia.
  #
  # …MAS SÓ COM BARRA PRA GASTAR, e é isto que fecha o ciclo dele.
  #
  # A corrente encadeia as skills DO POKÉMON: com todas em cooldown, apertar a
  # tecla não faz nada no jogo — e faz uma coisa péssima no bot, porque reabre a
  # janela de 4s e o revive perde a vez. Foi o que a noite de 02/09 mostrou:
  # 56 combos, 50 deles com a barra JÁ vazia, um a cada 4,0-4,5s (a janela
  # fechando e a rotação reapertando na hora), e só 7 revives. O cérebro decide
  # a cada 200ms e a mão dispara no frame seguinte: a mão sempre ganhava a
  # corrida, e o "usar o revive logo depois do combo" nunca acontecia.
  #
  # Com a barra vazia a resposta certa é NÃO APERTAR: aí o `mid_combo?` abre, o
  # cérebro vê `spent?` e manda o revive — que é o que devolve a barra e o que
  # faz a corrente seguinte valer alguma coisa.
  @impl true
  def sustained(loadout, ctx) do
    if bar_spent?(loadout, ctx), do: [], else: combo_key(loadout, ctx)
  end

  # Vazia é NENHUMA tecla de dano pronta. Leitura ausente é cega, e cega aperta:
  # segurar a corrente por causa de uma barra que ninguém conseguiu ler é o pior
  # lado de errar — a mesma regra que a rotação comum já segue.
  defp bar_spent?(loadout, ctx) do
    case Map.get(ctx, :ready_keys) do
      nil ->
        false

      ready ->
        case Plan.Standard.damage_keys(loadout, ctx) do
          [] -> false
          keys -> not Enum.any?(keys, &(&1 in ready))
        end
    end
  end

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
