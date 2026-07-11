defmodule Pokex.Bots.SkillBar do
  @moduledoc """
  Reads the skill hotbar and derives per-skill readiness — a PURE helper (plain
  functions, no process, no shared state). Each caller (the fishing sensor, the combat
  sensor, the panel, the diagnostic) does its OWN one-shot read when it needs it, so
  there is NO inter-process communication and nothing that can block a bot's tick or
  leave a stale/invalid shared state. Only the Body (mouse/keyboard) is shared; the
  screen is read independently, exactly like the glow and battle reads.

  `read/2` captures `skill_bar_region` and returns the per-slot `%{brightness, saturation,
  state}` (from `Vision.skill_slots/2`), or `nil` when the bar isn't calibrated or the
  capture fails. The slot count comes from calibration and stays fixed across frames;
  cooldown effects must never change the geometry of the bar. `all_ready?/2` and
  `ready_keys/1` derive the answers the bots need; the tenth slot maps to `0`.
  """

  alias Pokex.{Calibration, Vision}
  alias Pokex.Bots.Capture

  @doc "Per-slot `%{brightness, saturation, state}` list, or `nil` (not calibrated / capture failed)."
  def read(calib, settings) do
    with %Calibration{skill_bar_region: region} when is_tuple(region) <- calib,
         {:ok, frame} <- Capture.frame(region, "skillbar.png"),
         true <- Vision.skill_bar_frame?(frame) do
      slots_from_frame(frame, calib, settings)
    else
      _ -> nil
    end
  end

  @doc "Reads slot states from an already captured frame using the same rules as `read/2`."
  def slots_from_frame(frame, calib, settings) do
    count = calibrated_count(calib, settings)

    Vision.skill_slots(frame,
      count: count,
      min_saturation: settings[:skill_ready_min_saturation],
      min_vivid_pct: settings[:skill_ready_min_vivid_pct]
    )
  end

  @doc "Whether a captured frame still resembles the calibrated skill bar."
  def valid_frame?(frame), do: Vision.skill_bar_frame?(frame)

  @doc "Hotbar keys for `count` slots. PokeXGames labels slot 10 with `0`."
  def keys(count) when is_integer(count) and count > 0,
    do: for(index <- 0..(min(count, 10) - 1), do: key_for_index(index))

  def keys(_count), do: []

  @doc "Fits a saved priority order to the slots present in the selected bar."
  def fit_order(order, count) do
    available = keys(count)

    kept =
      order
      |> Enum.map(&if(to_string(&1) == "10", do: "0", else: to_string(&1)))
      |> Enum.uniq()
      |> Enum.filter(&(&1 in available))

    kept ++ (available -- kept)
  end

  @doc "The per-slot states (`[:ready | :cooldown]`), or `nil` when there's no reading."
  def states(nil), do: nil
  def states(slots), do: Enum.map(slots, & &1.state)

  @doc """
  Are ALL of `keys` (hotbar strings like `"4"`) ready? FAIL-OPEN on two fronts, so the
  fishing gate can NEVER softlock a held bite:
    * `nil` slots (no reading / uncalibrated bar) → `true`;
    * a key that isn't a readable hotbar slot — a non-digit ("e", "f1") or a digit past
      the bar's slot count — is UNTRACKABLE, so we don't block on it (its cooldown is
      unknowable). Only in-range digit keys actually gate.
  """
  def all_ready?(nil, _keys), do: true

  def all_ready?(slots, keys) do
    count = length(slots)

    Enum.all?(keys, fn key ->
      case slot_index(key, count) do
        nil -> true
        i -> match?(%{state: :ready}, Enum.at(slots, i))
      end
    end)
  end

  @doc """
  Is AT LEAST ONE of `keys` ready? The LOOSENED fishing gate: pull the moment any
  kill-skill is up, instead of waiting for the whole set (measured on Lucas's real bar:
  requiring ALL of 4/5/6 held ~54% of bites, because the ~40s kill-skills are usually
  mid-cooldown — so the fish sat unpulled while the bubbles flashed).

  FAIL-OPEN, same as `all_ready?`, so an unreadable bar can never softlock a held fish:
    * `nil` slots (no reading / uncalibrated) → `true`;
    * only UNTRACKABLE keys (non-digits, or digits past the bar) → no information to gate
      on → `true`. A key counts as ready only when it maps to a real slot reading `:ready`.
  """
  def any_ready?(nil, _keys), do: true

  def any_ready?(slots, keys) do
    count = length(slots)
    trackable = for key <- keys, i = slot_index(key, count), do: i

    trackable == [] or Enum.any?(trackable, &match?(%{state: :ready}, Enum.at(slots, &1)))
  end

  @doc """
  The ready hotbar keys in ascending slot order, or `nil` when there's NO reading —
  combat treats `nil` as "fall back to blind rotation" so it never stops using skills.
  """
  def ready_keys(nil), do: nil

  def ready_keys(slots),
    do: for({%{state: :ready}, i} <- Enum.with_index(slots), do: key_for_index(i))

  defp calibrated_count(%Calibration{skill_bar_count: count}, _settings)
       when is_integer(count) and count in 1..10,
       do: count

  defp calibrated_count(_calib, settings) do
    case settings[:skill_bar_count] do
      count when is_integer(count) and count in 1..10 -> count
      _ -> 6
    end
  end

  defp key_for_index(9), do: "0"
  defp key_for_index(index), do: to_string(index + 1)

  # 0-based slot index for a hotbar key, or nil if it isn't present in this bar.
  defp slot_index(key, count) do
    case to_string(key) do
      "0" when count >= 10 -> 9
      key -> numeric_slot_index(key, count)
    end
  end

  defp numeric_slot_index(key, count) do
    case Integer.parse(key) do
      {n, ""} when n >= 1 and n <= count -> n - 1
      _ -> nil
    end
  end
end
