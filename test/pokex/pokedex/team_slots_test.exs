defmodule Pokex.Pokedex.TeamSlotsTest do
  @moduledoc """
  The team as the bot must treat it: a thing it READS, not a thing it is told.

  Lucas: "a posição dos pokémons nos atalhos C+N nunca é fixa, conforme vou
  usando pokemons a ordem vai mudando". So there is no `set_slot` any more —
  the slot arrives with the `:team` feed's reading, and everything downstream
  takes it as an argument.
  """
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Team

  # what the :team feed publishes, mid-hunt
  defp live(pairs), do: Enum.map(pairs, fn {slot, name} -> %{slot: slot, name: name} end)

  test "the swap key is what the game shows, in the Rig's spelling" do
    # the HUD prints "C+2"; the rig speaks "ctrl+2" — the same modifier the
    # S+Q slot already uses as "shift+q"
    assert Team.swap_key(2) == "ctrl+2"
    assert Team.swap_key(6) == "ctrl+6"
  end

  test "best_counter reads the team on screen right now" do
    # Magikarp is Water: weak to Grass and Electric
    rows = live([{2, "Jigglypuff"}, {4, "Sceptile"}])

    assert Team.best_counter("Magikarp", rows) == 4
  end

  test "the SAME team in a different order answers with a different key" do
    # this is the whole point: Sceptile moved, so the key that brings it out
    # moved with it
    assert Team.best_counter("Magikarp", live([{4, "Sceptile"}])) == 4
    assert Team.best_counter("Magikarp", live([{6, "Sceptile"}])) == 6
  end

  test "no advantage means NO counter — a combo must not run on a guess" do
    assert Team.best_counter("Jigglypuff", live([{5, "Jigglypuff"}])) == nil
    assert Team.best_counter("Não Existe", live([{5, "Sceptile"}])) == nil
  end

  test "rows the eye could not identify are not candidates" do
    # an unread portrait arrives as name: nil — it must never be swapped to,
    # because nobody knows what would come out
    rows = [%{slot: 2, name: nil}, %{slot: 3, name: nil}]

    assert Team.best_counter("Magikarp", rows) == nil
  end

  test "an empty reading answers nothing rather than raising" do
    assert Team.best_counter("Magikarp", []) == nil
  end

  test "a row with no hotkey label is unreachable, however well it was identified" do
    # measured on the committed captures: earlier the same day the fifth row
    # carried no "C+N" at all. Pressing a key that is not bound does something
    # else entirely, so the row is not a candidate.
    rows = [%{slot: nil, name: "Sceptile"}]

    assert Team.best_counter("Magikarp", rows) == nil
  end
end
