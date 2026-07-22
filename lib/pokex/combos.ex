defmodule Pokex.Combos do
  @moduledoc """
  Sequences the bot plays against a specific enemy — Lucas's ask: "colocar a
  Jigglypuff, usar a skill 4 (sing, que faz dormir) e depois colocar meu
  pokémon que tenha vantagem contra o pokémon inimigo".

  A combo is DATA: a trigger and a list of steps. Nothing here presses a key or
  looks at the screen — it decides, and the runner in the combat path performs.
  That split is what makes the interesting part (does this combo apply, and to
  whom does it swap?) testable without a game running.

  Steps:

    * `{:swap_member, name}` — send out a specific pokémon by name
    * `{:swap_counter}` — send out whoever best answers THIS enemy
    * `{:skill, key}` — press a hotbar key
    * `{:wait, ms}` or `{:wait, setting}` — let the previous step land

  Resolution turns a combo plus an enemy into concrete steps, or refuses:
  a combo whose pokémon has no slot, or whose counter cannot be chosen, does
  not run at all. Half a combo is worse than none — it would leave the wrong
  creature out mid-fight.
  """

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Team
  alias Pokex.Settings

  defmodule Combo do
    @moduledoc "One named sequence and what sets it off."
    defstruct [:name, :trigger, :steps, enabled?: true]
  end

  @doc """
  The combo that applies to `enemy_name`, or nil.

  A species trigger beats an element trigger: naming the creature is a more
  specific statement than naming what it is made of.
  """
  def match(combos, enemy_name) when is_binary(enemy_name) do
    applicable = Enum.filter(combos, &(&1.enabled? and triggered?(&1, enemy_name)))

    Enum.find(applicable, &match?({:enemy_species, _}, &1.trigger)) || List.first(applicable)
  end

  def match(_combos, _no_enemy), do: nil

  defp triggered?(%Combo{trigger: {:enemy_species, species}}, enemy_name),
    do: String.downcase(species) == String.downcase(enemy_name)

  defp triggered?(%Combo{trigger: {:enemy_element, element}}, enemy_name) do
    case Pokedex.get(enemy_name) do
      %{elements: elements} -> element in elements
      _unknown -> false
    end
  end

  defp triggered?(_combo, _enemy), do: false

  @doc """
  Turns a combo into the exact steps to perform against `enemy_name`.

  Returns `{:ok, steps}` where every step is `{:press, key}` or `{:wait, ms}`,
  or `{:skip, reason}` when something cannot be resolved — an unslotted
  pokémon, or an enemy nobody on the team answers.
  """
  def resolve(%Combo{} = combo, enemy_name) do
    Enum.reduce_while(combo.steps, {:ok, []}, fn step, {:ok, acc} ->
      case resolve_step(step, enemy_name) do
        {:ok, resolved} -> {:cont, {:ok, acc ++ [resolved]}}
        {:skip, reason} -> {:halt, {:skip, reason}}
      end
    end)
  end

  defp resolve_step({:swap_member, name}, _enemy) do
    case Team.slot_of(name) do
      nil -> {:skip, {:no_slot, name}}
      slot -> {:ok, {:press, Team.swap_key(slot)}}
    end
  end

  defp resolve_step({:swap_counter}, enemy_name) do
    case Team.best_counter(enemy_name) do
      nil -> {:skip, {:no_counter, enemy_name}}
      slot -> {:ok, {:press, Team.swap_key(slot)}}
    end
  end

  defp resolve_step({:skill, key}, _enemy), do: {:ok, {:press, key}}

  defp resolve_step({:wait, setting}, _enemy) when is_atom(setting),
    do: {:ok, {:wait, Settings.get(setting)}}

  defp resolve_step({:wait, ms}, _enemy) when is_integer(ms) and ms >= 0,
    do: {:ok, {:wait, ms}}

  defp resolve_step(unknown, _enemy), do: {:skip, {:bad_step, unknown}}

  @doc "How long the whole sequence will take, so a caller can budget for it."
  def duration(steps),
    do:
      Enum.reduce(steps, 0, fn
        {:wait, ms}, total -> total + ms
        _press, total -> total
      end)
end
