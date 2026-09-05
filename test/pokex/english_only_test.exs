defmodule Pokex.EnglishOnlyTest do
  @moduledoc """
  AGENTS.md: identifiers and test names are English; only what reaches the
  user (feed lines, alarms, UI copy) stays pt-BR. This is a RATCHET, not a
  cleanup: every Portuguese identifier or test name that exists today is
  listed in the baseline and tolerated; a new one fails the suite.

  Shrink the baseline as files get renamed — never grow it.
  """
  use ExUnit.Case, async: true

  @baseline_path "test/support/english_baseline.txt"

  @stems ~w(tecla janela corrente pilha mundo bicho chefe cerca sono quantos prontas mao
    cerebro pedido andando parado saindo segundos restante tela lutando escudo dano falta faltam
    tomadas sobra piores mediana sementes mortos quedas carimbo emenda pegada folga agora ecos
    barra controle livre passos arrastando bolo cheio andados fase motivo trava origem vistos
    especial cor regra padrao ligada barata cega voltou gasta novo meio economico aperto rajada
    corrida noite juiz veredito promessa piso teto respiro bolso estoque reserva recuo chao limpo
    espera dormir vida vazia limpa pronto pronta nada ninguem cada quando onde ainda antes depois
    vez vezes cima baixo lado metade inteira medida medido leitura foto luta mata cacada rota
    trecho esquina canto passo jogo personagem bola bolas segura carimba apaga esquece guarda
    sobrou resto trem anel estrada ganancia pinga fecha pequena grande forte fraco rapido lento
    frio gelado esfriando sem com desperdicou tentando)

  @pt_text ~r/[çãõáéíóúâêô]|\b(não|pra|que|uma|dele|dela|isso|aqui|então|também|porque|ainda|quando|onde|mesmo|nada|tudo|cada|sem|com|até|está|são|foi|era|vai)\b/iu

  test "no new Portuguese identifier or test name outside the baseline" do
    found = MapSet.new(identifiers() ++ test_names())
    baseline = baseline()
    new = MapSet.difference(found, baseline) |> Enum.sort()

    assert new == [],
           "Portuguese in code (AGENTS.md says English): \n  " <>
             Enum.join(new, "\n  ") <>
             "\n\nRename it, or — for a pre-existing one you did not touch — nothing: it is already listed."
  end

  test "the baseline only shrinks" do
    found = MapSet.new(identifiers() ++ test_names())
    gone = MapSet.difference(baseline(), found) |> Enum.sort()

    assert gone == [],
           "these were renamed — remove them from #{@baseline_path}:\n  " <>
             Enum.join(gone, "\n  ")
  end

  defp identifiers do
    for f <- Path.wildcard("lib/**/*.ex"),
        name <-
          Regex.scan(~r/\bdefp?\s+([a-z_][a-zA-Z0-9_?!]*)/, File.read!(f))
          |> Enum.map(&Enum.at(&1, 1)),
        portuguese_name?(name),
        do: "#{f}: #{name}"
  end

  defp test_names do
    for f <- Path.wildcard("test/**/*_test.exs"),
        name <- Regex.scan(~r/^\s*test\s+"([^"]+)"/m, File.read!(f)) |> Enum.map(&Enum.at(&1, 1)),
        Regex.match?(@pt_text, name),
        do: "#{f}: test \"#{name}\""
  end

  defp portuguese_name?(name) do
    name
    |> String.trim_trailing("?")
    |> String.trim_trailing("!")
    |> String.split("_")
    |> Enum.any?(&(&1 in @stems))
  end

  defp baseline do
    case File.read(@baseline_path) do
      {:ok, body} -> body |> String.split("\n", trim: true) |> MapSet.new()
      _ -> MapSet.new()
    end
  end
end
