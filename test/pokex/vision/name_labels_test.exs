defmodule Pokex.Vision.NameLabelsTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.{Frame, NameLabels}

  @fixture Path.join([__DIR__, "..", "..", "support", "fixtures", "name_labels.png"])

  describe "his own client" do
    setup do
      {:ok, frame} = Frame.from_png_file(Path.expand(@fixture))
      %{frame: frame}
    end

    test "finds the hostile names the game draws", %{frame: frame} do
      assert [a, b, c] = NameLabels.find(frame)

      # Three creatures, placed where a person looking at the picture puts them.
      assert {a.x, a.y} == {62, 54}
      assert {b.x, b.y} == {214, 54}
      assert {c.x, c.y} == {214, 356}

      # "Pikachu" is one width on his display, whatever else is on screen — the
      # steadiest thing about the signal, and what makes the width band safe.
      for label <- [a, b, c], do: assert(label.w in 50..64)
    end

    test "a name buried under a skill banner is LOST, and that is the safe direction" do
      # The fixture holds a fourth "Pikachu" at the bottom left with "QUICK
      # ATTACK!" and "AGILITY!" painted across it, and this reader does not find
      # it. Measured on his recording, the same thing happens to every creature
      # standing inside an Earthquake.
      #
      # It is written down as a TEST rather than a known bug because the error
      # only ever runs one way: a hidden name is one creature FEWER, so a rule
      # that waits for a pile waits longer under effects instead of firing at a
      # pile that was never there.
      {:ok, frame} = Frame.from_png_file(Path.expand(@fixture))
      labels = NameLabels.find(frame)

      refute Enum.any?(labels, &(&1.x < 100 and &1.y > 300))
    end

    test "leaves his OWN pokémon out, because the game draws it green" do
      # The fixture holds a green "Dugtrio" label directly under a red "Pikachu"
      # one. A reader that counted every name would report his own pokémon as a
      # creature to fire at — the same class of mistake as teaching his pokémon
      # into the corpse library.
      {:ok, frame} = Frame.from_png_file(Path.expand(@fixture))
      labels = NameLabels.find(frame)

      # The Dugtrio label sits at y≈207 in fixture coordinates; nothing found
      # there means the colour rule did the excluding for free.
      refute Enum.any?(labels, &(&1.y in 195..225))
    end

    test "leaves the yellow skill banners out", %{frame: frame} do
      # "QUICK ATTACK!" and "AGILITY!" sit in the same band as the names and are
      # WIDER than any of them; counting one would inflate a pile that is not there.
      labels = NameLabels.find(frame)
      refute Enum.any?(labels, &(&1.w > 70))
    end
  end

  describe "shapes it must refuse" do
    test "an empty frame reads nothing" do
      assert NameLabels.find(grey(120, 80)) == []
    end

    test "a red run too short for a name is not a name" do
      frame = grey(120, 40) |> paint(10, 10, 8, 10, {220, 0, 0})
      assert NameLabels.find(frame) == []
    end

    test "a red run too TALL for a name is not a name" do
      # A health bar, a red floor tile, a blood splash: all wide, none 10px tall.
      frame = grey(200, 120) |> paint(20, 20, 60, 60, {220, 0, 0})
      assert NameLabels.find(frame) == []
    end

    test "a name-shaped red run is found where it was painted" do
      frame = grey(200, 120) |> paint(40, 30, 56, 10, {220, 0, 0})
      assert [label] = NameLabels.find(frame)
      assert label.x == 40
      assert label.w == 56
      assert label.y in 28..32
    end

    test "two names on the same row stay two" do
      frame =
        grey(300, 120)
        |> paint(10, 30, 56, 10, {220, 0, 0})
        |> paint(120, 30, 56, 10, {220, 0, 0})

      assert length(NameLabels.find(frame)) == 2
    end

    test "orange damage numbers are not names" do
      # (255, 140, 0): red dominates, but green and blue are far apart — the
      # channel-split test is the only thing standing between a big hit and a
      # phantom creature.
      frame = grey(200, 120) |> paint(40, 30, 56, 10, {255, 140, 0})
      assert NameLabels.find(frame) == []
    end
  end

  defp grey(w, h) do
    %Frame{width: w, height: h, rgba: for(_ <- 1..(w * h), into: <<>>, do: <<90, 90, 90, 255>>)}
  end

  defp paint(%Frame{width: w} = frame, x0, y0, bw, bh, {r, g, b}) do
    rgba =
      for i <- 0..(byte_size(frame.rgba) - 1)//4, into: <<>> do
        px = div(i, 4)
        {x, y} = {rem(px, w), div(px, w)}

        if x >= x0 and x < x0 + bw and y >= y0 and y < y0 + bh,
          do: <<r, g, b, 255>>,
          else: binary_part(frame.rgba, i, 4)
      end

    %{frame | rgba: rgba}
  end
end
