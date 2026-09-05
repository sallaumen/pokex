defmodule Pokex.Bots.SkillClock do
  @moduledoc """
  The key clock: what the bot pressed, when, and what that implies.

  Until this module existed the only answer to "is this key ready?" came from the SCREEN
  (`Perception.ready_skills/1`, the `:skill_bar` fact). That has three holes:

    * **A bad reading means blind rotation.** The fact fails OPEN on purpose (nothing
      may stop attacking because of a pixel), so an unreadable bar answers `nil` and
      combat goes back to pressing everything in order, including what just fired.
    * **Nobody had written down any cooldown.** The bot had no way to know the area
      skill takes 45s and the single-target one 8s, so it could not prefer an order
      nor say "everything is spent".
    * **The revive became a cheap reset button.** It costs an item and time; spending
      it with half the bar ready is paying a lot for little.

  This module is the missing half: whoever presses STAMPS here, and whoever decides asks here.
  The stamp lives in `Pokex.Bots.Body`, the only gate a key leaves through
  (`execute({:press, key})`), so no path can press without the clock knowing.

  ## The screen still wins when the two disagree

  `ready/4` crosses both sources and is conservative on both sides: a key is ready only if the
  screen does not say no AND a WRITTEN cooldown does not say no. The screen is the game speaking
  (it knows things nobody wrote down: a silence, a global cooldown); the clock is what we know
  we pressed (and it knows things the screen is slow to show, since the fact has an age and a
  400ms-old photo still shows a key that has already fired as ready).

  With the screen unreadable the clock answers alone, which is the big win: instead of blind
  rotation, the bot still knows what it spent.

  ## The revive resets everything

  That is rule R3 of his game, measured on video: the revive brings the pokémon back with every
  cooldown at zero. `reset/1` exists for the worker to stamp that, and it is what keeps the
  clock honest after a reset; without it the clock would hold keys the game already gave back.
  """

  @table :pokex_skill_clock

  # What to assume for a key he has not measured yet (his request: 45 seconds when nothing is
  # configured).
  @assumed_ms 45_000

  @doc "The cooldown assumed for a key with no written number."
  @spec assumed_ms() :: pos_integer
  def assumed_ms, do: @assumed_ms

  @doc false
  def table, do: @table

  # A public named table, in the mould of `WorldState`: written on every key (the Body), read
  # on every tick (the brain), from different processes.
  @doc "Garante a tabela. Idempotente — chamado no boot e por quem chegar antes."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    # two races creating the same table: the loser only needs not to die
    ArgumentError -> :ok
  end

  @doc "Stamps that `key` fired just now."
  @spec pressed(String.t(), integer) :: :ok
  def pressed(key, at \\ now()) when is_binary(key) do
    ensure_table()
    :ets.insert(@table, {key, at})
    :ok
  end

  @doc "When `key` last fired, or nil."
  @spec last_press(String.t()) :: integer | nil
  def last_press(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, key) do
      [{^key, at}] -> at
      [] -> nil
    end
  end

  @doc """
  Stamps that the SCREEN LIED about `key`: the bot pressed, and the bar kept saying the key is
  ready.

  This is the receipt (`Pokex.Bots.SkillReceipt`) speaking: `missed` only fires when the key was
  ready BEFORE and is still ready AFTER. The game did not react, and the only explanation left
  is the bar, whose readiness reading compares a reference pixel with what the calibration
  stored, and a reference taken while the skill was charging matches exactly the charging state.

  MEASURED on one of his captures: the game was writing `12`, `32` and `32` over keys 3, 4 and 5
  while the reading answered "3 and 5 ready". The rotation spent nineteen seconds pressing both.

  From here on the screen stops answering for that key until the clock says it is back. Narrow
  on purpose: it holds only for the key the game proved it ignores, and it lifts by itself.
  """
  @spec denied(String.t(), integer) :: :ok
  def denied(key, at \\ now()) when is_binary(key) do
    ensure_table()
    :ets.insert(@table, {{:denied, key}, at})
    :ok
  end

  @doc """
  How long, in ms, until the SCREEN answers for `key` again. Zero when nobody caught the bar
  lying about it.
  """
  @spec deaf_ms(String.t(), %{optional(String.t()) => pos_integer}, integer) :: non_neg_integer
  def deaf_ms(key, cooldowns, now \\ now()) do
    ensure_table()

    case :ets.lookup(@table, {:denied, key}) do
      [{_key, at}] -> max(at + Map.get(cooldowns, key, @assumed_ms) - now, 0)
      [] -> 0
    end
  end

  @doc """
  Forgets everything: what the revive does in the game, and what a new character needs.

  But what the revive erases is the COOLDOWN, not the fact that the key was pressed. Every stamp
  becomes an ECHO with the same timestamp: nobody reads an echo as a cooldown, and it exists to
  answer one question, "was that press the watcher just SAW through the window ours?".

  Without the echo one night ran like this: the bot fired 3, 4 and 5, paid a revive to reset the
  bar, this `reset` erased the stamps, and then `HandWatch` drained the presses the BOT ITSELF
  had just made, found no stamp and concluded it was his hand, re-stamping the cooldown 340ms
  after the revive. The bar came back cold, R3b said "I paid a revive and the bar did not come
  back" and disarmed for 600s. That was 235 presses attributed to his hand in 242 revives, 97%
  of them landing on top of a bot burst on the same key.

  Nobody reads the echo after `@own_window_ms`, so it does not need to expire: the next `reset`
  replaces it.
  """
  @spec reset() :: :ok
  def reset do
    ensure_table()

    ecos = for {key, at} <- :ets.tab2list(@table), is_binary(key), do: {{:echo, key}, at}

    :ets.delete_all_objects(@table)
    :ets.insert(@table, ecos)
    :ok
  end

  @doc """
  Forgets FOR REAL, echoes included: a character switch, and the test bench. A revive's
  `reset/0` preserves the echo on purpose; this one preserves nothing, because another
  character's keys are witness to nothing.
  """
  @spec wipe() :: :ok
  def wipe do
    ensure_table()
    :ets.delete_all_objects(@table)
    :ok
  end

  @doc """
  The time of the last press of `key` that a `reset/0` erased, or nil.

  NOT a cooldown: a key with an echo is ready. See `pressed_at/1`, which answers the whole
  question.
  """
  @spec echo(String.t()) :: integer | nil
  def echo(key) when is_binary(key) do
    ensure_table()

    case :ets.lookup(@table, {:echo, key}) do
      [{_echo, at}] -> at
      [] -> nil
    end
  end

  @doc """
  When WE last pressed `key`, whether or not the cooldown survived.

  `last_press/1` answers "when did the cooldown that is still running start", and it vanishes
  when the revive resets the bar. This one answers "was that press ours?", which is a different
  question and must not be erased by a reset: it is what tells the bot's own CGEvent coming back
  through the `HandWatch` window from a press of his hand.
  """
  @spec pressed_at(String.t()) :: integer | nil
  def pressed_at(key) when is_binary(key), do: last_press(key) || echo(key)

  @doc """
  Frees ONE key: erases its stamp, as if nobody had pressed it.

  This is the SCREEN correcting the clock (`Pokex.Bots.SkillTruth`): when the game shows a key
  as ready and the clock insists on holding it, one of the two lied, and between a stamp (what
  we THINK fired) and the game writing readiness on the screen, the game wins. Without this, a
  press swallowed by focus, a written cooldown longer than the real one, or a revive the bot did
  not see (an F4 from his hand) holds a good key for up to 50s.
  """
  @spec release(String.t()) :: :ok
  def release(key) when is_binary(key) do
    ensure_table()
    :ets.delete(@table, key)
    :ok
  end

  @doc """
  The keys of `keys` the CLOCK considers ready, with the assumed cooldown standing in for the
  ones nobody measured.

  Only used when the SCREEN did not answer: that is where the 45s guess is worth more than the
  nothing that existed before.
  """
  @spec ready_by_clock([String.t()], %{optional(String.t()) => pos_integer}, integer) ::
          [String.t()]
  def ready_by_clock(keys, cooldowns, now \\ now()) when is_list(keys) and is_map(cooldowns) do
    Enum.filter(keys, &(assumed_cooling_ms(&1, cooldowns, now) == 0))
  end

  @doc """
  How long until `key` is back, in ms, by the ASSUMED cooldown when there is no written one.
  Zero when it is ready.
  """
  @spec assumed_cooling_ms(String.t(), %{optional(String.t()) => pos_integer}, integer) ::
          non_neg_integer
  def assumed_cooling_ms(key, cooldowns, now \\ now()) do
    cooling_ms(key, Map.put_new(cooldowns, key, @assumed_ms), now)
  end

  @doc """
  How long until `key` is back, in ms. Zero when it is ready or when nobody wrote its cooldown
  down.
  """
  @spec cooling_ms(String.t(), %{optional(String.t()) => pos_integer}, integer) ::
          non_neg_integer
  def cooling_ms(key, cooldowns, now \\ now()) do
    with ms when is_integer(ms) and ms > 0 <- Map.get(cooldowns, key),
         at when is_integer(at) <- last_press(key) do
      max(at + ms - now, 0)
    else
      _sem_cooldown_ou_sem_press -> 0
    end
  end

  @doc """
  The keys that are really ready: the screen reading crossed with the clock.

    * screen with a list -> it rules, minus the keys a WRITTEN cooldown says are
      cooling (the photo has an age: a key that fired 200ms ago still shows as ready);
    * screen `nil` (unreadable, old, absent) -> the clock answers alone, and there the
      45s assumption applies. That is the point of this module, because before a bad
      reading left combat blind;
    * no known keys and no screen -> `nil`, the usual unknown, so readers keep failing
      OPEN as they always did.

  ## Why the ASSUMED cooldown does not override what the screen saw, unless it lies

  A guess does not disprove an observation. But `missed` is not a guess: it is the game
  answering that it did not react, and a ready key that does not fire does not exist. There the
  assumption applies, for that key only, until it comes back. See `denied/2`.

  A written cooldown is his own measurement and may contradict an old photo. An assumed cooldown
  is a guess: if the skill comes back in 8s and we guess 45, vetoing the screen would make the
  bot stop using the fastest key on the bar for 37 seconds, and nobody would see why. A guess
  fills a hole; it does not disprove an observation.
  """
  @spec ready([String.t()] | nil, [String.t()], %{optional(String.t()) => pos_integer}, integer) ::
          [String.t()] | nil
  def ready(screen, keys, cooldowns, now \\ now())

  def ready(screen, _keys, cooldowns, now) when is_list(screen),
    do: Enum.reject(screen, &muted?(&1, cooldowns, now))

  def ready(nil, [], _cooldowns, _now), do: nil

  def ready(nil, keys, cooldowns, now), do: ready_by_clock(keys, cooldowns, now)

  # Two reasons not to offer what the screen offered: a WRITTEN cooldown the frame has not
  # shown yet, and a key the game already proved it is not accepting (`denied/2`).
  defp muted?(key, cooldowns, now),
    do: cooling_ms(key, cooldowns, now) > 0 or deaf_ms(key, cooldowns, now) > 0

  defp now, do: System.monotonic_time(:millisecond)
end
