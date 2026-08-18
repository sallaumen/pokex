defmodule Pokex.Bots.SkillSuspect do
  @moduledoc """
  The slot whose reading is inverted, caught by its own silence.

  `SkillBar.slot_refs/2` documents this failure and guards against it: a bar
  calibrated while a skill was counting down would store the DARK panel as the
  ready reference, and from then on every cooldown matches (distance ~0 →
  `:ready`) while the true ready art does not. "The reading inverts permanently
  for that slot." The guard drops a slot whose `white_pct` says it was cooling —
  but a slot cooling just under that threshold slips through, and nothing
  downstream ever notices.

  Nothing until here. This is what notices.

  ## The signature is an absence

  An inverted slot always reads READY, so:

    * it is always eligible to fire, and always chosen;
    * the press spends nothing, because the skill was actually cooling;
    * the receipt reads it as ready afterwards and says `missed`;
    * and it is NEVER seen cooling, because cooling is what it calls ready.

  That last one is the tell. A healthy key fired over and over must sometimes be
  caught mid-cooldown — the receipt calls that `unknown`, not `missed`. A key
  that has missed many times and has never once been observed cooling is not
  unlucky: its reference is poisoned.

  Measured on his hunt of 2026-08-18: key `8` missed 25 times across ten
  minutes, keys `6` and `7` four times each (those two have `nil` refs, a
  different and already-handled cause), and the run killed 10 targets against 39
  misses.

  Pure on purpose: readings in, suspicion out. No process, no clock.
  """

  @type tally :: %{String.t() => %{missed: non_neg_integer, cooled?: boolean}}

  @doc "An empty tally."
  @spec new() :: tally
  def new, do: %{}

  @doc """
  Files a bar reading: every key of `watched` absent from `ready` was seen
  cooling, which clears it of suspicion for good.

  `nil` is not a reading — an unreadable bar says nothing about any slot, and
  counting it as "not cooling" would invent evidence.
  """
  @spec observe(tally, [String.t()] | nil, [String.t()]) :: tally
  def observe(tally, nil, _watched), do: tally

  def observe(tally, ready, watched) do
    Enum.reduce(watched, tally, fn key, acc ->
      if key in ready,
        do: acc,
        else: Map.put(acc, key, %{entry_of(acc, key) | cooled?: true})
    end)
  end

  @doc "Files a receipt that said these keys did not go off."
  @spec missed(tally, [String.t()]) :: tally
  def missed(tally, keys) do
    Enum.reduce(keys, tally, fn key, acc ->
      current = entry_of(acc, key)
      Map.put(acc, key, %{current | missed: current.missed + 1})
    end)
  end

  @doc """
  The keys whose reference looks poisoned: missed at least `min_missed` times
  and never once seen cooling.

  Deliberately quiet below the threshold. Two misses are a busy client; a dozen
  with no cooldown ever observed is a slot that cannot report one.
  """
  @spec suspects(tally, non_neg_integer) :: [String.t()]
  def suspects(tally, min_missed \\ 8) do
    for {key, %{missed: missed, cooled?: false}} <- tally,
        missed >= min_missed,
        do: key,
        into: []
  end

  @doc "What to say about a suspect, in his language."
  @spec explain(String.t(), non_neg_integer) :: String.t()
  def explain(key, missed) do
    "a tecla #{key} não saiu #{missed}x e o slot dela NUNCA foi visto em cooldown — " <>
      "a referência dela provavelmente foi aprendida com a skill carregando, e a leitura " <>
      "está invertida. Recalibre a barra com todas as skills prontas."
  end

  defp entry_of(tally, key), do: Map.get(tally, key, %{missed: 0, cooled?: false})
end
