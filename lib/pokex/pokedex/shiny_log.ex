defmodule Pokex.Pokedex.ShinyLog do
  @moduledoc """
  The trophy shelf (`~/.pokex/shiny_log.json`): every Shiny the bot SAW, with
  what happened to it.

  One entry per encounter — `%{at, star_px, action, outcome, note}`:

    * `action` — what the guard did on sight: "escape" | "alarm"
    * `outcome` — updated as the encounter resolves: `"seen"` → `"killed"`
      (combat killed it) / `"ball"` (a ball was thrown) / `"fled"` (we fled)

  Values are stored in English and shown through `action_label/1` and
  `outcome_label/1`; entries written by older builds are translated on read, so
  a shelf recorded in Portuguese keeps rendering exactly as it did.

  The species NAME is unknown to the detector (the star says SHINY, not
  WHICH) — `note` carries whatever context we do have (the lure's possible
  shinies, when the fishing lure is known). Newest first, capped, so the
  file stays small and the page renders instantly.
  """

  alias Pokex.Home

  @cap 200

  @legacy_action %{"fugir" => "escape", "alarme" => "alarm"}
  @legacy_outcome %{"visto" => "seen", "morto" => "killed", "bola" => "ball", "fugiu" => "fled"}

  @action_labels %{"escape" => "fugir", "alarm" => "alarme"}
  @outcome_labels %{"seen" => "visto", "killed" => "morto", "ball" => "bola", "fled" => "fugiu"}

  @doc "How the panel says what the guard did — the value itself if it is not one of ours."
  def action_label(action), do: Map.get(@action_labels, action, action)

  @doc "How the panel says how the encounter ended."
  def outcome_label(outcome), do: Map.get(@outcome_labels, outcome, outcome)

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
        outcome: attrs[:outcome] || "seen",
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
      action: translate(@legacy_action, map["action"]),
      outcome: translate(@legacy_outcome, map["outcome"] || "seen"),
      note: map["note"]
    }
  end

  defp entry(_corrupt), do: %{at: nil, star_px: nil, action: nil, outcome: "seen", note: nil}

  defp translate(table, value) when is_binary(value), do: Map.get(table, value, value)
  defp translate(_table, value), do: value

  defp file, do: Path.join(Home.dir(), "shiny_log.json")
end
