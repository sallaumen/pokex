defmodule Pokex.Bots.Cavebot.Photos do
  @moduledoc """
  What the START and the END of a route LOOK like.

  Coordinates say where a route begins; they do not say what is there. Coming
  back to a route recorded last week, "(2396, 30621)" is a riddle — a picture
  of the spot is the answer, and it costs one screenshot each: taken
  automatically when recording is armed and when it stops.

  The file IS the record: no schema, no migration, nothing to keep in sync with
  the route store. A route with a photo has the file; a renamed or deleted
  route loses it (the photos are keyed by the route's name), which is exactly
  the behaviour a picture of a place should have.

  They live in the captures dir because that is the one directory already
  served to the page (`/captures/:name`).
  """

  alias Pokex.{Home, Screenshot}

  @kinds [:start, :finish]

  @doc "The kinds a route can have a photo of."
  def kinds, do: @kinds

  @doc """
  Takes the photo for `route_name` — the whole screen, the game brought
  forward by the caller's own front block if it wants one. Failure is never
  fatal: a route without a picture is a route, and the recording that triggered
  it must not die for a missing screenshot.
  """
  @spec take(String.t(), :start | :finish) :: {:ok, String.t()} | :error
  def take(route_name, kind) when kind in @kinds do
    with {:ok, shot} <- Screenshot.take(temp_name(kind)),
         :ok <- File.cp(shot.path, path(route_name, kind)) do
      {:ok, file(route_name, kind)}
    else
      _no_photo -> :error
    end
  end

  @doc "The URL the page renders, or nil when this route has no such photo."
  @spec url(String.t(), :start | :finish) :: String.t() | nil
  def url(route_name, kind) do
    path = path(route_name, kind)

    if File.regular?(path) do
      # the mtime busts the browser cache: re-recording a route must not show
      # last week's picture of somewhere else
      "/captures/#{file(route_name, kind)}?v=#{mtime(path)}"
    end
  end

  @doc "Forgets both photos of a route (deleting or clearing it)."
  @spec forget(String.t()) :: :ok
  def forget(route_name) do
    Enum.each(@kinds, &File.rm(path(route_name, &1)))
  end

  @doc "Absolute path of one photo."
  @spec path(String.t(), :start | :finish) :: String.t()
  def path(route_name, kind), do: Path.join(Home.captures_dir(), file(route_name, kind))

  defp file(route_name, kind), do: "route-#{slug(route_name)}-#{kind}.png"

  defp temp_name(kind), do: "route_photo_#{kind}.png"

  # A route name is free text (accents, spaces, slashes): the file name it
  # produces must never escape the captures dir nor collide by accident.
  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "rota"
      slug -> String.slice(slug, 0, 48)
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} -> mtime
      _unknown -> 0
    end
  end
end
