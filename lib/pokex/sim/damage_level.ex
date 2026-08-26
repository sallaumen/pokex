defmodule Pokex.Sim.DamageLevel do
  @moduledoc """
  Os quatro níveis de dano que ele clica, em vez de digitar mínimo e máximo.

  "Faz ser sempre 4 níveis de dano pra eu selecionar clicando, de forma mais
  fácil, onde skills que eu marcar baixo dano dão 10~20 de HP, skills de médio
  dano dão 30~50 e skills de muito dano dão de 60~80, assim vou regulando as
  skills e a vida dos inimigos" (26/08).

  ## Por que a unidade importa mais que a comodidade

  As faixas são HP ABSOLUTO, e é isso que faz o experimento dele existir. Sem
  elas, o dano de uma tecla é uma PORCENTAGEM da vida do monstro
  (`aoe_damage_pct: 34`), então subir `mob_hp` de 100 pra 500 não deixa bicho
  nenhum mais duro — a tecla passa a tirar 170 em vez de 34 e tudo morre no
  mesmo número de tiros. Com HP absoluto, 500 de vida contra 60~80 por tiro é o
  monstro tanque que ele quer testar: "pra testar como lidamos com monstros com
  mais ou menos vida — se sabemos usar corretamente a skill de controle antes de
  usar ressurect para resetar os cooldowns, e seguir esse loop até matar".

  ## `:padrao` não é um nível, é a ausência de um

  Ele é o comportamento de sempre: nenhuma faixa gravada, e o mundo cai no chute
  em porcentagem. Fica na lista porque é preciso poder VOLTAR, e porque é o que
  as teclas que ele nunca tocou já estão fazendo — o que só é inofensivo
  enquanto ninguém sobe a vida do monstro. `mixed?/2` é quem sabe disso.
  """

  @levels [
    {:padrao, nil, "padrão", "o chute em % da vida — muda junto com a vida do bicho"},
    {:baixo, {10, 20}, "baixo", "10 a 20 de HP"},
    {:medio, {30, 50}, "médio", "30 a 50 de HP"},
    {:muito, {60, 80}, "muito", "60 a 80 de HP"}
  ]

  @type level :: :padrao | :baixo | :medio | :muito

  @doc "Os quatro, na ordem em que o editor os oferece."
  @spec all() :: [level]
  def all, do: Enum.map(@levels, &elem(&1, 0))

  @doc "A faixa em HP deste nível — `nil` no `:padrao`, que não grava faixa nenhuma."
  @spec band(level) :: {pos_integer, pos_integer} | nil
  def band(level), do: @levels |> entry(level) |> elem(1)

  @doc "O nome curto, do jeito que ele o disse."
  @spec label(level) :: String.t()
  def label(level), do: @levels |> entry(level) |> elem(2)

  @doc "O que este nível faz, em uma frase — a coluna que evita ter que adivinhar."
  @spec note(level) :: String.t()
  def note(level), do: @levels |> entry(level) |> elem(3)

  @doc """
  Qual nível uma faixa gravada representa — `:padrao` quando não há faixa.

  Uma faixa que ele digitou à mão antes destes níveis existirem (ou que veio de
  um `sim_setup.json` antigo) não é nenhum dos quatro. Ela responde
  `{:custom, {lo, hi}}`, e a tela mostra o número em vez de fingir que é um
  clique — apagar em silêncio o que ele mediu seria pior que oferecer um botão a
  menos.
  """
  @spec of({integer, integer} | nil) :: level | {:custom, {integer, integer}}
  def of(nil), do: :padrao

  def of({lo, hi}) do
    case Enum.find(@levels, fn {_l, band, _n, _d} -> band == {lo, hi} end) do
      {level, _band, _n, _d} -> level
      nil -> {:custom, {lo, hi}}
    end
  end

  @doc """
  Este conjunto de teclas mistura as duas unidades?

  A armadilha que estragaria o experimento dele em silêncio: com `mob_hp` em 500
  e SÓ ALGUMAS teclas em nível, as outras continuam tirando 34% — 170 de HP, mais
  do que o dobro do "muito dano". A tela avisa em vez de deixá-lo medir uma
  barra que não é a que ele configurou.
  """
  @spec mixed?(map, [String.t()]) :: boolean
  def mixed?(skill_damage, keys) do
    {tuned, untuned} = Enum.split_with(keys, &Map.has_key?(skill_damage, &1))

    tuned != [] and untuned != []
  end

  defp entry(levels, level) do
    Enum.find(levels, {level, nil, to_string(level), ""}, &(elem(&1, 0) == level))
  end
end
