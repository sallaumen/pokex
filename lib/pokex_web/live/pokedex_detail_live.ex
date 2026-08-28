defmodule PokexWeb.PokedexDetailLive do
  @moduledoc """
  One Pokémon, one page (`/pokedex/:name`): the click-through Lucas asked
  for — explore an individual Pokémon with easy back navigation and a snappy
  feel. Pure `Pokedex.get/1` + `variant_of/2` reads — nothing heavy — and
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

  # "Is it on my team?" and the matchup against the team are the ACTIVE
  # character's answers — switching character changes both on this page.
  @impl PokexWeb.CharacterAware
  def on_character_change(%{assigns: %{entry: %{name: name}}} = socket),
    do: assign_entry(socket, name)

  def on_character_change(%{assigns: %{missing_name: name}} = socket),
    do: assign_entry(socket, name)

  def on_character_change(socket), do: socket

  # handle_params (not mount) owns the lookup so evolution/shiny links between
  # detail pages patch in place — no full remount, stays snappy.
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

  defp assign_entry(socket, name), do: assign(socket, entry_assigns(Pokedex.get(name), name))

  # A name the Pokédex does not know still renders a page — every field just
  # answers "nothing", and `missing_name` is what the page complains about.
  defp entry_assigns(nil, name) do
    [
      page_title: "Pokédex",
      entry: nil,
      missing_name: name,
      base: nil,
      shiny: nil,
      membership: nil,
      matchup: [],
      team_empty?: Team.members() == []
    ]
  end

  defp entry_assigns(entry, _name) do
    [
      page_title: entry.name,
      entry: entry,
      missing_name: nil,
      base: entry.variant == "shiny" && Pokedex.variant_of(entry, "normal"),
      shiny: entry.variant == "normal" && Pokedex.variant_of(entry, "shiny"),
      membership: membership(entry.name),
      matchup: matchup(entry),
      team_empty?: Team.members() == []
    ]
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
        # "Nulo" on the wiki: that element takes not ONE hit point from it —
        # the worst possible hunt surprise, so it enters the matchup as a
        # warning
        nulo = Enum.filter(member.elements, &(&1 in entry.immune)),
        fere != [] or sofre != [] or nulo != [] do
      %{name: name, fere: fere, sofre: sofre, nulo: nulo}
    end
  end

  # The chart answers in tiers of different strength — Grass/Poison has BOTH
  # "Inefetivo" and "Muito Inefetivo" — so show the tiers apart, labelled as
  # the old wiki pages worded them. A single tier collapses back to one
  # unlabelled row.
  defp tiers(entry, kind, fallback) do
    case Enum.filter(entry.effectiveness, &(&1.kind == kind and &1.elements != [])) do
      [] -> [%{label: nil, elements: fallback}]
      [only] -> [%{only | label: nil}]
      many -> many
    end
  end

  # Both directions in one list, each row labelled — the wiki publishes
  # "Evolui de" and "Pode evoluir para" separately, and a species can have both.
  defp evolution_rows(entry) do
    Enum.map(entry.evolves_from, &{"evolui de", &1}) ++
      Enum.map(entry.evolves_to, &{"evolui para", &1})
  end

  attr :element, :string, required: true
  attr :class, :string, default: "px-1.5 py-0.5 text-pk-body"

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
        class="flex flex-wrap items-center gap-1.5 rounded-lg border border-pk-line bg-pk-raised px-2.5 py-1.5"
      >
        <span class={[
          "w-7 shrink-0 rounded px-1 py-0.5 text-center font-mono text-pk-meta font-bold",
          if(move.slot == "P",
            do: "bg-pk-warn-dim text-pk-warn",
            else: "bg-pk-raised text-pk-text-2"
          )
        ]}>
          {move.slot}
        </span>
        <span class="min-w-0 flex-1 truncate text-pk-body font-semibold">{move.name}</span>
        <.element_chip :if={move.element} element={move.element} class="px-1.5 py-0.5 text-pk-meta" />
        <span
          :if={move.cooldown_s}
          class="rounded bg-pk-warn-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-warn"
        >
          ⏱ {move.cooldown_s}s
        </span>
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
        <%!-- Back-to-list and jump-to-species are THIS page's actions, not app
              navigation: they live here in the body, under the standard header. --%>
        <section class="flex flex-wrap items-center gap-3">
          <.link
            navigate={~p"/pokedex"}
            class="font-mono text-pk-body text-pk-text-2 underline hover:text-white"
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
              class="input input-bordered h-8 w-44 bg-pk-sunken font-mono text-pk-meta"
            />
            <datalist id="species-names">
              <option :for={name <- @species_names} value={name} />
            </datalist>
            <button class="btn h-8 border border-pk-line-strong bg-transparent px-2.5 text-pk-meta text-pk-text-2 hover:border-pk-ok/60 hover:text-white">
              ir
            </button>
            <span :if={@jump_msg} id="jump-msg" class="font-mono text-pk-meta text-pk-warn">
              {@jump_msg}
            </span>
          </form>
        </section>

        <section
          :if={@entry == nil}
          id="entry-missing"
          class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-4 text-pk-body text-pk-warn"
        >
          Não achei "{@missing_name}" na Pokédex — confere o nome ou sincroniza a wiki.
        </section>

        <article :if={@entry} id="entry-card" class="space-y-3">
          <section class="rounded-lg border border-pk-line bg-pk-surface p-4">
            <div class="flex items-center gap-4">
              <img
                :if={@entry.sprite}
                src={"/" <> @entry.sprite}
                alt={@entry.name}
                onerror="this.style.display='none'"
                class="size-20 shrink-0 object-contain"
              />
              <div class="min-w-0">
                <h1 class="text-pk-title font-bold">
                  {@entry.name}<span :if={@entry.variant == "shiny"}> ✨</span>
                </h1>
                <p class="mt-1 flex flex-wrap gap-1.5 font-mono text-pk-body">
                  <span :if={@entry.number} class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2">
                    #{@entry.number}
                  </span>
                  <span class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2">
                    lv {@entry.level || "?"}
                  </span>
                  <.element_chip :for={el <- @entry.elements} element={el} />
                  <.link
                    :if={@entry.tier}
                    id="entry-tier"
                    navigate={~p"/pokedex?#{%{"tiers" => [@entry.tier]}}"}
                    title={"ver todos do tier #{@entry.tier}"}
                    class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2 transition hover:ring-1 hover:ring-pk-ok/60"
                  >
                    🏅 tier {@entry.tier}
                  </.link>
                  <.link
                    :if={@entry.generation}
                    id="entry-generation"
                    navigate={~p"/pokedex?#{%{"generations" => [@entry.generation]}}"}
                    title={"ver todos da geração #{@entry.generation}"}
                    class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2 transition hover:ring-1 hover:ring-pk-ok/60"
                  >
                    gen {@entry.generation}
                  </.link>
                  <span :if={@entry.role} class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2">
                    🎯 {@entry.role}
                  </span>
                  <span
                    :if={@entry.hp}
                    id="entry-hp"
                    class="rounded bg-pk-warn-dim px-1.5 py-0.5 text-pk-warn"
                  >
                    ❤️ {@entry.hp}
                  </span>
                  <span
                    :if={@entry.experience}
                    class="rounded bg-pk-raised px-1.5 py-0.5 text-pk-text-2"
                  >
                    ⭐ {@entry.experience}
                  </span>
                </p>
                <p class="mt-1 font-mono text-pk-meta text-pk-text-3">
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
              class="mt-3 border-l-2 border-pk-line pl-3 text-pk-body italic leading-relaxed text-pk-text-2"
            >
              {@entry.description}
            </p>
          </section>

          <section id="entry-team-context" class="rounded-lg border border-pk-line bg-pk-surface p-3">
            <div class="flex flex-wrap items-center gap-2">
              <h2 class="font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                ⚔️ contra o TEU time
              </h2>
              <span
                :if={@membership == :team}
                id="membership-badge"
                class="rounded bg-pk-ok-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-ok"
              >
                🧢 no teu time
              </span>
              <span
                :if={@membership == :bank}
                id="membership-badge"
                class="rounded bg-pk-info-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-info"
              >
                🏦 no teu banco
              </span>
              <span :if={@membership == nil} class="flex gap-1.5">
                <button
                  phx-click="add_to"
                  phx-value-where="team"
                  class="btn btn-xs h-7 border-0 bg-pk-ok px-2.5 text-pk-body font-bold text-pk-bg hover:bg-pk-ok/90"
                >
                  + time
                </button>
                <button
                  phx-click="add_to"
                  phx-value-where="bank"
                  class="btn btn-xs h-7 border border-pk-line bg-transparent px-2.5 text-pk-body text-pk-text hover:border-pk-ok/60 hover:text-white"
                >
                  + banco
                </button>
              </span>
              <.link
                navigate={~p"/time"}
                class="ml-auto font-mono text-pk-meta text-pk-text-2 underline hover:text-white"
              >
                gerenciar →
              </.link>
            </div>
            <p :if={@matchup == [] and @team_empty?} class="mt-1.5 text-pk-body text-pk-text-2">
              cadastra teu time em /time e eu te digo aqui quem fere quem
            </p>
            <p :if={@matchup == [] and not @team_empty?} class="mt-1.5 text-pk-body text-pk-text-2">
              nenhum matchup relevante com o teu time — luta neutra
            </p>
            <ul :if={@matchup != []} id="entry-matchup" class="mt-1.5 space-y-1">
              <li
                :for={row <- @matchup}
                class="flex flex-wrap items-center gap-1.5 font-mono text-pk-meta"
              >
                <.link navigate={~p"/pokedex/#{row.name}"} class="font-semibold hover:underline">
                  {row.name}
                </.link>
                <span :if={row.fere != []} class="rounded bg-pk-ok-dim px-1.5 py-0.5 text-pk-ok">
                  fere ele com {Enum.join(row.fere, "+")}
                </span>
                <span
                  :if={row.sofre != []}
                  class="rounded bg-pk-danger-dim px-1.5 py-0.5 text-pk-danger"
                >
                  APANHA de {Enum.join(row.sofre, "+")}
                </span>
                <span :if={row.nulo != []} class="rounded bg-pk-warn-dim px-1.5 py-0.5 text-pk-warn">
                  {Enum.join(row.nulo, "+")} não fere ele
                </span>
              </li>
            </ul>
          </section>

          <div class="grid gap-3 lg:grid-cols-3 lg:items-start">
            <section
              :if={@entry.moves in [nil, []]}
              id="entry-moves-missing"
              class="rounded-lg border border-pk-line bg-pk-surface p-3 lg:col-span-2"
            >
              <h2 class="mb-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                ⚔️ movimentos
              </h2>
              <p class="text-pk-body text-pk-text-2">
                sem tabela de golpes por aqui.
                <.link
                  href={Pokedex.wiki_url(@entry)}
                  target="_blank"
                  rel="noopener"
                  class="text-pk-info underline hover:text-white"
                >
                  conferir na wiki ↗
                </.link>
              </p>
            </section>

            <section
              :if={@entry.moves not in [nil, []]}
              id="entry-moves"
              class="rounded-lg border border-pk-line bg-pk-surface p-3 lg:col-span-2"
            >
              <h2 class="mb-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                ⚔️ movimentos <span class="text-pk-ok">PVE</span>
                <span class="font-normal normal-case tracking-normal text-pk-text-3">
                  (caçada)
                </span>
              </h2>
              <.moves_table moves={@entry.moves} />
            </section>

            <div class="space-y-3">
              <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
                <h2 class="mb-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  efetividades
                </h2>
                <p class="mb-0.5 font-mono text-pk-meta text-pk-text-3">bate FORTE nele</p>
                <p :if={@entry.weak_to == []} class="text-pk-body text-pk-text-2">nada mapeado</p>
                <div :for={tier <- tiers(@entry, "weak", @entry.weak_to)}>
                  <p :if={tier.label} class="font-mono text-pk-meta text-pk-text-3 opacity-70">
                    {tier.label}
                  </p>
                  <p class="flex flex-wrap gap-1">
                    <.element_chip
                      :for={el <- tier.elements}
                      element={el}
                      class="px-1.5 py-0.5 text-pk-meta"
                    />
                  </p>
                </div>

                <p class="mb-0.5 mt-2 font-mono text-pk-meta text-pk-text-3">ele RESISTE</p>
                <p :if={@entry.resists == []} class="text-pk-body text-pk-text-2">nada mapeado</p>
                <div :for={tier <- tiers(@entry, "resists", @entry.resists)}>
                  <p :if={tier.label} class="font-mono text-pk-meta text-pk-text-3 opacity-70">
                    {tier.label}
                  </p>
                  <p class="flex flex-wrap gap-1 opacity-70">
                    <.element_chip
                      :for={el <- tier.elements}
                      element={el}
                      class="px-1.5 py-0.5 text-pk-meta"
                    />
                  </p>
                </div>

                <div :if={@entry.immune != []} id="entry-immune">
                  <p class="mb-0.5 mt-2 font-mono text-pk-meta text-pk-text-3">
                    NÃO sente (nulo)
                  </p>
                  <p class="flex flex-wrap gap-1 opacity-50">
                    <.element_chip
                      :for={el <- @entry.immune}
                      element={el}
                      class="px-1.5 py-0.5 text-pk-meta line-through"
                    />
                  </p>
                </div>

                <details :if={@entry.neutral != []} id="entry-neutral" class="mt-2">
                  <summary class="cursor-pointer list-none font-mono text-pk-meta text-pk-text-3 hover:text-pk-text-2 [&::-webkit-details-marker]:hidden">
                    ▸ dano neutro ({length(@entry.neutral)})
                  </summary>
                  <p class="mt-1 flex flex-wrap gap-1 opacity-60">
                    <.element_chip
                      :for={el <- @entry.neutral}
                      element={el}
                      class="px-1 py-0.5 text-pk-meta"
                    />
                  </p>
                </details>
              </section>

              <section
                :if={@entry.habilidades != []}
                id="entry-info"
                class="rounded-lg border border-pk-line bg-pk-surface p-3"
              >
                <h2 class="mb-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                  habilidades
                </h2>
                <div class="space-y-1.5">
                  <p :if={@entry.habilidades != []} class="flex flex-wrap items-center gap-1">
                    <span class="font-mono text-pk-meta text-pk-text-3">🏄 habilidades</span>
                    <span
                      :for={hab <- @entry.habilidades}
                      class="rounded bg-pk-info-dim px-1.5 py-0.5 font-mono text-pk-body text-pk-info"
                    >
                      {hab}
                    </span>
                  </p>
                </div>
              </section>
            </div>
          </div>

          <div class="grid gap-3 sm:grid-cols-2 sm:items-start">
            <section
              :if={@entry.evolves_from != [] or @entry.evolves_to != []}
              id="entry-evolutions"
              class="rounded-lg border border-pk-line bg-pk-surface p-3"
            >
              <h2 class="mb-1.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
                evoluções
              </h2>
              <div class="space-y-1.5">
                <p
                  :for={{label, evo} <- evolution_rows(@entry)}
                  class="flex flex-wrap items-center gap-1.5"
                >
                  <span class="font-mono text-pk-meta text-pk-text-3">{label}</span>
                  <.link
                    patch={~p"/pokedex/#{evo.name}"}
                    class="rounded-lg border border-pk-line bg-pk-raised px-2 py-1 text-pk-meta hover:border-pk-ok/60 hover:text-white"
                  >
                    {evo.name}
                    <span :if={evo.level} class="font-mono text-pk-meta text-pk-text-3">
                      lv {evo.level}
                    </span>
                  </.link>
                  <span
                    :for={item <- evo.items}
                    class="rounded bg-pk-warn-dim px-1.5 py-0.5 font-mono text-pk-meta text-pk-warn"
                  >
                    💎 {item}
                  </span>
                </p>
              </div>
            </section>

            <section
              :if={@shiny || @base}
              id="entry-shiny-links"
              class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-3"
            >
              <.link
                :if={@shiny}
                patch={~p"/pokedex/#{@shiny.name}"}
                class="text-pk-body font-semibold text-pk-warn underline hover:text-pk-warn"
              >
                ✨ ver {@shiny.name} (lv {@shiny.level || "?"})
              </.link>
              <.link
                :if={@base}
                patch={~p"/pokedex/#{@base.name}"}
                class="text-pk-body font-semibold text-pk-warn underline hover:text-pk-warn"
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
