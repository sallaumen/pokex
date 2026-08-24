defmodule Pokex.GameFocusTest do
  @moduledoc """
  The game is fronted by PROCESS, which stopped moving anything when the client
  started living inside an app bundle: System Events sees two processes named
  "wine", both with zero windows, and reports success while the window stays
  put. The bundle is what activates — and the process's own executable path is
  where its name comes from.
  """
  use ExUnit.Case, async: true

  alias Pokex.GameFocus

  describe "bundle_from_path/1" do
    test "names the bundle the executable sits inside" do
      assert GameFocus.bundle_from_path(
               "/Users/x/Applications/PokeAlliance.app/Contents/Resources/wine/lib/wine/x86_64-unix/wine"
             ) == "PokeAlliance"
    end

    test "keeps a name with spaces whole" do
      assert GameFocus.bundle_from_path(
               "/Applications/Wine Stable.app/Contents/Resources/bin/wine"
             ) ==
               "Wine Stable"
    end

    test "takes the outermost bundle, never a helper nested inside it" do
      assert GameFocus.bundle_from_path(
               "/Applications/Game.app/Contents/Library/Helper.app/Contents/MacOS/helper"
             ) == "Game"
    end

    test "a binary outside any bundle has no name to activate" do
      assert GameFocus.bundle_from_path("/usr/local/bin/wine") == nil
      assert GameFocus.bundle_from_path(nil) == nil
    end
  end
end
