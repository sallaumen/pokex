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

  `ready/3` cruza as duas fontes e a regra é conservadora dos dois lados: uma
  tecla só está pronta se a tela não disser que não E o relógio não disser que
  não. A tela é o jogo falando (ela sabe de coisas que ninguém escreveu: um
  silence, um cooldown global); o relógio é o que a gente sabe ter apertado (e
  ele sabe de coisas que a tela demora a mostrar — o fato tem idade, e uma foto
  de 400ms atrás ainda mostra pronta a tecla que já saiu).

  Com a tela ilegível, o relógio responde sozinho — que é o ganho grande: em vez
  de rotação cega, o bot segue sabendo o que gastou.

  ## O revive zera tudo

  É a regra R3 do jogo dele, medida em vídeo: o revive devolve o pokémon com
  todos os cooldowns em zero. `reset/1` existe para o worker carimbar isso, e é
  o que torna o relógio fiel depois de um reset — sem ele, o relógio seguraria
  teclas que o jogo já devolveu.
  """

  @table :pokex_skill_clock

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
  As teclas que o RELÓGIO considera prontas, entre as de `cooldowns`.

  Uma tecla sem cooldown escrito conta como pronta: o relógio não inventa
  espera para o que ninguém mediu.
  """
  @spec ready_by_clock(%{optional(String.t()) => pos_integer}, integer) :: [String.t()]
  def ready_by_clock(cooldowns, now \\ now()) when is_map(cooldowns) do
    for {key, _ms} <- cooldowns, cooling_ms(key, cooldowns, now) == 0, do: key
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

  * tela com lista → a interseção, porque as duas fontes só valem quando
    concordam e cada uma sabe de algo que a outra não sabe;
  * tela `nil` (ilegível, velha, ausente) → a resposta do relógio, que é o
    ponto deste módulo: uma leitura ruim deixava o combate cego;
  * relógio vazio E tela nil → `nil`, o desconhecido de sempre, para quem lê
    isso continuar falhando OPEN como sempre fez.
  """
  @spec ready([String.t()] | nil, %{optional(String.t()) => pos_integer}, integer) ::
          [String.t()] | nil
  def ready(screen, cooldowns, now \\ now())

  def ready(screen, cooldowns, _now) when is_list(screen) and map_size(cooldowns) == 0,
    do: screen

  def ready(screen, cooldowns, now) when is_list(screen),
    do: Enum.reject(screen, &(cooling_ms(&1, cooldowns, now) > 0))

  def ready(nil, cooldowns, _now) when map_size(cooldowns) == 0, do: nil

  def ready(nil, cooldowns, now), do: ready_by_clock(cooldowns, now)

  defp now, do: System.monotonic_time(:millisecond)
end
