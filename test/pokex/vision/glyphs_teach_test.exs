defmodule Pokex.Vision.GlyphsTeachTest do
  @moduledoc """
  The shipped atlas can only contain the characters that happened to be on
  screen when captures were taken. Lucas hit exactly that: his HP read
  "?93?/9215" because the digits 8 and 2 had never been in a capture. Waiting
  for a developer to catch the right screenshot is not a fix — he must be able
  to close the gap himself.
  """
  use ExUnit.Case, async: false

  alias Pokex.Vision.Glyphs

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-glyphs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)
    Glyphs.clear()

    on_exit(fn ->
      Pokex.TestHome.restore()
      File.rm_rf!(tmp)
      Glyphs.clear()
    end)

    :ok
  end

  test "a taught glyph is read from then on, and survives a cache clear" do
    bitmap = [[1, 0, 1], [0, 1, 0], [1, 0, 1]]
    signature = Glyphs.signature(bitmap)

    refute Map.has_key?(Glyphs.atlas(), signature)

    assert {:ok, total} = Glyphs.teach(signature, "X")
    assert total > 0
    assert Glyphs.atlas()[signature] == "X"

    Glyphs.clear()
    assert Glyphs.atlas()[signature] == "X"
  end

  test "refuses to redefine a glyph the atlas already reads" do
    {signature, _char} = Enum.at(Glyphs.atlas(), 0)

    assert Glyphs.teach(signature, "Z") == {:error, :already_known}
  end

  test "unknown_in reports the unreadable glyphs with their bitmaps" do
    # a shape the atlas has no candidate for at all
    noise =
      Pokex.FrameFixtures.of(9, 9, fn x, y ->
        if rem(x + y, 2) == 0, do: {255, 255, 255}, else: {0, 0, 0}
      end)

    unknown = Glyphs.unknown_in(noise, {0, 0, 9, 9})

    assert unknown != []
    assert Enum.all?(unknown, &(is_list(&1.bitmap) and is_binary(&1.signature)))
  end

  test "a fully readable region reports nothing to teach" do
    label = Enum.find(Pokex.ScreenFixtures.labels(), &(&1["expected"] == "1525"))
    %{"fixture" => f, "region" => [x, y, w, h]} = label

    assert Glyphs.unknown_in(Pokex.ScreenFixtures.frame!(f), {x, y, w, h}) == []
  end
end
