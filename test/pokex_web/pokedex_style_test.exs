defmodule PokexWeb.PokedexStyleTest do
  use ExUnit.Case, async: true

  alias PokexWeb.PokedexStyle

  describe "clan_style/1" do
    test "each clan wears the palette of the element it represents" do
      assert PokedexStyle.clan_style("Volcanic") == PokedexStyle.element_style("fire")
      assert PokedexStyle.clan_style("Seavell") == PokedexStyle.element_style("water")
      assert PokedexStyle.clan_style("Ironhard") == PokedexStyle.element_style("steel")
      assert PokedexStyle.clan_style("psycraft") == PokedexStyle.element_style("psychic")
    end

    test "an unknown clan falls back to the neutral style, never crashes" do
      assert PokedexStyle.clan_style("Bazinga") == PokedexStyle.element_style(nil)
    end

    test "every canonical clan has its own style — none falls back" do
      fallback = PokedexStyle.element_style(nil)

      for clan <- Pokex.Pokedex.Clans.all() do
        assert PokedexStyle.clan_style(clan) != fallback, "clan #{clan} lacks its own color"
      end
    end
  end
end
