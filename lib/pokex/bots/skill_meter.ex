defmodule Pokex.Bots.SkillMeter do
  @moduledoc """
  How much each key takes off a mob, and how long it takes to take it.

  ## The idea is entirely his

  He asked for a check mode: the bot and a full-health enemy, the system sees the full bar,
  presses one skill, computes the difference and saves it against that skill. If key 4 alone
  already kills, it does not need to keep pressing 4, 5 and 6.

  And the second number, which he also saw before any measurement: a skill can take about a
  second to actually deal its damage, and meanwhile the bot presses 4, 5 and 6. In practice 4
  would already have killed, but the bot does not know that.

  ## Where it comes from, with no new capture

  The battle list is already photographed every tick and already publishes each row's health bar
  (`hp`) and which row is locked (`locked_row`). Measuring is looking at the locked row before
  the press and again after: the drop is the damage, and WHEN it appears is the delay. Nothing
  here takes a photo.

  ## One key at a time, or it is not a measurement

  A burst of three keys produces one drop, and nobody knows whose it was. So the meter only
  accepts presses of ONE key, which is exactly the check mode he described, and that is why
  `Pokex.Bots.Combat.Worker` only calls it when the burst has a single key and the mode is on.

  ## It measures the bar, not the number

  The bar is counted in green pixels, so what is stored is a FRACTION: how much of the bar
  vanished. That is what he asked for, and it survives mobs with different health pools, which
  an absolute number would not.

  ## What it cannot know

  That the drop was his. Another player hitting the same row enters the count, and a dying mob
  leaves the list before finishing its fall. That is why samples are stored raw and the summary
  comes out as a MEDIAN, with the sample count beside it: a number with three samples does not
  deserve the same faith as one with forty, and hiding that behind an average would be the same
  invention this module exists to erase.
  """

  alias Pokex.Perception.WorldState

  @type shot :: %{key: String.t(), took_pct: float, delay_ms: non_neg_integer}

  # How long to wait for the drop to show: about 1s observed, plus slack for the list tick.
  @wait_ms 2_500
  @poll_ms 100

  # A drop smaller than this is bar-reading noise, not damage.
  @min_drop_pct 2.0

  @doc "Is the mode on? Off by default: he measures when he wants to measure."
  @spec on?() :: boolean
  def on?, do: Pokex.Settings.get(:skill_meter_enabled) == true

  @doc """
  Watches ONE press: waits for the locked row to drop and answers how much and when.

  `{:ok, shot}` or `{:error, reason}`. Blocks until the drop or until `@wait_ms`, so the caller
  must be in a process that may die. In `Pokex.Bots.Combat.Worker` that is the burst's own
  process, next to the receipt.
  """
  @spec watch(String.t(), keyword) :: {:ok, shot} | {:error, atom}
  def watch(key, opts \\ []) do
    read = Keyword.get(opts, :read, &battle/0)
    now = Keyword.get(opts, :now, fn -> System.monotonic_time(:millisecond) end)

    case locked_bar(read.()) do
      {:ok, row, before} when before > 0 ->
        chase(%{
          key: key,
          row: row,
          before: before,
          started: now.(),
          now: now,
          read: read,
          sleep: Keyword.get(opts, :sleep, &Process.sleep/1)
        })

      # A bar already empty before the press has no drop to give.
      {:ok, _row, _zero} ->
        {:error, :no_bar}

      error ->
        error
    end
  end

  defp chase(t) do
    if t.now.() - t.started > @wait_ms do
      {:error, :no_drop}
    else
      t.sleep.(@poll_ms)
      judge(t, locked_bar(t.read.()))
    end
  end

  # DIED: the bar hit zero or the row left the list. The most valuable measurement here (a key
  # that kills alone), and the only one that would be lost for looking like an error.
  defp judge(%{row: row} = t, {:ok, row, 0}), do: killed(t)
  defp judge(t, {:error, :no_bar}), do: killed(t)

  # The locked row changed mob (the previous one died, the list moved): the drop now is not
  # from the same bar, and such a measurement is worse than none.
  defp judge(%{row: row} = t, {:ok, row, bar}), do: drop(t, bar)

  defp judge(_t, {:ok, _other_row, _bar}), do: {:error, :target_changed}

  # No locked target at all: the list may have moved for any reason, and calling that a death
  # would invent a 100%.
  defp judge(_t, {:error, _no_target}), do: {:error, :target_gone}

  defp drop(%{before: before} = t, bar) when bar >= before, do: chase(t)

  defp drop(t, bar) do
    took = (t.before - bar) * 100 / t.before

    if took >= @min_drop_pct,
      do: {:ok, shot(t, Float.round(took, 1))},
      else: chase(t)
  end

  defp killed(t), do: {:ok, shot(t, 100.0)}

  defp shot(t, pct), do: %{key: t.key, took_pct: pct, delay_ms: t.now.() - t.started}

  @doc """
  Watches and STORES. What the burst process calls in check mode.

  Never raises and never answers: a measurement that could take the hunt down with it would be a
  worse trade than not measuring.
  """
  @spec file(String.t(), keyword) :: :ok
  def file(key, opts \\ []) do
    case watch(key, opts) do
      {:ok, shot} -> save(Map.update(shots(), key, [shot], &[shot | &1]))
      {:error, _nothing_to_learn} -> :ok
    end
  rescue
    _anything -> :ok
  end

  @doc "Everything measured, per key, newest first."
  @spec shots() :: %{optional(String.t()) => [shot]}
  def shots do
    with {:ok, raw} <- File.read(Pokex.Home.skill_meter_file()),
         {:ok, %{"shots" => by_key}} <- JSON.decode(raw) do
      Map.new(by_key, fn {key, list} ->
        # The key is the map key; it goes back INSIDE each shot so a shot read from the
        # file has the same shape as a fresh one.
        {key, Enum.map(list, &%{key: key, took_pct: &1["took_pct"], delay_ms: &1["delay_ms"]})}
      end)
    else
      _nothing_or_torn -> %{}
    end
  end

  @doc "Forgets what it measured: another pokémon has other keys."
  @spec clear() :: :ok
  def clear, do: save(%{})

  @doc """
  What the samples say, per key, and what he wants to know from them.

  `%{shots:, took_pct:, delay_ms:, to_kill:}`. The `to_kill` is his whole question: if one key
  alone already kills, the rotation does not need to keep spending the others.

  MEDIAN, never mean: another player hitting the same row enters the count, and a mean leaves
  that foreign damage inside the number forever. The sample count comes along, because three
  samples do not deserve the faith of forty.
  """
  @spec summary() :: %{optional(String.t()) => map}
  def summary do
    Map.new(shots(), fn {key, list} ->
      pcts = list |> Enum.map(& &1.took_pct) |> Enum.sort()
      delays = list |> Enum.map(& &1.delay_ms) |> Enum.sort()
      took = median(pcts)

      {key,
       %{
         shots: length(list),
         took_pct: took,
         delay_ms: median(delays),
         to_kill: if(took > 0, do: ceil(100 / took), else: nil)
       }}
    end)
  end

  # The floor is the lower half: this meter errs low on purpose. "Need one more shot" is a
  # cheap mistake next to "thought it killed".
  defp median([]), do: 0
  defp median(sorted), do: Enum.at(sorted, div(length(sorted) - 1, 2))

  # The cap is not tidiness: the whole file is read on every measured shot.
  @max_shots 200

  defp save(by_key) do
    body =
      JSON.encode!(%{
        "shots" =>
          Map.new(by_key, fn {key, list} ->
            {key,
             list
             |> Enum.take(@max_shots)
             |> Enum.map(&%{"took_pct" => &1.took_pct, "delay_ms" => &1.delay_ms})}
          end)
      })

    Pokex.Home.write!(Pokex.Home.skill_meter_file(), body)
  end

  # The LOCKED row's bar, in green pixels. Without a locked target there is nothing to
  # measure: a random row's drop is not this key's damage.
  defp locked_bar(%{locked_row: row, hp: hp}) when is_integer(row) and is_list(hp) do
    case Enum.at(hp, row) do
      count when is_integer(count) -> {:ok, row, count}
      # The locked row left the list: during the chase that is a death, before it there is
      # nothing to measure. The caller knows which.
      nil -> {:error, :no_bar}
    end
  end

  defp locked_bar(_no_lock), do: {:error, :no_target}

  defp battle do
    max_age = Pokex.Settings.get(:combat_world_max_age_ms)

    case WorldState.get(:battle, max_age, System.monotonic_time(:millisecond)) do
      {:ok, fact} -> fact
      _stale_or_missing -> %{}
    end
  end
end
