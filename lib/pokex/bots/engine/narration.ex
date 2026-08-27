defmodule Pokex.Bots.Engine.Narration do
  @moduledoc """
  What the engine SAYS, as a pure function of two ticks.

  A brain that decides in silence is indistinguishable from a brain that is
  stopped, so this exists — but a 200ms cadence is five lines a second, and a
  feed nobody can read is the same silence with more scrolling. So only the
  EDGES talk: a count that changed, a measurement that became knowable, a mind
  that changed.

  Pure on purpose. It used to live inside the worker's tick as five `defp`s that
  each took the whole state and returned it unchanged after a `log/2` — which
  made the rule ("when does the engine speak?") only testable by starting a
  GenServer and reading a PubSub topic.

  `lines/2` takes the previous tick and the current one, each `%{picture:,
  orders:}`, and answers the sentences to say in the order to say them.
  """

  @type tick :: %{picture: map | nil, orders: map | nil}

  @doc """
  The lines this tick earns, oldest concern first.

  `who` is how the pokémon on the field is named in the own-row sentence — the
  one measurement whose reading only means something with a name attached to it.
  """
  @spec lines(tick, tick, String.t()) :: [String.t()]
  def lines(previous, current, who \\ "o pokémon em campo") do
    Enum.flat_map(
      [&count/3, &own_row/3, &decision/3],
      & &1.(previous, current, who)
    )
  end

  # The count, when it moves. Losing the list is its own sentence: `nil` and
  # zero are opposite facts and the feed has to be able to tell them apart.
  defp count(%{picture: %{enemies: same}}, %{picture: %{enemies: same}}, _who), do: []

  defp count(previous, %{picture: %{enemies: nil}}, _who) do
    case previous do
      %{picture: %{enemies: was}} when not is_nil(was) ->
        ["perdi a lista de batalha — não sei quantos são"]

      _never_had_one ->
        []
    end
  end

  defp count(_previous, %{picture: nil}, _who), do: []

  defp count(_previous, %{picture: picture}, _who),
    do: ["#{picture.enemies} #{plural(picture.enemies)}#{named_as(picture)}"]

  defp count(_previous, _no_picture, _who), do: []

  defp plural(1), do: "inimigo na tela"
  defp plural(_n), do: "inimigos na tela"

  defp named_as(%{named: []}), do: ""
  defp named_as(%{named: named}), do: " — " <> Enum.map_join(named, ", ", &row_label/1)

  @doc """
  How one row of the battle list reads out loud: its name when the glyphs can
  spell it, its health when they cannot, and both when both are known.

  The health half is the answer to "o que a gente está esperando?" (27/08): the
  panel has been showing how hurt every creature is all along, and the feed was
  saying "sem nomes — layout não localizado" over it.
  """
  @spec row_label(map) :: String.t()
  def row_label(row) do
    case {Map.get(row, :name), Map.get(row, :hp_pct)} do
      {name, pct} when is_binary(name) and is_number(pct) -> "#{name} #{pct_text(pct)}"
      {name, _no_bar} when is_binary(name) -> name
      {_no_name, pct} when is_number(pct) -> pct_text(pct)
      _nothing_known -> "?"
    end
  end

  defp pct_text(pct), do: "#{round(pct * 100)}%"

  # THE MEASUREMENT. Said once, when it becomes knowable, and again only if it
  # ever changes its mind: whether his own pokémon takes a row in the list is
  # what decides if the ruler of three is measured against 3 rows or 4.
  defp own_row(%{picture: %{own_row_seen?: same}}, %{picture: %{own_row_seen?: same}}, _who),
    do: []

  defp own_row(_previous, %{picture: nil}, _who), do: []
  defp own_row(_previous, %{picture: %{own_row_seen?: nil}}, _who), do: []

  # A discount made on an ABSENCE must never read like one made on a name: on
  # 2026-08-18 the by-name discount silently never fired for a whole hunt, and
  # nothing on any screen said so. This line is what would have said it.
  defp own_row(_previous, %{picture: %{own_row_seen?: :unnamed}}, who),
    do: [
      "#{who} está na lista mas o nome saiu ilegível — descontei a primeira " <>
        "linha sem nome. Ensine os glifos dele na calibração pra voltar a descontar pelo nome."
    ]

  # Found by HEALTH, not by name: the Pokebar and the row's own track are two
  # readings of the same number, and when they agree the row is his.
  defp own_row(_previous, %{picture: %{own_row_seen?: :by_hp, own_hp: hp}}, who),
    do: [
      "#{who} está na lista sem nome legível — descontei a linha que está com " <>
        "#{hp}% de vida, a mesma da Pokebar"
    ]

  defp own_row(_previous, %{picture: %{own_row_seen?: true}}, who),
    do: ["#{who} ocupa uma linha da lista — a contagem desconta ele"]

  defp own_row(_previous, %{picture: %{own_row_seen?: false, rows: rows}}, who),
    do: ["#{who} NÃO aparece na lista (#{rows} linha(s), nenhuma é ele)"]

  defp own_row(_previous, _no_picture, _who), do: []

  # THE SHADOW. One line per DECISION CHANGE, in the same feed as what the bot
  # actually did — so a night can be read as two columns without a second
  # screen: "🧠 quem mandaria" beside the hunt's own lines. The `why` is the
  # whole point; the phase is there so a change of mind is visible even when the
  # sentence reads similar.
  defp decision(%{orders: %{why: same}}, %{orders: %{why: same}}, _who), do: []
  defp decision(_previous, %{orders: nil}, _who), do: []
  defp decision(_previous, %{orders: orders}, _who), do: ["🧠 #{orders.why}#{hint(orders)}"]
  defp decision(_previous, _no_orders, _who), do: []

  # What it WOULD have changed, named only when it differs from just watching —
  # this is what makes the comparison against the bot's real behaviour concrete.
  # Ordered by weight, not by field: a tick that would revive AND hold the route
  # is a revive — naming the hold there would bury the expensive half.
  defp hint(%{revive: :now}), do: " [reviveria agora]"
  defp hint(%{fire: :free}), do: " [liberaria o fogo]"
  defp hint(%{route: :hold}), do: " [seguraria a rota]"
  defp hint(_watching), do: ""
end
