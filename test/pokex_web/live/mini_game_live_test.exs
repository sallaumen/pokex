defmodule PokexWeb.MiniGameLiveTest do
  use PokexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Pokex.Bots.MiniGame.{Mode, Worker}
  alias Pokex.Rig.Fake
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash_keys!([:mini_game_mode])
    :ok
  end

  test "shows the frame that was analysed, without capturing anything itself", %{conn: conn} do
    {:ok, _fake} = Fake.start_link(%{})
    {:ok, view, _html} = live(conn, ~p"/mini-game")

    before = Fake.calls()

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Worker.diag_topic(),
      {:mini_game_tick,
       %{
         mode: :manual_assist,
         preview_file: "mini_game_preview.png",
         preview_version: 7,
         sample: sample()
       }}
    )

    html = render(view)

    # the preview points at the copy of the analysed PNG, versioned so the
    # browser reloads it — and nothing here took a NEW capture
    assert html =~ "/captures/mini_game_preview.png?v=7"
    assert Enum.all?(Fake.calls() -- before, &(elem(&1, 0) == :cursor_position))

    # the numbers on the page are the ones from that very sample
    assert html =~ "0.42"
    assert html =~ "0.61"
    assert html =~ "impossible_speed"
    assert html =~ "somente diagnóstico" or html =~ "assistência manual"
  end

  test "announces that a game is waiting for a human", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mini-game")

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      Worker.topic(),
      {:mini_game,
       %{
         state: :playing,
         in_game?: true,
         confidence: 0.9,
         counters: %{detections: 1, clears: 0, failures: 0},
         error: nil,
         mode: :manual_assist,
         mode_label: "assistência manual",
         awaiting_manual?: true,
         manual_text: "minigame aguardando resolução manual",
         transition: :entered
       }}
    )

    html = render(view)
    assert html =~ "minigame aguardando resolução manual"
    assert html =~ "em jogo"
  end

  test "switching the mode persists it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/mini-game")

    assert view |> element("form[phx-change=set_mode]") |> render_change(%{"mode" => "auto"}) =~
             "piloto automático"

    assert Mode.current() == :auto
  end

  test "the mode setting round-trips through the JSON settings file" do
    Mode.put(:diagnostic)
    assert Pokex.Settings.get(:mini_game_mode) == "diagnostic"
    assert Mode.current() == :diagnostic
    refute Mode.plays?(Mode.current())

    # an unknown value can never hand the keyboard to the pilot
    Pokex.Settings.put(:mini_game_mode, "lixo")
    assert Mode.current() == :manual_assist
  end

  defp sample do
    %{
      i: 3,
      at: 0,
      t_ms: 240,
      cap_ms: 31,
      gap_ms: 84,
      tick_ms: 35,
      read: :ok,
      frame_w: 80,
      frame_h: 220,
      top: 10,
      bottom: 209,
      fish_y: 0.42,
      fish_aim: 0.42,
      bar_y: 0.61,
      bar_source: :blue,
      fish_vy: 0.3,
      bar_vy: -0.2,
      accepted: false,
      verdict: :impossible_speed,
      error: 0.19,
      hold: false,
      flip: false,
      blue_px: 512,
      dark_px: 9001,
      mode: :manual_assist
    }
  end
end
