defmodule Pokex.Vision.SparkleTest do
  @moduledoc """
  The shiny sparkle beside the name, on crops of his own video of 11/09
  (Shiny Feraligatr in the desert, tile 151, H.264). The bar positions were
  measured by hand on the crops; the eye finds them on live frames.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision.{CreatureMarks, Frame, Sparkle}

  @fixtures "test/fixtures/sparkle"

  defp frame!(name) do
    {:ok, frame} = Frame.from_png_file(Path.join(@fixtures, name))
    frame
  end

  defp near?({x, y}, {ex, ey}, tol), do: abs(x - ex) <= tol and abs(y - ey) <= tol

  test "the star beside a green name is found and handed to that creature's bar" do
    frame = frame!("feraligatr_shiny_green_name.png")
    bar = {168, 71}

    assert [%{bar: ^bar, point: point, px: px, box: {_, _, w, h}}] =
             Sparkle.find(frame, [%{point: bar}])

    assert near?(point, {116, 63}, 6)
    assert px >= 30
    assert w >= 8 and h >= 8
  end

  test "a yellow name does not pass for the star, and the star beside it is found" do
    frame = frame!("feraligatr_shiny_yellow_name.png")
    bar = {138, 76}

    assert [%{bar: ^bar, point: point}] = Sparkle.find(frame, [%{point: bar}])
    assert near?(point, {86, 68}, 6)
  end

  test "a common creature has no star beside its name" do
    frame = frame!("feraligatr_common.png")
    assert Sparkle.find(frame, [%{point: {150, 70}}, %{point: {140, 62}}]) == []
  end

  test "a pile of common creatures on sand lights nothing, wherever the eye finds bars" do
    frame = frame!("feraligatr_pile.png")
    marks = CreatureMarks.find(frame)
    everywhere = for x <- 30..570//20, y <- 30..370//20, do: %{point: {x, y}}
    assert Sparkle.find(frame, marks ++ everywhere) == []
  end

  # a painted frame: a dark floor (a cave), a plus-shaped star, a yellow WORD
  defp painted(w, h, bg, patches) do
    pixels =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} =
          Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
            if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
          end)

        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: pixels, scale: 1.0}
  end

  @amarelo {250, 215, 60}

  defp estrela(sx, sy),
    do: [{{sx - 1, sy - 6, 3, 13}, @amarelo}, {{sx - 5, sy - 1, 11, 3}, @amarelo}]

  test "over a black cave floor the star is still a star" do
    frame = painted(280, 280, {24, 24, 24}, estrela(90, 100))
    assert [%{bar: {140, 110}, px: 63}] = Sparkle.find(frame, [%{point: {140, 110}}])
  end

  test "the letters of a yellow name are not stars: each one has a neighbour" do
    # three 7×11 letters two pixels apart, where the name's start would be
    letters = for i <- 0..2, do: {{100 + i * 9, 95, 7, 11}, @amarelo}
    frame = painted(280, 280, {200, 180, 120}, letters)
    assert Sparkle.find(frame, [%{point: {140, 110}}]) == []
  end

  test "a mark near the frame's edge is looked at without crashing" do
    frame = frame!("feraligatr_common.png")
    assert Sparkle.find(frame, [%{point: {2, 2}}, %{point: {279, 139}}]) == []
  end
end
