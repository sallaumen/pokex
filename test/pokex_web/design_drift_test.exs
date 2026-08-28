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

  # A ESCALA DO TAILWIND É UM SEGUNDO SISTEMA. `text-sm` são 14px e `text-base`
  # são 16 — degraus que este sistema não tem, e que chegavam de graça em toda
  # página nova porque são o que a mão digita sem pensar. Eram 108 quando a
  # migração fechou (28/08), concentrados nas duas telas de pesca, que tinham
  # nascido no visual genérico do daisyUI.
  test "ninguém volta a usar a escala do Tailwind por cima da nossa" do
    offenders =
      for path <- templates(),
          source = File.read!(path),
          [full] <- Regex.scan(~r/\btext-(?:xs|sm|base|lg|xl|2xl|3xl)\b/, source),
          not comment_line?(source, full),
          do: "#{Path.relative_to(path, @web)}: #{full}"

    assert offenders == [],
           """
           Escala do Tailwind em vez da nossa. text-xs→pk-meta, text-sm→pk-body,
           text-base/lg/xl→pk-title:

           #{Enum.join(Enum.uniq(offenders), "\n")}
           """
  end

  # As duas telas de pesca vieram do gerador com `bg-base-200` e amigos: um
  # tema paralelo, que não responde aos tokens e não foi revisado por contraste.
  test "nenhuma superfície do daisyUI genérico sobrou" do
    offenders =
      for path <- templates(),
          source = File.read!(path),
          [full] <- Regex.scan(~r/\b(?:bg|text|border)-base-(?:100|200|300|content)\b/, source),
          do: "#{Path.relative_to(path, @web)}: #{full}"

    assert offenders == [],
           """
           Superfície genérica do daisyUI. Use os quatro tons do sistema
           (pk-bg / pk-sunken / pk-surface / pk-raised) e os três de texto:

           #{Enum.join(Enum.uniq(offenders), "\n")}
           """
  end

  # Um nome de classe citado dentro de comentário ou doc não é uso: este arquivo
  # mesmo cita `text-sm` para explicar a regra.
  defp comment_line?(source, needle) do
    source
    |> String.split("\n")
    |> Enum.filter(&String.contains?(&1, needle))
    |> Enum.all?(
      &(String.trim_leading(&1) =~ ~r/^(#|\*|<%!--|`)/ or &1 =~ ~r/`[^`]*#{Regex.escape(needle)}/)
    )
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
