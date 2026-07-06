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

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end
end
