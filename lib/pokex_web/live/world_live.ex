defmodule PokexWeb.WorldLive do
  @moduledoc """
  /world — "o que a IA vê": every fact currently on the WorldState blackboard,
  with its age and a human summary. Pure read-side: this page never captures,
  never touches a worker — it renders `WorldState.entries/0` and refreshes on
  the "world" PubSub topic plus a timer (ages advance even when nothing new is
  published, and feeds re-put fresh timestamps without broadcasting).
  """
  use PokexWeb, :live_view

  alias Pokex.Perception
  alias Pokex.Perception.WorldState

  @refresh_ms 500

  # Age → freshness bucket. Purely visual: each consumer applies its OWN
  # max-age when acting; these bands just make a wedged feed jump out.
  @fresh_ms 1_000
  @aging_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok, assign(socket, page_title: "Mundo", entries: entries())}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, entries: entries())}
  end

  # Any world broadcast just re-reads the table — the table is the truth.
  def handle_info({:world, _key, _obs}, socket) do
    {:noreply, assign(socket, entries: entries())}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp entries do
    now = System.monotonic_time(:millisecond)

    WorldState.entries()
    |> Enum.sort_by(fn {key, _obs, _at} -> to_string(key) end)
    |> Enum.map(fn {key, obs, at} ->
      age = max(now - at, 0)

      %{
        key: key,
        age_ms: age,
        freshness: freshness(age),
        summary: summary(key, obs)
      }
    end)
  end

  defp freshness(age) when age <= @fresh_ms, do: :fresh
  defp freshness(age) when age <= @aging_ms, do: :aging
  defp freshness(_age), do: :stale

  defp summary(:mini_game, %{playing?: playing?} = obs) do
    status = if playing?, do: "jogando", else: "fora do jogo"
    "#{status} · confiança #{Map.get(obs, :confidence, 0.0)}"
  end

  defp summary(:battle, %{enemies: enemies} = obs) do
    lock =
      case obs do
        %{locked?: true, locked_row: row} -> " · lock na linha #{row}"
        _no_lock -> ""
      end

    "#{length(enemies)} na lista#{lock}"
  end

  defp summary(:corpses, %{corpses: corpses} = obs) do
    scan = if Map.get(obs, :scanning?), do: "varrendo", else: "parado"
    corpo = if length(corpses) == 1, do: "corpo", else: "corpos"
    "#{length(corpses)} #{corpo} · #{scan}"
  end

  defp summary(:arena, obs) when is_map(obs) do
    obs |> Map.drop([:captured_at]) |> inspect(limit: 8, printable_limit: 120)
  end

  defp summary(_key, obs), do: inspect(obs, limit: 8, printable_limit: 120)

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:world}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Mundo</h1>
          <p class="mt-1 text-sm opacity-70">
            O que a IA vê agora: cada fato no blackboard, com idade e resumo.
            Fato velho = quem publica está travado ou parado — os consumidores
            já o ignoram sozinhos (fail-open).
          </p>
        </header>

        <div
          :if={@entries == []}
          class="rounded-xl border border-base-content/10 bg-base-200 p-6 text-center text-sm opacity-60"
        >
          nada publicado ainda — ligue o bot (ou um worker) e os fatos aparecem aqui
        </div>

        <ul :if={@entries != []} class="space-y-2">
          <li
            :for={entry <- @entries}
            class="flex items-center gap-3 rounded-xl border border-base-content/10 bg-base-200 px-4 py-3"
          >
            <span class={[
              "size-2.5 shrink-0 rounded-full",
              entry.freshness == :fresh && "bg-success",
              entry.freshness == :aging && "bg-warning",
              entry.freshness == :stale && "bg-error"
            ]} />
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline gap-2">
                <span class="font-mono text-sm font-semibold">{entry.key}</span>
                <span class="font-mono text-xs opacity-50">{format_age(entry.age_ms)}</span>
              </div>
              <p class="truncate font-mono text-xs opacity-70">{entry.summary}</p>
            </div>
          </li>
        </ul>
      </div>
    </Layouts.app>
    """
  end

  defp format_age(ms) when ms < 10_000, do: "#{ms}ms"
  defp format_age(ms), do: "#{div(ms, 1000)}s"
end
