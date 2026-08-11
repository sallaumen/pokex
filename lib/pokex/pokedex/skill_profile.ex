defmodule Pokex.Pokedex.SkillProfile do
  @moduledoc """
  What each of a pokémon's skills is FOR.

  A combo written as "press 4, then 1, then 3 and 5" only ever works for the
  pokémon whose bar it was written against — swap Vileplume for Vespiqueen and
  the same keys do something else entirely. So the plan stops naming keys and
  names JOBS instead: heal, buffs (auras, barriers, armour), area damage and
  crowd control (stun, blind, sleep, paralysis). Each pokémon says which of ITS
  keys does what, and one written strategy drives all of them —
  `Vileplume`'s area is 3 and 5, `Vespiqueen`'s is 3, 4 and 5, and a pokémon
  with no barrier at all simply has nothing to press on that step.

  The profile is stored the way it is EDITED — one job per key
  (`%{"3" => :aoe}`) — which makes a key belonging to two categories
  impossible by construction rather than by validation. `by_category/1` and
  `keys/2` give the engine the view it wants.

  Hotbar order is the firing order, because that is how he described every one
  of his own combos ("as skills 3 e 5", "3, 4, 5"): left to right.
  """

  @categories [:heal, :buffs, :aoe, :crowd]

  # The hotbar as the game lays it out: 1..9 then 0 for the tenth slot, the
  # same mapping `Pokex.Bots.SkillBar` reads cooldowns from.
  @hotbar_keys ~w(1 2 3 4 5 6 7 8 9 0)

  @type category :: :heal | :buffs | :aoe | :crowd
  @type t :: %{optional(String.t()) => category}

  @doc "Every job a skill can have, in the order the editor offers them."
  @spec categories() :: [category]
  def categories, do: @categories

  @doc "Every hotbar key, in firing order."
  @spec hotbar_keys() :: [String.t()]
  def hotbar_keys, do: @hotbar_keys

  @doc "The Portuguese label for a job — the only place these words are written."
  @spec label(category) :: String.t()
  def label(:heal), do: "cura"
  def label(:buffs), do: "aura"
  def label(:aoe), do: "área"
  def label(:crowd), do: "controle"

  @doc """
  Gives `key` the job `category`, or takes its job away with `:none`.

  A key nobody has and a job nobody knows both leave the profile untouched —
  the same rule the route's `set_action/3` follows: a control that cannot act
  is a no-op, never an error.
  """
  @spec put(t, String.t(), category | :none) :: t
  def put(profile, key, :none) when is_map(profile), do: Map.delete(profile, key)

  def put(profile, key, category)
      when is_map(profile) and category in @categories and key in @hotbar_keys,
      do: Map.put(profile, key, category)

  def put(profile, _key, _unknown) when is_map(profile), do: profile

  @doc "The engine's view: every category, with its keys in firing order."
  @spec by_category(t) :: %{category => [String.t()]}
  def by_category(profile), do: Map.new(@categories, &{&1, keys(profile, &1)})

  @doc """
  The keys of one job, in firing order — `[]` when this pokémon has none.

  The empty list is not a failure: it is what makes one strategy fit every
  pokémon, however many skills it has in each category.
  """
  @spec keys(t, category) :: [String.t()]
  def keys(profile, category), do: Enum.filter(@hotbar_keys, &(profile[&1] == category))

  @doc """
  The profile in one line, in firing order: `"cura 4 · área 3+5 · controle 1+2"`.

  Empty categories are left out; a profile with nothing in it says so, because
  a blank line beside a pokémon reads as a rendering bug rather than as work
  still to do.
  """
  @spec summary(t) :: String.t()
  def summary(profile) do
    @categories
    |> Enum.map(fn category -> {category, keys(profile, category)} end)
    |> Enum.reject(fn {_category, keys} -> keys == [] end)
    |> case do
      [] ->
        "nenhuma skill classificada"

      filled ->
        Enum.map_join(filled, " · ", &"#{label(elem(&1, 0))} #{Enum.join(elem(&1, 1), "+")}")
    end
  end

  @doc """
  Builds a profile from the editor's form data: `%{"1" => "none", "3" => "aoe"}`.

  The WHOLE form comes back on every change — one select per key, each with its
  own name — so the profile is rebuilt rather than patched. That is what makes
  the editor stateless: no `_target` to interpret, no per-key event that a
  browser was never going to send (`phx-value-*` does not ride on form events;
  the first cut of this editor was silently unable to save anything).
  """
  @spec from_form(term) :: t
  def from_form(params) when is_map(params) do
    for {key, value} <- params,
        key in @hotbar_keys,
        category = decode_category(value),
        into: %{} do
      {key, category}
    end
  end

  def from_form(_absent), do: %{}

  @doc """
  Reads a profile off disk: keys and jobs are WHITELISTED, never
  `String.to_atom/1` — `team.json` is a file he can edit by hand, and a typo in
  it must not mint atoms.
  """
  @spec decode(term) :: t
  def decode(map) when is_map(map) do
    for {key, value} <- map, key in @hotbar_keys, category = decode_category(value), into: %{} do
      {key, category}
    end
  end

  def decode(_absent), do: %{}

  defp decode_category(value) when is_atom(value) and value in @categories, do: value

  defp decode_category(value) when is_binary(value),
    do: Enum.find(@categories, &(Atom.to_string(&1) == value))

  defp decode_category(_unknown), do: nil

  @doc "The JSON-safe shape: `%{\"3\" => \"aoe\"}`."
  @spec encode(t) :: %{optional(String.t()) => String.t()}
  def encode(profile), do: Map.new(profile, fn {key, cat} -> {key, Atom.to_string(cat)} end)
end
