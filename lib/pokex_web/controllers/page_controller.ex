defmodule PokexWeb.PageController do
  use PokexWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
