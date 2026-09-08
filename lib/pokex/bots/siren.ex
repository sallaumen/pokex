defmodule Pokex.Bots.Siren do
  @moduledoc """
  THE SOUND THAT DOES NOT LIVE IN A BROWSER TAB.

  Every alarm in this app is a chirp the PANEL plays, which means a tab has to
  be open, audible and not muted for the sector. On a single-screen notebook
  with the game in front, none of that holds: on 2026-09-07 the bot was stopped
  in a pile of six with the `:command` and `:hp` sectors muted, the character
  died six minutes later, and the only trace was a line in a tab he was not
  looking at.

  This process listens to the same topics the journal does and plays a Mac
  system sound through `afplay` for the two sectors that have no mute button:

    * `:mortal` — HIS life, and a stop that leaves him exposed (Basso: low,
      hard to miss);
    * `:setup` — the bot refused to start, or the watchman found a reading it
      cannot make (Submarine: distinct from every game sound, not unpleasant,
      so it can ring once a minute without being hated).

  One sound per sector per `@min_gap_ms`, so a burst of alarms is one ring.
  `native_alarm_sound` turns it off. Tests inject the player and never shell
  out (`:native_sound_cmd` is false in the suite).
  """
  use GenServer

  alias Pokex.Settings

  @topics ~w(fishing combat catcher mini_game game body cavebot logout engine settings)
  @sounds %{
    mortal: "/System/Library/Sounds/Basso.aiff",
    setup: "/System/Library/Sounds/Submarine.aiff"
  }
  @min_gap_ms 2_500

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      play: Keyword.get(opts, :play, &default_play/1),
      clock: Keyword.get(opts, :clock, &now/0),
      last: %{}
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "The sound file of a sector, or `nil` for the ones only the panel plays."
  @spec sound(atom) :: String.t() | nil
  def sound(category), do: Map.get(@sounds, category)

  @doc "The sectors with a native sound."
  @spec sectors() :: [atom]
  def sectors, do: Map.keys(@sounds)

  @doc "Rings a sector now, for callers that do not go through an alarm broadcast."
  @spec ring(atom, GenServer.server()) :: :ok
  def ring(category, server \\ __MODULE__), do: GenServer.cast(server, {:ring, category})

  @impl true
  def init(state) do
    Enum.each(@topics, &Phoenix.PubSub.subscribe(Pokex.PubSub, &1))
    {:ok, state}
  end

  @impl true
  def handle_cast({:ring, category}, state), do: {:noreply, maybe_ring(state, category)}

  @impl true
  def handle_info({:rule_alarm, category, _text}, state) when is_map_key(@sounds, category),
    do: {:noreply, maybe_ring(state, category)}

  # Everything else on these topics is somebody else's conversation.
  def handle_info(_msg, state), do: {:noreply, state}

  defp maybe_ring(state, category) do
    now = state.clock.()
    last = Map.get(state.last, category)

    cond do
      Settings.get(:native_alarm_sound) != true -> state
      not is_map_key(@sounds, category) -> state
      is_integer(last) and now - last < @min_gap_ms -> state
      true -> ring_now(state, category, now)
    end
  end

  defp ring_now(state, category, now) do
    safe_play(state.play, Map.fetch!(@sounds, category))
    %{state | last: Map.put(state.last, category, now)}
  end

  # A player that raises must not take the siren down: the next alarm still rings.
  defp safe_play(play, file) do
    play.(file)
  catch
    _kind, _reason -> :ok
  end

  # `afplay` in a task: the sound takes a second and this process must never wait on it.
  defp default_play(file) do
    if Application.get_env(:pokex, :native_sound_cmd, true) and
         System.find_executable("afplay") do
      Task.start(fn -> System.cmd("afplay", [file], stderr_to_stdout: true) end)
    end

    :ok
  end

  defp now, do: System.monotonic_time(:millisecond)
end
