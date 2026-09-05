defmodule Pokex.Bots.StatusCure do
  @moduledoc """
  THE STATUS POTION IN FRONT OF THE ATTACK — when 100ms of cleaning is worth it.

  "Meu pokémon pode estar sob efeito de status negativo antes de usar o auto
  combo (…) a tecla `e` usa o Status potion, que cura qualquer status negativo"
  (Lucas, 2026-09-05). Asleep, silenced or frozen, the chain is a dead key: no
  skill leaves, the bar is not spent, and the bot keeps pressing every four
  seconds at a mob that keeps hitting back.

  ## Why the cleaning is blind, and why it can be

  No reader recognizes status on screen today, so there is no asking first. But
  he confirmed the potion is **not consumed when there is no status**: the use
  is a no-op and the item stays in the bag. That takes money out of the account
  and leaves only time — and then the right answer is prophylaxis, every time
  the cost fits.

  ## This module presses nothing

  It answers WHETHER cleaning is worth it; the `Combat.Worker` presses, inside
  the same burst and after letting go of the arrows. Two hands pressing in
  parallel is the race that once cost a whole night (#480).
  """

  alias Pokex.Engine.Events
  alias Pokex.Settings

  @typedoc "How often a hunt mode cleans — see `Combat.Plan.cure_policy/1`."
  @type policy :: :always | :opening

  @doc "The Status Potion key. `\"\"` means he configured none."
  @spec key() :: String.t()
  def key, do: Settings.get(:status_cure_key) |> to_string() |> String.trim()

  @doc "Whether cleaning is on."
  @spec enabled?() :: boolean
  def enabled?, do: Settings.get(:status_cure_enabled) == true

  @doc """
  How long the game gets to apply the potion before the burst leaves.

  Zero is a legitimate answer ("no breath needed"), and it is also what a
  corrupt setting reads as: a breath nobody can parse must never become an open
  ended wait in the middle of a fight.
  """
  @spec settle_ms() :: non_neg_integer
  def settle_ms do
    case Settings.get(:status_cure_settle_ms) do
      ms when is_integer(ms) and ms > 0 -> ms
      _no_breath -> 0
    end
  end

  @doc """
  Does this burst deserve a cleaning in front of it?

  `cured?` is "this fight was already cleaned" — the worker clears it on every
  engagement, and it only matters under the `:opening` policy.
  """
  @spec due?(policy, [String.t()], boolean) :: boolean
  def due?(policy, keys, cured?) do
    enabled?() and key() != "" and attack?(keys) and worth?(policy, cured?)
  end

  @doc """
  PRESSES THE POTION — the standalone press, and the only place that knows how
  to record it.

  Always `:ok`, even when nothing left the hand: the callers are a burst in the
  middle of a fight and a panel button, and neither may become an error because
  the game was out of focus. With no key configured it does not touch the
  keyboard — a `press("")` would reach the rig as an empty combination.
  """
  @spec press() :: :ok
  def press do
    key = key()

    if enabled?() and key != "" do
      case Pokex.Rig.impl().press(key) do
        :ok -> Events.record(:cure, %{key: key})
        _refused -> :ok
      end
    end

    :ok
  end

  defp worth?(:always, _cured?), do: true
  defp worth?(:opening, cured?), do: not cured?
  defp worth?(_no_policy, _cured?), do: false

  # TARGETING AND CHANGING STANCE ARE NOT ATTACKING. Neither Tab nor `shift+N`
  # makes the pokémon cast anything, and both leave in a burst of their OWN:
  # without this fence the fight's first potion was spent on the stance change,
  # and the attack right behind it went out with no cleaning at all.
  defp attack?(keys), do: Enum.any?(keys, &(&1 not in bystanders()))

  defp bystanders do
    Enum.map([:tab_key, :attack_mode_key, :defense_mode_key], fn key ->
      Settings.get(key) |> to_string() |> String.trim()
    end)
  end
end
