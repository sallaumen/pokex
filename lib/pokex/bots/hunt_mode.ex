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
  The engine knobs this mode CHANGES, by the name the decision calls them
  (`Pokex.Bots.Engine.Config`) — `%{}` only for a value that names no mode.

  ## Sobreposição, nunca escrita

  This is merged over `Config.in_force/0` in memory and never written to
  `settings.json`. Writing is how "um modo não afeta a config do outro" would
  quietly become false — and how his settings got eaten once already.

  ## Só knobs TÁTICOS

  Nothing here may reach a safety path: the health bands, the revive budget,
  the give-up brake, the logout, the alarms. A mode decides how a fight is
  fought, never whether the character is protected — `hunt_mode_test.exs`
  fails on any key outside `Config.knobs/0` and on any key in the forbidden
  list.

  ## E só o que o CÉREBRO decide

  Whether the fight uses Tab, and whether it presses single-target keys, are not
  knobs at all any more: they are what a mode IS (`Combat.Plan`). A switch that
  could contradict the mode is the invalid combination this whole split exists
  to make impossible.
  """
  @spec engine_overrides(t) :: %{atom => term}
  def engine_overrides(:economy) do
    %{
      # Gathering a pile saves AREA, and on a cheap route area is the exception: every
      # gathered pile is aggro nobody asked for.
      gather_piles: false,
      bunch_ms: 0,
      # Hit, fight: the three-mob ruler exists to spare the area.
      engage_from: 1,
      # Retreating buys time for the bar to return; with no bar to wait for it only
      # re-walks the route backwards.
      kite_when_spent: false,
      # The two rules that BUY convenience with a revive. On a weak route the revive is
      # worth more in the pocket; emergency and fainted stay intact, they do not pass
      # through here.
      reset_revive: false,
      prepare_revive: false
    }
  end

  # Auto Combo never gathers while walking. The mobs chasing him OFF screen are not counted
  # until they reach him, so walking "to gather" calls more than the list shows. Standing
  # still, the ruler counts who arrives, opens when it is worth it, and the chain does the
  # rest. Bench cost: 14% fewer kills in the combo scenario, zero falls.
  def engine_overrides(:auto_combo), do: %{gather_piles: false}

  def engine_overrides(_unknown_runs_the_bot_as_it_is), do: %{}

  @doc """
  Knobs no mode may touch, named out loud so a test can prove it.

  They are the ones whose wrong value costs a character rather than a hunt.
  """
  @spec forbidden_knobs() :: [atom]
  def forbidden_knobs do
    [
      :band_yellow_pct,
      :band_red_pct,
      :resume_pct,
      :revive_reserve,
      :downed_give_up_ms,
      :recover_timeout_ms,
      :revive_confirm_ms,
      :rescue_cooldown_ms,
      :rescue_floor_ms,
      :fainted_revive_cooldown_ms
    ]
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
