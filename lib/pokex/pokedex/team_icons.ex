defmodule Pokex.Pokedex.TeamIcons do
  @moduledoc """
  The portraits this install has learned, so the bot can tell which pokémon is
  sitting in each C+N row.

  Learned rather than shipped, for the same reason the glyph atlas is: what
  matters is how the game draws things on THIS screen. Stored at
  `~/.pokex/team_icons.json` and keyed by pokémon name, so re-teaching one
  member leaves the rest alone.

  A signature is a sparse grid, so it travels as a list of `[x, y, r, g, b]`
  cells — everything absent is portrait-free space, which is signal too.
  """

  alias Pokex.Home

  @filename "team_icons.json"

  @doc "Every learned portrait: %{name => signature}."
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> %{}
    end
  rescue
    # a corrupt file must never take the team feed down: forgetting is safe,
    # the panel just shows the slots as unknown until they are taught again
    _error -> %{}
  end

  @doc "Learns one pokémon's portrait, replacing whatever was there."
  def learn(name, signature) when is_binary(name) and is_map(signature) do
    all() |> Map.put(name, signature) |> persist()
    :ok
  end

  @doc "Forgets one pokémon (say, after it evolved and no longer looks the same)."
  def forget(name) when is_binary(name) do
    all() |> Map.delete(name) |> persist()
    :ok
  end

  @doc "Forgets everything."
  def clear, do: persist(%{})

  @doc "Which pokémon have portraits, sorted."
  def known, do: all() |> Map.keys() |> Enum.sort()

  defp persist(icons) do
    File.mkdir_p!(Home.dir())
    File.write!(path(), JSON.encode!(%{icons: encode(icons)}))
    :ok
  end

  defp path, do: Path.join(Home.dir(), @filename)

  defp decode(%{"icons" => icons}) when is_map(icons) do
    Map.new(icons, fn {name, cells} ->
      {name, Map.new(cells, fn [x, y, r, g, b] -> {{x, y}, {r, g, b}} end)}
    end)
  end

  defp decode(_corrupt), do: %{}

  defp encode(icons) do
    Map.new(icons, fn {name, signature} ->
      {name, Enum.map(signature, fn {{x, y}, {r, g, b}} -> [x, y, r, g, b] end)}
    end)
  end
end
