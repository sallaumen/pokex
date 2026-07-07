defmodule PokexWeb.ExportsController do
  @moduledoc """
  Serves diagnostics exports (JSON dumps, event logs) written under
  `~/.pokex/exports/`, so a UI link can download or view them. Mirrors
  CapturesController; `Path.basename/1` blocks traversal outside the dir.
  """
  use PokexWeb, :controller

  def show(conn, %{"name" => name}) do
    path = Path.join(Pokex.Home.exports_dir(), Path.basename(name))

    if File.regular?(path) do
      conn
      |> put_resp_content_type(content_type(path))
      |> send_file(200, path)
    else
      send_resp(conn, 404, "not found")
    end
  end

  defp content_type(path) do
    case Path.extname(path) do
      ".json" -> "application/json"
      _ -> "text/plain"
    end
  end
end
