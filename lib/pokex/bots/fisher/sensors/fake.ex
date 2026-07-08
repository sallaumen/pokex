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
    # Default [] (no enemy) so combat scripts that never mention this key idle; a test that
    # wants a fight scripts the attackable rows, e.g. enemy_rows: [[0], [0], []].
    enemy_rows: [],
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
        Enum.map_reduce(needs, script, fn need, acc ->
          case acc[need] do
            [only] -> {{need, only}, acc}
            [head | tail] -> {{need, head}, Map.put(acc, need, tail)}
            _ -> {{need, @defaults[need]}, acc}
          end
        end)
      end)

    {:ok, Map.new(observations)}
  end
end
