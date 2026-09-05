defmodule Pokex.Bots.SkillMeter do
  @moduledoc """
  Quanto cada tecla tira de um bicho, e quanto tempo ela leva pra tirar.

  ## A ideia é dele, inteira

  "Seria interessante se ele às vezes entrasse num modo de calibração de
  checagem. Por exemplo ele e um inimigo de vida cheia, o sistema identifica que
  o inimigo de vida cheia, usa uma skill e calcula a diferença e salva essa
  diferença e associa a essa skill... se ele se identificar aqui com a skill 4
  sozinha, ele já mata, ele não precisa ficar usando 4, 5, 6 sempre" (26/08).

  E o segundo número, que ele também viu antes de qualquer medição: "a spell 4
  leva tipo 1s para realmente dar dano e às vezes ele sai apertando 4, 5, 6. Na
  prática a spell 4 já mataria mas parece que ele não sabe."

  ## De onde sai, sem nenhuma captura nova

  A lista de batalha já é fotografada a cada tique e já publica a barra de vida
  de cada linha (`hp`) e qual delas está travada (`locked_row`). Medir é olhar a
  linha travada antes do aperto e de novo depois — a queda é o dano, e QUANDO
  ela aparece é o atraso. Nada aqui tira foto.

  ## Uma tecla por vez, senão não é medida

  Uma rajada de três teclas tira uma queda só, e ninguém sabe de quem foi. Então
  o medidor só aceita presses de UMA tecla, que é exatamente o modo de checagem
  que ele descreveu — e é por isso que `Pokex.Bots.Combat.Worker` só o chama
  quando a rajada tem uma tecla e o modo está ligado.

  ## Ele mede a barra, não o número

  A barra é contada em pixels verdes, então o que se guarda é uma FRAÇÃO: quanto
  da barra sumiu. É o que ele pediu ("tira essa porcentagem de vida do pokémon e
  salva isso associado"), e sobrevive a monstros de vidas diferentes, que um
  número absoluto não faria.

  ## O que ele NÃO consegue saber

  Que a queda foi dele. Outro jogador batendo na mesma linha entra na conta, e
  um bicho morrendo some da lista antes de terminar de cair. Por isso as
  amostras são guardadas cruas e o resumo sai em MEDIANA, com quantas amostras
  ele tem ao lado: um número com três amostras não merece a mesma fé que um com
  quarenta, e escondê-lo atrás de uma média seria a mesma invenção que este
  módulo existe pra apagar.
  """

  alias Pokex.Perception.WorldState

  @type shot :: %{key: String.t(), took_pct: float, delay_ms: non_neg_integer}

  # How long to wait for the drop to show: about 1s observed, plus slack for the list tick.
  @wait_ms 2_500
  @poll_ms 100

  # A drop smaller than this is bar-reading noise, not damage.
  @min_drop_pct 2.0

  @doc "O modo está ligado? Desligado por padrão: ele mede quando quer medir."
  @spec on?() :: boolean
  def on?, do: Pokex.Settings.get(:skill_meter_enabled) == true

  @doc """
  Observa UM aperto: espera a linha travada cair e devolve quanto e quando.

  `{:ok, shot}` ou `{:error, reason}`. Bloqueia até a queda ou até `@wait_ms`,
  então quem chama tem que estar num processo que pode morrer — no
  `Pokex.Bots.Combat.Worker` é o mesmo processo da rajada, ao lado do recibo.
  """
  @spec watch(String.t(), keyword) :: {:ok, shot} | {:error, atom}
  def watch(key, opts \\ []) do
    read = Keyword.get(opts, :read, &battle/0)
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)

    case locked_bar(read.()) do
      {:ok, row, before} when before > 0 ->
        chase(%{
          key: key,
          row: row,
          before: before,
          started: now.(),
          now: now,
          read: read,
          sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
        })

      # A bar already empty before the press has no drop to give.
      {:ok, _row, _zero} ->
        {:error, :no_bar}

      error ->
        error
    end
  end

  defp chase(t) do
    if t.now.() - t.started > @wait_ms do
      {:error, :no_drop}
    else
      t.sleep.(@poll_ms)
      judge(t, locked_bar(t.read.()))
    end
  end

  # DIED: the bar hit zero or the row left the list. The most valuable measurement here (a key
  # that kills alone), and the only one that would be lost for looking like an error.
  defp judge(%{row: row} = t, {:ok, row, 0}), do: killed(t)
  defp judge(t, {:error, :no_bar}), do: killed(t)

  # The locked row changed mob (the previous one died, the list moved): the drop now is not
  # from the same bar, and such a measurement is worse than none.
  defp judge(%{row: row} = t, {:ok, row, bar}), do: drop(t, bar)

  defp judge(_t, {:ok, _other_row, _bar}), do: {:error, :target_changed}

  # No locked target at all: the list may have moved for any reason, and calling that a death
  # would invent a 100%.
  defp judge(_t, {:error, _no_target}), do: {:error, :target_gone}

  defp drop(%{before: before} = t, bar) when bar >= before, do: chase(t)

  defp drop(t, bar) do
    took = (t.before - bar) * 100 / t.before

    if took >= @min_drop_pct,
      do: {:ok, shot(t, Float.round(took, 1))},
      else: chase(t)
  end

  defp killed(t), do: {:ok, shot(t, 100.0)}

  defp shot(t, pct), do: %{key: t.key, took_pct: pct, delay_ms: t.now.() - t.started}

  @doc """
  Observa e GUARDA. O que o processo da rajada chama no modo de checagem.

  Nunca levanta e nunca responde: uma medição que pudesse derrubar a caçada
  junto seria uma troca pior do que não medir.
  """
  @spec file(String.t(), keyword) :: :ok
  def file(key, opts \\ []) do
    case watch(key, opts) do
      {:ok, shot} -> save(Map.update(shots(), key, [shot], &[shot | &1]))
      {:error, _nothing_to_learn} -> :ok
    end
  rescue
    _anything -> :ok
  end

  @doc "Tudo que foi medido, por tecla, mais novo primeiro."
  @spec shots() :: %{optional(String.t()) => [shot]}
  def shots do
    with {:ok, raw} <- File.read(Pokex.Home.skill_meter_file()),
         {:ok, %{"shots" => by_key}} <- JSON.decode(raw) do
      Map.new(by_key, fn {key, list} ->
        # The key is the map key; it goes back INSIDE each shot so a shot read from the
        # file has the same shape as a fresh one.
        {key, Enum.map(list, &%{key: key, took_pct: &1["took_pct"], delay_ms: &1["delay_ms"]})}
      end)
    else
      _nothing_or_torn -> %{}
    end
  end

  @doc "Esquece o que mediu — outro pokémon tem outras teclas."
  @spec clear() :: :ok
  def clear, do: save(%{})

  @doc """
  O que as amostras dizem, por tecla — e o que ele quer saber com elas.

  `%{shots:, took_pct:, delay_ms:, to_kill:}`. O `to_kill` é a pergunta dele
  inteira: "se ele se identificar aqui com a skill 4 sozinha, ele já mata, ele
  não precisa ficar usando 4, 5, 6 sempre".

  MEDIANA, nunca média: outro jogador batendo na mesma linha entra na conta, e
  uma média deixa esse dano alheio dentro do número pra sempre. E o número de
  amostras sai junto, porque três amostras não merecem a fé de quarenta.
  """
  @spec summary() :: %{optional(String.t()) => map}
  def summary do
    Map.new(shots(), fn {key, list} ->
      pcts = list |> Enum.map(& &1.took_pct) |> Enum.sort()
      delays = list |> Enum.map(& &1.delay_ms) |> Enum.sort()
      took = median(pcts)

      {key,
       %{
         shots: length(list),
         took_pct: took,
         delay_ms: median(delays),
         to_kill: if(took > 0, do: ceil(100 / took), else: nil)
       }}
    end)
  end

  # The floor is the lower half: this meter errs low on purpose. "Need one more shot" is a
  # cheap mistake next to "thought it killed".
  defp median([]), do: 0
  defp median(sorted), do: Enum.at(sorted, div(length(sorted) - 1, 2))

  # The cap is not tidiness: the whole file is read on every measured shot.
  @max_shots 200

  defp save(by_key) do
    body =
      JSON.encode!(%{
        "shots" =>
          Map.new(by_key, fn {key, list} ->
            {key,
             list
             |> Enum.take(@max_shots)
             |> Enum.map(&%{"took_pct" => &1.took_pct, "delay_ms" => &1.delay_ms})}
          end)
      })

    Pokex.Home.write!(Pokex.Home.skill_meter_file(), body)
  end

  # The LOCKED row's bar, in green pixels. Without a locked target there is nothing to
  # measure: a random row's drop is not this key's damage.
  defp locked_bar(%{locked_row: row, hp: hp}) when is_integer(row) and is_list(hp) do
    case Enum.at(hp, row) do
      count when is_integer(count) -> {:ok, row, count}
      # The locked row left the list: during the chase that is a death, before it there is
      # nothing to measure. The caller knows which.
      nil -> {:error, :no_bar}
    end
  end

  defp locked_bar(_no_lock), do: {:error, :no_target}

  defp battle do
    max_age = Pokex.Settings.get(:combat_world_max_age_ms)

    case WorldState.get(:battle, max_age, System.monotonic_time(:millisecond)) do
      {:ok, fact} -> fact
      _stale_or_missing -> %{}
    end
  end
end
