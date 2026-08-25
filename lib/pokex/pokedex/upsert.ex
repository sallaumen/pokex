defmodule Pokex.Pokedex.Upsert do
  @moduledoc """
  Merging a sync's harvest into the base on disk, with the two dates the app
  keeps about each entry: when it ENTERED the base (`first_seen_at`) and when
  its content last actually changed (`changed_at`).

  Every run upserts: freshly fetched entries replace their names, everything
  else stays. That is what makes `--only Seadra` safe — it refreshes one
  species without dropping the other 909.
  """

  @doc "The base on disk plus this run's harvest, stamped."
  def merge(existing, fresh) do
    by_name = Map.new(existing, &{entry_name(&1), &1})
    fresh_names = MapSet.new(fresh, & &1.name)

    stamped = Enum.map(fresh, &stamp(&1, Map.get(by_name, &1.name)))

    Enum.reject(existing, &MapSet.member?(fresh_names, entry_name(&1))) ++ stamped
  end

  # Volatile/bookkeeping keys never count as a content change.
  @bookkeeping ~w(scraped_at first_seen_at changed_at)

  defp stamp(fresh, previous) do
    case Map.get(fresh, :scraped_at) do
      nil ->
        fresh

      now ->
        changed_at =
          cond do
            previous == nil -> now
            content(fresh) == content(previous) -> field(previous, "changed_at") || now
            true -> now
          end

        Map.merge(fresh, %{
          first_seen_at: (previous && field(previous, "first_seen_at")) || now,
          changed_at: changed_at
        })
    end
  end

  # Compare on STRING keys with the bookkeeping dropped: existing entries come
  # from JSON, fresh ones are atom-keyed maps — round-tripping the fresh one
  # through JSON makes the two directly comparable.
  defp content(entry) do
    entry
    |> JSON.encode!()
    |> JSON.decode!()
    |> Map.drop(@bookkeeping)
  end

  defp entry_name(entry), do: field(entry, "name")

  defp field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))
end
