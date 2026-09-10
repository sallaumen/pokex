defmodule Pokex.Bots.Cavebot.Store do
  @moduledoc """
  Where cavebot routes live: `~/.pokex/routes.json`.

  A route is a user-authored program, not a Settings scalar — hence its own
  file and store. The seed is EMPTY on purpose: no generic route makes sense
  to demo; every route is born from waypoints recorded on the real map.
  Impure only in file IO (`File`/`JSON` under `Pokex.Home.dir()`); the rest is
  pure `%Route{}` transformation.
  """

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Bots.HuntMode
  alias Pokex.Home

  require Logger
  alias Pokex.StateFile

  @filename "routes.json"

  @doc "Every saved route; a missing or corrupted file reads as an empty list."
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> []
    end
  rescue
    # Keeping the cavebot up is right; doing it in silence is not. `routes.json`
    # is hand-editable, and a broken one read exactly like "there are no routes":
    # the hunt had nothing to walk and nobody could say why.
    error ->
      Logger.warning(
        "rotas: #{path()} ilegível (#{Exception.message(error)}) — seguindo sem rota nenhuma"
      )

      []
  end

  @doc "Replaces the whole list."
  def put(routes) when is_list(routes) do
    File.mkdir_p!(Home.dir())
    Home.write!(path(), JSON.encode!(%{routes: Enum.map(routes, &encode/1)}))
  end

  @doc """
  Adds a route, replacing any existing one with the same name.

  The name is the identity `set_enabled/2` and `delete/1` work by, so two
  routes sharing a name would make both unreachable.
  """
  def add(%Route{name: name} = route) when is_binary(name) and name != "" do
    StateFile.update(fn ->
      all()
      |> Enum.reject(&(&1.name == name))
      |> Kernel.++([route])
      |> put()
    end)
  end

  def add(_nameless), do: {:error, :invalid_name}

  @doc "Removes a route by name."
  def delete(name) do
    StateFile.update(fn ->
      all()
      |> Enum.reject(&(&1.name == name))
      |> put()
    end)
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
    StateFile.update(fn ->
      all()
      |> Enum.map(fn
        %Route{name: ^name} = route -> %Route{route | enabled?: enabled?}
        %Route{} = other when enabled? -> %Route{other | enabled?: false}
        %Route{} = other -> other
      end)
      |> put()
    end)
  end

  defp path, do: Path.join(Home.dir(), @filename)

  defp decode(%{"routes" => list}) when is_list(list), do: Enum.map(list, &decode_route/1)

  defp decode(shapeless),
    do:
      raise(ArgumentError, "sem a chave \"routes\": #{inspect(shapeless) |> String.slice(0, 80)}")

  # KEYS READ PAST ON PURPOSE. `"z"` on the route (the floor it started on,
  # dead since `floors/1` derives the whole set from the waypoints), and now
  # `"action"`, `"combo"`, `"skills"` and `"gather_wait_ms"` on the waypoint —
  # the mob-stretch marks and everything hanging off them. They stay in his
  # file until the next save and are never read again: deleting a key nobody
  # reads is not worth a migration, and a route saved once comes back clean.
  defp decode_route(map) do
    %Route{
      name: map["name"],
      dungeon: map["dungeon"],
      enabled?: map["enabled"] != false,
      mode: HuntMode.parse(map["mode"]),
      waypoints: Enum.map(map["waypoints"] || [], &decode_waypoint/1)
    }
  end

  # The whitelist as {text, atom} pairs, resolved once at COMPILE time. Built
  # per waypoint it meant an `Atom.to_string/1` for every stop and every skill
  # of every waypoint of every read, and the hunt re-reads this file many times
  # a second. MEASURED 2026-08-26 on the step alone: 0.7us per waypoint against
  # 0.4us — small next to the file read, and free.
  @stop_names Enum.map(Route.stops(), &{Atom.to_string(&1), &1})

  defp decode_waypoint(%{"x" => x, "y" => y, "z" => z} = map),
    do: %{
      x: x,
      y: y,
      z: z,
      stops: decode_stops(map),
      at: decode_at(map["at"]),
      dwell_ms: decode_dwell(map["dwell_ms"]),
      fight_ms: decode_dwell(map["fight_ms"]),
      gather_ms: decode_dwell(map["gather_ms"])
    }

  defp decode_at(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> at
      _unreadable -> nil
    end
  end

  defp decode_at(_absent), do: nil

  defp decode_dwell(value) when is_integer(value) and value >= 0, do: value
  defp decode_dwell(_absent), do: nil

  # Whitelisted, like the action — which is also what drops `"sweep"` off every
  # route recorded before 2026-08-28 without touching the file: the stop was
  # removed from `Route.stops/0`, so the name matches nothing and the waypoint
  # loads carrying only the stops that still exist.
  defp decode_stops(%{"stops" => list}) when is_list(list) do
    for {name, stop} <- @stop_names, name in list, do: stop
  end

  defp decode_stops(_none), do: []

  defp encode(%Route{} = route) do
    %{
      "name" => route.name,
      "dungeon" => route.dungeon,
      "enabled" => route.enabled?,
      "mode" => encode_mode(route.mode),
      "waypoints" => Enum.map(route.waypoints, &encode_waypoint/1)
    }
  end

  defp encode_waypoint(%{x: x, y: y, z: z} = waypoint),
    do: %{
      "x" => x,
      "y" => y,
      "z" => z,
      "stops" => Enum.map(Map.get(waypoint, :stops) || [], &Atom.to_string/1),
      "at" => encode_at(Map.get(waypoint, :at)),
      "dwell_ms" => Map.get(waypoint, :dwell_ms),
      "fight_ms" => Map.get(waypoint, :fight_ms),
      "gather_ms" => Map.get(waypoint, :gather_ms)
    }

  defp encode_mode(mode) when is_atom(mode) and not is_nil(mode), do: Atom.to_string(mode)
  defp encode_mode(_none), do: nil

  defp encode_at(%DateTime{} = at), do: DateTime.to_iso8601(at)
  defp encode_at(_none), do: nil
end
