defmodule Pokex.Bots.Cavebot.Store do
  @moduledoc """
  Onde as rotas do cavebot vivem: `~/.pokex/routes.json`.

  Espelha `Pokex.Combos.Store` (uma rota é um programa autorado pelo usuário,
  não um escalar de Settings), com uma diferença: o seed é VAZIO — não existe
  rota genérica que faça sentido demonstrar; cada rota nasce de waypoints
  gravados no mapa real do Lucas.

  Impuro só no IO de arquivo (`File`/`JSON` sob `Pokex.Home.dir()`); todo o
  resto é transformação pura de `%Route{}`.
  """

  alias Pokex.Bots.Cavebot.Route
  alias Pokex.Home

  @filename "routes.json"

  @doc "Toda rota salva; arquivo ausente ou corrompido lê como lista vazia."
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> []
    end
  rescue
    # um routes.json corrompido não pode derrubar o cavebot junto
    _error -> []
  end

  @doc "Substitui a lista inteira."
  def put(routes) when is_list(routes) do
    File.mkdir_p!(Home.dir())
    File.write!(path(), JSON.encode!(%{routes: Enum.map(routes, &encode/1)}))
    :ok
  end

  @doc """
  Adiciona uma rota, substituindo qualquer existente de mesmo nome.

  O nome é a identidade por onde `set_enabled/2` e `delete/1` trabalham, então
  duas rotas dividindo um nome tornariam ambas inalcançáveis.
  """
  def add(%Route{name: name} = route) when is_binary(name) and name != "" do
    all()
    |> Enum.reject(&(&1.name == name))
    |> Kernel.++([route])
    |> put()
  end

  def add(_nameless), do: {:error, :invalid_name}

  @doc "Remove uma rota pelo nome."
  def delete(name) do
    all()
    |> Enum.reject(&(&1.name == name))
    |> put()
  end

  @doc "Liga ou desliga uma rota pelo nome."
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

  defp decode_waypoint(%{"x" => x, "y" => y, "z" => z}), do: %{x: x, y: y, z: z}

  defp encode(%Route{} = route) do
    %{
      "name" => route.name,
      "dungeon" => route.dungeon,
      "z" => route.z,
      "enabled" => route.enabled?,
      "waypoints" => Enum.map(route.waypoints, &encode_waypoint/1)
    }
  end

  defp encode_waypoint(%{x: x, y: y, z: z}), do: %{"x" => x, "y" => y, "z" => z}
end
