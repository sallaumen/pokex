defmodule Pokex.Bots.PlayerSupport.Logic do
  @moduledoc """
  Pure decision core for the survival combo. No I/O, no time of its own — the caller supplies the
  HP reading and the monotonic `now`, so the whole rule is a total function that is trivial to test.

  `decide/1` answers `:rescue | :hold` for the main Pokémon. `combo/1` builds the atomic Body
  sequence that recalls the Pokémon, max-revives it on its portrait, and puts it back out.
  """

  @type decision :: :rescue | :hold

  @doc """
  `:rescue` when the main Pokémon needs the survival combo NOW, else `:hold`. Fail-safe: a disabled
  toggle, an unknown (nil) HP reading, or HP at/above the threshold all hold, and once a combo has
  fired no second one is allowed until `cooldown_ms` has fully elapsed (revives are expensive).

  TWO consecutive reads must agree it's low (`prev_hp_pct` below the threshold too): a single
  garbage frame — a screenshot of the wrong screen at boot, a mid-scroll tear — must never burn a
  revive. Costs one tick (~120ms) of rescue delay, which the combo's own ~600ms dwarfs.

  Expects a map with `:hp_pct` and `:prev_hp_pct` (0..100 or nil), `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_rescue_at` (monotonic ms or nil) and `:now` (monotonic ms).
  """
  @spec decide(map) :: decision
  def decide(%{enabled?: false}), do: :hold
  def decide(%{hp_pct: nil}), do: :hold
  def decide(%{hp_pct: hp, threshold_pct: threshold}) when hp >= threshold, do: :hold

  def decide(%{prev_hp_pct: prev, threshold_pct: threshold})
      when is_nil(prev) or prev >= threshold,
      do: :hold

  def decide(%{last_rescue_at: nil}), do: :rescue

  def decide(%{now: now, last_rescue_at: last, cooldown_ms: cooldown}),
    do: if(now - last >= cooldown, do: :rescue, else: :hold)

  @doc """
  True when the main Pokémon wants a potion — everything EXCEPT the combat gate: enabled, HP known
  and below the potion threshold, and the previous sip's heal channel (cooldown) has elapsed. The
  caller checks combat separately because that answer costs a screen capture — this predicate is
  what makes that capture worth taking. A potion drunk in combat is a wasted potion (the channel is
  interrupted the moment a fight starts), so the worker only fires when it CONFIRMED out-of-combat.

  Same two-consecutive-reads rule as `decide/1` (`prev_hp_pct` must agree): a single garbage
  frame must not chug a potion either.

  Expects `:hp_pct` and `:prev_hp_pct` (0..100 or nil), `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_potion_at` (monotonic ms or nil) and `:now` (monotonic ms).
  """
  @spec potion_wanted?(map) :: boolean
  def potion_wanted?(%{enabled?: false}), do: false
  def potion_wanted?(%{hp_pct: nil}), do: false
  def potion_wanted?(%{hp_pct: hp, threshold_pct: threshold}) when hp >= threshold, do: false

  def potion_wanted?(%{prev_hp_pct: prev, threshold_pct: threshold})
      when is_nil(prev) or prev >= threshold,
      do: false

  def potion_wanted?(%{last_potion_at: nil}), do: true

  def potion_wanted?(%{now: now, last_potion_at: last, cooldown_ms: cooldown}),
    do: now - last >= cooldown

  @doc """
  The atomic combo, as a Body action list: recall (`rescue_key`), move onto the portrait, max-revive
  (`max_revive_key`), release (`rescue_key`), recentre the cursor. `step_ms` waits sit between the
  presses so the game registers each — the whole list runs as ONE Body perform so nothing (not even
  a fishing/loot click — combat is keyboard-only via Tab targeting and never touches the Body) can
  move the cursor off the portrait mid-combo.
  """
  @spec combo(map) :: [tuple]
  def combo(%{
        rescue_key: rescue_key,
        max_revive_key: max_revive_key,
        photo_point: photo_point,
        neutral_point: neutral_point,
        step_ms: step_ms
      }) do
    [
      {:press, rescue_key},
      {:wait, step_ms},
      {:move, photo_point},
      {:wait, step_ms},
      {:press, max_revive_key},
      {:wait, step_ms},
      {:press, rescue_key},
      {:wait, step_ms},
      {:move, neutral_point}
    ]
  end
end
