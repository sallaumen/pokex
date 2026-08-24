defmodule Pokex.Modes do
  @moduledoc """
  The ways Lucas plays, as data: standing on a fishing spot, walking around
  hunting by hand, or letting the cavebot walk a route (caçada).

  A mode is a BUILT-IN PRESET, not a second owner of the truth. `Settings`
  stays the only place a value lives; this module only says which values a mode
  stands for, applies them, and reports which ones currently diverge. That last
  part is what lets the panel show "manual: off" on a line instead of leaving
  him to guess why the bot behaves differently from what the mode promises.

  The bundle is deliberately SMALL. Only what genuinely has a different right
  answer per mode belongs here:

    * `capture_enabled` — the ball is aimed from a ground baseline learned while
      standing still. Walking, there is no such baseline.
    * `reposition_enabled` — after a fight the support middle-clicks the
      calibrated tile. On a spot that is going home; walking, it undoes the walk.

  Looting, revive, potion, the escape and the support itself are right in both
  modes and stay out. So do the fishing gates (`require_cooldowns`,
  `require_pokemon_hp`): with no rod running they have nothing to hold back, and
  flipping them would be theatre.
  """

  alias Pokex.Settings

  @default "still"

  # The mode is a stored value, so it is English like the rest of the code; the
  # panel shows `label/1` instead of the raw value.
  @labels %{"still" => "Parado", "moving" => "Movimento", "hunt" => "Caçada"}

  @bundles %{
    "still" => %{
      workers: [:fishing, :combat, :catcher, :mini_game, :player_support, :timers],
      settings: %{capture_enabled: true, reposition_enabled: true}
    },
    "moving" => %{
      # The catcher stays UP so a kill is still SEEN while he walks — only the
      # ball, gated separately by capture_enabled, needs him still.
      workers: [:combat, :catcher, :player_support, :timers],
      settings: %{capture_enabled: false, reposition_enabled: false}
    },
    "hunt" => %{
      # NO :combat here — the cavebot OWNS the Combat's run/halt (it arms the
      # fight on its first tick and only drops it when it blocks). Starting the
      # fight directly would leave two owners disagreeing about it.
      workers: [:catcher, :player_support, :cavebot, :timers],
      settings: %{}
    }
  }

  @modes Map.keys(@bundles)

  @doc "Every mode, in the order the panel offers them."
  def all, do: [@default | @modes -- [@default]]

  @doc "Whether `mode` is one this bot knows how to run."
  def known?(mode), do: mode in @modes

  @doc "How the panel names `mode` — the value itself if it is not one of ours."
  def label(mode), do: Map.get(@labels, mode, to_string(mode))

  @doc "The mode in force."
  def current(server \\ Settings), do: Settings.get(:player_mode, server)

  @doc """
  What `mode` stands for: the workers `Iniciar` brings up and the settings it
  applies.

  An unknown mode answers with the default bundle rather than raising — a
  hand-edited settings file must never be able to blank the panel.
  """
  def bundle(mode) when mode in @modes, do: @bundles[mode]
  def bundle(_unknown), do: @bundles[@default]

  @doc "The workers `mode` runs."
  def workers(mode), do: bundle(mode).workers

  @doc """
  Switches to `mode` and writes its whole bundle.

  Switching REAPPLIES the defaults, so any exception made under the previous
  mode is discarded — the panel says so on the button rather than hiding it.
  """
  def apply!(mode, server \\ Settings)

  def apply!(mode, server) when mode in @modes do
    :ok = Settings.put(:player_mode, mode, server)

    Enum.each(bundle(mode).settings, fn {key, value} ->
      :ok = Settings.put(key, value, server)
    end)
  end

  def apply!(_unknown, _server), do: {:error, :unknown_mode}

  @doc """
  The bundle keys whose value in force differs from what `mode` asks for, as
  `{key, value_now}`.

  Empty means the bot is doing exactly what the mode promises.
  """
  def overrides(mode, server \\ Settings) do
    mode
    |> bundle()
    |> Map.fetch!(:settings)
    |> Enum.sort()
    |> Enum.flat_map(fn {key, wanted} ->
      case Settings.get(key, server) do
        ^wanted -> []
        now -> [{key, now}]
      end
    end)
  end
end
