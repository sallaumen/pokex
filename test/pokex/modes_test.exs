defmodule Pokex.ModesTest do
  use ExUnit.Case, async: true

  alias Pokex.{Modes, Settings}

  setup %{tmp_dir: tmp} do
    {:ok, server} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
    %{settings: server}
  end

  @moduletag :tmp_dir

  describe "the bundles" do
    test "parado runs the rod; movimento does not" do
      assert :fishing in Modes.bundle("parado").workers
      assert :mini_game in Modes.bundle("parado").workers

      refute :fishing in Modes.bundle("movimento").workers
      refute :mini_game in Modes.bundle("movimento").workers
    end

    test "every mode loots and keeps the pokémon alive" do
      for mode <- Modes.all() do
        workers = Modes.bundle(mode).workers
        assert :catcher in workers
        assert :player_support in workers
      end

      assert :combat in Modes.bundle("parado").workers
      assert :combat in Modes.bundle("movimento").workers
    end

    test "caçada runs catcher, support and cavebot, without direct combat" do
      w = Pokex.Modes.bundle("caçada").workers
      assert :cavebot in w
      assert :catcher in w
      assert :player_support in w
      refute :combat in w
    end

    test "the ball and the reposition are the only settings the mode decides" do
      assert Modes.bundle("parado").settings ==
               %{capture_enabled: true, reposition_enabled: true}

      assert Modes.bundle("movimento").settings ==
               %{capture_enabled: false, reposition_enabled: false}
    end

    test "an unknown mode falls back to parado rather than crashing the panel" do
      assert Modes.bundle("caverna") == Modes.bundle("parado")
    end
  end

  describe "apply!/2" do
    test "writes the mode and its whole bundle", %{settings: server} do
      :ok = Modes.apply!("movimento", server)

      assert Settings.get(:player_mode, server) == "movimento"
      assert Settings.get(:capture_enabled, server) == false
      assert Settings.get(:reposition_enabled, server) == false
    end

    test "switching back restores the parado defaults, discarding the exceptions", %{
      settings: server
    } do
      :ok = Modes.apply!("movimento", server)
      :ok = Settings.put(:capture_enabled, true, server)

      :ok = Modes.apply!("parado", server)

      assert Settings.get(:capture_enabled, server) == true
      assert Settings.get(:reposition_enabled, server) == true
    end

    test "refuses a mode it does not know, leaving settings untouched", %{settings: server} do
      before = Settings.get(:player_mode, server)
      assert Modes.apply!("caverna", server) == {:error, :unknown_mode}
      assert Settings.get(:player_mode, server) == before
    end
  end

  describe "overrides/2 — what the panel marks as YOUR exception" do
    test "a bundle applied cleanly has none", %{settings: server} do
      :ok = Modes.apply!("parado", server)
      assert Modes.overrides("parado", server) == []
    end

    test "names the key AND the value now in force, in both directions", %{settings: server} do
      :ok = Modes.apply!("parado", server)
      :ok = Settings.put(:reposition_enabled, false, server)

      assert Modes.overrides("parado", server) == [{:reposition_enabled, false}]

      :ok = Modes.apply!("movimento", server)
      :ok = Settings.put(:capture_enabled, true, server)

      assert Modes.overrides("movimento", server) == [{:capture_enabled, true}]
    end
  end
end
