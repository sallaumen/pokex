defmodule Pokex.Bots.Catcher.Ball do
  @moduledoc """
  How a Pokéball is thrown — single owner of the sequence.

  Replaces the old Rig primitive (`Rig.Mac.capture_sequence/1`), which (measured
  2026-07-30) hardcoded "f1" (the only key that wasn't a setting), had no settle
  wait between move and press (the rod waits `wait_after_equip_ms` = 30ms and
  works), and dropped the `move` return — `Rig.Mac.gated/1` answers `:ok` when it
  SUPPRESSES, so the panel logged a throw no key ever delivered. As a Body
  sequence every step passes the input and mini-game gates, the wait is
  configurable, and the return is real.

  `ball_needs_click` covers what only the game can answer: whether the PokeTibia hotkey
  uses the ball directly (commit 2f21811 assumed so) or arms an aim that awaits a
  click. When on, the sequence clicks the target after the key.
  """

  alias Pokex.Screen.BarOffset
  alias Pokex.Settings

  @doc """
  Action sequence that throws a ball at `ponto` (SCREEN point): position → settle
  → hotkey → (optional) click → hold. The final hold exists because the Body
  restores the cursor as soon as the sequence ends (`restore_mouse_after_actions`):
  without it the mouse was yanked ~2ms after the key, before the game registered
  the target.

  A MIRA DESCE PRO CORPO, E É O ÚNICO LUGAR ONDE ISSO ACONTECE.

  Todo ponto que este bot tem de um bicho é o centro da BARRA de vida dele, que
  flutua acima da cabeça — 70 px acima e 25 px à direita no ultrawide dele,
  medido em 33 marcas das caixas-pretas de 13/09. Pra decidir tile isso some no
  arredondamento; pra apontar o mouse, não: num tile de 151 a bola era mirada
  na fronteira entre o tile do corpo e o de cima, e caía num ou noutro conforme
  o jogo arredondasse. "Mais erra do que acerta hoje em dia" (13/09), com ele
  jogando as bolas na mão pra compensar.

  A correção fica AQUI e não no rastro de propósito: o rastro compara barra com
  barra (nascer, seguir, confirmar captura) e é coerente em coordenada de
  barra. Quem precisa do corpo é o mouse, e só ele.
  """
  def sequence(point, ball_key \\ nil) do
    key = ball_key || key()
    alvo = BarOffset.body(point)

    [{:move_checked, alvo}, {:wait, Settings.get(:capture_aim_settle_ms)}, {:press_checked, key}] ++
      clique(alvo) ++
      [{:wait, Settings.get(:capture_hold_ms)}]
  end

  @doc "The DEFAULT throw key — `Pokex.Bots.Catcher.Balls` picks per corpse."
  def key, do: Settings.get(:ball_key)

  defp clique(point) do
    if Settings.get(:ball_needs_click), do: [{:click, :left, point}], else: []
  end
end
