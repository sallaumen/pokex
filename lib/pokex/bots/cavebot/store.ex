defmodule Pokex.Bots.Cavebot.Store do
  @moduledoc """
  Where cavebot routes live: `~/.pokex/routes.json`.

  Mirrors `Pokex.Combos.Store` (a route is a user-authored program, not a
  Settings scalar), with one difference: the seed is EMPTY — no generic route
  makes sense to demo; every route is born from waypoints recorded on the real
  map. Impure only in file IO (`File`/`JSON` under `Pokex.Home.dir()`); the
  rest is pure `%Route{}` transformation.
  """

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Home

  @filename "routes.json"

  @doc "Every saved route; a missing or corrupted file reads as an empty list."
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> []
    end
  rescue
    # a corrupted routes.json must not take the cavebot down with it
    _error -> []
  end

  @doc "Replaces the whole list."
  def put(routes) when is_list(routes) do
    File.mkdir_p!(Home.dir())
    File.write!(path(), JSON.encode!(%{routes: Enum.map(routes, &encode/1)}))
    :ok
  end

  @doc """
  Adds a route, replacing any existing one with the same name.

  The name is the identity `set_enabled/2` and `delete/1` work by, so two
  routes sharing a name would make both unreachable.
  """
  def add(%Route{name: name} = route) when is_binary(name) and name != "" do
    all()
    |> Enum.reject(&(&1.name == name))
    |> Kernel.++([route])
    |> put()
  end

  def add(_nameless), do: {:error, :invalid_name}

  @doc "Removes a route by name."
  def delete(name) do
    all()
    |> Enum.reject(&(&1.name == name))
    |> put()
  end

  @doc "Enables or disables a route by name."
  def set_enabled(name, enabled?) when is_boolean(enabled?) do
    all()
    |> Enum.map(fn
      %Route{name: ^name} = route -> %Route{route | enabled?: enabled?}
      route -> route
    end)
    |> put()
  end

  defp path, do: Path.join(Home.dir(), @filename)

  defp decode(%{"routes" => list}) when is_list(list), do: Enum.map(list, &decode_route/1)
  defp decode(_corrupt), do: []

  defp decode_route(map) do
    %Route{
      name: map["name"],
      dungeon: map["dungeon"],
      z: map["z"],
      enabled?: map["enabled"] != false,
      waypoints: Enum.map(map["waypoints"] || [], &decode_waypoint/1)
    }
  end

  defp decode_waypoint(%{"x" => x, "y" => y, "z" => z} = map),
    do: %{
      x: x,
      y: y,
      z: z,
      action: decode_action(map["action"]),
      sweep?: map["sweep"] == true
    }

  # Whitelisted, never `String.to_atom/1`: the file is user-editable, and a
  # typo in it must not mint atoms. Anything unknown — including the missing
  # key in every route recorded before waypoints had jobs — is a plain corner.
  defp decode_action("lure_start"), do: :lure_start
  defp decode_action("lure_end"), do: :lure_end
  defp decode_action(_walk_or_unknown), do: :walk

  defp encode(%Route{} = route) do
    %{
      "name" => route.name,
      "dungeon" => route.dungeon,
      "z" => route.z,
      "enabled" => route.enabled?,
      "waypoints" => Enum.map(route.waypoints, &encode_waypoint/1)
    }
  end

  defp encode_waypoint(%{x: x, y: y, z: z} = waypoint),
    do: %{
      "x" => x,
      "y" => y,
      "z" => z,
      "action" => Atom.to_string(Map.get(waypoint, :action) || :walk),
      "sweep" => Map.get(waypoint, :sweep?) == true
    }
end
