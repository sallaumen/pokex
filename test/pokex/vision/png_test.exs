defmodule Pokex.Vision.PngTest do
  use ExUnit.Case, async: true

  import Bitwise

  alias Pokex.Vision.Png

  @moduledoc """
  The fast decoder has to answer EXACTLY what ExPng answers, filter by filter.

  `Pokex.PngFixtures` only ever writes filter 0, so a suite built on it would
  never touch the four reconstructions that carry the arithmetic — and those
  are the ones a real `screencapture` file is full of. Every case here encodes
  the same picture under one chosen filter and holds the result against ExPng,
  the decoder this one replaced.
  """

  @filters [0, 1, 2, 3, 4]

  defp picture(w, h, channels) do
    for y <- 0..(h - 1), do: for(x <- 0..(w - 1), do: pixel(x, y, w, channels))
  end

  # A gradient with a hard edge down the middle: smooth enough that paeth and
  # average predict well, broken enough that a wrong predictor shows up.
  defp pixel(x, y, w, channels) do
    base = {rem(x * 7 + y * 3, 256), rem(x * x + y, 256), rem(x + y * 11, 256)}
    {r, g, b} = if x > div(w, 2), do: base, else: {255 - elem(base, 0), 30, 200}

    if channels == 4, do: {r, g, b, rem(x + y, 2) * 255}, else: {r, g, b}
  end

  defp encode(rows, filter, channels) do
    w = length(hd(rows))
    h = length(rows)

    raw =
      rows
      |> Enum.map_reduce(:binary.copy(<<0>>, w * channels), fn row, prev ->
        line = for px <- row, into: <<>>, do: bytes(px)
        {<<filter>> <> apply_filter(filter, line, prev, channels), line}
      end)
      |> elem(0)
      |> IO.iodata_to_binary()

    color = if channels == 4, do: 6, else: 2

    <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
      chunk("IHDR", <<w::32, h::32, 8, color, 0, 0, 0>>) <>
      chunk("IDAT", :zlib.compress(raw)) <>
      chunk("IEND", <<>>)
  end

  defp bytes({r, g, b}), do: <<r, g, b>>
  defp bytes({r, g, b, a}), do: <<r, g, b, a>>

  defp chunk(type, data) do
    payload = type <> data
    <<byte_size(data)::32>> <> payload <> <<:erlang.crc32(payload)::32>>
  end

  defp apply_filter(0, line, _prev, _bpp), do: line

  defp apply_filter(f, line, prev, bpp) do
    pad = :binary.copy(<<0>>, bpp)

    for i <- 0..(byte_size(line) - 1)//1, into: <<>> do
      x = :binary.at(line, i)
      a = if i >= bpp, do: :binary.at(line, i - bpp), else: 0
      b = :binary.at(prev, i)
      c = if i >= bpp, do: :binary.at(prev, i - bpp), else: 0
      _ = pad

      predictor =
        case f do
          1 -> a
          2 -> b
          3 -> (a + b) >>> 1
          4 -> paeth(a, b, c)
        end

      <<x - predictor &&& 0xFF>>
    end
  end

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

  defp via_ex_png(bytes, tmp) do
    path = Path.join(tmp, "reference-#{System.unique_integer([:positive])}.png")
    File.write!(path, bytes)
    {:ok, %ExPng.Image{width: w, height: h, pixels: rows}} = ExPng.Image.from_file(path)
    {w, h, rows |> List.flatten() |> IO.iodata_to_binary()}
  end

  describe "reconstructing every PNG filter" do
    for filter <- @filters, channels <- [3, 4] do
      @tag :tmp_dir
      test "filter #{filter} with #{channels} channels decodes to the same pixels as ExPng", %{
        tmp_dir: tmp
      } do
        filter = unquote(filter)
        channels = unquote(channels)
        bytes = encode(picture(37, 23, channels), filter, channels)

        assert {:ok, 37, 23, rgba} = Png.decode(bytes)
        assert {37, 23, rgba} == via_ex_png(bytes, tmp)
      end
    end

    @tag :tmp_dir
    test "a capture whose rows each carry a DIFFERENT filter still reconstructs", %{tmp_dir: tmp} do
      rows = picture(29, 15, 3)
      w = 29

      raw =
        rows
        |> Enum.with_index()
        |> Enum.map_reduce(:binary.copy(<<0>>, w * 3), fn {row, y}, prev ->
          line = for px <- row, into: <<>>, do: bytes(px)
          f = rem(y, 5)
          {<<f>> <> apply_filter(f, line, prev, 3), line}
        end)
        |> elem(0)
        |> IO.iodata_to_binary()

      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<w::32, 15::32, 8, 2, 0, 0, 0>>) <>
          chunk("IDAT", :zlib.compress(raw)) <>
          chunk("IEND", <<>>)

      assert {:ok, ^w, 15, rgba} = Png.decode(png)
      assert {w, 15, rgba} == via_ex_png(png, tmp)
    end
  end

  describe "what belongs to ExPng" do
    test "an interlaced file is declined, not guessed at" do
      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<4::32, 4::32, 8, 2, 0, 0, 1>>) <>
          chunk("IDAT", :zlib.compress(<<0>>)) <>
          chunk("IEND", <<>>)

      assert Png.decode(png) == :unsupported
    end

    test "a palette file is declined, not guessed at" do
      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<4::32, 4::32, 8, 3, 0, 0, 0>>) <>
          chunk("IDAT", :zlib.compress(<<0>>)) <>
          chunk("IEND", <<>>)

      assert Png.decode(png) == :unsupported
    end

    test "16-bit channels are declined, not truncated in silence" do
      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<4::32, 4::32, 16, 6, 0, 0, 0>>) <>
          chunk("IDAT", :zlib.compress(<<0>>)) <>
          chunk("IEND", <<>>)

      assert Png.decode(png) == :unsupported
    end
  end

  describe "bytes that are not a frame" do
    test "anything without the signature is refused" do
      assert Png.decode("not a png at all") == {:error, :not_png}
    end

    test "a file cut short of its pixels is an error, never a half frame" do
      rows = picture(20, 10, 3)
      full = encode(rows, 0, 3)
      {head, _} = String.split_at(full, byte_size(full) - 200)

      assert match?({:error, _}, Png.decode(head))
    end

    test "an IDAT that does not hold every scanline is an error" do
      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<8::32, 8::32, 8, 2, 0, 0, 0>>) <>
          chunk("IDAT", :zlib.compress(<<0, 1, 2, 3>>)) <>
          chunk("IEND", <<>>)

      assert Png.decode(png) == {:error, :truncated}
    end

    test "an IDAT that is not zlib at all is an error" do
      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<8::32, 8::32, 8, 2, 0, 0, 0>>) <>
          chunk("IDAT", "lixo cru") <>
          chunk("IEND", <<>>)

      assert Png.decode(png) == {:error, :bad_zlib}
    end
  end

  describe "chunks around the pixels" do
    @tag :tmp_dir
    test "pixels split across several IDAT chunks are joined back", %{tmp_dir: tmp} do
      rows = picture(16, 9, 4)

      raw =
        rows
        |> Enum.map_reduce(nil, fn row, _ ->
          {<<0>> <> for(px <- row, into: <<>>, do: bytes(px)), nil}
        end)
        |> elem(0)
        |> IO.iodata_to_binary()

      compressed = :zlib.compress(raw)
      {head, tail} = String.split_at(compressed, div(byte_size(compressed), 2))

      png =
        <<137, ?P, ?N, ?G, ?\r, ?\n, 26, ?\n>> <>
          chunk("IHDR", <<16::32, 9::32, 8, 6, 0, 0, 0>>) <>
          chunk("IDAT", head) <>
          chunk("IDAT", tail) <>
          chunk("IEND", <<>>)

      assert {:ok, 16, 9, rgba} = Png.decode(png)
      assert {16, 9, rgba} == via_ex_png(png, tmp)
    end

    @tag :tmp_dir
    test "ancillary chunks before the pixels are skipped", %{tmp_dir: tmp} do
      rows = picture(11, 5, 3)
      full = encode(rows, 4, 3)
      <<sig::bytes-size(8), ihdr::bytes-size(25), rest::binary>> = full

      png = sig <> ihdr <> chunk("gAMA", <<45_455::32>>) <> chunk("tEXt", "a\0b") <> rest

      assert {:ok, 11, 5, rgba} = Png.decode(png)
      assert {11, 5, rgba} == via_ex_png(full, tmp)
    end
  end
end
