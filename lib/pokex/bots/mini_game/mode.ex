defmodule Pokex.Bots.MiniGame.Mode do
  @moduledoc """
  What the bot DOES when the fishing mini-game opens. Three explicit modes,
  with the safe one as the default:

    * `:manual_assist` (default) — detect, publish the `:mini_game` fact (which
      is what holds fishing/combat/capture), make sure Space is not held, alert
      Lucas and wait for HIM to play. The bot never presses a key.
    * `:diagnostic` — same hands-off behaviour, without the alert: for watching
      a game and collecting evidence while doing something else.
    * `:auto` — the Pilot plays, exactly as before.

  Diagnostics are collected in ALL THREE: a manual game is the most valuable
  recording there is, because the capsule is being flown by someone who knows
  what the fish is doing.

  Stored as a STRING, not an atom: `~/.pokex/settings.json` round-trips through
  JSON, where an atom comes back a string — a seed atom would never compare
  equal to the persisted value, so the override would stick as a string and
  every `mode == :auto` in the codebase would silently read false. Normalizing
  on the way out (here, once) keeps the rest of the code on atoms.
  """

  alias Pokex.Settings

  @modes [:manual_assist, :diagnostic, :auto]
  @default :manual_assist

  @spec all() :: [atom]
  def all, do: @modes

  @spec default() :: atom
  def default, do: @default

  @doc "The configured mode, as an atom. Anything unrecognized fails SAFE."
  @spec current() :: atom
  def current, do: parse(Settings.get(:mini_game_mode))

  @doc "Normalize a stored/user-supplied value to a known mode (default when unknown)."
  @spec parse(term) :: atom
  def parse(value) when value in @modes, do: value

  def parse(value) when is_binary(value) do
    Enum.find(@modes, @default, &(Atom.to_string(&1) == value))
  end

  def parse(_unknown), do: @default

  @doc "Persist the mode (accepts atom or string)."
  @spec put(term) :: :ok
  def put(value), do: Settings.put(:mini_game_mode, value |> parse() |> Atom.to_string())

  @doc "Does this mode let the Pilot touch the keyboard?"
  @spec plays?(atom) :: boolean
  def plays?(mode), do: parse(mode) == :auto

  @doc "Does this mode alert Lucas that a game is waiting for him?"
  @spec alerts?(atom) :: boolean
  def alerts?(mode), do: parse(mode) == :manual_assist

  @spec label(atom) :: String.t()
  def label(mode) do
    case parse(mode) do
      :manual_assist -> "assistência manual"
      :diagnostic -> "somente diagnóstico"
      :auto -> "piloto automático"
    end
  end
end
