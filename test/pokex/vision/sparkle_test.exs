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

  # THE RAW STAR (17:26 and 17:28 of 11/09, the two shinies the first build
  # missed): r 248-255, g 194-230, b 37-88, a 13-15 × 16 cross of 61-74 px with
  # its small twin 3 px away — cut from the black box's full frames, bar at
  # (140,40). The third one stands under the chain's green haze.
  for n <- 1..3 do
    test "the raw star beside the name is found and handed to that creature's bar (#{n})" do
      name =
        Enum.at(
          ["star_raw_1.png", "star_raw_2.png", "star_raw_3_under_chain.png"],
          unquote(n) - 1
        )

      frame = frame!(name)
      bar = {140, 40}

      assert [%{bar: ^bar, point: point, px: px, box: {_, _, w, h}}] =
               Sparkle.find(frame, [%{point: bar}])

      assert near?(point, {86, 31}, 8)
      assert px >= 45
      assert w >= 12 and h >= 14
    end
  end

  # 17:25:55 of 11/09: three offset blocks of a slightly duller yellow
  # (234,230,53) beside a COMMON creature's name — 38 px, no cross, r < 244.
  test "the staircase beside a common creature's name is not a star" do
    frame = frame!("staircase_raw.png")
    assert Sparkle.find(frame, [%{point: {140, 40}}]) == []
  end

  # the video is H.264: its star lost red (228-252) and would not pass the raw
  # palette; the crops stay as the NEGATIVE cases (a common creature, the pile)
  test "the compressed video's common creature and its yellow name light nothing" do
    frame = frame!("feraligatr_shiny_yellow_name.png")
    assert Sparkle.find(frame, [%{point: {138, 76}}]) |> Enum.reject(&(&1.px >= 30)) == []
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
        {r, g, b} = paint(x, y, bg, patches)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: pixels, scale: 1.0}
  end

  defp paint(x, y, bg, patches) do
    Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
      if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
    end)
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

  # 17:01 of 11/09, first hunt with the sparkle on: "qualquer bicho na minha
  # tela, ele tá falando que tem shiny". Nine yellow specks of sand beside
  # names in twelve of the guard's own raw photos — 4×4 to 5×5 px,
  # (216-248, 184-192, 88-104) — and each one was a sighting. The real star is
  # 38-63 px and its yellow keeps green ≥ 196 and blue ≤ 96.
  for n <- 1..3 do
    test "a speck of desert sand beside a name is not a star (#{n})" do
      frame = frame!("desert_specks_#{unquote(n)}.png")
      assert Sparkle.find(frame, [%{point: {140, 40}}]) == []
    end
  end

  test "a mark near the frame's edge is looked at without crashing" do
    frame = frame!("feraligatr_common.png")
    assert Sparkle.find(frame, [%{point: {2, 2}}, %{point: {279, 139}}]) == []
  end
end
