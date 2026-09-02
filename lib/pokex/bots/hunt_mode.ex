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
      # Juntar bolo é economia de ÁREA, e numa rota barata a área é a exceção.
      # Cada pilha juntada é aggro que ninguém pediu.
      gather_piles: false,
      bunch_ms: 0,
      # Bateu, luta: a régua dos três existe pra poupar a área.
      engage_from: 1,
      # Recuar compra tempo pra barra voltar. Sem barra pra esperar, recuar só
      # refaz de costas o chão que a rota acabou de andar.
      kite_when_spent: false,
      # As duas regras que COMPRAM conveniência com revive. Numa rota fraca o
      # revive vale mais no bolso — a emergência e o caído continuam intactos,
      # porque não passam por aqui.
      reset_revive: false,
      prepare_revive: false
    }
  end

  # O AUTO COMBO NÃO JUNTA ANDANDO. É o modo das hunts fortes, e a regra dele
  # (02/09) é literal: "se tem 8 na tela ele deveria parar na hora, não dar
  # mais nenhum passo e deixar os bichos virem até mim — andar até eles é mais
  # perigoso ainda, que vai chamar ainda mais bicho". O diário de 07:58 mostra o
  # porquê: a lista leu 2→3→4→6 enquanto ele andava 11 passos "juntando", e
  # pulou pra 9 de uma vez — os que corriam atrás dele FORA da tela não entram
  # na contagem até alcançá-lo. Ele via doze; o bot via seis e foi buscar mais.
  # Parado, a régua conta quem chega, abre quando vale, e a corrente cuida do
  # resto. Custo medido na bancada: −14% de mortos no cenário do combo, zero
  # quedas dos dois lados — e a bancada não enxerga os doze fora da tela.
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
