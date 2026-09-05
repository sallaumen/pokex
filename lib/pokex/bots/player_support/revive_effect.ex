defmodule Pokex.Bots.PlayerSupport.ReviveEffect do
  @moduledoc """
  The revive's EFFECT judge: it was paid for, and the health did not come back?

  Two deaths in one morning came from an empty BAG. The F4 landed (the receipt proved it), the
  game accepted the key and did NOTHING, and the tank bled from 55% to 2% while the brain asked
  for a revive every 5s forever. Ten "the revive did not fire" lines in a row and no shout: the
  three-break disarm only watches the RESET revive (R3b), while the BAND revives (yellow and
  red) repeated in silence. And the stock alert watches the DECLARED number (`revive_stock`),
  which said 2000.

  This module is pure and judges what no declared counter can lie about: HEALTH. A revive paid
  for with the pokémon hurt has to heal; if the bar has not risen in about 4.5s, that is a
  break. Three in a row means the bag is dry (or the game has stopped accepting F4, and both
  conclusions ask for the same shout). A fainted pokémon that needs insistence counts a strike
  outright: it was paid for and nobody stood up.

  The worker is the one that shouts (category `:mortal`, which pierces the mute) and asks for
  the logout (`player_hp_logout`); only the verdict lives here.
  """

  @probe_max_hp 60
  @probe_after_ms 4_500
  @probe_blind_max_ms 10_000
  @healed_jump 25
  @healed_floor 90
  @streak_to_scream 3
  @scream_refractory_ms 120_000

  @type t :: %{
          probe: nil | %{at: integer, hp: 0..100},
          streak: non_neg_integer,
          screamed_at: nil | integer
        }

  def new, do: %{probe: nil, streak: 0, screamed_at: nil}

  @doc """
  A rescue was PAID for with the pokémon at this health. Only health at or below
  #{@probe_max_hp}% opens a probe: a reset revive on a full pokémon has no healing to measure.
  """
  def paid(judge, hp, now) when is_integer(hp) and hp <= @probe_max_hp,
    do: %{judge | probe: %{at: now, hp: hp}}

  def paid(judge, _healthy_or_unknown, _now), do: judge

  @doc "The fainted one needed INSISTENCE: paid for and nobody stood up, a direct strike."
  def fallen_again(judge, now), do: judge |> strike() |> verdict(now)

  @doc """
  One health reading. Closes an expired probe (healed resets it, not healed is a strike) and
  answers `{judge, :quiet | :scream}`, with `:scream` at most once per
  #{div(@scream_refractory_ms, 1000)}s window.
  """
  def tick(judge, hp, _now) when is_integer(hp) and hp >= @healed_floor,
    do: {%{judge | probe: nil, streak: 0}, :quiet}

  def tick(%{probe: %{at: at, hp: was}} = judge, hp, now)
      when is_integer(hp) and now - at >= @probe_after_ms do
    if hp >= was + @healed_jump,
      do: {%{judge | probe: nil, streak: 0}, :quiet},
      else: %{judge | probe: nil} |> strike() |> verdict(now)
  end

  # The probe won and the bar is still unreadable: the pokémon did not come back to the
  # screen. After #{@probe_blind_max_ms}ms of blindness, that IS the break.
  def tick(%{probe: %{at: at}} = judge, hp, now)
      when not is_integer(hp) and now - at >= @probe_blind_max_ms do
    %{judge | probe: nil} |> strike() |> verdict(now)
  end

  def tick(judge, _hp, _now), do: {judge, :quiet}

  defp strike(judge), do: %{judge | streak: judge.streak + 1}

  defp verdict(%{streak: streak} = judge, now) when streak >= @streak_to_scream do
    if judge.screamed_at == nil or now - judge.screamed_at >= @scream_refractory_ms,
      do: {%{judge | screamed_at: now}, :scream},
      else: {judge, :quiet}
  end

  defp verdict(judge, _now), do: {judge, :quiet}

  @doc "How many consecutive breaks the judge has seen, for the shout's text."
  def streak(%{streak: streak}), do: streak
end
