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

  @doc """
  Arms or disarms a route by name. Arming DISARMS every other one.

  The hunt walks the first enabled route it finds, so two armed at once meant
  the screen said "é a que a caçada vai andar" about one of them while the bot
  walked the other. Live, 2026-08-11: "teste" (floor 5) and "Azumaril easy"
  (floors 1 and 2) were both armed, he stood in the Azumaril, and the hunt
  walked "teste" — every position on a floor that route never visits, blocked
  on the first step. Exclusive here is the only place it cannot drift.
  """
  def set_enabled(name, enabled?) when is_boolean(enabled?) do
    all()
    |> Enum.map(fn
      %Route{name: ^name} = route -> %Route{route | enabled?: enabled?}
      %Route{} = other when enabled? -> %Route{other | enabled?: false}
      %Route{} = other -> other
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
      stops: decode_stops(map),
      at: decode_at(map["at"]),
      dwell_ms: decode_dwell(map["dwell_ms"]),
      park_point: decode_point(map["park_point"])
    }

  defp decode_point([x, y]) when is_integer(x) and is_integer(y), do: {x, y}
  defp decode_point(_absent), do: nil

  defp decode_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp decode_at(_absent), do: nil

  defp decode_dwell(value) when is_integer(value) and value >= 0, do: value
  defp decode_dwell(_absent), do: nil

  # Whitelisted, like the action. `"sweep" => true` is the shape the very first
  # marked routes were written with, before stops became a list — it reads as
  # `[:sweep]` forever.
  defp decode_stops(%{"stops" => list}) when is_list(list) do
    Enum.filter(Route.stops(), &(Atom.to_string(&1) in list))
  end

  defp decode_stops(%{"sweep" => true}), do: [:sweep]
  defp decode_stops(_none), do: []

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
      "stops" => Enum.map(Map.get(waypoint, :stops) || [], &Atom.to_string/1),
      "at" => encode_at(Map.get(waypoint, :at)),
      "dwell_ms" => Map.get(waypoint, :dwell_ms),
      "park_point" => encode_point(Map.get(waypoint, :park_point))
    }

  defp encode_point({x, y}), do: [x, y]
  defp encode_point(_none), do: nil

  defp encode_at(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encode_at(_none), do: nil
end
