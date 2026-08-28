defmodule PokexWeb.DesignDriftTest do
  @moduledoc """
  A CERCA DO DESIGN SYSTEM: as duas derivas que já custaram legibilidade.

  Ele lê estas telas de óculos, e disse por que a queixa é recorrente: "eu que
  uso óculos consigo entender nada direito" (28/08). Quando cada página escolhe
  o próprio tamanho e o próprio cinza, corrigir uma não corrige nenhuma outra —
  e a próxima página nasce torta de novo.

  Duas regras, as duas do DESIGN.md:

    * **A escala de três degraus** (`pk-meta` 11px, `pk-body` 13px, `pk-title`
      15px). Um `text-[9px]` não é um degrau: é cinza-sobre-cinza que ninguém
      revisa. A página /time tinha 33 deles.
    * **Cores por TOKEN.** `#69737b` sobre `#111519` dá 3.4:1 e reprova em AA
      — e ninguém descobre isso lendo um hex no meio de uma classe. Os tokens
      são revisados uma vez, no arquivo do tema.

  As exceções são declaradas por NOME aqui embaixo, com o motivo. Uma exceção
  que ninguém consegue justificar é a deriva voltando.
  """
  use ExUnit.Case, async: true

  @web "lib/pokex_web"

  # Cores que NÃO são texto nem superfície: identificadores categóricos, onde o
  # ponto é justamente ser uma cor que nenhum token tem.
  @allowed_hex [
    # as faixas de acento que separam os grupos do overlay de editores
    "#c9772f",
    "#8f6ad1",
    "#b8933d",
    "#c94f4f",
    "#1d9e75",
    # as séries do gráfico do mini-game (traços de SVG, não texto)
    "#22d3ee",
    "#94a3b8",
    "#f97316",
    "#facc15"
  ]

  defp templates do
    Path.wildcard("#{@web}/**/*.ex") ++ Path.wildcard("#{@web}/**/*.heex")
  end

  test "nenhum texto fora da escala de três degraus" do
    offenders =
      for path <- templates(),
          source = File.read!(path),
          [_full, size] <- Regex.scan(~r/text-\[(\d+)px\]/, source),
          do: "#{Path.relative_to(path, @web)}: text-[#{size}px]"

    assert offenders == [],
           """
           Texto em pixel cru fora da escala. Use pk-meta (11) / pk-body (13) /
           pk-title (15) — e se nenhum servir, o degrau novo entra no tema, não
           na classe:

           #{Enum.join(Enum.uniq(offenders), "\n")}
           """
  end

  test "nenhuma cor crua fora das exceções declaradas" do
    offenders =
      for path <- templates(),
          source = File.read!(path),
          [_full, hex] <- Regex.scan(~r/\[(#[0-9a-fA-F]{6})\]/, source),
          String.downcase(hex) not in @allowed_hex,
          do: "#{Path.relative_to(path, @web)}: #{hex}"

    assert offenders == [],
           """
           Cor em hex cru. Use os tokens pk-* (as cores do DESIGN.md, revisadas
           por contraste uma vez só) — ou declare a exceção com o motivo em
           @allowed_hex:

           #{Enum.join(Enum.uniq(offenders), "\n")}
           """
  end
end
