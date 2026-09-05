defmodule Pokex.Bots.SkillRack do
  @moduledoc """
  The bar as it is RIGHT NOW, key by key, with both sources side by side.

  A key's readiness has two witnesses and they do not always agree: the SCREEN (the game's bar,
  read by comparing pixels against a calibration reference) and the CLOCK
  (`Pokex.Bots.SkillClock`, what the bot stamped as pressed, crossed with the cooldown he wrote
  in `/time`).

  While both lived only inside the decision, a disagreement was invisible, and disagreement is
  exactly the defect that cost one hunt: the game was writing `12`, `32` and `32` over keys 3, 4
  and 5, the reading answered "3 and 5 ready", and the rotation spent nineteen seconds pressing
  both. No screen anywhere said so.

  So this module does not choose a witness: it shows both, and says which one the rotation will
  obey. `state` is the OBEYED answer, from the same `SkillClock.ready/4` combat calls and never
  from a second similar rule, and `disagree?` marks the row worth looking at.

  As pure as it can be: it takes `now`, reads the clock (ETS) and answers a list. No capture, no
  decision.
  """

  alias Pokex.Bots.SkillClock

  @type tile :: %{
          key: String.t(),
          job: String.t(),
          screen: :ready | :cooling | :unknown,
          clock: :ready | :cooling | :unknown,
          state: :ready | :cooling,
          left_ms: non_neg_integer,
          written_ms: pos_integer | nil,
          muted?: boolean,
          disagree?: boolean
        }

  @doc """
  One piece per key of the bar, in the bar's order.

  `loadout` is the view the page already has (`opening`, `reserved`, `buffs`, `heal`, `single`,
  `cooldowns`); `screen` is `Pokex.Perception.ready_skills/1`, the list of ready keys, or `nil`
  when the bar was not read.
  """
  @spec build(map | nil, [String.t()] | nil, integer) :: [tile]
  def build(loadout, screen, now \\ System.monotonic_time(:millisecond))

  def build(nil, _screen, _now), do: []

  def build(loadout, screen, now) do
    keys = order(loadout)
    cooldowns = Map.get(loadout, :cooldowns) || %{}
    offered = SkillClock.ready(screen, keys, cooldowns, now) || []

    Enum.map(keys, &tile(&1, loadout, screen, cooldowns, offered, now))
  end

  @doc """
  The ROW's order, with the zero last, which is where it sits on the bar.

  The single-target keys are in even when the rotation goes without them: the bar is what HE
  has, not what the bot is going to press, and a key that vanishes from the screen is a key he
  does not know exists. What says it is out is the `job`.
  """
  @spec order(map) :: [String.t()]
  def order(loadout) do
    [:opening, :reserved, :buffs, :single, :heal]
    |> Enum.flat_map(&(Map.get(loadout, &1) || []))
    |> Enum.uniq()
    |> Enum.sort_by(&slot_number/1)
  end

  defp slot_number("0"), do: 10

  defp slot_number(key) do
    case Integer.parse(key) do
      {n, ""} -> n
      # non-digit keys (f4, shift+1) go last, in stable order
      _not_a_slot -> 99
    end
  end

  defp tile(key, loadout, screen, cooldowns, offered, now) do
    written = written_ms(cooldowns, key)
    cooling = SkillClock.cooling_ms(key, cooldowns, now)
    deaf = SkillClock.deaf_ms(key, cooldowns, now)
    screen_says = screen_says(key, screen)
    clock_says = clock_says(key, written, max(cooling, deaf))
    state = if key in offered, do: :ready, else: :cooling

    %{
      key: key,
      job: job_of(key, loadout),
      screen: screen_says,
      clock: clock_says,
      state: state,
      # Time left; zero on a cooling key means "unknown": the screen can say cold with no
      # number written for it, and a counter that invents seconds is worse than a dash.
      left_ms: if(state == :cooling, do: max(cooling, deaf), else: 0),
      written_ms: written,
      muted?: deaf > 0,
      disagree?: disagree?(screen_says, clock_says)
    }
  end

  defp written_ms(cooldowns, key) do
    case Map.get(cooldowns, key) do
      ms when is_integer(ms) and ms > 0 -> ms
      _nao_escrito -> nil
    end
  end

  defp screen_says(_key, nil), do: :unknown
  defp screen_says(key, ready), do: if(key in ready, do: :ready, else: :cooling)

  # The clock only speaks for keys with a WRITTEN cooldown or already caught lying. Otherwise
  # it is saying "unknown", not "ready", and the two must not share a colour.
  defp clock_says(_key, nil, 0), do: :unknown
  defp clock_says(_key, _written, left) when left > 0, do: :cooling

  defp clock_says(key, _written, _zero),
    do: if(SkillClock.last_press(key), do: :ready, else: :unknown)

  defp disagree?(same, same), do: false
  defp disagree?(:unknown, _clock), do: false
  defp disagree?(_screen, :unknown), do: false
  defp disagree?(_screen, _clock), do: true

  # Order matters: `reserved` is the rotation's EXCLUSION list and mixes control with shield,
  # so the shield must be asked first. A diagnostics screen calling the shield "control" lies
  # about the exact thing it exists to show.
  @jobs [
    {:shield, "escudo"},
    {:reserved, "controle (guardado pro revive)"},
    {:buffs, "aura"},
    {:heal, "cura"},
    {:opening, "dano"},
    {:single, "alvo único (fora da rotação)"}
  ]

  @doc "What this key does in this hunt."
  @spec job_of(String.t(), map) :: String.t()
  def job_of(key, loadout) do
    Enum.find_value(@jobs, "sem trabalho", fn {field, label} ->
      key in (Map.get(loadout, field) || []) and label
    end)
  end

  @doc "How many are really ready: the ones the rotation may press now."
  @spec ready_count([tile]) :: non_neg_integer
  def ready_count(tiles), do: Enum.count(tiles, &(&1.state == :ready))

  @doc """
  How much of the recovery has passed, 0-100, for drawing the filling rail. Without a written
  number there is no fraction: the piece shows the state, not an invented bar.
  """
  @spec recovered_pct(tile) :: non_neg_integer | nil
  def recovered_pct(%{state: :ready}), do: 100
  def recovered_pct(%{left_ms: 0}), do: nil

  def recovered_pct(%{left_ms: left} = tile) do
    # A key silenced by a lying bar is held by the assumed cooldown when nobody wrote its
    # number: the rail must measure the same thing as the count.
    total = tile.written_ms || (tile.muted? && SkillClock.assumed_ms())

    if total, do: round(max(total - left, 0) * 100 / total)
  end
end
