defmodule Pokex.PngFixtures do
  @moduledoc "Minimal RGBA8 PNG encoder so tests never depend on binary fixture files."

  @doc """
  A solid-colour PNG of `w`x`h`, built without materialising a pixel list.

  `write!/2` wants a list of rows of `{r,g,b,a}` tuples, which is right for a
  hand-painted scene and absurd for a picture that is one colour: the display
  fixtures in `Pokex.ScreenshotTest` are 3024x1964 and 3440x1440, so building
  them that way meant ~11 million tuples for a file whose only interesting
  bytes are the four in its IHDR.
  """
  def solid!(path, w, h, {r, g, b, a}) do
    row = <<0>> <> :binary.copy(<<r, g, b, a>>, w)
    encode!(path, w, h, :binary.copy(row, h))
  end

  def write!(path, rows) do
    height = length(rows)
    width = length(hd(rows))

    raw =
      for row <- rows, into: <<>> do
        <<0>> <> for({r, g, b, a} <- row, into: <<>>, do: <<r, g, b, a>>)
      end

    encode!(path, width, height, raw)
  end

  defp encode!(path, width, height, raw) do
    ihdr = chunk("IHDR", <<width::32, height::32, 8, 6, 0, 0, 0>>)
    idat = chunk("IDAT", :zlib.compress(raw))

    File.write!(
      path,
      <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <> ihdr <> idat <> chunk("IEND", <<>>)
    )

    path
  end

  @doc """
  A 220x220 mini-game scene: floor everywhere, a dark track column at `bar_x`
  spanning rows 10..209, with optional `fish:` (olive) and `capsule:` (blue)
  row ranges drawn on the track. `bar_x: nil` = calm frame, no overlay.
  Shared by the worker/supervisor tests that drive the real detection+play
  pipeline through Rig.Fake captures.
  """
  def mini_game_scene!(dir, name, opts \\ []) do
    bar_x = Keyword.get(opts, :bar_x, 104..116)
    fish = Keyword.get(opts, :fish)
    capsule = Keyword.get(opts, :capsule)

    rows =
      for y <- 0..219 do
        for x <- 0..219, do: scene_pixel(x, y, bar_x, fish, capsule)
      end

    write!(Path.join(dir, name), rows)
  end

  @ground {150, 120, 86, 255}

  defp scene_pixel(x, y, bar_x, fish, capsule) do
    cond do
      bar_x == nil or x not in bar_x -> @ground
      fish != nil and y in fish -> {120, 100, 0, 255}
      capsule != nil and y in capsule -> {0, 160, 255, 255}
      y in 10..209 -> {26, 30, 48, 255}
      true -> @ground
    end
  end

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end
end
