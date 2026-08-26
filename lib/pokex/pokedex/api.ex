defmodule Pokex.Pokedex.Api do
  @moduledoc """
  The Poké Alliance wiki's HTTP surface, and the only module in the app that
  knows a URL.

  Two routes carry the whole Pokédex: `/api/pokemon` (the index, 910 species)
  and `/api/page/<path>` (one species, `{content, path}`). The origin lives in
  config (`:wiki_base`) — the one place the specific server is named.

  Errors come back as `{:error, term}`. Nothing raises: a sync that loses one
  page keeps the other 909.
  """

  @doc "The wiki origin, e.g. `https://wiki.pokealliance.com`."
  def base, do: Application.get_env(:pokex, :wiki_base)

  @doc "The decoded `/api/pokemon` payload — feed it to `Pokex.Pokedex.Index`."
  def index do
    with {:ok, body} <- get("/api/pokemon") do
      JSON.decode(body)
    end
  end

  @doc """
  The absolute URL for a wiki path, percent-encoded.

  Encoding is not cosmetic: one species is `gen/6/669_flabébé`, and the raw
  accented path is rejected before it ever leaves the machine — it was the
  single failure of the first full 910-species run.
  """
  def url(path) when is_binary(path), do: base() <> URI.encode(path)

  @doc "One species page's HTML — feed it to `Pokex.Pokedex.PageParser`."
  def page(path) when is_binary(path) do
    with {:ok, body} <- get("/api/page/" <> path),
         {:ok, %{"content" => content}} when is_binary(content) <- JSON.decode(body) do
      {:ok, content}
    else
      {:ok, _no_content} -> {:error, :no_content}
      error -> error
    end
  end

  @doc "A sprite or icon's bytes, by the path the API points at (`/pokemon/001.png`)."
  def asset(path) when is_binary(path), do: get(path)

  defp get(path) do
    case Req.get(url(path), retry: :transient, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, JSON.encode!(body)}
      other -> {:error, other}
    end
  end
end
