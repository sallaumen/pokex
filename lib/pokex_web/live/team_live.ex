defmodule PokexWeb.TeamLive do
  @moduledoc """
  Lucas's Pokémon, on their own page (`/time`) — his review of the first
  Pokédex cut: "toda a questão do meu próprio time deveria ser uma página à
  parte... que até possa mapear o que não está no meu time, mas eu tenho no
  banco guardado". Two lists (Time / Banco, movable both ways, each entry
  with its level), his character level + the hunt window, and the hunt
  suggestions ranked INSIDE that window — no more lv-5 recommendations at
  lv 88. The threats column ("cuidado") is gone by his call; the context
  still computes it for whoever wants it back.
  """
  use PokexWeb, :live_view

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Team
  alias PokexWeb.PanelForms

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Meu Time",
       species_names: Enum.map(Pokedex.search(%{}), & &1.name)
     )
     |> assign_team()}
  end

  @impl true
  def handle_event("add", %{"member" => name, "where" => where}, socket) do
    where = if where == "bank", do: :bank, else: :team

    case Team.add(String.trim(name), where) do
      {:ok, _data} ->
        {:noreply, assign_team(socket)}

      {:error, :unknown} ->
        {:noreply,
         assign_team(socket, "não conheço \"#{String.trim(name)}\" — usa um nome da Pokédex")}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    Team.remove(name)
    {:noreply, assign_team(socket)}
  end

  def handle_event("move", %{"name" => name, "to" => to}, socket) do
    Team.move(name, if(to == "bank", do: :bank, else: :team))
    {:noreply, assign_team(socket)}
  end

  def handle_event("set_level", %{"name" => name} = params, socket) do
    case PanelForms.parse_int(params["level"], 1..999) do
      {:ok, level} -> Team.set_level(name, level)
      # blank clears; garbage changes nothing
      :error -> if params["level"] == "", do: Team.set_level(name, nil)
    end

    {:noreply, assign_team(socket)}
  end

  def handle_event("save_hunt_window", params, socket) do
    case PanelForms.parse_int(params["player_level"], 1..999) do
      {:ok, level} -> Team.set_player_level(level)
      :error -> if params["player_level"] == "", do: Team.set_player_level(nil)
    end

    case PanelForms.parse_int(params["level_margin"], 1..300) do
      {:ok, margin} -> Team.set_level_margin(margin)
      :error -> :ok
    end

    {:noreply, assign_team(socket)}
  end

  # Everything on this page derives from the saved team file + the Pokédex —
  # one funnel keeps the lists, the window and the suggestions in sync.
  defp assign_team(socket, team_msg \\ nil) do
    members = Team.members()
    bank = Team.bank()
    player_level = Team.player_level()
    margin = Team.level_margin()

    suggestions =
      if members == [] do
        %{targets: [], window: :all}
      else
        Pokedex.hunt_suggestions(Enum.map(members, & &1.name), %{
          player_level: player_level,
          level_margin: margin
        })
      end

    assign(socket,
      team: with_entries(members),
      bank: with_entries(bank),
      player_level: player_level,
      level_margin: margin,
      targets: Enum.take(suggestions.targets, 24),
      window: suggestions.window,
      team_msg: team_msg
    )
  end

  defp with_entries(list) do
    for %{name: name, level: level} <- list,
        entry = Pokedex.get(name),
        entry != nil,
        do: %{name: name, level: level, entry: entry}
  end

  defp window_note(:all, _margin), do: nil

  defp window_note({:window, lo, hi}, margin),
    do: "alvos entre lv #{lo} e #{hi} (teu level ±#{margin})"

  defp window_note({:below, player_level}, _margin),
    do: "nada na janela — mostrando os mais próximos ABAIXO do teu lv #{player_level}"

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-[#080b0d] px-3 py-4 text-[#d9dde1]">
      <div class="mx-auto max-w-[900px] space-y-3">
        <header class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-lg font-bold">🧢 Meu Time</h1>
          <div class="flex items-center gap-3">
            <.link
              navigate={~p"/pokedex"}
              class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
            >
              pokédex
            </.link>
            <.link
              navigate={~p"/"}
              class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
            >
              painel
            </.link>
          </div>
        </header>

        <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <form
            id="hunt-window-form"
            phx-change="save_hunt_window"
            class="flex flex-wrap items-center gap-1.5 font-mono text-[10px] text-[#77828a]"
          >
            <span>meu level</span>
            <input
              name="player_level"
              type="number"
              min="1"
              max="999"
              value={@player_level}
              phx-debounce="500"
              class="h-8 w-16 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-sm text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            />
            <span>· janela ±</span>
            <input
              name="level_margin"
              type="number"
              min="1"
              max="300"
              value={@level_margin}
              phx-debounce="500"
              class="h-8 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-sm text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            />
            <span class="text-[#59636b]">
              — as sugestões miram caças perto da tua força
            </span>
          </form>
        </section>

        <form id="team-add-form" phx-submit="add" class="flex flex-wrap items-center gap-2">
          <input
            name="member"
            list="species-names"
            placeholder="ex.: Venusaur"
            autocomplete="off"
            class="input input-bordered h-9 w-52 bg-[#090d0f] font-mono text-sm"
          />
          <datalist id="species-names">
            <option :for={name <- @species_names} value={name} />
          </datalist>
          <select
            name="where"
            class="select select-bordered h-9 bg-[#090d0f] font-mono text-sm"
          >
            <option value="team">→ time</option>
            <option value="bank">→ banco</option>
          </select>
          <button class="btn h-9 border-0 bg-[#37d07d] px-3 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">
            Adicionar
          </button>
          <span :if={@team_msg} id="team-msg" class="text-[11px] text-[#e7ca82]">{@team_msg}</span>
        </form>

        <section id="team-list" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <h2 class="mb-2 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🧢 time ({length(@team)})
          </h2>
          <p :if={@team == []} class="text-[11px] text-[#7f8992]">
            cadastra teus Pokémon e eu te digo quem vale a caçada
          </p>
          <ul class="space-y-1">
            <.member_row :for={row <- @team} row={row} other="bank" other_label="→ banco" />
          </ul>
        </section>

        <section id="bank-list" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <h2 class="mb-2 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🏦 banco ({length(@bank)})
          </h2>
          <p :if={@bank == []} class="text-[11px] text-[#7f8992]">
            o que você tem guardado mas não caça com — pra não perder de vista
          </p>
          <ul class="space-y-1">
            <.member_row :for={row <- @bank} row={row} other="team" other_label="→ time" />
          </ul>
        </section>

        <section
          :if={@targets != []}
          id="hunt-card"
          class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
        >
          <h2 class="mb-0.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🎯 melhores caçadas pro teu time
          </h2>
          <p
            :if={window_note(@window, @level_margin)}
            id="hunt-window-note"
            class="mb-1.5 font-mono text-[9px] text-[#8b949d]"
          >
            {window_note(@window, @level_margin)}
          </p>
          <ul id="hunt-targets" class="grid gap-1 lg:grid-cols-2">
            <li :for={row <- @targets}>
              <.link
                navigate={~p"/pokedex/#{row.entry.name}"}
                class="block rounded-lg border border-[#232b30] bg-[#101418] px-2.5 py-1.5 transition hover:border-[#37d07d]/60"
              >
                <div class="flex items-center gap-2">
                  <img
                    :if={row.entry.sprite}
                    src={"/" <> row.entry.sprite}
                    alt={row.entry.name}
                    onerror="this.style.display='none'"
                    class="size-6 shrink-0 object-contain"
                  />
                  <p class="min-w-0 flex-1 truncate text-sm font-semibold">
                    {row.entry.name}
                    <span class="font-mono text-[9px] font-normal text-[#737d85]">
                      lv {row.entry.level || "?"}
                    </span>
                  </p>
                  <span class="font-mono text-[10px] font-bold text-[#37d07d]">+{row.score}</span>
                </div>
                <p class="mt-0.5 flex flex-wrap gap-1 font-mono text-[9px]">
                  <span class="rounded bg-[#0d3822] px-1 py-0.5 text-[#3de083]">
                    {Enum.join(row.hits, "+")} fere ({row.member})
                  </span>
                  <span
                    :if={row.resisted != []}
                    class="rounded bg-[#241114] px-1 py-0.5 text-[#ff9ca4]"
                  >
                    resiste {Enum.join(row.resisted, "+")}
                  </span>
                  <span :if={row.shiny?} class="rounded bg-[#211b0d] px-1 py-0.5 text-[#f3ba4e]">
                    ✨ tem shiny
                  </span>
                  <span
                    :for={lure <- Enum.take(row.lures, 2)}
                    class="rounded bg-[#101d24] px-1 py-0.5 text-[#7cc0e8]"
                  >
                    🎣 {lure.lure} lv{lure.fishing_level}
                  </span>
                </p>
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end

  attr :row, :map, required: true
  attr :other, :string, required: true
  attr :other_label, :string, required: true

  defp member_row(assigns) do
    ~H"""
    <li class="flex items-center gap-2 rounded-lg border border-[#293238] bg-[#101418] px-2.5 py-1.5">
      <img
        :if={@row.entry.sprite}
        src={"/" <> @row.entry.sprite}
        alt={@row.name}
        onerror="this.style.display='none'"
        class="size-6 shrink-0 object-contain"
      />
      <.link
        navigate={~p"/pokedex/#{@row.name}"}
        class="min-w-0 flex-1 truncate text-sm font-semibold hover:underline"
      >
        {@row.name}<span :if={@row.entry.shiny_of}> ✨</span>
        <span class="font-mono text-[9px] font-normal text-[#737d85]">
          {Enum.join(@row.entry.elements, "/")}
        </span>
      </.link>
      <form
        id={"level-form-" <> String.replace(@row.name, ~r/\W+/, "-")}
        phx-change="set_level"
        class="flex items-center gap-1 font-mono text-[9px] text-[#737d85]"
      >
        <input type="hidden" name="name" value={@row.name} />
        <span>lv</span>
        <input
          name="level"
          type="number"
          min="1"
          max="999"
          value={@row.level}
          phx-debounce="500"
          class="h-7 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[11px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
        />
      </form>
      <button
        phx-click="move"
        phx-value-name={@row.name}
        phx-value-to={@other}
        class="cursor-pointer font-mono text-[10px] text-[#89939a] hover:text-white"
      >
        {@other_label}
      </button>
      <button
        phx-click="remove"
        phx-value-name={@row.name}
        title="remover"
        class="cursor-pointer text-[#89939a] hover:text-[#ff9ca4]"
      >
        ×
      </button>
    </li>
    """
  end
end
