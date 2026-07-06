defmodule PokexWeb.PageHTML do
  @moduledoc """
  This module contains pages rendered by PageController.

  See the `page_html` directory for all templates available.
  """
  use PokexWeb, :html

  embed_templates "page_html/*"
end
