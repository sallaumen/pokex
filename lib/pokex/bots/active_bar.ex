defmodule Pokex.Bots.ActiveBar do
  @moduledoc """
  The skill bar of whoever is on the field: where it is, how many slots it has,
  and the per-slot READY references.

  "seria legal se pudéssemos calibrar uma barra de skills para cada pokémon (…)
  e agora depende do nome do pokémon" (Lucas, 2026-08-12). He is right, and for
  a reason stronger than the layout: the READY references ARE the skill icons.
  A set captured with one pokémon out is a set of the WRONG PICTURES the moment
  he swaps — every cooldown then scores against art that is not on the bar.

  The number of slots is the visible half of the same problem: his pokémon do
  not all carry nine moves.

  ## There is no shared bar anymore

  There used to be one: a pokémon without its own bar fell back to the screen
  calibration's. The fallback is what made 2026-08-24 possible — the shared
  rectangle was re-marked over eight slots while its count stayed at four, and
  since nothing on the field owned it, nothing contradicted it: the screen
  ruler read the doubled slot as a screen 1.9× the reference and rescaled 21
  settings by it. "Só deveria aceitar barra skill calibrada por pokemon, nada
  de barra global mais" (Lucas, 2026-08-24).

  So the answer is the active pokémon's bar or NOTHING, and `Pokex.Preflight`
  refuses to start a bot that would read a bar nobody owns.
  """

  alias Pokex.Pokedex.Team

  @type bar :: %{
          region: tuple | nil,
          count: pos_integer | nil,
          refs: list | nil,
          name: String.t() | nil
        }

  @doc """
  The bar to read right now: the active pokémon's, or an empty one when the
  pokémon on the field has none of its own.

  `name` says whose it is, and `nil` there means there is no bar to read — not
  "somebody else's".
  """
  @spec current() :: bar
  def current do
    case active_bar() do
      nil -> %{region: nil, count: nil, refs: nil, name: nil}
      {name, bar} -> %{region: bar[:region], count: bar[:count], refs: bar[:refs], name: name}
    end
  end

  @doc "Just the region, for callers that only need to know where to capture."
  @spec region() :: tuple | nil
  def region, do: current().region

  @doc "Whether the pokémon on the field has a bar of its own."
  @spec own?() :: boolean
  def own?, do: active_bar() != nil

  # Team resolves it in one read of the file: this is asked twice per skill-bar
  # feed tick, so `active/0` followed by `bar/1` — four reads for one answer —
  # is not a spelling detail down here.
  defp active_bar, do: Team.active_bar()
end
