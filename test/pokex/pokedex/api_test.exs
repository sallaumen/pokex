defmodule Pokex.Pokedex.ApiTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Api

  describe "url/1" do
    test "hangs the path off the configured wiki origin" do
      assert Api.url("/api/page/gen/1/001_bulbasaur") ==
               "https://wiki.pokealliance.com/api/page/gen/1/001_bulbasaur"
    end

    test "percent-encodes an accented species path" do
      assert Api.url("/api/page/gen/6/669_flabébé") ==
               "https://wiki.pokealliance.com/api/page/gen/6/669_flab%C3%A9b%C3%A9"
    end

    test "leaves the path separators alone" do
      assert Api.url("/pokemon/001.1.png") == "https://wiki.pokealliance.com/pokemon/001.1.png"
    end
  end
end
