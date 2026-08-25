defmodule Pokex.Pokedex.TypeChart do
  @moduledoc """
  Element effectiveness for the Poké Alliance, as the canonical 18-type chart.

  The PA wiki publishes no effectiveness anywhere — not a page, not a field
  (measured 25/08 across all 957 wiki paths). Its 18 elements are exactly the
  canonical Pokémon types, though (PokeXGames carried a nineteenth, `Crystal`;
  the PA does not), so the standard chart is the best available answer.

  It is an ASSUMPTION, not a measurement: a PokeTibia server can retune the
  chart. That is precisely why it lives here as pure data and why
  `Pokex.Pokedex` derives the buckets at LOAD time instead of writing them
  into pokedex.json — correcting one cell later costs an edit, not a re-sync
  of 910 pages.

  The matrix is written as the exceptions only: `@chart` maps an attacking
  element to what it does UNUSUALLY well or badly. Everything unlisted is 1.0.
  """

  @elements ~w(Bug Dark Dragon Electric Fairy Fighting Fire Flying Ghost
               Grass Ground Ice Normal Poison Psychic Rock Steel Water)

  # attacking => %{defending => multiplier}. Only the non-1.0 cells.
  @chart %{
    "Bug" => %{
      "Dark" => 2.0,
      "Grass" => 2.0,
      "Psychic" => 2.0,
      "Fairy" => 0.5,
      "Fighting" => 0.5,
      "Fire" => 0.5,
      "Flying" => 0.5,
      "Ghost" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Dark" => %{
      "Ghost" => 2.0,
      "Psychic" => 2.0,
      "Dark" => 0.5,
      "Fairy" => 0.5,
      "Fighting" => 0.5
    },
    "Dragon" => %{"Dragon" => 2.0, "Steel" => 0.5, "Fairy" => 0.0},
    "Electric" => %{
      "Flying" => 2.0,
      "Water" => 2.0,
      "Dragon" => 0.5,
      "Electric" => 0.5,
      "Grass" => 0.5,
      "Ground" => 0.0
    },
    "Fairy" => %{
      "Dark" => 2.0,
      "Dragon" => 2.0,
      "Fighting" => 2.0,
      "Fire" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Fighting" => %{
      "Dark" => 2.0,
      "Ice" => 2.0,
      "Normal" => 2.0,
      "Rock" => 2.0,
      "Steel" => 2.0,
      "Bug" => 0.5,
      "Fairy" => 0.5,
      "Flying" => 0.5,
      "Poison" => 0.5,
      "Psychic" => 0.5,
      "Ghost" => 0.0
    },
    "Fire" => %{
      "Bug" => 2.0,
      "Grass" => 2.0,
      "Ice" => 2.0,
      "Steel" => 2.0,
      "Dragon" => 0.5,
      "Fire" => 0.5,
      "Rock" => 0.5,
      "Water" => 0.5
    },
    "Flying" => %{
      "Bug" => 2.0,
      "Fighting" => 2.0,
      "Grass" => 2.0,
      "Electric" => 0.5,
      "Rock" => 0.5,
      "Steel" => 0.5
    },
    "Ghost" => %{"Ghost" => 2.0, "Psychic" => 2.0, "Dark" => 0.5, "Normal" => 0.0},
    "Grass" => %{
      "Ground" => 2.0,
      "Rock" => 2.0,
      "Water" => 2.0,
      "Bug" => 0.5,
      "Dragon" => 0.5,
      "Fire" => 0.5,
      "Flying" => 0.5,
      "Grass" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Ground" => %{
      "Electric" => 2.0,
      "Fire" => 2.0,
      "Poison" => 2.0,
      "Rock" => 2.0,
      "Steel" => 2.0,
      "Bug" => 0.5,
      "Grass" => 0.5,
      "Flying" => 0.0
    },
    "Ice" => %{
      "Dragon" => 2.0,
      "Flying" => 2.0,
      "Grass" => 2.0,
      "Ground" => 2.0,
      "Fire" => 0.5,
      "Ice" => 0.5,
      "Steel" => 0.5,
      "Water" => 0.5
    },
    "Normal" => %{"Rock" => 0.5, "Steel" => 0.5, "Ghost" => 0.0},
    "Poison" => %{
      "Fairy" => 2.0,
      "Grass" => 2.0,
      "Ghost" => 0.5,
      "Ground" => 0.5,
      "Poison" => 0.5,
      "Rock" => 0.5,
      "Steel" => 0.0
    },
    "Psychic" => %{
      "Fighting" => 2.0,
      "Poison" => 2.0,
      "Psychic" => 0.5,
      "Steel" => 0.5,
      "Dark" => 0.0
    },
    "Rock" => %{
      "Bug" => 2.0,
      "Fire" => 2.0,
      "Flying" => 2.0,
      "Ice" => 2.0,
      "Fighting" => 0.5,
      "Ground" => 0.5,
      "Steel" => 0.5
    },
    "Steel" => %{
      "Fairy" => 2.0,
      "Ice" => 2.0,
      "Rock" => 2.0,
      "Electric" => 0.5,
      "Fire" => 0.5,
      "Steel" => 0.5,
      "Water" => 0.5
    },
    "Water" => %{
      "Fire" => 2.0,
      "Ground" => 2.0,
      "Rock" => 2.0,
      "Dragon" => 0.5,
      "Grass" => 0.5,
      "Water" => 0.5
    }
  }

  # {multiplier, label, kind} — the words the detail page prints, in the order
  # it prints them (hardest hit first).
  @tiers [
    {4.0, "Muito Efetivo", "weak"},
    {2.0, "Efetivo", "weak"},
    {1.0, "Normal", "neutral"},
    {0.5, "Inefetivo", "resists"},
    {0.25, "Muito Inefetivo", "resists"},
    {0.0, "Imune", "immune"}
  ]

  @doc "The eighteen canonical elements, capitalised and alphabetical."
  def elements, do: @elements

  @doc """
  How hard `attacking` hits a species whose elements are `defending` — the
  product of one column per defending element. An unknown element contributes
  1.0, so a typo in the base narrows nothing instead of erasing everything.
  """
  def multiplier(attacking, defending) when is_binary(attacking) and is_list(defending) do
    row = Map.get(@chart, attacking, %{})
    Enum.reduce(defending, 1.0, fn element, acc -> acc * Map.get(row, element, 1.0) end)
  end

  @doc "Elements that hit these elements HARD (multiplier above 1)."
  def weak_to(defending), do: bucket(defending, &(&1 > 1.0))

  @doc "Elements these elements shrug off (multiplier between 0 and 1)."
  def resists(defending), do: bucket(defending, &(&1 > 0.0 and &1 < 1.0))

  @doc "Elements that do NOTHING to these elements (multiplier 0)."
  def immune(defending), do: bucket(defending, &(&1 == 0.0))

  @doc "Elements with no opinion either way (multiplier exactly 1)."
  def neutral(defending), do: bucket(defending, &(&1 == 1.0))

  @doc """
  The buckets as the detail page shows them: one row per strength tier,
  worded like the old PokeTibia pages did, with empty tiers dropped.
  """
  def effectiveness(defending) do
    for {value, label, kind} <- @tiers,
        elements = bucket(defending, &(&1 == value)),
        elements != [],
        do: %{label: label, kind: kind, elements: elements}
  end

  defp bucket(defending, keep?) do
    Enum.filter(@elements, &keep?.(multiplier(&1, defending)))
  end
end
