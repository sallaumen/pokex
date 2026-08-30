defmodule Pokex.Sim.Verdict do
  @moduledoc """
  O que um cenário PROMETEU, cobrado da corrida que ele produziu.

  Até aqui uma corrida da bancada respondia seis números — mortos, sumiram, de
  pé, vida no fim, quando reviveu, como acabou — e cabia a ele lembrar qual era
  a pergunta daquele cenário e decidir sozinho se aquilo era bom. Treze
  cenários depois isso é trabalho de arqueólogo: os números do "Couraçado" e do
  "Casca de ovo" são parecidos e querem dizer coisas opostas.

  Uma promessa é uma propriedade que a corrida ou cumpre ou não cumpre, escrita
  na língua dele e verificável contra o relatório do `Sim.Bench`. O cenário
  declara quais valem pra ele (`Scenario.espera`), e a tela mostra ✅ ou ❌ ao
  lado do nome — que é a diferença entre "rodei e olhei" e "passou".

  ## As promessas não são todas do mesmo tipo, e é de propósito

  Três delas (`:nao_cai`, `:mata`, `:anda`) falam da CAÇADA: ela aconteceu, e
  aconteceu inteira. As outras falam das REGRAS que ele ditou — o revive só com
  a barra gasta, o revive dentro dos 5s depois do controle. Um cenário costuma
  cobrar uma de cada: "sobreviveu" sem "usou o revive direito" é um bot que
  sobreviveu por sorte.

  ## O que NÃO tem promessa

  Um cenário `:quebrado` (a tecla que não sai, o revive que falha) existe pra
  mostrar o estrago, e cobrar `:nao_cai` dele seria cobrar que a falha não
  falhasse. Esses declaram só o que ainda tem que valer com a peça quebrada —
  em geral `:anda`: seja qual for o defeito, a caçada não pode virar estátua.
  """

  # A ORDEM É A DA TELA. Uma promessa quebrada aparece primeiro na lista de
  # falhas, então a mais grave vem antes: cair é pior que gastar revive à toa.
  @promessas [
    {:nao_cai, "não cai", "o pokémon não vai ao chão nenhuma vez"},
    {:mata, "mata", "a caçada matou alguma coisa — não andou em círculos"},
    {:anda, "anda", "não passou a corrida parada no mesmo lugar"},
    {:revive_util, "revive só com a barra gasta",
     "nenhum revive saiu com tecla de dano ainda pronta"},
    {:revive_no_prazo, "controle antes do revive",
     "nenhum revive saiu com o controle pronto na mão e sem usar (R10)"},
    {:sem_revive, "sem gastar revive", "a corrida inteira sem precisar de um revive"},
    {:sem_dano, "sem tomar dano", "o pokémon terminou sem levar UMA mordida"},
    {:aguenta, "o tanque segura",
     "a vida nunca caiu abaixo da metade — nenhuma janela cascateou"},
    {:stun_sempre, "chefe sempre no ciclo",
     "nenhum chefe passou de uma janela estrutural acordado (3s) — acima disso um ciclo se perdeu"},
    {:limpa, "limpa a tela", "terminou sem monstro de pé"}
  ]

  @type promessa ::
          :nao_cai
          | :mata
          | :anda
          | :revive_util
          | :revive_no_prazo
          | :sem_revive
          | :sem_dano
          | :aguenta
          | :stun_sempre
          | :limpa
  @type t :: %{
          promessa: promessa,
          label: String.t(),
          note: String.t(),
          cumpriu?: boolean,
          porque: String.t()
        }

  @doc "Todas as promessas que um cenário pode declarar, na ordem da tela."
  @spec all() :: [promessa]
  def all, do: Enum.map(@promessas, &elem(&1, 0))

  @doc "O nome curto de uma promessa."
  @spec label(promessa) :: String.t()
  def label(promessa), do: @promessas |> entry(promessa) |> elem(1)

  @doc "O que ela cobra, em uma frase."
  @spec note(promessa) :: String.t()
  def note(promessa), do: @promessas |> entry(promessa) |> elem(2)

  @doc """
  Julga uma corrida contra as promessas de `espera`.

  `report` é o que `Sim.Bench.run/2` devolve. Uma promessa que este relatório
  não consegue responder cumpre — a bancada não tem nada a dizer, e inventar um
  ❌ a partir de silêncio é pior que não perguntar.
  """
  @spec judge(map, [promessa]) :: [t]
  def judge(report, espera) do
    for promessa <- Enum.filter(all(), &(&1 in espera)) do
      {cumpriu?, porque} = check(promessa, report)

      %{
        promessa: promessa,
        label: label(promessa),
        note: note(promessa),
        cumpriu?: cumpriu?,
        porque: porque
      }
    end
  end

  @doc "A corrida cumpriu TODAS as promessas que declarou?"
  @spec passed?([t]) :: boolean
  def passed?(veredito), do: Enum.all?(veredito, & &1.cumpriu?)

  @doc """
  O selo de uma corrida: `:ok` quando tudo passou, `:falhou` quando alguma
  promessa caiu, `:sem_promessa` quando o cenário não declarou nenhuma.
  """
  @spec seal([t]) :: :ok | :falhou | :sem_promessa
  def seal([]), do: :sem_promessa
  def seal(veredito), do: if(passed?(veredito), do: :ok, else: :falhou)

  # --- as cobranças -----------------------------------------------------------

  defp check(:nao_cai, %{metrics: %{deaths: []}}), do: {true, "ficou de pé a corrida inteira"}

  defp check(:nao_cai, %{metrics: %{deaths: quedas}}),
    do: {false, "caiu #{length(quedas)}× (primeira em #{segundos(hd(quedas))})"}

  defp check(:mata, %{outcome: %{killed: n}}) when n > 0, do: {true, "#{n} mortos"}
  defp check(:mata, _nada), do: {false, "não matou nada"}

  # "Parada" é o tempo que o mundo passou sem o personagem sair do lugar, e o
  # próprio `Bench` já o conta (`ms_stalled`). Metade da corrida é o corte:
  # uma caçada legítima passa tempo parada matando, mas não a maior parte dela.
  defp check(:anda, %{metrics: %{ms_stalled: parada, ms: total}}) when total > 0 do
    if parada * 2 <= total,
      do: {true, "parada em #{pct(parada, total)}% da corrida"},
      else: {false, "parada em #{pct(parada, total)}% da corrida"}
  end

  defp check(:anda, _sem_corrida), do: {true, "a corrida não durou o bastante pra dizer"}

  # A régua do combo dele contra chefe (29/08): "ou otimizamos para realmente
  # não termos abertura a falha, ou 1 segundo sem stun no campo quer dizer que
  # eu morri". `sem_dano` é o RESULTADO — nem uma mordida; `stun_sempre` é o
  # MECANISMO — nenhum chefe acordado por 1s. Cobrar os dois separa "sorte"
  # de "combo certo": dá pra não tomar dano fugindo, e dá pra manter o stun e
  # morrer de outra coisa.
  defp check(:sem_dano, %{metrics: %{min_hp: 100}}), do: {true, "nem uma mordida"}

  defp check(:sem_dano, %{metrics: %{min_hp: hp}}) when is_integer(hp),
    do: {false, "a vida chegou a #{hp}%"}

  defp check(:sem_dano, _sem_leitura), do: {false, "a vida nunca foi lida — não dá pra afirmar"}

  # A RÉGUA É A FÍSICA DO COMBO DELE (30/08): o stun dura 3s e só sai como
  # prefixo do F4; o ciclo de segurança cabe em 5s ("se tudo não cabe em 5
  # segundos, tem algo errado"). Isso deixa ~2s de chefe acordado POR CICLO,
  # por construção — inevitável. O que a promessa acusa é o ciclo PERDIDO:
  # um chefe acordado além de 3s (uma janela estrutural + a folga da rajada)
  # significa que um stun ou um F4 não saiu na vez dele.
  defp check(:stun_sempre, %{metrics: %{bosses_born: 0}}),
    do: {false, "nenhum chefe nasceu — a promessa não foi exercida"}

  defp check(:stun_sempre, %{metrics: %{boss_awake_max_ms: pior}}) when pior <= 3_000,
    do: {true, "pior trecho acordado: #{pior}ms"}

  defp check(:stun_sempre, %{metrics: %{boss_awake_max_ms: pior}}),
    do: {false, "um chefe ficou #{pior}ms acordado — um ciclo do combo se perdeu"}

  # …e `aguenta` é a outra metade: as janelas estruturais custam mordida, mas
  # nunca podem CASCATEAR — vida abaixo da metade é ciclo perdido virando
  # espiral.
  defp check(:aguenta, %{metrics: %{min_hp: hp}}) when is_integer(hp) and hp >= 50,
    do: {true, "vida mínima: #{hp}%"}

  defp check(:aguenta, %{metrics: %{min_hp: hp}}) when is_integer(hp),
    do: {false, "a vida caiu a #{hp}% — as janelas cascatearam"}

  defp check(:aguenta, _sem_leitura), do: {false, "a vida nunca foi lida — não dá pra afirmar"}

  # `spent?` é tri-estado: `false` é a acusação (havia tecla de dano pronta e o
  # revive saiu assim mesmo), `nil` é a barra ilegível — e num cenário cego
  # tratar "não sei" como desperdício seria cobrar dele o que a tela escondeu.
  #
  # E vale só COM BICHO NA FRENTE, pelo mesmo motivo que a promessa do controle:
  # o revive de PREPARAÇÃO (R11, tela limpa) existe justamente pra sair com a
  # barra pela metade — "eu sempre uso um revive antes de matar o próximo grupo,
  # mesmo que nem tenha acabado todos os cooldowns, pra já deixar preparado".
  # Cobrar dele barra gasta é cobrar que a regra dele não aconteça: medido, era
  # o que reprovava o "Casca de ovo" em todas as sementes, com 5 ou 6 revives
  # que eram todos preparação numa tela vazia.
  defp check(:revive_util, %{metrics: %{revives: revives}}) do
    atoa = Enum.filter(revives, &desperdicou_revive?/1)

    case atoa do
      [] -> {true, "#{length(aceitos(revives))} revives, nenhum desperdiçado na pilha"}
      atoa -> {false, "#{length(atoa)} revive(s) na pilha com tecla de dano ainda pronta"}
    end
  end

  # R10, a regra que ele ditou — e ela tem DUAS metades, das quais só uma é
  # cobrável do bot: "usar o revive dentro de 5s depois do controle" vale
  # quando existe controle pra usar. A outra metade é ordem dele em maiúsculas:
  # "se não tiver livre, usar o que tem de cooldown e usa o revive, não perde
  # tempo fugindo".
  #
  # Então o que se cobra é o DESPERDÍCIO: revive que saiu com o controle pronto
  # na mão e sem stun na janela. Um revive com o controle frio cumpre; um revive
  # num pokémon sem controle classificado (`control_ready?: nil`) não tem
  # escolha a fazer e também cumpre. Cobrar a janela de todo revive acusaria o
  # bot de desobedecer a regra exatamente quando está obedecendo à outra.
  @janela_ms 5_000

  defp check(:revive_no_prazo, %{metrics: %{revives: revives}}) do
    desperdicados = Enum.filter(aceitos(revives), &desperdicou_controle?/1)

    case {aceitos(revives), desperdicados} do
      {[], _nenhum} -> {true, "não precisou de revive"}
      {todos, []} -> {true, "#{length(todos)} revives, nenhum com controle na mão"}
      {_todos, atoa} -> {false, "#{length(atoa)} revive(s) com o controle pronto e sem usar"}
    end
  end

  defp check(:sem_revive, %{metrics: %{revives: revives}}) do
    case aceitos(revives) do
      [] -> {true, "nenhum revive gasto"}
      gastos -> {false, "gastou #{length(gastos)} revive(s)"}
    end
  end

  defp check(:limpa, %{outcome: %{left_alive: 0}}), do: {true, "terminou com a tela limpa"}
  defp check(:limpa, %{outcome: %{left_alive: n}}), do: {false, "#{n} ainda de pé no fim"}

  # Desperdício de revive é o que sai com a barra pela metade NA PILHA e fora
  # da emergência. As duas exceções são regras dele, não folga:
  #
  #   * tela limpa é o revive de PREPARAÇÃO (R11) — ele existe pra sair com a
  #     barra pela metade, "pra já deixar preparado pro próximo grupo";
  #   * `:emergency` é a faixa vermelha — reviver pra salvar o pokémon de morrer
  #     não olha cooldown nenhum, e cobrar economia de um resgate é cobrar que
  #     ele deixe o bicho cair.
  defp desperdicou_revive?(revive) do
    revive.accepted? and revive.spent? == false and com_bicho_na_frente?(revive) and
      revive.phase != :emergency
  end

  # Só é desperdício com TRÊS coisas verdadeiras ao mesmo tempo: havia bicho na
  # frente, o controle estava PRONTO, e o stun não saiu na janela.
  #
  # A primeira é a que quase deixei de fora, e ela inverte o veredito de metade
  # dos revives: o revive de TELA LIMPA (a R11, `revive: :prepare` — chegar no
  # próximo grupo com a barra cheia) não gasta controle DE PROPÓSITO, e é isso
  # que mantém a tecla guardada pro revive perigoso. Contá-lo como desperdício
  # acusa o bot exatamente pela economia que ele está fazendo.
  #
  # `control_ready?` ausente (relatório antigo) ou `nil` (pokémon sem controle
  # classificado) não acusa ninguém.
  defp desperdicou_controle?(revive) do
    com_bicho_na_frente?(revive) and Map.get(revive, :control_ready?) == true and
      (is_nil(revive.since_stun_ms) or revive.since_stun_ms > @janela_ms)
  end

  # `nil` é a tela ilegível: não dá pra saber se havia pilha, e um cenário cego
  # não pode produzir acusação.
  defp com_bicho_na_frente?(%{enemies: n}) when is_integer(n), do: n > 0
  defp com_bicho_na_frente?(_tela_ilegivel), do: false

  defp aceitos(revives), do: Enum.filter(revives, & &1.accepted?)

  defp segundos(ms), do: "#{Float.round(ms / 1_000, 1)}s"
  defp pct(part, total), do: round(part * 100 / total)

  defp entry(promessas, promessa) do
    Enum.find(promessas, {promessa, to_string(promessa), ""}, &(elem(&1, 0) == promessa))
  end
end
