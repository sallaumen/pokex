defmodule PokexWeb.ExportsController do
  @moduledoc """
  Serves diagnostics exports (JSON dumps, event logs, mini-game evidence
  bundles) written under `~/.pokex/exports/`, so a UI link can download or view
  them. Mirrors CapturesController.

  Bundles are DIRECTORIES (`mini_game-<stamp>/summary.json`), so the route takes
  a wildcard path — and `Path.safe_relative/1` is what keeps that path inside
  the exports dir: it rejects absolute paths and any `..` that would escape.
  """
  use PokexWeb, :controller

  def show(conn, %{"path" => segments}) do
    case Path.safe_relative(Path.join(segments)) do
      # A traversal attempt is answered exactly like a missing file: it IS one,
      # as far as anything under the exports dir is concerned.
      {:ok, relative} -> send_export(conn, Path.join(Pokex.Home.exports_dir(), relative))
      :error -> send_resp(conn, 404, "not found")
    end
  end

  defp send_export(conn, path) do
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
      ".png" -> "image/png"
      _ -> "text/plain"
    end
  end
end
