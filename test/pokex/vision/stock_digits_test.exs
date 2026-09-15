defmodule Pokex.Vision.StockDigitsTest do
  use ExUnit.Case, async: true

  alias Pokex.Vision.{Frame, StockDigits}

  test "reads the F1 count from the recorded hotbar" do
    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    assert {:ok, 827} = frame |> Frame.crop({34, 28, 20, 8}) |> StockDigits.read()
  end

  test "reads other exact counts from the same recorded hotbar" do
    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")

    for {region, count} <- [
          {{72, 28, 18, 8}, 123},
          {{135, 28, 27, 8}, 2424},
          {{286, 28, 20, 8}, 479}
        ] do
      assert {:ok, ^count} = frame |> Frame.crop(region) |> StockDigits.read()
    end
  end

  test "reads six from the hotbar and zero and five from the recorded small font" do
    {:ok, hotbar} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    assert {:ok, 6} = hotbar |> Frame.crop({120, 28, 6, 8}) |> StockDigits.read()
    {:ok, frame} = Frame.from_file("test/fixtures/screen/minimapa_1512x982_1053_1358_6.raw")
    assert {:ok, 0} = frame |> Frame.crop({11, 4, 5, 8}) |> StockDigits.read()
    assert {:ok, 5} = frame |> Frame.crop({18, 4, 5, 8}) |> StockDigits.read()
  end

  test "rejects abbreviated counts and the whole hotbar" do
    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    assert :unread = frame |> Frame.crop({252, 28, 18, 8}) |> StockDigits.read()
    assert :unread = StockDigits.read(frame)
  end

  test "rejects a dot without silently dropping it" do
    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    count = Frame.crop(frame, {34, 28, 20, 8})

    rows =
      for y <- 0..7, into: <<>> do
        binary_part(count.rgba, y * 80, 80) <>
          <<0, 0, 0, 255>> <> if(y == 7, do: <<230, 230, 230, 255>>, else: <<0, 0, 0, 255>>)
      end

    assert :unread = StockDigits.read(%Frame{width: 22, height: 8, rgba: rows})
  end

  test "rejects a blank or damaged count" do
    assert :unread =
             StockDigits.read(%Frame{
               width: 20,
               height: 8,
               rgba: :binary.copy(<<0, 0, 0, 255>>, 160)
             })

    {:ok, frame} = Frame.from_file("test/fixtures/hud/hotbar_f1_827.png")
    assert :unread = frame |> Frame.crop({36, 30, 18, 6}) |> StockDigits.read()
  end
end
