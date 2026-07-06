defmodule Pokex.Settings do
  @moduledoc "Runtime-tunable bot settings, persisted as JSON. Keys are a closed set."
  use GenServer

  @defaults %{
    skill_keys: ["1", "2", "3"],
    tick_ms_watching: 200,
    tick_ms_fighting: 1000,
    tick_ms_default: 300,
    wait_focus_ms: 150,
    wait_after_equip_ms: 300,
    wait_assess_ms: 1500,
    wait_loot_ms: 400,
    wait_after_capture_ms: 2000,
    watch_timeout_ms: 30_000,
    fight_timeout_ms: 90_000,
    glow_threshold: nil,
    max_consecutive_failures: 5,
    tile_size: 32,
    hostile_scan_every: 2,
    wild_min_red_pixels: 12,
    auto_capture: true,
    glow_streak_needed: 2
  }

  def defaults, do: @defaults

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  def get(key, server \\ __MODULE__), do: GenServer.call(server, {:get, key})
  def all(server \\ __MODULE__), do: GenServer.call(server, :all)

  def put(key, value, server \\ __MODULE__) when is_map_key(@defaults, key),
    do: GenServer.call(server, {:put, key, value})

  @impl true
  def init(opts) do
    path =
      Keyword.get(opts, :path) ||
        Application.get_env(:pokex, :settings_path) ||
        Pokex.Home.settings_file()

    {:ok, %{path: path, data: Map.merge(@defaults, load(path))}}
  end

  @impl true
  # Fall back to @defaults so a process that started before a new key was added
  # (e.g. after a hot code reload) returns the default instead of crashing.
  def handle_call({:get, key}, _from, state),
    do: {:reply, Map.get(state.data, key, Map.get(@defaults, key)), state}

  def handle_call(:all, _from, state), do: {:reply, state.data, state}

  def handle_call({:put, key, value}, _from, state) do
    data = Map.put(state.data, key, value)
    File.mkdir_p!(Path.dirname(state.path))
    File.write!(state.path, JSON.encode!(data))
    {:reply, :ok, %{state | data: data}}
  end

  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      for {key_string, value} <- json,
          key = known_key(key_string),
          key != nil,
          into: %{},
          do: {key, value}
    else
      _ -> %{}
    end
  end

  defp known_key(key_string) do
    Enum.find(Map.keys(@defaults), &(Atom.to_string(&1) == key_string))
  end
end
