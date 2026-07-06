defmodule PokexWeb.CapturesControllerTest do
  use PokexWeb.ConnCase, async: false

  @tag :tmp_dir
  test "serves an existing capture inline", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    File.write!(Path.join(Pokex.Home.captures_dir(), "diag.png"), "fakepng")

    conn = get(conn, ~p"/captures/diag.png")
    assert response(conn, 200) == "fakepng"
    assert response_content_type(conn, :png) =~ "image/png"
  end

  @tag :tmp_dir
  test "404 for missing file and rejects traversal", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    assert response(get(conn, ~p"/captures/nope.png"), 404)
    assert response(get(conn, ~p"/captures/#{"..%2Fcalibration.json"}"), 404)
  end
end
