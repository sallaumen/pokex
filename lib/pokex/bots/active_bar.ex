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

  ## The calibration is the fallback, not the rival

  A pokémon he has not calibrated answers with the screen calibration, exactly
  as before this module existed. That is what lets this arrive without a flag
  day: nothing breaks for the ones he has not got to yet, and each one he does
  calibrate simply starts being read with its own bar.
  """

  alias Pokex.Calibration
  alias Pokex.Pokedex.Team

  @type bar :: %{
          region: tuple | nil,
          count: pos_integer | nil,
          refs: list | nil,
          name: String.t() | nil
        }

  @doc """
  The bar to read right now: the active pokémon's when it has one, the screen
  calibration's otherwise.

  `name` says whose it is — `nil` meaning "the calibration's", which is what a
  page needs to tell him whether he is looking at this pokémon's bar or at the
  old shared one.
  """
  @spec current(Calibration.t() | nil) :: bar
  def current(calib) do
    case active_bar() do
      nil -> from_calibration(calib)
      {name, bar} -> %{region: bar[:region], count: bar[:count], refs: bar[:refs], name: name}
    end
  end

  @doc "Just the region, for callers that only need to know where to capture."
  @spec region(Calibration.t() | nil) :: tuple | nil
  def region(calib), do: current(calib).region

  @doc "Whether the pokémon on the field has a bar of its own."
  @spec own?() :: boolean
  def own?, do: active_bar() != nil

  defp active_bar do
    with name when is_binary(name) <- Team.active(),
         %{region: {_x, _y, _w, _h}} = bar <- Team.bar(name) do
      {name, bar}
    else
      _no_choice_or_no_bar -> nil
    end
  end

  defp from_calibration(%Calibration{} = calib),
    do: %{
      region: calib.skill_bar_region,
      count: calib.skill_bar_count,
      refs: calib.skill_slot_refs,
      name: nil
    }

  defp from_calibration(_no_calibration),
    do: %{region: nil, count: nil, refs: nil, name: nil}
end
