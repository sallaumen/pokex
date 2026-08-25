defmodule Pokex.Engine.Tally do
  @moduledoc """
  A NOITE DE VERDADE em números, na mesma forma que o placar do simulador.

  O simulador responde "esse cérebro é melhor que aquele" porque é dono do
  mundo: ele sabe quantos monstros existiam e quantos morreram. Uma caçada real
  não tem esse luxo — o que ela tem é o rastro que o bot deixou. Este módulo lê
  esse rastro e responde as mesmas perguntas com ele.

  Três fontes, e cada uma sabe uma coisa que as outras não sabem:

    * `vitals` — o pulso da engine: vida, quantos na lista, quantas teclas de
      dano prontas, e se o pokémon está em campo. É daqui que saem o tempo no
      chão, o tempo sem cooldown e a distribuição de pilhas que ele encontrou.
    * `decision` — uma linha por MUDANÇA DE IDEIA, com a fase. É daqui que sai
      "onde foi o minuto".
    * `kill` — o único momento que o mundo real não deduz: `Combat` viu um alvo
      cair.

  ## O que este placar NÃO é

  Não é comparável ao do simulador linha a linha. Lá as taxas saem de um mundo
  inventado e valem como COMPARAÇÃO entre dois cérebros; aqui elas saem do jogo
  e valem como o que a noite realmente rendeu. O que se compara entre os dois é
  a FORMA — se a caçada real gasta o minuto onde a simulada gasta, o simulador
  está dizendo a verdade sobre a caçada.
  """

  alias Pokex.Engine.Events

  @minute_ms 60_000

  @doc """
  O placar de um dia, ou `nil` quando não há rastro nenhum.

  `at` existe pro teste: a janela é do primeiro ao último registro do dia, e um
  dia com um registro só não tem janela.
  """
  @spec of_day(Date.t()) :: map | nil
  def of_day(date \\ Date.utc_today()), do: date |> Events.read_day() |> card()

  @doc "O placar de uma lista de registros já lida."
  @spec card([map]) :: map | nil
  def card([]), do: nil

  def card(events) do
    vitals = Enum.filter(events, &(&1["kind"] == "vitals"))
    decisions = Enum.filter(events, &(&1["kind"] == "decision"))
    kills = Enum.filter(events, &(&1["kind"] == "kill"))

    case window(events) do
      nil ->
        nil

      {from, to} ->
        minutes = max(to - from, 1) / @minute_ms

        %{
          from: from,
          to: to,
          minutes: Float.round(minutes, 1),
          kills: length(kills),
          kills_per_min: per_min(length(kills), minutes),
          revives: revives(decisions),
          revives_per_min: per_min(revives(decisions), minutes),
          down_pct: share(vitals, &(&1["out"] != true)),
          stalled_pct: share(vitals, &stalled?/1),
          piles: piles(vitals),
          by_phase: by_phase(decisions, to)
        }
    end
  end

  # A janela é o rastro, não o relógio: um dia com um registro só não tem
  # duração, e dividir por ela seria inventar uma taxa.
  defp window(events) do
    times = for e <- events, is_integer(e["at"]), do: e["at"]

    case times do
      [] -> nil
      [_only] -> nil
      _many -> {Enum.min(times), Enum.max(times)}
    end
  end

  # A prensa do revive é uma DECISÃO, e é assim que ela aparece no rastro: uma
  # linha de decisão com `revive: "now"`. Contada por mudança de ideia, que é a
  # cadência em que essas linhas são escritas — duas seguidas com a mesma frase
  # são a mesma prensa.
  defp revives(decisions), do: Enum.count(decisions, &(&1["revive"] == "now"))

  # Sem pokémon em campo é o único tempo que é pura perda: não mata, não
  # defende, e as mordidas passam a ser DELE.
  defp share([], _pred), do: 0.0

  defp share(vitals, pred) do
    Float.round(Enum.count(vitals, pred) * 100 / length(vitals), 1)
  end

  # "Zero cooldowns livres com bicho na tela" — o estado que a R7 ataca.
  defp stalled?(v) do
    is_integer(v["enemies"]) and v["enemies"] > 0 and is_integer(v["ready"]) and v["ready"] == 0
  end

  # AS PILHAS QUE ELE ENCONTROU, que é a visão de mundo que faltava: quantas
  # vezes a lista de batalha teve 1, 2, 3… — a régua dele discutida com o que o
  # jogo entrega, em vez de com o que eu imagino.
  defp piles(vitals) do
    vitals
    |> Enum.map(& &1["enemies"])
    |> Enum.filter(&(is_integer(&1) and &1 > 0))
    |> Enum.frequencies()
  end

  # Onde foi o minuto. Uma linha de decisão vale até a próxima, que é
  # exatamente o que "uma linha por mudança de ideia" significa.
  defp by_phase([], _to), do: []

  defp by_phase(decisions, to) do
    decisions
    |> Enum.chunk_every(2, 1, [%{"at" => to}])
    |> Enum.reduce(%{}, fn [d, next], acc ->
      Map.update(acc, d["phase"], span(d, next), &(&1 + span(d, next)))
    end)
    |> shares()
  end

  defp span(d, next), do: max((next["at"] || d["at"]) - d["at"], 0)

  defp shares(by_phase) do
    total = by_phase |> Map.values() |> Enum.sum() |> max(1)

    by_phase
    |> Enum.map(fn {phase, ms} ->
      %{phase: phase, ms: ms, pct: Float.round(ms * 100 / total, 1)}
    end)
    |> Enum.sort_by(& &1.ms, :desc)
  end

  defp per_min(_count, minutes) when minutes <= 0, do: 0.0
  defp per_min(count, minutes), do: Float.round(count / minutes, 2)
end
