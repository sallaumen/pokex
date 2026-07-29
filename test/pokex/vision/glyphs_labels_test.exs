defmodule Pokex.Vision.GlyphsLabelsTest do
  use ExUnit.Case, async: true

  # Estes testes mastigam TODAS as fixtures de captura real com Vision.Glyphs —
  # ~21s num Apple Silicon, bem além dos 60s default no runner de 2 núcleos do
  # CI. A folga acomoda hardware lento sem esconder um travamento de verdade.
  @moduletag timeout: 300_000

  test "every labeled region fits inside its fixture" do
    for %{"fixture" => name, "region" => [x, y, w, h]} = label <- Pokex.ScreenFixtures.labels() do
      frame = Pokex.ScreenFixtures.frame!(name)

      assert x >= 0 and y >= 0 and x + w <= frame.width and y + h <= frame.height,
             "label #{label["expected"]} out of bounds in #{name}: #{inspect({x, y, w, h})}"
    end
  end

  test "the label set covers every field the HUD feeds will read" do
    expected = Pokex.ScreenFixtures.labels() |> Enum.map(& &1["expected"]) |> MapSet.new()

    for must <- [
          "1525",
          "90",
          "96",
          "322",
          "36",
          "7",
          "43",
          "5559/6410",
          "(337, 46107, 4)",
          "Pidgeot"
        ] do
      assert must in expected, "the atlas would never learn #{must}"
    end
  end
end
