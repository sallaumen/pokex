defmodule Pokex.PngFixtures do
  @moduledoc "Minimal RGBA8 PNG encoder so tests never depend on binary fixture files."

  def write!(path, rows) do
    height = length(rows)
    width = length(hd(rows))

    raw =
      for row <- rows, into: <<>> do
        <<0>> <> for({r, g, b, a} <- row, into: <<>>, do: <<r, g, b, a>>)
      end

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
        for x <- 0..219 do
          cond do
            bar_x == nil or x not in bar_x -> {150, 120, 86, 255}
            fish != nil and y in fish -> {120, 100, 0, 255}
            capsule != nil and y in capsule -> {0, 160, 255, 255}
            y in 10..209 -> {26, 30, 48, 255}
            true -> {150, 120, 86, 255}
          end
        end
      end

    write!(Path.join(dir, name), rows)
  end

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end
end
