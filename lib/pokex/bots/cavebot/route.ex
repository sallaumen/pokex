defmodule Pokex.Bots.Cavebot.Route do
  @moduledoc """
  Rota de caçada do cavebot: uma sequência ordenada de waypoints em um único andar.

  Struct pura — sem processo, sem tela, sem Settings, sem IO. O invariante
  central é o de andar único (`z`): o primeiro waypoint fixa o andar da rota
  e todos os demais precisam estar no mesmo `z`.
  """

  @enforce_keys [:name]
  defstruct name: nil,
            dungeon: nil,
            z: nil,
            enabled?: true,
            waypoints: []

  @type waypoint :: %{x: integer, y: integer, z: integer}

  @type t :: %__MODULE__{
          name: String.t(),
          dungeon: String.t() | nil,
          z: integer | nil,
          enabled?: boolean,
          waypoints: [waypoint]
        }

  @doc """
  Cria uma rota vazia. `waypoints: []`, `z: nil`, `enabled?: true`.
  """
  @spec new(String.t(), String.t() | nil) :: t
  def new(name, dungeon \\ nil) when is_binary(name) do
    %__MODULE__{name: name, dungeon: dungeon}
  end

  @doc """
  Acrescenta um waypoint ao fim da rota.

  O `z` do primeiro waypoint fixa o andar da rota; waypoints em outro
  andar são recusados com `{:error, :floor_mismatch}`.
  """
  @spec append(t, {integer, integer, integer}) :: {:ok, t} | {:error, :floor_mismatch}
  def append(%__MODULE__{z: nil} = route, {x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, %{route | z: z, waypoints: route.waypoints ++ [%{x: x, y: y, z: z}]}}
  end

  def append(%__MODULE__{z: z} = route, {x, y, z})
      when is_integer(x) and is_integer(y) and is_integer(z) do
    {:ok, %{route | waypoints: route.waypoints ++ [%{x: x, y: y, z: z}]}}
  end

  def append(%__MODULE__{}, {_x, _y, _z}), do: {:error, :floor_mismatch}

  @doc """
  Valida a rota: precisa ter ao menos um waypoint e todos no mesmo andar.
  """
  @spec validate(t) :: :ok | {:error, :empty} | {:error, :floor_mismatch}
  def validate(%__MODULE__{waypoints: []}), do: {:error, :empty}

  def validate(%__MODULE__{waypoints: [%{z: z} | _] = waypoints}) do
    if Enum.all?(waypoints, &(&1.z == z)) do
      :ok
    else
      {:error, :floor_mismatch}
    end
  end
end
