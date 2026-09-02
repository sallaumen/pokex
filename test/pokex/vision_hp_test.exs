defmodule Pokex.VisionHpTest do
  @moduledoc """
  The phantom revive of 2026-08-07, in one file.

  On a single monitor the browser sits in front of the game, so the HP strip
  captures that window instead of the bar. Every DARK pixel counted as "the
  bar's empty track", so a uniformly dark frame read as a perfectly recognised
  bar at 0% — and the survival combo fired on a Pokémon at full health.
  """
  use ExUnit.Case, async: true

  alias Pokex.Vision

  defp frame(pixels) do
    w = length(hd(pixels))
    h = length(pixels)
    rgba = for row <- pixels, {r, g, b} <- row, into: <<>>, do: <<r, g, b, 255>>
    %Pokex.Vision.Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp fill(w, h, colour), do: List.duplicate(List.duplicate(colour, w), h)

  @dark {26, 26, 26}
  @green {80, 160, 70}
  @white {240, 240, 240}

  test "a uniformly dark strip is a COVERED WINDOW, never an empty bar" do
    covered = frame(fill(40, 10, @dark))

    refute Vision.hp_region_plausible?(covered)
    # and the reason is the brightness floor, not the known-pixel count:
    # everything dark still counts as "known track"
    assert Vision.hp_region_plausible?(covered, min_bright_pct: 0)
  end

  test "a real bar is plausible — full, and empty with its white numbers" do
    # mostly coloured fill with the white number text over it
    full = frame(fill(40, 8, @green) ++ fill(40, 2, @white))
    assert Vision.hp_region_plausible?(full)

    # 0 HP: no fill left, but the track edges and the "0/13520" text remain
    empty = frame(fill(30, 7, @dark) ++ fill(30, 3, @white))
    assert Vision.hp_region_plausible?(empty)
    assert Vision.hp_fill_pct(empty) == 0
  end

  # THE 58% ON A FULL BAR (2026-08-07): the numbers "13710/13710" are drawn ON
  # TOP of the bar, and every column hidden entirely behind a white digit was
  # counted as EMPTY. Measured on his real bar: 28 of 157 columns were pure
  # text, and a full bar came back as 58%.
  test "the white numbers over the bar neither fill nor empty it" do
    # a FULL bar with a block of white digits across the middle
    green_col = List.duplicate(@green, 10)
    text_col = List.duplicate(@white, 10)

    rows =
      for y <- 0..9 do
        for x <- 0..19 do
          if x in 8..11, do: Enum.at(text_col, y), else: Enum.at(green_col, y)
        end
      end

    full_with_text = frame(rows)

    # 16 green columns of 20; the 4 text columns leave the denominator instead
    # of counting as empty (which would have read 80%)
    assert Vision.hp_fill_pct(full_with_text) == 100
  end

  test "an emptying bar still reads lower — the text exclusion is not a blank cheque" do
    rows =
      for _y <- 0..9 do
        for x <- 0..19 do
          cond do
            x in 8..11 -> @white
            x < 8 -> @green
            true -> @dark
          end
        end
      end

    # 8 green, 8 dark, 4 text → judged on 16 columns, half of them filled
    assert Vision.hp_fill_pct(frame(rows)) == 50
  end

  # O TRILHO NÃO É VIDA (02/09): o trilho vazio da Pokebar do Poké Alliance é um
  # cinza-esverdeado (56,89,89) — saturação 33, azul EMPATADO com o verde. A
  # regra de cor o tomava por vida (saturação acima do piso, azul não acima do
  # canal máximo): toda coluna vazia contava como cheia e o pokémon leu 98-100%
  # a noite inteira (339 leituras) com a barra visivelmente em 23%.
  @teal_track {56, 89, 89}

  defp on_teal(fill_cols) do
    frame(for(_y <- 0..9, do: for(x <- 0..19, do: teal_pixel(x, fill_cols))))
  end

  defp teal_pixel(x, fill_cols), do: if(x < fill_cols, do: @green, else: @teal_track)

  test "o trilho cinza-esverdeado da Pokebar não é vida, e a barra continua plausível" do
    assert Vision.hp_fill_pct(on_teal(5)) == 25
    assert Vision.hp_fill_pct(on_teal(0)) == 0
    assert Vision.hp_fill_pct(on_teal(20)) == 100
    assert Vision.hp_region_plausible?(on_teal(5))
    assert Vision.hp_region_plausible?(on_teal(0), min_bright_pct: 0)
  end

  test "a Pokebar cheia de 02/09 lê cheia" do
    {:ok, frame} = Pokex.Vision.Frame.from_file("test/fixtures/hp/pokebar_cheia.raw")
    assert Vision.hp_fill_pct(frame) == 100
    assert Vision.hp_region_plausible?(frame)
  end

  test "the floor is measured, not guessed" do
    # his screen: real bar 68.5% bright, covered frame 0.1% — 10% sits between
    # them with room on both sides
    almost_dark = frame(fill(100, 10, @dark) ++ fill(100, 1, @white))
    refute Vision.hp_region_plausible?(almost_dark)

    lit = frame(fill(10, 10, @white) ++ fill(90, 10, @dark))
    assert Vision.hp_region_plausible?(lit)
  end

  # THE BLIND SPOT AT 65% (Poké Alliance, 2026-08-26): the pokebar's empty
  # track is (45,69,69) — brighter than the 60 the old client's track sat
  # under, so an emptying column counted as neither fill nor track. The known
  # share fell with the HP and crossed the floor at ~65%, blanking the reading
  # exactly where the potion (85%) and the rescue (60%) live.
  @light_track {45, 69, 69}

  test "an emptying bar stays readable when its track is lighter than the old client's" do
    rows =
      for _y <- 0..9 do
        for x <- 0..19, do: if(x < 6, do: @green, else: @light_track)
      end

    bar = frame(rows)

    # desde 02/09 o trilho é reconhecido pela COR (azul empatado com o verde),
    # não só pelo brilho: o teto de brilho deixou de ser o que o segura
    assert Vision.hp_region_plausible?(bar, max_track_brightness: 60)
    assert Vision.hp_region_plausible?(bar)
    assert Vision.hp_fill_pct(bar) == 30
  end
end
