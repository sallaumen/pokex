defmodule Pokex.Bots.Fisher.Sensors.Fake do
  @moduledoc "Scripted observations, one queue PER key so waiting ticks don't desync scripts."
  @behaviour Pokex.Bots.Fisher.Sensors

  use Agent

  @defaults %{
    cursor: {500, 500},
    glow: false,
    wild: false,
    hostile: nil,
    battle_lock: [0, 0, 0, 0, 0, 0],
    # Default: no enemy, no ring — combat idles. A test scripts a fight with
    # battle: [%{enemies: [0], red: [0,...]}, %{enemies: [0], red: [600,0,...]}, ...]
    # (candidate at row 0, then the ring lights row 0 → confirmed → fight).
    battle: %{enemies: [], red: [0, 0, 0, 0, 0, 0]},
    # Default TRUE (kill-skills ready) so fishing scripts that don't mention
    # cooldowns hook exactly as before — the gate is opt-in via require_cooldowns.
    cooldowns_ready?: true,
    # Default nil (no skill-bar reading) so combat scripts that don't mention it use
    # the unchanged blind skill rotation.
    ready_skills: nil
  }

  def start_link(script \\ %{}), do: Agent.start_link(fn -> Map.new(script) end, name: __MODULE__)

  @impl true
  def observe(needs, _calib, _settings) do
    observations =
      Agent.get_and_update(__MODULE__, fn script ->
        Enum.map_reduce(needs, script, &pop_scripted/2)
      end)

    {:ok, Map.new(observations)}
  end

  # The last scripted value for a need STAYS (a test that scripted one frame
  # gets it for every read); anything else pops one and falls back to a default.
  defp pop_scripted(need, script) do
    case script[need] do
      [only] -> {{need, only}, script}
      [head | tail] -> {{need, head}, Map.put(script, need, tail)}
      _exhausted -> {{need, @defaults[need]}, script}
    end
  end
end
