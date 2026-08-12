defmodule Pokex.Bots.Catcher.BallsTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.Balls

  @types [
    %{"key" => "f1", "name" => "Poké Ball"},
    %{"key" => "f2", "name" => "Bola de aquáticos"}
  ]

  defp species_rule(species, key),
    do: %{"trigger" => %{"kind" => "species", "value" => species}, "key" => key}

  defp element_rule(element, key),
    do: %{"trigger" => %{"kind" => "element", "value" => element}, "key" => key}

  describe "choosing the ball for a recognised corpse" do
    test "a species rule wins over an element rule for the same body" do
      rules = [element_rule("Water", "f2"), species_rule("Tentacool", "f1")]

      assert Balls.key_for("Tentacool", rules, @types) == "f1"
    end

    test "an element rule covers every creature made of it" do
      rules = [element_rule("Water", "f2")]

      assert Balls.key_for("Tentacool", rules, @types) == "f2"
      assert Balls.key_for("Krabby", rules, @types) == "f2"
    end

    # He teaches a corpse under whatever name he types, and the shiny stand-in he
    # paints by hand is "Tentacool shiny". A rule for Tentacool has to catch it —
    # that is the entire reason the rule exists.
    test "a species rule catches the name he actually typed" do
      rules = [species_rule("Tentacool", "f2")]

      assert Balls.key_for("Tentacool shiny", rules, @types) == "f2"
      assert Balls.key_for("tentacool SHINY", rules, @types) == "f2"
    end

    test "the hand-written name still resolves to its element" do
      rules = [element_rule("Water", "f2")]

      assert Balls.key_for("Krabby shiny", rules, @types) == "f2"
    end

    test "a corpse no rule mentions gets the default ball" do
      rules = [species_rule("Tentacool", "f2")]

      assert Balls.key_for("Rattata", rules, @types) == Balls.default_key()
    end

    test "an unrecognised corpse gets the default ball" do
      assert Balls.key_for(nil, [species_rule("Tentacool", "f2")], @types) == Balls.default_key()
    end

    # A rule pointing at a key he has no ball on would throw nothing at all —
    # worse than the ordinary ball, because it looks like it worked.
    test "a rule for a ball he does not have is ignored" do
      rules = [species_rule("Tentacool", "f7")]

      assert Balls.key_for("Tentacool", rules, @types) == Balls.default_key()
    end

    test "malformed rules never take the throw down" do
      rules = [%{"key" => "f2"}, %{"trigger" => %{"kind" => "species"}, "key" => "f2"}, "lixo"]

      assert Balls.key_for("Tentacool", rules, @types) == Balls.default_key()
    end

    test "no rules at all is the plain default" do
      assert Balls.key_for("Tentacool", [], @types) == Balls.default_key()
      assert Balls.key_for("Tentacool", nil, @types) == Balls.default_key()
    end
  end

  describe "naming a ball for the feed" do
    test "a configured ball is named" do
      assert Balls.label("f2", @types) == "Bola de aquáticos"
    end

    test "an unconfigured key names itself rather than going blank" do
      assert Balls.label("f9", @types) == "f9"
      assert Balls.label("f2", [%{"key" => "f2", "name" => ""}]) == "f2"
    end
  end
end
