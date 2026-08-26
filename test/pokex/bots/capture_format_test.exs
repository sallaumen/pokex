defmodule Pokex.Bots.CaptureFormatTest do
  @moduledoc """
  PNG is for pictures that TRAVEL. These never leave the machine.

  The helper already writes raw when the filename asks for it, and
  `Pokex.Vision.Frame.from_file/1` sniffs the header — so the whole difference
  between the two paths is four characters at the call site, and nothing warns
  when someone types the slower ones.

  MEASURED on this machine (2026-08-26), decoding one frame:

      200×200      40 kpx      51ms as PNG        1ms as raw
      400×700     280 kpx     529ms as PNG        0ms as raw
      1719×754   1296 kpx   11648ms as PNG        1ms as raw
      2400×1400  3360 kpx   22733ms as PNG        4ms as raw

  Five call sites were still on PNG when this test was written, one of them
  capturing the biggest region in the codebase. That is not a thing to find
  again by accident.
  """
  use ExUnit.Case, async: true

  # The pictures that must stay PNG, each for a stated reason. A browser cannot
  # open raw pixels, and a raw file has no PNG header to measure.
  @allowed_png [
    # The mini-game keeps evidence frames and refreshes a live preview by
    # COPYING the file it just read, so the image he looks at is byte-for-byte
    # the image the code judged.
    "mini_game_strip.png",
    "mini_game_preview.png",
    # Drawn back to him in an <img> on the calibration page: these ARE the crops
    # he is being asked to approve.
    "pokemon_teach.png",
    "corpse_teach.png",
    # Part of the diagnostics report he reads.
    "diag_glow.png",
    # The x-ray measures the display's SCALE from this file's PNG header
    # (`Frame.png_dimensions/1`) — raw pixels carry no header to measure. 100×100,
    # so the decode it avoids is not worth the measurement it would lose.
    "xray_probe.png"
  ]

  test "every screen capture asks for raw pixels" do
    offenders =
      Path.wildcard("lib/**/*.ex")
      |> Enum.flat_map(fn file ->
        file
        |> File.read!()
        |> String.split("\n")
        |> Enum.with_index(1)
        |> Enum.filter(fn {line, _n} ->
          String.contains?(line, "Capture.frame") or String.contains?(line, "Capture.grab")
        end)
        |> Enum.filter(fn {line, _n} -> String.contains?(line, ".png") end)
        |> Enum.reject(fn {line, _n} -> Enum.any?(@allowed_png, &String.contains?(line, &1)) end)
        |> Enum.map(fn {line, n} -> "#{file}:#{n}  #{String.trim(line)}" end)
      end)

    assert offenders == [],
           "these captures decode a PNG for pixels the helper already had in memory:\n" <>
             Enum.join(offenders, "\n")
  end
end
