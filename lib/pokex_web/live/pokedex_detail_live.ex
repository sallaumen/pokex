defmodule PokexWeb.PokedexDetailLive do
  @moduledoc """
  One Pokémon, one page (`/pokedex/:name`): the click-through Lucas asked for
  ("quando eu clicar em um Pokémon individualmente, gostaria que tivesse uma
  página para explorar mais informações... com fáceis de voltar e algo bem
  ágil"). Pure `Pokedex.get/1` + `lures_for/1` reads — nothing heavy — and
  every related name (evolutions, shiny variant, base form) is another
  navigate link, so exploring chains is one click per hop with the browser's
  back button always meaningful.
  """
  use PokexWeb, :live_view
  @behaviour PokexWeb.CharacterAware

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Team
  alias PokexWeb.PokedexStyle

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, species_names: Enum.map(Pokedex.search(%{}), & &1.name))}

  # "Está no meu time?" e o confronto contra o time são do personagem ativo —
  # trocar de personagem muda as duas respostas nesta página.
  @impl PokexWeb.CharacterAware
  def on_character_change(%{assigns: %{entry: %{name: name}}} = socket),
    do: assign_entry(socket, name)

  def on_character_change(socket), do: socket

  # handle_params (not mount) owns the lookup so evolution/shiny links between
  # detail pages patch in place — no full remount, "bem ágil".
  @impl true
  def handle_params(%{"name" => name}, _uri, socket),
    do: {:noreply, socket |> assign(jump_msg: nil) |> assign_entry(name)}

  # The jump box: land on any Pokémon FROM any Pokémon — no round-trip
  # through the list. Same-LiveView patch, so it is instant.
  @impl true
  def handle_event("jump", %{"name" => name}, socket) do
    name = String.trim(name)

    if Pokedex.get(name) do
      {:noreply, push_patch(socket, to: ~p"/pokedex/#{name}")}
    else
      {:noreply, assign(socket, jump_msg: "não conheço \"#{name}\"")}
    end
  end

  # Add straight from the page he is LOOKING at — no detour through /time.
  def handle_event("add_to", %{"where" => where}, socket) do
    Team.add(socket.assigns.entry.name, if(where == "bank", do: :bank, else: :team))
    {:noreply, assign_entry(socket, socket.assigns.entry.name)}
  end

  defp assign_entry(socket, name) do
    entry = Pokedex.get(name)

    assign(socket,
      page_title: (entry && entry.name) || "Pokédex",
      entry: entry,
      missing_name: unless(entry, do: name),
      lures: (entry && Pokedex.lures_for(entry.name)) || [],
      base: entry && entry.shiny_of && Pokedex.get(entry.shiny_of),
      shiny: entry && entry.shiny_name && Pokedex.get(entry.shiny_name),
      membership: entry && membership(entry.name),
      matchup: (entry && matchup(entry)) || [],
      team_empty?: Team.members() == []
    )
  end

  defp membership(name) do
    cond do
      Enum.any?(Team.members(), &(&1.name == name)) -> :team
      Enum.any?(Team.bank(), &(&1.name == name)) -> :bank
      true -> nil
    end
  end

  # THIS Pokémon against MY team, member by member: which of my elements hit
  # its weaknesses (fere) and which of ITS elements hit the member's (sofre).
  # Only members with something to say make the list.
  defp matchup(entry) do
    for %{name: name} <- Team.members(),
        member = Pokedex.get(name),
        member != nil,
        fere = Enum.filter(member.elements, &(&1 in entry.weak_to)),
        sofre = Enum.filter(entry.elements, &(&1 in member.weak_to)),
        # "Nulo" na wiki: esse elemento não tira UM ponto de vida dele — a pior
        # surpresa possível numa caçada, então entra no matchup como aviso
        nulo = Enum.filter(member.elements, &(&1 in entry.immune)),
        fere != [] or sofre != [] or nulo != [] do
      %{name: name, fere: fere, sofre: sofre, nulo: nulo}
    end
  end

  # The wiki words effectiveness in tiers of different strength — Venusaur has
  # BOTH "Inefetivo" and "Muito Inefetivo" — so show the tiers apart, labelled
  # as the page labels them. Only one tier (or an entry scraped before we kept
  # the labels) collapses back to a single unlabelled row.
  defp tiers(entry, kind, fallback) do
    case Enum.filter(entry.effectiveness, &(&1.kind == kind and &1.elements != [])) do
      [] -> [%{label: nil, elements: fallback}]
      [only] -> [%{only | label: nil}]
      many -> many
    end
  end

  attr :element, :string, required: true
  attr :class, :string, default: "px-1.5 py-0.5 text-[11px]"

  defp element_chip(assigns) do
    assigns = assign(assigns, :icon, PokedexStyle.element_icon(assigns.element))

    ~H"""
    <span
      class={["inline-flex items-center gap-1 rounded font-mono", @class]}
      style={PokedexStyle.element_style(@element)}
    >
      <img :if={@icon} src={@icon} alt="" class="size-3.5 object-contain" loading="lazy" />
      {@element}
    </span>
    """
  end

  attr :moves, :list, required: true

  defp moves_table(assigns) do
    ~H"""
    <ul class="space-y-1">
      <li
        :for={move <- @moves}
        class="flex flex-wrap items-center gap-1.5 rounded-lg border border-[#232b30] bg-[#101418] px-2.5 py-1.5"
      >
        <span class={[
          "w-7 shrink-0 rounded px-1 py-0.5 text-center font-mono text-[10px] font-bold",
          if(move.slot == "P",
            do: "bg-[#211b0d] text-[#f3ba4e]",
            else: "bg-[#161b1f] text-[#8b949d]"
          )
        ]}>
          {move.slot}
        </span>
        <span class="min-w-0 flex-1 truncate text-sm font-semibold">{move.name}</span>
        <.element_chip :if={move.element} element={move.element} class="px-1.5 py-0.5 text-[10px]" />
        <span
          :if={move.cooldown_s}
          class="rounded bg-[#211b0d] px-1.5 py-0.5 font-mono text-[10px] text-[#f3ba4e]"
        >
          ⏱ {move.cooldown_s}s
        </span>
        <span
          :for={tag <- Enum.reject(move.tags, &(&1 == "Focus Blocked"))}
          class="rounded bg-[#161b1f] px-1.5 py-0.5 font-mono text-[9px] text-[#8b949d]"
        >
          {tag}
        </span>
        <span :if={move.level} class="font-mono text-[9px] text-[#59636b]">lv {move.level}</span>
      </li>
    </ul>
    """
  end

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:pokedex}
      {Layouts.header(assigns)}
      max_width="max-w-[1080px]"
    >
      <div class="space-y-3">
        <%!-- Voltar pra lista e pular pra outra espécie são ações DESTA página, não
              navegação do app: ficam aqui no corpo, sob o header padrão. --%>
        <section class="flex flex-wrap items-center gap-3">
          <.link
            navigate={~p"/pokedex"}
            class="font-mono text-[11px] text-pk-text-2 underline hover:text-white"
          >
            ← pokédex
          </.link>
          <form id="jump-form" phx-submit="jump" class="flex items-center gap-1.5">
            <input
              name="name"
              list="species-names"
              placeholder="pular pra outro…"
              autocomplete="off"
              data-quick-search
              class="input input-bordered h-8 w-44 bg-pk-sunken font-mono text-xs"
            />
            <datalist id="species-names">
              <option :for={name <- @species_names} value={name} />
            </datalist>
            <button class="btn h-8 border border-pk-line-strong bg-transparent px-2.5 text-xs text-pk-text-2 hover:border-pk-ok/60 hover:text-white">
              ir
            </button>
            <span :if={@jump_msg} id="jump-msg" class="font-mono text-[10px] text-pk-warn">
              {@jump_msg}
            </span>
          </form>
        </section>

        <section
          :if={@entry == nil}
          id="entry-missing"
          class="rounded-lg border border-[#674f20] bg-[#211b0d] p-4 text-sm text-[#e7ca82]"
        >
          Não achei "{@missing_name}" na Pokédex — confere o nome ou sincroniza a wiki.
        </section>

        <article :if={@entry} id="entry-card" class="space-y-3">
          <section class="rounded-lg border border-[#232b30] bg-[#111519] p-4">
            <div class="flex items-center gap-4">
              <img
                :if={@entry.sprite}
                src={"/" <> @entry.sprite}
                alt={@entry.name}
                onerror="this.style.display='none'"
                class="size-20 shrink-0 object-contain"
              />
              <div class="min-w-0">
                <h1 class="text-xl font-bold">
                  {@entry.name}<span :if={@entry.shiny_of}> ✨</span>
                </h1>
                <p class="mt-1 flex flex-wrap gap-1.5 font-mono text-[11px]">
                  <span :if={@entry.number} class="rounded bg-[#161b1f] px-1.5 py-0.5 text-[#aeb6bd]">
                    #{@entry.number}
                  </span>
                  <span class="rounded bg-[#161b1f] px-1.5 py-0.5 text-[#aeb6bd]">
                    lv {@entry.level || "?"}
                  </span>
                  <.element_chip :for={el <- @entry.elements} element={el} />
                  <span :if={@entry.clans != []} id="entry-clans" class="contents">
                    <.link
                      :for={clan <- @entry.clans}
                      navigate={~p"/pokedex?#{%{"clans" => [clan]}}"}
                      title={"ver todos do clã #{clan}"}
                      class="rounded px-1.5 py-0.5 transition hover:ring-1 hover:ring-[#37d07d]/60"
                      style={PokedexStyle.clan_style(clan)}
                    >
                      ⚑ {clan}
                    </.link>
                  </span>
                  <span :if={@entry.boost} class="rounded bg-[#211b0d] px-1.5 py-0.5 text-[#f3ba4e]">
                    boost {@entry.boost}
                  </span>
                </p>
                <p class="mt-1 font-mono text-[9px] text-[#59636b]">
                  <span :if={@entry.edited_at}>wiki editada em {@entry.edited_at} ·</span>
                  <.link
                    id="wiki-link"
                    href={Pokedex.wiki_url(@entry)}
                    target="_blank"
                    rel="noopener"
                    class="underline hover:text-white"
                  >
                    ver na wiki ↗
                  </.link>
                </p>
              </div>
            </div>
            <p
              :if={@entry.description}
              id="entry-description"
              class="mt-3 border-l-2 border-[#293238] pl-3 text-[12px] italic leading-relaxed text-[#9aa3aa]"
            >
              {@entry.description}
            </p>
          </section>

          <section id="entry-team-context" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                ⚔️ contra o TEU time
              </h2>
              <span
                :if={@membership == :team}
                id="membership-badge"
                class="rounded bg-[#0d3822] px-1.5 py-0.5 font-mono text-[10px] text-[#3de083]"
              >
                🧢 no teu time
              </span>
              <span
                :if={@membership == :bank}
                id="membership-badge"
                class="rounded bg-[#101d24] px-1.5 py-0.5 font-mono text-[10px] text-[#7cc0e8]"
              >
                🏦 no teu banco
              </span>
              <span :if={@membership == nil} class="flex gap-1.5">
                <button
                  phx-click="add_to"
                  phx-value-where="team"
                  class="btn btn-xs h-7 border-0 bg-[#37d07d] px-2.5 text-[11px] font-bold text-[#06140c] hover:bg-[#45dd88]"
                >
                  + time
                </button>
                <button
                  phx-click="add_to"
                  phx-value-where="bank"
                  class="btn btn-xs h-7 border border-[#293238] bg-transparent px-2.5 text-[11px] text-[#c7cdd2] hover:border-[#37d07d]/60 hover:text-white"
                >
                  + banco
                </button>
              </span>
              <.link
                navigate={~p"/time"}
                class="ml-auto font-mono text-[10px] text-[#89939a] underline hover:text-white"
              >
                gerenciar →
              </.link>
            </div>
            <p :if={@matchup == [] and @team_empty?} class="mt-1.5 text-[11px] text-[#7f8992]">
              cadastra teu time em /time e eu te digo aqui quem fere quem
            </p>
            <p :if={@matchup == [] and not @team_empty?} class="mt-1.5 text-[11px] text-[#7f8992]">
              nenhum matchup relevante com o teu time — luta neutra
            </p>
            <ul :if={@matchup != []} id="entry-matchup" class="mt-1.5 space-y-1">
              <li
                :for={row <- @matchup}
                class="flex flex-wrap items-center gap-1.5 font-mono text-[10px]"
              >
                <.link navigate={~p"/pokedex/#{row.name}"} class="font-semibold hover:underline">
                  {row.name}
                </.link>
                <span :if={row.fere != []} class="rounded bg-[#0d3822] px-1.5 py-0.5 text-[#3de083]">
                  fere ele com {Enum.join(row.fere, "+")}
                </span>
                <span :if={row.sofre != []} class="rounded bg-[#241114] px-1.5 py-0.5 text-[#ff9ca4]">
                  APANHA de {Enum.join(row.sofre, "+")}
                </span>
                <span :if={row.nulo != []} class="rounded bg-[#1c1a12] px-1.5 py-0.5 text-[#e0c46a]">
                  {Enum.join(row.nulo, "+")} não fere ele
                </span>
              </li>
            </ul>
          </section>

          <div class="grid gap-3 lg:grid-cols-3 lg:items-start">
            <section
              :if={@entry.moves in [nil, []]}
              id="entry-moves-missing"
              class="rounded-lg border border-[#232b30] bg-[#111519] p-3 lg:col-span-2"
            >
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                ⚔️ movimentos
              </h2>
              <p class="text-[12px] text-[#9aa3aa]">
                sem tabela de golpes por aqui.
                <.link
                  href={Pokedex.wiki_url(@entry)}
                  target="_blank"
                  rel="noopener"
                  class="text-[#7cc0e8] underline hover:text-white"
                >
                  conferir na wiki ↗
                </.link>
              </p>
            </section>

            <section
              :if={@entry.moves not in [nil, []]}
              id="entry-moves"
              class="rounded-lg border border-[#232b30] bg-[#111519] p-3 lg:col-span-2"
            >
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                ⚔️ movimentos <span class="text-[#3de083]">PVE</span>
                <span class="font-normal normal-case tracking-normal text-[#59636b]">
                  (caçada)
                </span>
              </h2>
              <.moves_table moves={@entry.moves} />

              <details :if={@entry.moves_pvp not in [nil, []]} id="entry-moves-pvp" class="mt-2 group">
                <summary class="cursor-pointer list-none font-mono text-[10px] uppercase tracking-[0.12em] text-[#69737b] hover:text-[#9aa3aa] [&::-webkit-details-marker]:hidden">
                  ▸ moveset PVP
                  <span class="font-normal normal-case tracking-normal text-[#59636b]">
                    — mesmos golpes, cooldowns diferentes
                  </span>
                </summary>
                <div class="mt-1.5 opacity-80">
                  <.moves_table moves={@entry.moves_pvp} />
                </div>
              </details>
            </section>

            <div class="space-y-3">
              <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
                <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                  efetividades
                </h2>
                <p class="mb-0.5 font-mono text-[9px] text-[#59636b]">bate FORTE nele</p>
                <p :if={@entry.weak_to == []} class="text-[11px] text-[#7f8992]">nada mapeado</p>
                <div :for={tier <- tiers(@entry, "weak", @entry.weak_to)}>
                  <p :if={tier.label} class="font-mono text-[9px] text-[#59636b] opacity-70">
                    {tier.label}
                  </p>
                  <p class="flex flex-wrap gap-1">
                    <.element_chip
                      :for={el <- tier.elements}
                      element={el}
                      class="px-1.5 py-0.5 text-[10px]"
                    />
                  </p>
                </div>

                <p class="mb-0.5 mt-2 font-mono text-[9px] text-[#59636b]">ele RESISTE</p>
                <p :if={@entry.resists == []} class="text-[11px] text-[#7f8992]">nada mapeado</p>
                <div :for={tier <- tiers(@entry, "resists", @entry.resists)}>
                  <p :if={tier.label} class="font-mono text-[9px] text-[#59636b] opacity-70">
                    {tier.label}
                  </p>
                  <p class="flex flex-wrap gap-1 opacity-70">
                    <.element_chip
                      :for={el <- tier.elements}
                      element={el}
                      class="px-1.5 py-0.5 text-[10px]"
                    />
                  </p>
                </div>

                <div :if={@entry.immune != []} id="entry-immune">
                  <p class="mb-0.5 mt-2 font-mono text-[9px] text-[#59636b]">
                    NÃO sente (nulo)
                  </p>
                  <p class="flex flex-wrap gap-1 opacity-50">
                    <.element_chip
                      :for={el <- @entry.immune}
                      element={el}
                      class="px-1.5 py-0.5 text-[10px] line-through"
                    />
                  </p>
                </div>

                <details :if={@entry.neutral != []} id="entry-neutral" class="mt-2">
                  <summary class="cursor-pointer list-none font-mono text-[9px] text-[#59636b] hover:text-[#9aa3aa] [&::-webkit-details-marker]:hidden">
                    ▸ dano neutro ({length(@entry.neutral)})
                  </summary>
                  <p class="mt-1 flex flex-wrap gap-1 opacity-60">
                    <.element_chip
                      :for={el <- @entry.neutral}
                      element={el}
                      class="px-1 py-0.5 text-[9px]"
                    />
                  </p>
                </details>
              </section>

              <section
                :if={@entry.habilidades != [] or @entry.evolution_stones != [] or @entry.materia}
                id="entry-info"
                class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
              >
                <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                  habilidades &amp; itens
                </h2>
                <div class="space-y-1.5">
                  <p :if={@entry.habilidades != []} class="flex flex-wrap items-center gap-1">
                    <span class="font-mono text-[9px] text-[#59636b]">🏄 habilidades</span>
                    <span
                      :for={hab <- @entry.habilidades}
                      class="rounded bg-[#101d24] px-1.5 py-0.5 font-mono text-[11px] text-[#7cc0e8]"
                    >
                      {hab}
                    </span>
                  </p>
                  <p :if={@entry.evolution_stones != []} class="flex flex-wrap items-center gap-1">
                    <span class="font-mono text-[9px] text-[#59636b]">💎 pedra</span>
                    <span
                      :for={stone <- @entry.evolution_stones}
                      class="rounded bg-[#211b0d] px-1.5 py-0.5 font-mono text-[11px] text-[#f3ba4e]"
                    >
                      {stone}
                    </span>
                  </p>
                  <p :if={@entry.materia} class="flex items-center gap-1">
                    <span class="font-mono text-[9px] text-[#59636b]">🧪 matéria</span>
                    <span class="rounded bg-[#161b1f] px-1.5 py-0.5 font-mono text-[11px] text-[#aeb6bd]">
                      {@entry.materia}
                    </span>
                  </p>
                </div>
              </section>

              <section
                :if={@lures != []}
                id="entry-lures"
                class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
              >
                <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                  🎣 vem nestas iscas
                </h2>
                <p class="flex flex-wrap gap-1">
                  <span
                    :for={lure <- @lures}
                    class="rounded bg-[#101d24] px-1.5 py-0.5 font-mono text-[11px] text-[#7cc0e8]"
                  >
                    {lure.lure} · lv {lure.fishing_level}
                  </span>
                </p>
              </section>
            </div>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 sm:items-start">
            <section
              :if={@entry.evolutions != []}
              id="entry-evolutions"
              class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
            >
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                evoluções
              </h2>
              <p class="flex flex-wrap items-center gap-1.5">
                <.link
                  :for={evo <- @entry.evolutions}
                  patch={~p"/pokedex/#{evo.name}"}
                  class="rounded-lg border border-[#293238] bg-[#101418] px-2 py-1 text-xs hover:border-[#37d07d]/60 hover:text-white"
                >
                  {evo.name}
                  <span :if={evo.level} class="font-mono text-[9px] text-[#737d85]">lv {evo.level}</span>
                </.link>
              </p>
            </section>

            <section
              :if={@shiny || @base}
              id="entry-shiny-links"
              class="rounded-lg border border-[#674f20] bg-[#211b0d] p-3"
            >
              <.link
                :if={@shiny}
                patch={~p"/pokedex/#{@shiny.name}"}
                class="text-sm font-semibold text-[#f3ba4e] underline hover:text-[#ffd27a]"
              >
                ✨ ver {@shiny.name} (lv {@shiny.level || "?"})
              </.link>
              <.link
                :if={@base}
                patch={~p"/pokedex/#{@base.name}"}
                class="text-sm font-semibold text-[#f3ba4e] underline hover:text-[#ffd27a]"
              >
                ver a forma base: {@base.name} (lv {@base.level || "?"})
              </.link>
            </section>
          </div>
        </article>
      </div>
    </Layouts.app>
    """
  end
end
