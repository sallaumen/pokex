defmodule Pokex.Timers.Store do
  @moduledoc """
  Where the scheduled actions live: `~/.pokex/timers.json`, seeded on first
  read with the one he asked for by name (the aura, eight seconds into a mob
  stretch).

  Same storage philosophy as the combos and the routes: a small user-authored
  program gets its own file, not a Settings scalar. Impure only in file IO; the
  rest is `Pokex.Timers` transformation.
  """

  alias Pokex.Home
  alias Pokex.Timers
  alias Pokex.Timers.Timer

  @filename "timers.json"

  @doc "Every saved timer; a missing file seeds, a corrupt one reads as the seed."
  @spec all() :: [Timer.t()]
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> Timers.seed()
    end
  rescue
    # a corrupted timers.json must not take the bot down with it
    _error -> Timers.seed()
  end

  @doc "Replaces the whole list."
  @spec put([Timer.t()]) :: :ok
  def put(timers) when is_list(timers) do
    File.mkdir_p!(Home.dir())
    Home.write!(path(), JSON.encode!(%{timers: Enum.map(timers, &Timers.encode/1)}))
    :ok
  end

  @doc """
  Adds a timer, replacing any existing one with the same id.

  The id is the identity `toggle/2` and `delete/1` work by — and the one
  `Schedule` stamps firings against, so two timers sharing one would take turns
  resetting each other's clock.
  """
  @spec add(Timer.t()) :: :ok
  def add(%Timer{id: id} = timer) when is_binary(id) and id != "" do
    all()
    |> Enum.reject(&(&1.id == id))
    |> Kernel.++([timer])
    |> put()
  end

  def add(_idless), do: {:error, :invalid_id}

  @doc "Removes a timer by id."
  @spec delete(String.t()) :: :ok
  def delete(id) do
    all()
    |> Enum.reject(&(&1.id == id))
    |> put()
  end

  @doc "Turns one on or off, keeping everything else about it."
  @spec toggle(String.t(), boolean) :: :ok
  def toggle(id, enabled?) do
    all()
    |> Enum.map(fn
      %Timer{id: ^id} = timer -> %{timer | enabled?: enabled?}
      timer -> timer
    end)
    |> put()
  end

  defp decode(%{"timers" => list}) when is_list(list),
    do: list |> Enum.map(&Timers.decode/1) |> Enum.reject(&is_nil/1)

  defp decode(_shapeless), do: Timers.seed()

  defp path, do: Path.join(Home.dir(), @filename)
end
