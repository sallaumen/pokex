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

  alias Pokex.{Calibration, Rig, Vision}
  alias Pokex.Vision.Frame

  @doc "Per-slot `%{brightness, saturation, state}` list, or `nil` (not calibrated / capture failed)."
  def read(calib, settings) do
    with %Calibration{skill_bar_region: region} when is_tuple(region) <- calib,
         {:ok, path} <- Rig.impl().capture(region, "skillbar.png"),
         {:ok, frame} <- Frame.from_png_file(path) do
      Vision.skill_slots(frame,
        count: settings[:skill_bar_count],
        min_brightness: settings[:skill_ready_min_brightness],
        min_saturation: settings[:skill_ready_min_saturation]
      )
    else
      _ -> nil
    end
  end

  @doc "The per-slot states (`[:ready | :cooldown]`), or `nil` when there's no reading."
  def states(nil), do: nil
  def states(slots), do: Enum.map(slots, & &1.state)

  @doc """
  Are ALL of `keys` (hotbar strings like `"4"`) ready? FAIL-OPEN: `true` when there's no
  reading, so `require_cooldowns` never softlocks fishing on a missing/uncalibrated bar.
  """
  def all_ready?(nil, _keys), do: true
  def all_ready?(slots, keys), do: Enum.all?(keys, &(slot_state(slots, &1) == :ready))

  @doc """
  The ready hotbar keys in ascending slot order, or `nil` when there's NO reading —
  combat treats `nil` as "fall back to blind rotation" so it never stops using skills.
  """
  def ready_keys(nil), do: nil

  def ready_keys(slots),
    do: for({%{state: :ready}, i} <- Enum.with_index(slots), do: to_string(i + 1))

  defp slot_state(slots, key) do
    case Integer.parse(to_string(key)) do
      {n, _} -> slots |> Enum.at(n - 1) |> slot_or_cooldown()
      :error -> :cooldown
    end
  end

  defp slot_or_cooldown(%{state: state}), do: state
  defp slot_or_cooldown(_), do: :cooldown
end
