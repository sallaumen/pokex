defmodule Pokex.Bots.Corner do
  @moduledoc """
  Single source of truth for the panic (kill) corner: the top-left screen
  point a human drags the mouse to for an emergency stop. Shared by
  `Fishing.Logic`, `Combat.Logic` (per-tick, self-stop) and `Guardian`
  (polling, whole-bot stop) so the geometry is defined exactly once.
  """

  @doc "True when the cursor point sits in the top-left panic corner (mouse-to-corner = emergency stop)."
  @spec in_kill_corner?(term) :: boolean
  def in_kill_corner?({x, y}) when is_number(x) and is_number(y) and x <= 10 and y <= 10,
    do: true

  def in_kill_corner?(_), do: false

  @doc """
  True quando o cursor está no canto SUPERIOR DIREITO — o canto de COMANDO:
  segurar o mouse ali liga/desliga o último modo usado, de dentro do jogo.

  Existe porque o Iniciar do painel exige clicar no navegador — o que tira o
  foco do jogo e fecha o portão de entrada no exato instante em que a frota
  tenta os primeiros passos. Mover o mouse não muda foco: o comando nasce com
  o jogo focado e o portão aberto. Espelha o canto de pânico (que segue sendo
  o kill switch, no canto OPOSTO — os dois nunca se confundem).

  Precisa da largura da tela (o pânico não: {0,0} é universal) — quem chama
  passa a largura da calibração.
  """
  @spec in_command_corner?(term, term) :: boolean
  def in_command_corner?({x, y}, screen_w)
      when is_number(x) and is_number(y) and is_number(screen_w) and x >= screen_w - 10 and
             y <= 10,
      do: true

  def in_command_corner?(_point, _screen_w), do: false
end
