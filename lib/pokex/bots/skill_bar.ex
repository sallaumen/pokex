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
  capture fails. `all_ready?/2` and `ready_keys/1` derive the answers the bots need,
  mapping slot i (0-based, left→right) to hotbar key `to_string(i + 1)`.
  """

  alias Pokex.{Calibration, Vision}
  alias Pokex.Bots.Capture
  alias Pokex.Vision.Frame

  @doc "Per-slot `%{brightness, saturation, state}` list, or `nil` (not calibrated / capture failed)."
  def read(calib, settings) do
    with %Calibration{skill_bar_region: region} when is_tuple(region) <- calib,
         {:ok, path} <- Capture.grab(region, "skillbar.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      Vision.skill_slots(frame,
        count: settings[:skill_bar_count],
        min_brightness: settings[:skill_ready_min_brightness],
        min_saturation: settings[:skill_ready_min_saturation],
        min_vivid_pct: settings[:skill_ready_min_vivid_pct]
      )
    else
      _ -> nil
    end
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
    do: for({%{state: :ready}, i} <- Enum.with_index(slots), do: to_string(i + 1))

  # 0-based slot index for a hotbar key, or nil if it isn't a digit in 1..count.
  defp slot_index(key, count) do
    case Integer.parse(to_string(key)) do
      {n, ""} when n >= 1 and n <= count -> n - 1
      _ -> nil
    end
  end
end
