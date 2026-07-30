defmodule Pokex.Bots.Catcher.BallTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Ball
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash_keys!([
      :ball_key,
      :ball_needs_click,
      :capture_aim_settle_ms,
      :capture_hold_ms
    ])

    :ok
  end

  test "posiciona, ESPERA a batida, e só então aciona o atalho" do
    # A ordem e a batida são o ponto: a versão antiga apertava a tecla no mesmo
    # instante do movimento. A vara — mesma forma — espera 30ms e funciona.
    assert [
             {:move, {500, 400}},
             {:wait, 30},
             {:press, "f1"},
             {:wait, _hold}
           ] = Ball.sequence({500, 400})
  end

  test "a tecla é CONFIGURÁVEL (era a única do bot cravada no código)" do
    Pokex.Settings.put(:ball_key, "f3")

    assert [_move, _wait, {:press, "f3"} | _] = Ball.sequence({1, 2})
    assert Ball.key() == "f3"
  end

  test "ball_needs_click cobre a dúvida do jogo: atalho direto x mira que espera clique" do
    Pokex.Settings.put(:ball_needs_click, true)

    acoes = Ball.sequence({300, 200})

    assert {:click, :left, {300, 200}} in acoes
    # o clique vem DEPOIS da tecla (a mira é armada primeiro)
    posicao_tecla = Enum.find_index(acoes, &match?({:press, _}, &1))
    posicao_clique = Enum.find_index(acoes, &match?({:click, _, _}, &1))
    assert posicao_clique > posicao_tecla
  end

  test "segura o cursor no alvo antes do Body devolvê-lo" do
    Pokex.Settings.put(:capture_hold_ms, 250)

    assert List.last(Ball.sequence({1, 1})) == {:wait, 250}
  end

  test "a batida é ajustável (máquina lenta, jogo lerdo)" do
    Pokex.Settings.put(:capture_aim_settle_ms, 120)

    assert [_move, {:wait, 120} | _] = Ball.sequence({1, 1})
  end
end
