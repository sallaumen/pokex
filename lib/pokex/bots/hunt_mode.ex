defmodule Pokex.Bots.HuntMode do
  @moduledoc """
  WHICH combat strategy a hunt runs, and where that answer comes from.

  Two of them, and they are about different game problems:

    * `:auto_combo` — the strong-monster hunt. The client already chains every
      offensive skill behind ONE key, so the bot presses it once, treats the
      combo as running for a window, and spends that window on the only two
      things left: the revive that resets the bar and the safety ladder.
    * `:economy` — the cheap route. Tab, one single-target key, a short wait,
      and the area key only when it is still needed.

  ## Why a module instead of a setting read

  The mode has to be asked in four places that must never disagree inside one
  tick — the brain composing the hand, the fight pressing it, the bench
  measuring it and the page showing it. A setting read in four places is four
  chances to read a different value, which is the shape of defect that
  `Engine.Config` and `Engine.Inputs` were both born to close.

  So: one list, one resolution order, one label table.

  ## The resolution order is route FIRST

  "O mesmo Pokex pode ser usado em diferentes tipos de rota" — so the mode
  belongs to the hunt profile, with the global setting as the floor underneath
  it. It is the same order `Route.gather_wait/3` already uses for the huddle
  ruler, and for the same reason: what is true of one dungeon is not true of
  the next.

  `nil` on the route is ABSENCE, never a mode: it means "use the default", and
  the page says so instead of pretending the route chose.
  """

  alias Pokex.Settings

  @modes [:auto_combo, :economy]
  @default :auto_combo

  # User-visible, so pt-BR — the value stored is the English atom.
  @labels %{auto_combo: "Auto Combo", economy: "Econômico"}

  @type t :: :auto_combo | :economy

  @doc "Every mode, in the order a page offers them."
  @spec all() :: [t]
  def all, do: @modes

  @doc "The mode a hunt runs when nobody said otherwise."
  @spec default() :: t
  def default, do: @default

  @spec known?(term) :: boolean
  def known?(mode), do: mode in @modes

  @doc "How the screen names `mode`."
  @spec label(term) :: String.t()
  def label(mode), do: Map.get(@labels, mode, to_string(mode))

  @doc """
  The mode `value` names — `nil` when it names none.

  Whitelisted on purpose: the setting is a hand-editable string and a typo in
  it must not mint an atom, exactly like the route file's actions and stops.
  """
  @spec parse(term) :: t | nil
  def parse(value) when is_atom(value), do: if(known?(value), do: value)

  def parse(value) when is_binary(value) do
    Enum.find(@modes, &(Atom.to_string(&1) == value))
  end

  def parse(_neither), do: nil

  @doc """
  The mode in force for a hunt whose route says `route_mode`.

  Takes the route's VALUE rather than the route, so this module never has to
  know the struct — the dependency points one way, from the route to here.
  """
  @spec in_force(t | nil) :: t
  def in_force(route_mode \\ nil) do
    parse(route_mode) || parse(Settings.get(:hunt_mode)) || @default
  end

  @doc """
  WHERE the mode in force came from: the route chose it, or it fell through to
  the global default.

  The page shows this beside the selector — the same reason `Modes.overrides/2`
  exists: a value in force whose origin is invisible is a value he has to guess
  at.
  """
  @spec source(t | nil) :: :route | :global
  def source(route_mode) do
    if parse(route_mode), do: :route, else: :global
  end
end
