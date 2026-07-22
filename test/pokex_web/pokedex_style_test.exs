defmodule PokexWeb.PokedexStyleTest do
  use ExUnit.Case, async: true

  alias PokexWeb.PokedexStyle

  describe "clan_style/1" do
    test "cada clã veste a paleta do elemento que representa" do
      assert PokedexStyle.clan_style("Volcanic") == PokedexStyle.element_style("fire")
      assert PokedexStyle.clan_style("Seavell") == PokedexStyle.element_style("water")
      assert PokedexStyle.clan_style("Ironhard") == PokedexStyle.element_style("steel")
      assert PokedexStyle.clan_style("psycraft") == PokedexStyle.element_style("psychic")
    end

    test "clã desconhecido cai no fallback neutro, nunca quebra" do
      assert PokedexStyle.clan_style("Bazinga") == PokedexStyle.element_style(nil)
    end

    test "todo clã canônico tem estilo próprio — nenhum cai no fallback" do
      fallback = PokedexStyle.element_style(nil)

      for clan <- Pokex.Pokedex.Clans.all() do
        assert PokedexStyle.clan_style(clan) != fallback, "clã #{clan} sem cor própria"
      end
    end
  end
end
