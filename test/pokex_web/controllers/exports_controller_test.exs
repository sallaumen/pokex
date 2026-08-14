defmodule PokexWeb.ExportsControllerTest do
  use PokexWeb.ConnCase, async: false

  @tag :tmp_dir
  test "serves a JSON export with the right content-type", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    File.write!(Path.join(Pokex.Home.exports_dir(), "latest.json"), ~s({"ok":true}))

    conn = get(conn, ~p"/exports/latest.json")
    assert response(conn, 200) == ~s({"ok":true})
    assert get_resp_header(conn, "content-type") |> hd() =~ "application/json"
  end

  @tag :tmp_dir
  test "serves an event log as text", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    File.write!(Path.join(Pokex.Home.exports_dir(), "events.log"), "linha 1\nlinha 2\n")

    conn = get(conn, ~p"/exports/events.log")
    assert response(conn, 200) =~ "linha 1"
    assert get_resp_header(conn, "content-type") |> hd() =~ "text/plain"
  end

  @tag :tmp_dir
  test "rejects path traversal and 404s a missing file", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # basename strips the traversal — it looks for "settings.json" in exports/, not ../
    assert conn |> get(~p"/exports/nope.json") |> response(404)
    assert conn |> get("/exports/..%2f..%2fsettings.json") |> response(404)
  end
end
