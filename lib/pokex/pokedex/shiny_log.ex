defmodule Pokex.Pokedex.ShinyLog do
  @moduledoc """
  The trophy shelf (`~/.pokex/shiny_log.json`): every Shiny the bot SAW, with
  what happened to it.

  One entry per encounter — `%{at, star_px, action, outcome, note}`:

    * `action` — what the guard did on sight: "fugir" | "alarme"
    * `outcome` — updated as the encounter resolves: `"visto"` → `"morto"`
      (combat killed it) / `"bola"` (a ball was thrown) / `"fugiu"` (we fled)

  The species NAME is unknown to the detector (the star says SHINY, not
  WHICH) — `note` carries whatever context we do have (the lure's possible
  shinies, when the fishing lure is known). Newest first, capped, so the
  file stays small and the page renders instantly.
  """

  alias Pokex.Home

  @cap 200

  @doc "Every logged encounter, newest first."
  def entries do
    with {:ok, bin} <- File.read(file()),
         {:ok, list} when is_list(list) <- JSON.decode(bin) do
      Enum.map(list, &entry/1)
    else
      _missing_or_corrupt -> []
    end
  end

  @doc "Logs a fresh sighting; returns the entry (with its `at` id)."
  def record(attrs) do
    entry =
      %{
        at: DateTime.utc_now() |> DateTime.to_iso8601(),
        star_px: attrs[:star_px],
        action: attrs[:action],
        outcome: attrs[:outcome] || "visto",
        note: attrs[:note]
      }

    persist([entry | entries()])
    entry
  end

  @doc """
  Updates the outcome of the most recent encounter (the one still open) —
  what the kill / ball-thrown resolutions write when the fight ends.
  No-op when there is nothing logged.
  """
  def resolve_last(outcome, note \\ nil) do
    case entries() do
      [] ->
        :ok

      [last | rest] ->
        persist([%{last | outcome: outcome, note: note || last.note} | rest])
        :ok
    end
  end

  @doc "How many encounters are on the shelf."
  def count, do: length(entries())

  def clear, do: persist([])

  defp persist(list) do
    File.mkdir_p!(Home.dir())
    File.write!(file(), JSON.encode!(Enum.take(list, @cap)))
  end

  defp entry(map) when is_map(map) do
    %{
      at: map["at"],
      star_px: map["star_px"],
      action: map["action"],
      outcome: map["outcome"] || "visto",
      note: map["note"]
    }
  end

  defp entry(_corrupt), do: %{at: nil, star_px: nil, action: nil, outcome: "visto", note: nil}

  defp file, do: Path.join(Home.dir(), "shiny_log.json")
end
