defmodule Pokex.VisionStarTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision
  alias Pokex.Vision.Frame

  # Lucas's REAL battle list (2026-07-21): row 0 = Wigglytuff (normal, with the
  # quest pokeball), row 1 = Shiny Seadra (gold ★ before the name). This is the
  # ground truth the star detector is tuned against — if PXG ever restyles the
  # list, this test breaks loudly instead of the bot silently going blind.
  @fixture "test/fixtures/battle/shiny_star_list.png"

  # the two rows of the real capture: 95px tall, ~47px per row
  defp bands, do: [top: 8, band: 47, rows: 2]

  defp frame! do
    {:ok, frame} = Frame.from_png_file(@fixture)
    frame
  end

  test "finds the star ONLY on the shiny's row" do
    rows = Vision.star_rows(frame!(), bands() ++ [min_cluster: 3])

    assert [{1, run}] = rows
    # measured: five consecutive columns carry 4-7 gold pixels each
    assert run >= 5
  end

  test "the per-row runs separate the shiny from the normal row by a mile" do
    assert [normal, shiny] = Vision.star_row_clusters(frame!(), bands())

    assert normal == 0
    assert shiny >= 5
  end

  test "a threshold above the measured star finds nothing (the tuning knob works)" do
    assert Vision.star_rows(frame!(), bands() ++ [min_cluster: 99]) == []
  end

  test "a battle list full of YELLOW pokémon is not a battle list full of shinies" do
    # The false positive that made this rule necessary: five Magikarps, whose
    # fins are gold. Summing a 3-column window scored them 10 against the real
    # star's 19 — with the threshold at 10, every fish was a shiny.
    {:ok, frame} = Frame.from_png_file("test/fixtures/screen/ultrawide_3440x1440_outro_mapa.png")
    {:ok, fix} = Pokex.Layout.locate(frame)
    {x, y, w, h} = Pokex.Layout.region(:battle_list, fix)
    body = Frame.crop(Frame.crop(frame, {x, y, w, h}), {0, 0, w - 30, h})
    {top, band} = Pokex.Calibration.row_band_geometry(1.0, 46)

    assert Vision.star_rows(body, top: top, band: band, rows: 6) == []
    assert Enum.max(Vision.star_row_clusters(body, top: top, band: band, rows: 6)) <= 2
  end

  test "the red pokeball never reads as a star" do
    # a frame of pure pokeball red (255,28,28) — high R, but G is far too low
    rows = for _y <- 1..40, do: List.duplicate({255, 28, 28, 255}, 60)
    path = Pokex.PngFixtures.write!(Path.join(System.tmp_dir!(), "pokeball_red.png"), rows)
    {:ok, red} = Frame.from_png_file(path)

    assert Vision.star_rows(red, top: 0, band: 20, rows: 2, min_cluster: 3) == []
  end

  describe "os falsos alarmes do campo (2026-07-30) — as capturas REAIS do Lucas" do
    # O guarda alarmou tanto que foi DESLIGADO. Reproduzido offline nas
    # capturas dele: o ícone do Shuckle (a lâmpada amarela, b chegando a 0 e
    # g>r) e ícones genuinamente dourados disparavam "estrela". Duas defesas,
    # cada uma provada por um fixture que a OUTRA não cura:
    #   - piso de cor (b>=50, g<=r) → mata a classe Shuckle/Vileplume;
    #   - zona do nome (min_x)      → mata os ícones genuinamente dourados.
    defp fixture!(nome) do
      {:ok, frame} = Frame.from_png_file("test/fixtures/shiny/#{nome}")
      frame
    end

    test "o ícone do Shuckle não é mais estrela — o piso de cor basta" do
      # antes do piso: estrela falsa na fileira 0 com run 7, nas DUAS capturas
      assert Vision.star_rows(fixture!("shuckle_falsa_estrela.png"),
               top: 30,
               band: 46,
               rows: 6,
               min_cluster: 3
             ) == []

      assert Vision.star_rows(fixture!("shuckle_falsa_estrela_2.png"),
               top: 30,
               band: 46,
               rows: 6,
               min_cluster: 3
             ) == []
    end

    test "ícones GENUINAMENTE dourados (g<=r em 976/976 px) só morrem pela ZONA" do
      frame = fixture!("icones_falsa_estrela_3fileiras.png")
      opts = [top: 30, band: 46, rows: 6, min_cluster: 3]

      # sem zona, o piso de cor não separa: 3 fileiras falsas sobrevivem
      assert length(Vision.star_rows(frame, opts)) == 3

      # os ícones terminam em x<=52; a zona do nome (63 = 83-20) os corta
      assert Vision.star_rows(frame, opts ++ [min_x: 63]) == []
    end

    test "a estrela REAL da Shiny Seadra sobrevive ao predicado endurecido" do
      # medida no campo: b 70..148, r>=g — o piso (b>=50, g<=r) passa 36/36 px
      {:ok, seadra} = Frame.from_png_file(@fixture)
      assert [{1, run}] = Vision.star_rows(seadra, top: 8, band: 47, rows: 2, min_cluster: 3)
      assert run >= 5
    end
  end
end
