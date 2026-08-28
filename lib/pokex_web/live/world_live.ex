defmodule PokexWeb.WorldLive do
  @moduledoc """
  /world — "what the AI sees": every fact currently on the WorldState blackboard,
  with its age and a human summary. Pure read-side: this page never captures,
  never touches a worker — it renders `WorldState.entries/0` and refreshes on
  the "world" PubSub topic plus a timer (ages advance even when nothing new is
  published, and feeds re-put fresh timestamps without broadcasting).
  """
  use PokexWeb, :live_view

  alias Pokex.Perception
  alias Pokex.Perception.DisplayFeeds
  alias Pokex.Perception.WorldState
  alias Pokex.World
  alias PokexWeb.PositionReadout

  @refresh_ms 500

  # Age → freshness bucket. Purely visual: each consumer applies its OWN
  # max-age when acting; these bands just make a wedged feed jump out.
  @fresh_ms 1_000
  @aging_ms 3_000

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket) do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())
      # feeds only capture while someone is attached — a watching page IS a
      # consumer, so :team and :minimap run exactly while they are looked at
      # (:minimap included — without it the position on this page would be
      # frozen at whatever the last OTHER consumer happened to publish)
      DisplayFeeds.attach_all()
      Process.send_after(self(), :refresh, @refresh_ms)
    end

    {:ok,
     assign(socket,
       page_title: "Mundo",
       entries: entries(),
       snapshot: World.snapshot(),
       minimap_reads: 0,
       minimap_misses: 0
     )}
  end

  @impl true
  def handle_info(:refresh, socket) do
    Process.send_after(self(), :refresh, @refresh_ms)
    {:noreply, assign(socket, entries: entries(), snapshot: World.snapshot())}
  end

  # The minimap publishes whether or not the coordinate came out readable
  # (`pos: nil` IS the miss), so counting its publishes is the only place the
  # good/bad ratio can come from — a fact that gets overwritten keeps no history.
  def handle_info({:world, :minimap, obs}, socket) do
    socket =
      if Map.get(obs, :pos) == nil,
        do: assign(socket, minimap_misses: socket.assigns.minimap_misses + 1),
        else: assign(socket, minimap_reads: socket.assigns.minimap_reads + 1)

    {:noreply, assign(socket, entries: entries(), snapshot: World.snapshot())}
  end

  # Any world broadcast just re-reads the table — the table is the truth.
  def handle_info({:world, _key, _obs}, socket) do
    {:noreply, assign(socket, entries: entries(), snapshot: World.snapshot())}
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
    corpse = if length(corpses) == 1, do: "corpo", else: "corpos"
    "#{length(corpses)} #{corpse} · #{scan}"
  end

  defp summary(:arena, obs) when is_map(obs) do
    obs |> Map.drop([:captured_at]) |> inspect(limit: 8, printable_limit: 120)
  end

  defp summary(:hud, %{level: level, slots: slots}) do
    "level #{num(level)} · F1 #{num(slots[:f1])} · F2 #{num(slots[:f2])} · E #{num(slots[:e])} · S+Q #{num(slots[:s_q])}"
  end

  defp summary(:team, %{pokemon_hp: hp, rows: rows}) do
    alive = Enum.count(rows, & &1.present?)
    "ativo #{hp_text(hp)} · #{alive}/#{length(rows)} no time"
  end

  defp summary(:minimap, %{pos: nil}), do: "posição ilegível"
  defp summary(:minimap, %{pos: {x, y, z}}), do: "posição #{x}, #{y} (andar #{z})"

  defp summary(_key, obs), do: inspect(obs, limit: 8, printable_limit: 120)

  defp enemies_text(%{enemies: [], shiny?: false}), do: "livre"
  defp enemies_text(%{enemies: [], shiny?: true}), do: "✨ SHINY"

  defp enemies_text(%{enemies: enemies, shiny?: shiny?}) do
    names = Enum.map_join(enemies, ", ", &Pokex.Bots.Engine.Narration.row_label/1)
    if shiny?, do: "✨ " <> names, else: names
  end

  defp num(nil), do: "?"
  defp num(n), do: to_string(n)

  defp hp_text(nil), do: "?"
  defp hp_text({current, max}), do: "#{current}/#{max}"

  @doc false
  def pct(nil), do: "?"
  def pct(fraction), do: "#{round(fraction * 100)}%"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_page={:world} {Layouts.header(assigns)}>
      <div class="space-y-4">
        <section
          id="world-snapshot"
          class="rounded-lg border border-pk-line bg-pk-surface p-4"
        >
          <div class="flex items-baseline justify-between">
            <h2 class="text-pk-body font-bold uppercase tracking-[0.12em] text-pk-text-2">
              O que a IA vê agora
            </h2>
            <span :if={not @snapshot.layout?} class="font-mono text-pk-meta text-pk-danger">
              HUD não localizado
            </span>
          </div>

          <dl class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <div>
              <dt class="font-mono text-pk-meta uppercase text-pk-text-3">Pokémon ativo</dt>
              <dd class="font-mono text-pk-body text-pk-text">
                {hp_text(@snapshot.me.pokemon_hp)}
                <span class="text-pk-ok">{pct(World.pokemon_hp_pct(@snapshot))}</span>
              </dd>
            </div>
            <div>
              <dt class="font-mono text-pk-meta uppercase text-pk-text-3">Level · pesca</dt>
              <dd class="font-mono text-pk-body text-pk-text">
                {num(@snapshot.me.level)} · {num(@snapshot.me.fishing)}
              </dd>
            </div>
            <%!-- The position is the field he watches all the time (it is how
                  he checks the bot knows where it is), so it can't be a mute
                  number: it comes with the AGE and the phrase separating "not
                  reading" from "reading, and you are here". --%>
            <div id="world-position">
              <dt class="font-mono text-pk-meta uppercase text-pk-text-3">Posição</dt>
              <dd class="font-mono text-pk-body text-pk-text">
                {PositionReadout.coords(@snapshot.pos)}
              </dd>
              <p class={[
                "mt-0.5 font-mono text-pk-meta",
                PositionReadout.note_class(@snapshot.pos, @snapshot.pos_age_ms)
              ]}>
                {PositionReadout.note(@snapshot.pos, @snapshot.pos_age_ms)}
              </p>
              <p id="world-read-health" class="font-mono text-pk-meta text-pk-text-3">
                {PositionReadout.read_health(@minimap_reads, @minimap_misses)}
              </p>
            </div>
            <div>
              <dt class="font-mono text-pk-meta uppercase text-pk-text-3">Batalha</dt>
              <dd class="font-mono text-pk-body text-pk-text">
                {enemies_text(@snapshot)}
              </dd>
            </div>
          </dl>

          <div class="mt-3 grid grid-cols-2 gap-3 sm:grid-cols-4">
            <div :for={{slot, label} <- [f1: "F1", f2: "F2", e: "E", s_q: "S+Q"]}>
              <dt class="font-mono text-pk-meta uppercase text-pk-text-3">{label}</dt>
              <dd class="font-mono text-pk-body text-pk-text">{num(@snapshot.inventory[slot])}</dd>
            </div>
          </div>

          <ul :if={@snapshot.team != []} class="mt-3 flex flex-wrap gap-2">
            <li
              :for={row <- @snapshot.team}
              class="rounded border border-pk-line px-2 py-1 font-mono text-pk-meta text-pk-text-2"
            >
              C+{row.slot} {pct(row.hp_pct)}
            </li>
          </ul>
        </section>

        <Layouts.page_title icon="hero-globe-alt">
          Mundo
          <:aside>
            <p class="max-w-xl text-pk-body text-pk-text-2">
              O que a IA vê agora: cada fato no blackboard, com idade e resumo.
              Fato velho = quem publica está travado ou parado — os consumidores
              já o ignoram sozinhos (fail-open).
            </p>
          </:aside>
        </Layouts.page_title>

        <div
          :if={@entries == []}
          class="rounded-xl border border-pk-line bg-pk-surface p-6 text-center text-pk-body opacity-60"
        >
          nada publicado ainda — ligue o bot (ou um worker) e os fatos aparecem aqui
        </div>

        <ul :if={@entries != []} id="world-facts" class="space-y-2">
          <li
            :for={entry <- @entries}
            class="flex items-center gap-3 rounded-xl border border-pk-line bg-pk-surface px-4 py-3"
          >
            <span class={[
              "size-2.5 shrink-0 rounded-full",
              entry.freshness == :fresh && "bg-success",
              entry.freshness == :aging && "bg-warning",
              entry.freshness == :stale && "bg-error"
            ]} />
            <div class="min-w-0 flex-1">
              <div class="flex items-baseline gap-2">
                <span class="font-mono text-pk-body font-semibold">{entry.key}</span>
                <span class="font-mono text-pk-meta opacity-50">{format_age(entry.age_ms)}</span>
              </div>
              <p class="truncate font-mono text-pk-meta opacity-70">{entry.summary}</p>
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
