defmodule PokexWeb.CapturesController do
  use PokexWeb, :controller

  def show(conn, %{"name" => name}) do
    path = Path.join(Pokex.Home.captures_dir(), Path.basename(name))

    if File.regular?(path) do
      conn
      |> put_resp_content_type("image/png")
      |> send_file(200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end
end
