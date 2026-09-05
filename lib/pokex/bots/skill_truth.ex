defmodule Pokex.Bots.SkillTruth do
  @moduledoc """
  The screen correcting the key clock, one frame at a time.

  A `Pokex.Bots.SkillClock` stamp is a PREDICTION: "I pressed, so it cools for Xs". It is wrong
  in three ways his hunt has already paid for, and his own words for it were that the bot thinks
  it used a skill and marks the cooldown when the skill never fired:

    * the press was SWALLOWED. The focus gate suppresses the input and answers `:ok`,
      and the stamp is born without a key ever leaving;
    * the WRITTEN cooldown is longer than the real one, so the clock holds a key the
      game has already given back;
    * a revive the bot did not dispatch (an F4 from his hand) reset the whole bar, and
      the clock was not there to see it.

  In all three the signature is the same: **the screen shows the key READY and the clock has a
  stamp saying it is not**. This module looks at every fresh bar frame (the `:skill_bar` feed,
  ~400ms) and, when the disagreement persists, erases the stamp (`SkillClock.release/1`). The
  opposite direction deliberately does not exist here: stamping a press the bot did not make is
  `Pokex.Bots.HandWatch`'s job, reading the real keyboard rather than a pixel.

  ## The three guards before freeing

    * **Grace** (`@grace_ms`): a skill's effect takes about 800ms to a second to show, so
      a stamp younger than that has not had time to become a count on screen, and
      freeing it would undo a legitimate press.
    * **Two consecutive frames** (`@frames_to_free`): one frame is a photo, and a photo
      has noise. The same disagreement in two frames is the game insisting.
    * **A deaf key stays out** (`deaf_ms`): once the game has proved the bar LIES about a
      key (`SkillClock.denied/2`), "ready on screen" is exactly the lying state, and it
      disproves nothing.

  Freeing is always safe: at worst combat offers a key the game refuses, the receipt
  (`SkillReceipt`) catches the `missed`, and the chain corrects itself. Holding a good key is
  the expensive mistake, and it is what froze the rotation for 19s once.

  The narration only fires when the stamp was still young enough to be MUTING the key (younger
  than the assumed cooldown): an old expired stamp is silent housekeeping, not news.
  """

  alias Pokex.Bots.SkillClock

  @table :pokex_skill_truth

  # A skill's effect takes ~800ms-1s to show; the slack covers that and the age the frame
  # already had when the press left.
  @grace_ms 2_500
  @frames_to_free 2

  @doc false
  def table, do: @table

  @doc "Ensures the streak table. Idempotent, in the SkillClock mould."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc """
  Looks at a FRESH bar frame (the observation `Interpret.skills/3` has just built) and corrects
  the clock. Answers the keys it freed.

  `ready_keys: nil` (an unreadable bar) corrects nothing: a screen that does not speak disproves
  nobody.
  """
  @spec observe(map, integer) :: [String.t()]
  def observe(obs, now \\ System.monotonic_time(:millisecond))

  def observe(%{ready_keys: ready}, now) when is_list(ready) do
    ensure_table()

    # `judge` condemns, `free` executes, and free RE-CHECKS the stamp, because between the
    # two the Body may have pressed the same key again.
    freed = Enum.filter(ready, fn key -> judge(key, now) and free(key, now) end)

    # A key the screen shows COOLING agrees with any stamp: its disagreement died, and the
    # streak dies with it.
    Enum.each(known_streaks() -- ready, &:ets.delete(@table, &1))

    freed
  end

  def observe(_sem_leitura, _now), do: []

  # The key is ready ON SCREEN. Does it deserve to be freed?
  defp judge(key, now) do
    with at when is_integer(at) <- SkillClock.last_press(key),
         true <- now - at > @grace_ms,
         0 <- SkillClock.deaf_ms(key, %{}, now) do
      bump(key) >= @frames_to_free
    else
      _sem_carimbo_carencia_ou_surda ->
        :ets.delete(@table, key)
        false
    end
  end

  # Frees for real, and says whether it did. The age is RE-READ here: between the judgement
  # and this erase the Body may have stamped a NEW press on the same key, and freeing it would
  # erase a legitimate shot. A stamp younger than the grace = changed hands; the streak resets
  # and the judgement restarts from the first frame.
  defp free(key, now) do
    :ets.delete(@table, key)
    age = now - (SkillClock.last_press(key) || now)

    if age > @grace_ms do
      SkillClock.release(key)

      # A stamp that would still hold the key is news; an expired stamp is housekeeping,
      # and housekeeping narrated in a loop would bury the feed.
      if age < SkillClock.assumed_ms(), do: narrate(key, age)
      true
    else
      false
    end
  end

  defp narrate(key, age) do
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Pokex.Bots.Combat.Worker.topic(),
      {:combat_log, :macro,
       "combate: 🧭 o jogo mostra a #{key} pronta e o relógio a segurava " <>
         "(aperto de #{div(age, 1_000)}s atrás que não deve ter chegado) — soltei"}
    )
  end

  defp bump(key) do
    ensure_table()
    :ets.update_counter(@table, key, {2, 1}, {key, 0})
  end

  defp known_streaks do
    ensure_table()
    :ets.select(@table, [{{:"$1", :_}, [], [:"$1"]}])
  end
end
