defmodule Pokex.Vision.Png do
  @moduledoc """
  PNG → flat RGBA8, for the shapes a screen capture actually has.

  `ExPng` is correct and covers the whole format, but it decodes into
  `[[<<r,g,b,a>>, ...], ...]` — one 4-byte binary per PIXEL inside one list per
  row — and its de-filtering walks each line with `Enum.reduce` over per-pixel
  binaries, rebuilding a byte at a time with `<>`. On a 3440x1440 capture that
  is ~5 million tiny binaries and ~20 million list steps, and the `average`
  filter indexes the previous line with `Enum.at/2` inside that loop, which is
  quadratic per row. MEASURED 2026-08-26 on `ultrawide_3440x1440_outro_mapa`:
  39s through ExPng.

  Every capture this project reads is 8-bit, non-interlaced, truecolor with or
  without alpha — the only two shapes macOS `screencapture` and
  ScreenCaptureKit ever write. Those get the loop below: `:zlib` for the
  compressed stream, then one pass per scanline that reconstructs straight into
  a binary accumulator, specialised per bytes-per-pixel so the filter math is
  arithmetic on integers instead of allocation. Anything else — palette,
  greyscale, 16-bit, interlaced — is handed to ExPng untouched, so no file that
  used to decode stops decoding.
  """

  import Bitwise

  @signature <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>>

  @doc """
  Decodes PNG bytes into `{:ok, width, height, rgba}` with RGBA8 row-major pixels.

  Answers `:unsupported` for the variants that belong to ExPng, and
  `{:error, reason}` for bytes that are not a readable PNG at all.
  """
  def decode(@signature <> chunks) do
    with {:ok, header, idat} <- read_chunks(chunks) do
      case header do
        %{depth: 8, interlace: 0, color: color} when color in [2, 6] ->
          inflate(idat, header)

        _other ->
          :unsupported
      end
    end
  end

  def decode(_not_a_png), do: {:error, :not_png}

  defp read_chunks(chunks), do: read_chunks(chunks, nil, [])

  defp read_chunks(<<len::32, "IHDR", body::bytes-size(len), _crc::32, rest::binary>>, nil, []) do
    case body do
      <<width::32, height::32, depth, color, 0, 0, interlace>>
      when width > 0 and height > 0 ->
        header = %{width: width, height: height, depth: depth, color: color, interlace: interlace}
        read_chunks(rest, header, [])

      _unreadable ->
        {:error, :bad_header}
    end
  end

  defp read_chunks(
         <<len::32, "IDAT", body::bytes-size(len), _crc::32, rest::binary>>,
         header,
         acc
       )
       when header != nil do
    read_chunks(rest, header, [body | acc])
  end

  defp read_chunks(<<_len::32, "IEND", _rest::binary>>, header, acc) when acc != [] do
    {:ok, header, acc |> Enum.reverse() |> IO.iodata_to_binary()}
  end

  defp read_chunks(
         <<len::32, _type::bytes-size(4), _body::bytes-size(len), _crc::32, rest::binary>>,
         header,
         acc
       ) do
    read_chunks(rest, header, acc)
  end

  defp read_chunks(_truncated, _header, _acc), do: {:error, :truncated}

  defp inflate(idat, %{width: w, height: h, color: color}) do
    bpp = if color == 6, do: 4, else: 3

    try do
      :zlib.uncompress(idat)
    rescue
      _ -> {:error, :bad_zlib}
    else
      raw when byte_size(raw) == h * (1 + w * bpp) ->
        {:ok, w, h, unfilter(raw, w * bpp, bpp)}

      _short ->
        {:error, :truncated}
    end
  end

  defp unfilter(raw, row_bytes, bpp) do
    rows(row_bytes, bpp, raw, :binary.copy(<<0>>, row_bytes), [])
  end

  defp rows(_row_bytes, bpp, <<>>, _prev, acc) do
    pixels = acc |> Enum.reverse() |> IO.iodata_to_binary()
    if bpp == 4, do: pixels, else: widen(pixels, <<>>)
  end

  defp rows(row_bytes, bpp, raw, prev, acc) do
    <<f, line::bytes-size(row_bytes), rest::binary>> = raw
    row = reconstruct(f, line, prev, bpp)
    rows(row_bytes, bpp, rest, row, [row | acc])
  end

  defp reconstruct(0, line, _prev, _bpp), do: line
  defp reconstruct(2, line, prev, _bpp), do: up(line, prev, <<>>)
  defp reconstruct(1, line, _prev, 3), do: sub3(line, 0, 0, 0, <<>>)
  defp reconstruct(1, line, _prev, 4), do: sub4(line, 0, 0, 0, 0, <<>>)
  defp reconstruct(3, line, prev, 3), do: avg3(line, prev, 0, 0, 0, <<>>)
  defp reconstruct(3, line, prev, 4), do: avg4(line, prev, 0, 0, 0, 0, <<>>)
  defp reconstruct(4, line, prev, 3), do: paeth3(line, prev, 0, 0, 0, 0, 0, 0, <<>>)
  defp reconstruct(4, line, prev, 4), do: paeth4(line, prev, 0, 0, 0, 0, 0, 0, 0, 0, <<>>)

  defp up(
         <<x1, x2, x3, x4, x5, x6, x7, x8, rest::binary>>,
         <<b1, b2, b3, b4, b5, b6, b7, b8, p::binary>>,
         acc
       ) do
    up(
      rest,
      p,
      <<acc::binary, x1 + b1, x2 + b2, x3 + b3, x4 + b4, x5 + b5, x6 + b6, x7 + b7, x8 + b8>>
    )
  end

  defp up(<<x, rest::binary>>, <<b, p::binary>>, acc), do: up(rest, p, <<acc::binary, x + b>>)
  defp up(<<>>, _prev, acc), do: acc

  defp sub3(<<x1, x2, x3, rest::binary>>, a1, a2, a3, acc) do
    r1 = x1 + a1 &&& 0xFF
    r2 = x2 + a2 &&& 0xFF
    r3 = x3 + a3 &&& 0xFF
    sub3(rest, r1, r2, r3, <<acc::binary, r1, r2, r3>>)
  end

  defp sub3(<<>>, _a1, _a2, _a3, acc), do: acc

  defp sub4(<<x1, x2, x3, x4, rest::binary>>, a1, a2, a3, a4, acc) do
    r1 = x1 + a1 &&& 0xFF
    r2 = x2 + a2 &&& 0xFF
    r3 = x3 + a3 &&& 0xFF
    r4 = x4 + a4 &&& 0xFF
    sub4(rest, r1, r2, r3, r4, <<acc::binary, r1, r2, r3, r4>>)
  end

  defp sub4(<<>>, _a1, _a2, _a3, _a4, acc), do: acc

  defp avg3(<<x1, x2, x3, rest::binary>>, <<b1, b2, b3, prev::binary>>, a1, a2, a3, acc) do
    r1 = x1 + ((a1 + b1) >>> 1) &&& 0xFF
    r2 = x2 + ((a2 + b2) >>> 1) &&& 0xFF
    r3 = x3 + ((a3 + b3) >>> 1) &&& 0xFF
    avg3(rest, prev, r1, r2, r3, <<acc::binary, r1, r2, r3>>)
  end

  defp avg3(<<>>, _prev, _a1, _a2, _a3, acc), do: acc

  defp avg4(
         <<x1, x2, x3, x4, rest::binary>>,
         <<b1, b2, b3, b4, prev::binary>>,
         a1,
         a2,
         a3,
         a4,
         acc
       ) do
    r1 = x1 + ((a1 + b1) >>> 1) &&& 0xFF
    r2 = x2 + ((a2 + b2) >>> 1) &&& 0xFF
    r3 = x3 + ((a3 + b3) >>> 1) &&& 0xFF
    r4 = x4 + ((a4 + b4) >>> 1) &&& 0xFF
    avg4(rest, prev, r1, r2, r3, r4, <<acc::binary, r1, r2, r3, r4>>)
  end

  defp avg4(<<>>, _prev, _a1, _a2, _a3, _a4, acc), do: acc

  defp paeth3(
         <<x1, x2, x3, rest::binary>>,
         <<b1, b2, b3, prev::binary>>,
         a1,
         a2,
         a3,
         c1,
         c2,
         c3,
         acc
       ) do
    r1 = x1 + paeth(a1, b1, c1) &&& 0xFF
    r2 = x2 + paeth(a2, b2, c2) &&& 0xFF
    r3 = x3 + paeth(a3, b3, c3) &&& 0xFF
    paeth3(rest, prev, r1, r2, r3, b1, b2, b3, <<acc::binary, r1, r2, r3>>)
  end

  defp paeth3(<<>>, _prev, _a1, _a2, _a3, _c1, _c2, _c3, acc), do: acc

  defp paeth4(
         <<x1, x2, x3, x4, rest::binary>>,
         <<b1, b2, b3, b4, prev::binary>>,
         a1,
         a2,
         a3,
         a4,
         c1,
         c2,
         c3,
         c4,
         acc
       ) do
    r1 = x1 + paeth(a1, b1, c1) &&& 0xFF
    r2 = x2 + paeth(a2, b2, c2) &&& 0xFF
    r3 = x3 + paeth(a3, b3, c3) &&& 0xFF
    r4 = x4 + paeth(a4, b4, c4) &&& 0xFF
    paeth4(rest, prev, r1, r2, r3, r4, b1, b2, b3, b4, <<acc::binary, r1, r2, r3, r4>>)
  end

  defp paeth4(<<>>, _prev, _a1, _a2, _a3, _a4, _c1, _c2, _c3, _c4, acc), do: acc

  defp paeth(a, b, c) do
    p = a + b - c
    pa = abs(p - a)
    pb = abs(p - b)
    pc = abs(p - c)

    cond do
      pa <= pb and pa <= pc -> a
      pb <= pc -> b
      true -> c
    end
  end

  defp widen(<<r1, g1, b1, r2, g2, b2, r3, g3, b3, r4, g4, b4, rest::binary>>, acc) do
    widen(
      rest,
      <<acc::binary, r1, g1, b1, 255, r2, g2, b2, 255, r3, g3, b3, 255, r4, g4, b4, 255>>
    )
  end

  defp widen(<<r, g, b, rest::binary>>, acc), do: widen(rest, <<acc::binary, r, g, b, 255>>)
  defp widen(<<>>, acc), do: acc
end
