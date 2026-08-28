defmodule PokexWeb.CavebotFenceTest do
  @moduledoc """
  The page must say when its eyes are switched off.

  The simulator's fence points the feeds at a world that is not the game. On the
  Cavebot page the effect is total: NO broadcast arrives, so the LiveView
  renders once at mount and then sits there. On 2026-08-26 that showed a
  coordinate an hour old while the game had him on another floor entirely, and
  he walked a whole route believing it was recording.

  A page that can only learn it is blind from the thing that went blind cannot
  warn about it — hence a heartbeat, and these tests.
  """
  # async: false — flips a global switch and scopes :home_dir.
  use PokexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Pokex.Sim.Fence

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  defp raise_fence do
    :persistent_term.put({Fence, :arm_state}, rig: Pokex.Rig.Sim)
    on_exit(fn -> :persistent_term.erase({Fence, :arm_state}) end)
  end

  test "with the fence down the page says nothing about it", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/cavebot")

    refute html =~ "os olhos do bot estão apontados pro mundo falso"
  end

  test "with the fence up it says so, loudly and first", %{conn: conn} do
    raise_fence()

    {:ok, _view, html} = live(conn, ~p"/cavebot")

    assert html =~ "cavebot-sim-armed"
    assert html =~ "os olhos do bot estão apontados pro mundo falso"
    # …and the way out, because "it is broken" without "here is the switch" is
    # what cost him the walk.
    assert html =~ "Desarme no simulador"
  end

  test "the reading tile stops claiming it is waiting for a first read", %{conn: conn} do
    raise_fence()

    {:ok, _view, html} = live(conn, ~p"/cavebot")

    assert html =~ "os olhos estão desligados pelo simulador"
    refute html =~ "aguardando a primeira leitura"
  end

  test "recording REFUSES to arm while the fence is up", %{conn: conn} do
    raise_fence()

    {:ok, view, _html} = live(conn, ~p"/cavebot?modo=editar")
    html = view |> element(~s([phx-click="toggle_recording"])) |> render_click()

    # The refusal has to name the fix, and must NOT look like it started.
    assert html =~ "a gravação não receberia nenhuma posição"
    refute html =~ "volte pro jogo e ande"
  end

  test "the heartbeat notices the fence going up on a page already open", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/cavebot")
    refute html =~ "cavebot-sim-armed"

    raise_fence()
    send(view.pid, :health)

    assert render(view) =~ "cavebot-sim-armed"
  end

  test "…and notices it coming back down", %{conn: conn} do
    raise_fence()
    {:ok, view, _html} = live(conn, ~p"/cavebot")
    assert render(view) =~ "cavebot-sim-armed"

    :persistent_term.erase({Fence, :arm_state})
    send(view.pid, :health)

    refute render(view) =~ "cavebot-sim-armed"
  end

  describe "os dígitos que o atlas não tem" do
    # Um dígito ausente não vira "não sei ler": vira OUTRO dígito. A regra da
    # margem do casador compara o que está no atlas com o que está no atlas, e
    # não tem como perceber que o certo nunca esteve na disputa.
    #
    # Em 27/08 o jogo dele mostrava `1088, 1409, 5` e o painel `1066, 1409`.
    test "o aviso sai pela fonte que a faixa DELE usa, com o dígito e a altura", %{conn: conn} do
      publish_minimap(%{pos: {1066, 1409, 5}, coord_gap: %{px: 8, faltam: ["8"]}})

      {:ok, _view, html} = live(conn, ~p"/cavebot")

      assert html =~ "não tem"
      assert html =~ "o número pode vir ERRADO, não vazio"
      assert html =~ "8px de altura"
      assert html =~ "o 8 nunca foi ensinado"
    end

    test "sem buraco na fonte lida, a Central não diz nada", %{conn: conn} do
      publish_minimap(%{pos: {1088, 1409, 5}, coord_gap: nil})

      {:ok, _view, html} = live(conn, ~p"/cavebot")

      refute html =~ "o número pode vir ERRADO, não vazio"
    end

    defp publish_minimap(obs) do
      Pokex.Perception.WorldState.put(:minimap, obs, System.monotonic_time(:millisecond))
      on_exit(fn -> Pokex.Perception.WorldState.clear() end)
    end
  end
end
