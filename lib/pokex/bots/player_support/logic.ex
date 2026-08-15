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
  True when the main Pokémon should press its own HEALING SKILL — the one job on
  `/time` that nothing used to fire.

  This exists because of what `potion_wanted?/1` says right above: a potion is a
  CHANNEL and combat cancels it, so the sip only ever happens out of battle.
  Which leaves the case that actually kills a pokémon — HP falling WHILE it
  fights — with nothing at all between the last full bar and the revive. A skill
  is an instant press, not a channel: it is the only one of the three that works
  mid-fight, so this predicate deliberately has NO combat gate.

  Hence the ladder, cheapest and most available first:

      heal skill  — free, works in combat        (pokemon_hp_heal_pct, highest)
      potion      — costs money, out of combat   (pokemon_hp_potion_pct)
      revive      — costs a revive, last resort  (pokemon_hp_rescue_pct, lowest)

  Same two-consecutive-reads rule as the other two: one garbage frame must not
  spend a cooldown either. The cooldown here is only anti-spam — whether the
  skill is actually up is the SKILL BAR's answer, and the caller asks it.

  Expects `:hp_pct`, `:prev_hp_pct`, `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_heal_at` and `:now`.
  """
  @spec heal_wanted?(map) :: boolean
  def heal_wanted?(%{enabled?: false}), do: false
  def heal_wanted?(%{hp_pct: nil}), do: false
  def heal_wanted?(%{hp_pct: hp, threshold_pct: threshold}) when hp >= threshold, do: false

  def heal_wanted?(%{prev_hp_pct: prev, threshold_pct: threshold})
      when is_nil(prev) or prev >= threshold,
      do: false

  def heal_wanted?(%{last_heal_at: nil}), do: true

  def heal_wanted?(%{now: now, last_heal_at: last, cooldown_ms: cooldown}),
    do: now - last >= cooldown

  @doc """
  Everything he still has in hand when the stun did NOT go out — the last
  thing tried before the field is given up.

  "Stun não confirmado: se não tem mais outras skills pra usar, pra tentar dar
  aquele último dano, daí recolhe" (Lucas, 2026-08-14). Recalling with a full
  hand is the worst of both worlds: the pokémon leaves, the pile stays awake,
  and the character is the one standing there. So a refused stun escalates
  instead — another control key may put the pile down, and damage may simply
  end it.

  Order IS the priority: `crowd` first (it is what the stun was for), then
  `aoe` (a gathered pile is a crowd by definition), then `single`. Keys already
  pressed drop out — pressing again what just failed to fire buys nothing.
  `ready` filters against the skill bar, and `nil` (no reading) keeps
  everything: the same fail-open rule as `stun_prefix/2`, because in this
  moment a blind press beats no press at all.
  """
  @spec last_resort_keys(map | nil, [String.t()], [String.t()] | nil) :: [String.t()]
  def last_resort_keys(nil, _tried, _ready), do: []

  def last_resort_keys(loadout, tried, ready) do
    (Map.get(loadout, :crowd, []) ++ Map.get(loadout, :aoe, []) ++ Map.get(loadout, :single, []))
    |> Enum.uniq()
    |> Enum.reject(&(&1 in tried))
    |> then(fn keys -> if is_list(ready), do: Enum.filter(keys, &(&1 in ready)), else: keys end)
  end

  @doc """
  True when the pokémon on the field DIED — read from the bar's trajectory,
  because a dead pokémon has no bar left to read.

  When it falls, the game's pokémon window changes shape and the calibrated
  strip stops holding a bar at all (Lucas, 2026-08-14) — so the reading goes
  `:unrecognized`, which is exactly what a covered game or a minimized party
  window also produce. Identical in the pixels; what tells them apart is where
  the bar WAS the moment before. A bar at 12% that vanishes is a death; a bar
  at 100% that vanishes is a window someone moved.

  Hence: unreadable for two consecutive reads (the house rule against a single
  garbage frame) AND the last thing actually SEEN was below `faint_below_pct`.

  The caller clears `last_seen_hp` once this fires, so a death costs exactly
  one revive: firing again requires seeing the pokémon alive first. That is
  what stops a pokémon merely STORED in its ball from burning the stock.

  Expects `:enabled?`, `:unreadable_streak`, `:last_seen_hp`, `:faint_below_pct`,
  `:cooldown_ms`, `:last_faint_at` and `:now`.
  """
  @spec fainted?(map) :: boolean
  def fainted?(%{enabled?: false}), do: false
  def fainted?(%{unreadable_streak: streak}) when streak < 2, do: false
  def fainted?(%{last_seen_hp: nil}), do: false
  def fainted?(%{last_seen_hp: hp, faint_below_pct: below}) when hp > below, do: false
  def fainted?(%{last_faint_at: nil}), do: true

  def fainted?(%{now: now, last_faint_at: last, cooldown_ms: cooldown}),
    do: now - last >= cooldown

  @doc """
  The FALLEN combo: he is already inside the ball, so there is nothing to
  recall — cursor onto the portrait, max revive, and out he comes alive.

  "Você apertar Shift+Q com o mouse em cima do pokémon é instantâneo, e aí
  depois você apertar Q, ele já sai da pokébola viva (…) esse combo é bem
  feitinho" (Lucas, 2026-08-14).

  Deliberately shorter than `combo/1`: that one opens by recalling a pokémon
  who is still out and still tanking, and pays a settle so the pile is asleep
  before the field empties. Here the field is ALREADY empty and the character
  is the one being hit — every millisecond is exposure, so there is no stun and
  no settle, only the two presses that end it.
  """
  @spec fallen_combo(map) :: [tuple]
  def fallen_combo(%{
        rescue_key: rescue_key,
        max_revive_key: max_revive_key,
        photo_point: photo_point,
        neutral_point: neutral_point,
        step_ms: step_ms
      }) do
    [
      {:move, photo_point},
      {:wait, step_ms},
      {:press, max_revive_key},
      {:wait, step_ms},
      {:press, rescue_key},
      {:wait, step_ms},
      {:move, neutral_point}
    ]
  end

  @doc """
  The atomic combo, as a Body action list: an optional STUN PREFIX (`stun_steps`, already-compiled
  `{:press, _}`/`{:wait, _}` actions — see `stun_prefix/2`), then recall (`rescue_key`), move onto
  the portrait, max-revive (`max_revive_key`), release (`rescue_key`), recentre the cursor.
  `step_ms` waits sit between the presses so the game registers each — the whole list runs as ONE
  Body perform so nothing (not even a fishing/loot click — combat is keyboard-only via Tab
  targeting and never touches the Body) can move the cursor off the portrait mid-combo. The stun
  prefix rides INSIDE that same perform: hunting strong mobs, the area stuns buy the revive its
  time — nothing may wedge itself between the stun and the recall (2026-07-30).

  `settle_ms` (optional) is how long the game's sleep still needs to LAND before the field may be
  emptied — a lead wait the caller computes from when the stun was actually pressed. It rides
  inside this same perform on purpose: the whole point is that nothing separates the pile falling
  asleep from the pokémon leaving (2026-08-14, a rescue that exposed the character himself).
  """
  @spec combo(map) :: [tuple]
  def combo(
        %{
          rescue_key: rescue_key,
          max_revive_key: max_revive_key,
          photo_point: photo_point,
          neutral_point: neutral_point,
          step_ms: step_ms
        } = config
      ) do
    stun = Map.get(config, :stun_steps, [])
    glue = if stun == [], do: [], else: [{:wait, step_ms}]
    settle = settle_wait(Map.get(config, :settle_ms, 0))

    stun ++
      glue ++
      settle ++
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

  defp settle_wait(ms) when is_integer(ms) and ms > 0, do: [{:wait, ms}]
  defp settle_wait(_none), do: []

  @doc """
  Compiles a combo's stun steps into Body actions against the skill-bar reading.

  `ready` is the list of ready keys — or `nil` when the reading is unavailable, in which case ALL
  go in blind (a cooling key is a no-op in game; holding the rescue waiting for a read costs HP).
  A skill on cooldown is SKIPPED and returned in `skipped` so the log can name it (decision: skip,
  never wait). Waits are always kept (ms cost, zero risk). A step that isn't a skill/wait is
  ignored — eligibility filters earlier, and a combo edited between selection and firing must
  NEVER take a rescue down.

  Returns `{actions, skipped}`.
  """
  @spec stun_prefix([tuple], [String.t()] | nil) :: {[tuple], [String.t()]}
  def stun_prefix(steps, ready) do
    {actions, skipped} =
      Enum.reduce(steps, {[], []}, fn
        {:skill, key}, {actions, skipped} ->
          if ready == nil or key in ready,
            do: {[{:press, key} | actions], skipped},
            else: {actions, [key | skipped]}

        {:wait, ms}, {actions, skipped} when is_integer(ms) ->
          {[{:wait, ms} | actions], skipped}

        _odd_step, acc ->
          acc
      end)

    {Enum.reverse(actions), Enum.reverse(skipped)}
  end
end
