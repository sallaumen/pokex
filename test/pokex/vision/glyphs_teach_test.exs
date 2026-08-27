defmodule Pokex.Vision.GlyphsTeachTest do
  @moduledoc """
  The shipped atlas can only contain the characters that happened to be on
  screen when captures were taken. Lucas hit exactly that: his HP read
  "?93?/9215" because the digits 8 and 2 had never been in a capture. Waiting
  for a developer to catch the right screenshot is not a fix — he must be able
  to close the gap himself.
  """
  use ExUnit.Case, async: false

  alias Pokex.Vision.Glyphs

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-glyphs-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    Application.put_env(:pokex, :home_dir, tmp)
    Glyphs.clear()

    on_exit(fn ->
      Pokex.TestHome.restore()
      File.rm_rf!(tmp)
      Glyphs.clear()
    end)

    :ok
  end

  test "a taught glyph is read from then on, and survives a cache clear" do
    bitmap = [[1, 0, 1], [0, 1, 0], [1, 0, 1]]
    signature = Glyphs.signature(bitmap)

    refute Map.has_key?(Glyphs.atlas(), signature)

    assert {:ok, total} = Glyphs.teach(signature, "X")
    assert total > 0
    assert Glyphs.atlas()[signature] == "X"

    Glyphs.clear()
    assert Glyphs.atlas()[signature] == "X"
  end

  test "refuses to redefine a glyph the atlas already reads" do
    {signature, _char} = Enum.at(Glyphs.atlas(), 0)

    assert Glyphs.teach(signature, "Z") == {:error, :already_known}
  end

  test "unknown_in reports the unreadable glyphs with their bitmaps" do
    # a shape the atlas has no candidate for at all
    noise =
      Pokex.FrameFixtures.of(9, 9, fn x, y ->
        if rem(x + y, 2) == 0, do: {255, 255, 255}, else: {0, 0, 0}
      end)

    unknown = Glyphs.unknown_in(noise, {0, 0, 9, 9})

    assert unknown != []
    assert Enum.all?(unknown, &(is_list(&1.bitmap) and is_binary(&1.signature)))
  end

  test "a fully readable region reports nothing to teach" do
    label = Enum.find(Pokex.ScreenFixtures.labels(), &(&1["expected"] == "1525"))
    %{"fixture" => f, "region" => [x, y, w, h]} = label

    assert Glyphs.unknown_in(Pokex.ScreenFixtures.frame!(f), {x, y, w, h}) == []
  end

  # O buraco de 27/08: o jogo dele em `1088, 1409, 5` e o painel em `1066,
  # 1409`. O atlas tinha 8 em duas alturas e nenhum na da faixa dele, e um
  # dígito que não está no atlas não volta como "não sei": volta como o mais
  # parecido que está. A regra da margem compara o atlas com o atlas — só quem
  # olha o alfabeto inteiro enxerga um dígito que nunca foi ensinado.
  describe "o alfabeto que falta" do
    test "acusa o dígito que falta na altura da fonte, e cala quando ele é ensinado" do
      assert %{"8" => faltam_em} =
               Glyphs.missing_digits()
               |> Enum.reduce(%{}, fn {altura, faltam}, acc ->
                 Enum.reduce(faltam, acc, &Map.update(&2, &1, [altura], fn a -> [altura | a] end))
               end)

      altura = Enum.min(faltam_em)
      oito = for linha <- 1..altura, do: for(coluna <- 1..5, do: rem(linha * coluna, 2))

      assert {:ok, _total} = Glyphs.teach(Glyphs.signature(oito), "8")

      refute "8" in Map.get(Glyphs.missing_digits(), altura, [])
    end

    test "uma altura sem dígito nenhum não está incompleta, está fora do assunto" do
      virgula = [[0, 1], [1, 0]]
      assert {:ok, _total} = Glyphs.teach(Glyphs.signature(virgula), ",")

      refute Map.has_key?(Glyphs.missing_digits(), 2)
    end
  end
end
