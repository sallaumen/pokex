defmodule Pokex.Bots.Combat.Combo do
  @moduledoc """
  A CORRENTE DO JOGO RODANDO — quanto ainda falta pra ela terminar.

  No modo Auto Combo o cliente encadeia as skills ofensivas atrás de um toque
  só, e enquanto essa corrente sai o bot não pode encostar em mais nada: uma
  segunda prensa corta a corrente, e um revive no meio dela recolhe o pokémon
  com metade das skills por sair.

  ## Por que um carimbo, e não um `sleep`

  A decisão chega a cada 200ms e a rajada roda num processo próprio que morre
  em cerca de um segundo — o `burst_pid` (uma rajada em voo) protege por esse
  segundo e não pelos quatro. Uma janela que vive dentro do processo da prensa
  é uma janela que não existe pro tique seguinte.

  Então a janela é um CARIMBO com dono, exatamente como a janela cega do revive
  (`ReviveLedger.landed_within?/1`): quem quer apertar pergunta, e quem responde
  é o relógio das teclas. O eco do `SkillClock` sobrevive ao reset do próprio
  revive, e o `HandWatch` carimba o R que ELE apertou com a própria mão — o que
  é a resposta certa: a corrente está rodando do mesmo jeito.

  ## `nil` é "esta caçada não tem combo"

  Fora do Auto Combo não há corrente pra esperar, e a resposta é `nil` e não
  zero: zero seria "acabou agora", que é uma afirmação sobre uma corrente que
  nunca existiu. Todo consumidor trata `nil` como "não se aplica".
  """

  alias Pokex.Bots.HuntMode
  alias Pokex.Bots.SkillClock
  alias Pokex.Settings

  @doc "A tecla que dispara a corrente."
  @spec key() :: String.t()
  def key, do: Settings.get(:auto_combo_key) |> to_string() |> String.trim()

  @doc "Quanto tempo a corrente ocupa as mãos."
  @spec window_ms() :: non_neg_integer
  def window_ms, do: Settings.get(:auto_combo_window_ms)

  @doc """
  Quanto falta da corrente em `mode`, em ms — `nil` quando o modo não tem
  corrente, e `0` quando ela já acabou (ou nunca saiu).
  """
  @spec left_ms(HuntMode.t() | nil, integer) :: non_neg_integer | nil
  def left_ms(mode, now \\ now())

  def left_ms(:auto_combo, now) do
    janela = window_ms()
    tecla = key()

    if tecla == "" or not is_integer(janela) or janela <= 0,
      do: 0,
      else: restante(SkillClock.pressed_at(tecla), janela, now)
  end

  def left_ms(_no_combo, _now), do: nil

  @doc """
  A corrente ainda está saindo? Só o Auto Combo pode responder que sim.

  É o veredito que a mão consulta antes de cada prensa — no molde do
  `blackout?/1` do combate, que faz a mesma pergunta sobre o F4.
  """
  @spec running?(HuntMode.t() | nil, integer) :: boolean
  def running?(mode, now \\ now()) do
    case left_ms(mode, now) do
      left when is_integer(left) -> left > 0
      _sem_combo -> false
    end
  end

  defp restante(at, janela, now) when is_integer(at), do: max(at + janela - now, 0)
  defp restante(_nunca_saiu, _janela, _now), do: 0

  defp now, do: System.monotonic_time(:millisecond)
end
