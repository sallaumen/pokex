defmodule PokexWeb.CapturesControllerTest do
  use PokexWeb.ConnCase, async: false

  @tag :tmp_dir
  test "serves an existing capture inline", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    File.write!(Path.join(Pokex.Home.captures_dir(), "diag.png"), "fakepng")

    conn = get(conn, ~p"/captures/diag.png")
    assert response(conn, 200) == "fakepng"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  @tag :tmp_dir
  test "404 for missing file and rejects traversal", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    assert response(get(conn, ~p"/captures/nope.png"), 404)
    assert response(get(conn, ~p"/captures/#{"..%2Fcalibration.json"}"), 404)
  end

  @tag :tmp_dir
  test "a real ../ traversal name cannot escape the captures dir", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # sentinel lives in home dir, one level ABOVE captures/ — must never be served
    File.mkdir_p!(Pokex.Home.captures_dir())
    File.write!(Path.join(Pokex.Home.dir(), "secret.png"), "TOPSECRET")

    conn = PokexWeb.CapturesController.show(conn, %{"name" => "../secret.png"})

    assert conn.status == 404
    refute conn.resp_body == "TOPSECRET"
  end
end
