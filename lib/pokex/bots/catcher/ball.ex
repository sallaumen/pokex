defmodule Pokex.Bots.Catcher.Ball do
  @moduledoc """
  Como uma Pokébola é arremessada — o dono único dessa sequência.

  Antes isto era um primitivo do Rig (`Rig.Mac.capture_sequence/1`) escrito
  assim:

      with :ok <- move(point) do
        press("f1")
      end

  Três problemas, todos medidos em 2026-07-30:

    * **`"f1"` cravado no código.** Era a ÚNICA tecla do bot que não era
      setting — `rod_key`, `logout_key`, `potion_key`, `tab_key` são todas
      configuráveis. E ela já mudou de mão uma vez sem o código acompanhar.
    * **Sem batida entre mover e apertar.** A vara — que tem exatamente a mesma
      forma (posicionar, depois acionar) — espera `wait_after_equip_ms` (30ms)
      e funciona. A bola apertava no mesmo instante do movimento.
    * **`with` sem `else`, retorno ignorado.** Um erro real do `move` sumia, e
      como `Rig.Mac.gated/1` devolve `:ok` quando SUPRIME, o painel escrevia
      "bola arremessada" sem tecla nenhuma ter chegado no jogo.

  Aqui a bola vira uma SEQUÊNCIA do Body: cada passo passa pelo portão e pelo
  gate do mini-game, o `{:wait, _}` é configurável, e o retorno é de verdade.

  `ball_needs_click` cobre a incerteza que só o jogo responde: se o atalho do
  PXG usa a bola direto (o que o commit 2f21811 assumiu ao remover o clique) ou
  se ele arma uma mira que espera um clique. Ligue e a sequência clica no alvo
  depois da tecla.
  """

  alias Pokex.Settings

  @doc """
  A sequência de ações que arremessa uma bola no `ponto` (ponto de TELA).

  Posiciona → espera a batida → aciona o atalho → (opcional) clica → segura o
  cursor. O `hold` final existe porque o Body devolve o cursor pro lugar do
  Lucas assim que a sequência acaba (`restore_mouse_after_actions`): sem ele, o
  mouse era puxado ~2ms depois da tecla, antes de o jogo registrar o alvo.
  """
  def sequence(ponto) do
    [{:move, ponto}, {:wait, Settings.get(:capture_aim_settle_ms)}, {:press, key()}] ++
      clique(ponto) ++
      [{:wait, Settings.get(:capture_hold_ms)}]
  end

  @doc "A tecla configurada pro arremesso."
  def key, do: Settings.get(:ball_key)

  defp clique(ponto) do
    if Settings.get(:ball_needs_click), do: [{:click, :left, ponto}], else: []
  end
end
