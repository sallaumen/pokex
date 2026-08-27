defmodule Pokex.Bots.SkillClock do
  @moduledoc """
  O relógio das teclas: o que o bot apertou, quando, e o que isso implica.

  Até 27/08/2026 a única resposta para "essa tecla está pronta?" vinha da TELA
  (`Perception.ready_skills/1`, o fato `:skill_bar`). Isso tem três buracos que
  ele descreveu de uma vez:

    * **Leitura ruim = rotação cega.** O fato falha OPEN de propósito — nada
      pode parar de atacar por causa de um pixel — então uma barra ilegível
      devolve `nil` e o combate volta a apertar tudo em ordem, incluindo o que
      acabou de sair.
    * **Ninguém escreveu o cooldown de nada.** O bot não tinha onde saber que a
      área dele leva 45s e a de alvo único 8s, então não havia como preferir uma
      ordem, nem como dizer "acabou tudo".
    * **O revive virava um botão de reset barato.** Ele custa uma bola e um
      tempo; gastá-lo com metade da barra pronta é pagar caro por pouco.

  Este módulo é a metade que faltava: quem aperta CARIMBA aqui, e quem decide
  pergunta aqui. O carimbo mora em `Pokex.Bots.Body`, o único portão por onde
  uma tecla sai (`execute({:press, key})`), então não existe caminho que aperte
  sem o relógio saber.

  ## A tela continua mandando quando discorda

  `ready/4` cruza as duas fontes e a regra é conservadora dos dois lados: uma
  tecla só está pronta se a tela não disser que não E um cooldown ESCRITO não
  disser que não. A tela é o jogo falando (ela sabe de coisas que ninguém
  escreveu: um silence, um cooldown global); o relógio é o que a gente sabe ter
  apertado (e ele sabe de coisas que a tela demora a mostrar — o fato tem idade,
  e uma foto de 400ms atrás ainda mostra pronta a tecla que já saiu).

  Com a tela ilegível, o relógio responde sozinho — que é o ganho grande: em vez
  de rotação cega, o bot segue sabendo o que gastou.

  ## O revive zera tudo

  É a regra R3 do jogo dele, medida em vídeo: o revive devolve o pokémon com
  todos os cooldowns em zero. `reset/1` existe para o worker carimbar isso, e é
  o que torna o relógio fiel depois de um reset — sem ele, o relógio seguraria
  teclas que o jogo já devolveu.
  """

  @table :pokex_skill_clock

  # O QUE ASSUMIR PARA A TECLA QUE ELE AINDA NÃO MEDIU (pedido dele, 27/08: "na
  # falta de configuração, faz ele assumir que o cooldown é 45 segundos").
  #
  # É a média das duas famílias que o vídeo mediu (26/08, gravação de 53s): as
  # teclas 1, 2 e 3 voltam com 40s e as 4, 5 e 6 com 50s. O mesmo número que o
  # simulador usa pra quem não tem cooldown escrito.
  @assumed_ms 45_000

  @doc "O cooldown assumido pra tecla sem número escrito."
  @spec assumed_ms() :: pos_integer
  def assumed_ms, do: @assumed_ms

  @doc false
  def table, do: @table

  # Uma tabela pública e nomeada, no mesmo molde do `WorldState`: escrita a cada
  # tecla (o Body), lida a cada tique (o cérebro), de processos diferentes.
  @doc "Garante a tabela. Idempotente — chamado no boot e por quem chegar antes."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    # duas corridas criando a mesma tabela: a perdedora só precisa não morrer
    ArgumentError -> :ok
  end

  @doc "Carimba que `key` saiu agora."
  @spec pressed(String.t(), integer) :: :ok
  def pressed(key, at \\ now()) when is_binary(key) do
    ensure_table()
    :ets.insert(@table, {key, at})
    :ok
  end

  @doc "Quando `key` saiu pela última vez, ou nil."
  @spec last_press(String.t()) :: integer | nil
  def last_press(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, at}] -> at
      [] -> nil
    end
  end

  @doc """
  Esquece tudo — o que o revive faz no jogo, e o que um personagem novo pede.
  """
  @spec reset() :: :ok
  def reset do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  As teclas de `keys` que o RELÓGIO considera prontas — com o assumido valendo
  para as que ninguém mediu.

  Só é usado quando a TELA não respondeu: é aí que o palpite de 45s vale mais
  que o nada que existia antes.
  """
  @spec ready_by_clock([String.t()], %{optional(String.t()) => pos_integer}, integer) ::
          [String.t()]
  def ready_by_clock(keys, cooldowns, now \\ now()) when is_list(keys) and is_map(cooldowns) do
    Enum.filter(keys, &(assumed_cooling_ms(&1, cooldowns, now) == 0))
  end

  @doc """
  Quanto falta para `key` voltar, em ms, pelo cooldown ASSUMIDO quando não há um
  escrito. Zero quando está pronta.
  """
  @spec assumed_cooling_ms(String.t(), %{optional(String.t()) => pos_integer}, integer) ::
          non_neg_integer
  def assumed_cooling_ms(key, cooldowns, now \\ now()) do
    cooling_ms(key, Map.put_new(cooldowns, key, @assumed_ms), now)
  end

  @doc """
  Quanto falta para `key` voltar, em ms. Zero quando está pronta ou quando
  ninguém escreveu o cooldown dela.
  """
  @spec cooling_ms(String.t(), %{optional(String.t()) => pos_integer}, integer) ::
          non_neg_integer
  def cooling_ms(key, cooldowns, now \\ now()) do
    with ms when is_integer(ms) and ms > 0 <- Map.get(cooldowns, key),
         at when is_integer(at) <- last_press(key) do
      max(at + ms - now, 0)
    else
      _sem_cooldown_ou_sem_press -> 0
    end
  end

  @doc """
  As teclas prontas de verdade: a leitura da tela cruzada com o relógio.

  * tela com lista → ela manda, menos as teclas que um cooldown ESCRITO diz
    estarem esfriando (a foto tem idade: uma tecla que saiu há 200ms ainda
    aparece pronta nela);
  * tela `nil` (ilegível, velha, ausente) → o relógio responde sozinho, e aí o
    assumido de 45s vale — é o ponto deste módulo, porque antes uma leitura
    ruim deixava o combate cego;
  * sem teclas conhecidas e sem tela → `nil`, o desconhecido de sempre, pra
    quem lê continuar falhando OPEN como sempre fez.

  ## Por que o ASSUMIDO não derruba o que a tela viu

  Um cooldown escrito é medição dele e pode contradizer uma foto velha. Um
  cooldown assumido é palpite: se a skill volta em 8s e a gente chuta 45, vetar
  a tela faria o bot deixar de usar a tecla mais rápida da barra por 37
  segundos, e ninguém veria por quê. Palpite preenche buraco; não desmente
  observação.
  """
  @spec ready([String.t()] | nil, [String.t()], %{optional(String.t()) => pos_integer}, integer) ::
          [String.t()] | nil
  def ready(screen, keys, cooldowns, now \\ now())

  def ready(screen, _keys, cooldowns, _now) when is_list(screen) and map_size(cooldowns) == 0,
    do: screen

  def ready(screen, _keys, cooldowns, now) when is_list(screen),
    do: Enum.reject(screen, &(cooling_ms(&1, cooldowns, now) > 0))

  def ready(nil, [], _cooldowns, _now), do: nil

  def ready(nil, keys, cooldowns, now), do: ready_by_clock(keys, cooldowns, now)

  defp now, do: System.monotonic_time(:millisecond)
end
