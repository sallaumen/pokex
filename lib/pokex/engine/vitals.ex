defmodule Pokex.Engine.Vitals do
  @moduledoc """
  The plain reading the engine files beside its decisions — and the rule for
  when to file one.

  A `decision` record is written when the engine CHANGES ITS MIND. That is the
  right cadence for reading a night and the wrong one for measuring it: five
  minutes of one steady fight is a single line, and a rate needs samples. So the
  same tick also files health, how many are on the list, how many damage keys
  are ready, and whether the pokémon is on the field at all.

  ## The rule: transitions exactly, everything else on a heartbeat

  The four measurements the simulator was still guessing at all hang off
  MOMENTS — the bar going away, the bar coming back, the list shrinking, the
  cooldowns running out. Sampling those on a one-second heartbeat would blur
  each of them by up to a second, which is most of the number in the case of
  `revive_settle_ms`.

  So a reading is filed the instant any watched field changes (tick resolution,
  200ms) and otherwise once every `engine_vitals_ms`. That keeps the
  transitions exact without turning a night into a hundred thousand identical
  lines: a quiet hour costs ~3600 records, a busy one a few thousand more.

  Read back by `Pokex.Sim.Calibrate`, which turns the stream into the mordida,
  the cost of one monster, the price of F4 and whether F4 clears the cooldowns.
  """

  # `revive` is watched, not just recorded: the order is the anchor a settle is
  # measured from, and a revive ordered and cleared between two heartbeats would
  # otherwise leave no trace at all.
  @watched [:enemies, :out, :spent, :revive]

  @doc "The fields whose change is worth a line of its own."
  @spec watched() :: [atom]
  def watched, do: @watched

  @doc """
  One reading, from the picture the decision was taken on.

  `ready` counts only THIS pokémon's damage keys, because "0 cooldowns livres"
  is a statement about the keys that kill, not about the bar. `nil` when the bar
  could not be read — which is not the same as zero, and the calibration refuses
  to treat it as such.
  """
  @spec reading(map, map, [String.t()]) :: map
  def reading(picture, orders, damage_keys) do
    ready = picture.ready_keys

    %{
      enemies: picture.enemies,
      hp: picture.own_hp,
      out: picture.own_out?,
      spent: picture.spent?,
      ready: ready && Enum.count(damage_keys, &(&1 in ready)),
      keys: length(damage_keys),
      phase: orders.phase,
      revive: orders.revive
    }
  end

  @doc """
  Should this reading be written?

  `last` is the reading already on disk, with its `:at`. The first reading of a
  run always is — a stream that starts mid-fight has no baseline.
  """
  @spec due?(map | nil, map, integer, integer) :: boolean
  def due?(nil, _reading, _now, _every_ms), do: true

  def due?(last, reading, now, every_ms) do
    changed?(last, reading) or now - last.at >= every_ms
  end

  defp changed?(last, reading),
    do: Enum.any?(@watched, &(Map.get(last, &1) != Map.get(reading, &1)))
end
