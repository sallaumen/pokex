defmodule Pokex.Bots.Catcher.Balls do
  @moduledoc """
  Which Pokéball to throw at the corpse we just recognised.

  Lucas keeps more than one kind on his hotbar — F1 the ordinary one, F2 one
  that is better at water types — and the aim already knows the NAME of the body
  it is throwing at. Spending the good ball on everything is waste; spending the
  ordinary one on the thing he is hunting is worse.

  Rules read like the combo triggers he already writes, and settle the same way:
  naming the CREATURE beats naming what it is made of, and both beat the default
  ball. A rule pointing at a key he has no ball on would throw nothing, so a rule
  whose key is not among the configured balls is ignored.

  The species rule matches by CONTAINMENT, not equality: he teaches a corpse
  under whatever name he types, and the shiny stand-in he paints by hand is
  "Tentacool shiny". A rule for "Tentacool" has to catch it — that is the whole
  reason the rule exists.
  """

  alias Pokex.Pokedex
  alias Pokex.Settings

  @doc """
  The hotbar key for a corpse named `name` (nil = unrecognised → the default).

  Reads the configured balls and rules at call time: he flips these between
  hunts, and a ball chosen from a config frozen at boot is a ball he did not ask
  for.
  """
  @spec key_for(String.t() | nil) :: String.t()
  def key_for(name), do: key_for(name, Settings.get(:ball_rules), Settings.get(:ball_types))

  @doc "Same, against explicit rules and balls — the testable half."
  @spec key_for(String.t() | nil, list, list) :: String.t()
  def key_for(name, rules, types) do
    with true <- is_binary(name),
         rules = Enum.filter(List.wrap(rules), &known_ball?(&1, types)),
         %{} = rule <- best_rule(rules, name) do
      rule["key"]
    else
      _no_rule -> default_key()
    end
  end

  @doc "How the panel names a key: the ball's label, or the bare key."
  @spec label(String.t()) :: String.t()
  def label(key), do: label(key, Settings.get(:ball_types))

  @spec label(String.t(), list) :: String.t()
  def label(key, types) do
    case Enum.find(List.wrap(types), &(&1["key"] == key)) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _unnamed -> key
    end
  end

  @doc "The default ball — what an unrecognised or unruled corpse gets."
  def default_key, do: Settings.get(:ball_key)

  defp best_rule(rules, name) do
    Enum.find(rules, &species_match?(&1, name)) || Enum.find(rules, &element_match?(&1, name))
  end

  defp known_ball?(%{"key" => key}, types),
    do: Enum.any?(List.wrap(types), &(&1["key"] == key))

  defp known_ball?(_malformed, _types), do: false

  defp species_match?(%{"trigger" => %{"kind" => "species", "value" => species}}, name)
       when is_binary(species) and species != "",
       do: String.contains?(String.downcase(name), String.downcase(species))

  defp species_match?(_other, _name), do: false

  defp element_match?(%{"trigger" => %{"kind" => "element", "value" => element}}, name)
       when is_binary(element) and element != "" do
    case species_of(name) do
      %{elements: elements} ->
        Enum.any?(elements, &(String.downcase(&1) == String.downcase(element)))

      _unknown ->
        false
    end
  end

  defp element_match?(_other, _name), do: false

  # The taught name is whatever he typed — "Tentacool shiny" is not a species
  # the Pokédex knows. Try the whole name, then its words, so a hand-written
  # label still resolves to the creature it is talking about.
  defp species_of(name) do
    Pokedex.get(name) || name |> String.split() |> Enum.find_value(&Pokedex.get/1)
  end
end
