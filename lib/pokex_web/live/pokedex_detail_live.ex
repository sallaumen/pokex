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

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Team

  @impl true
  def mount(_params, _session, socket),
    do: {:ok, assign(socket, species_names: Enum.map(Pokedex.search(%{}), & &1.name))}

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
        fere != [] or sofre != [] do
      %{name: name, fere: fere, sofre: sofre}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-[#080b0d] px-3 py-4 text-[#d9dde1]">
      <div class="mx-auto max-w-[720px] space-y-3">
        <header class="flex flex-wrap items-center justify-between gap-2">
          <.link
            navigate={~p"/pokedex"}
            class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
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
              class="input input-bordered h-8 w-44 bg-[#090d0f] font-mono text-xs"
            />
            <datalist id="species-names">
              <option :for={name <- @species_names} value={name} />
            </datalist>
            <button class="btn h-8 border border-[#293238] bg-transparent px-2.5 text-xs text-[#c7cdd2] hover:border-[#37d07d]/60 hover:text-white">
              ir
            </button>
            <span :if={@jump_msg} id="jump-msg" class="font-mono text-[10px] text-[#e7ca82]">
              {@jump_msg}
            </span>
          </form>
          <.link
            navigate={~p"/"}
            class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
          >
            painel
          </.link>
        </header>

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
                  <span
                    :for={el <- @entry.elements}
                    class="rounded bg-[#101d24] px-1.5 py-0.5 text-[#7cc0e8]"
                  >
                    {el}
                  </span>
                  <span :if={@entry.boost} class="rounded bg-[#211b0d] px-1.5 py-0.5 text-[#f3ba4e]">
                    boost {@entry.boost}
                  </span>
                </p>
                <p :if={@entry.edited_at} class="mt-1 font-mono text-[9px] text-[#59636b]">
                  wiki editada em {@entry.edited_at}
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
              </li>
            </ul>
          </section>

          <section
            :if={@entry.moves == nil}
            id="entry-moves-stale"
            class="rounded-lg border border-[#674f20] bg-[#211b0d] p-3 text-[11px] text-[#e7ca82]"
          >
            🔄 Esta entrada é de antes da colheita de movimentos — sincroniza a wiki (só
            "{@entry.name}" leva segundos) pra puxar movimentos, habilidades e descrição.
          </section>

          <section
            :if={@entry.moves != nil}
            id="entry-moves"
            class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
          >
            <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
              movimentos
            </h2>
            <p :if={@entry.moves == []} class="text-[11px] text-[#7f8992]">
              a página da wiki não tem tabela de movimentos
            </p>
            <ul class="space-y-1">
              <li
                :for={move <- @entry.moves}
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
                <span
                  :if={move.element}
                  class="rounded bg-[#101d24] px-1.5 py-0.5 font-mono text-[10px] text-[#7cc0e8]"
                >
                  {move.element}
                </span>
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
                <span :if={move.level} class="font-mono text-[9px] text-[#59636b]">
                  lv {move.level}
                </span>
              </li>
            </ul>
          </section>

          <div class="grid gap-3 sm:grid-cols-3">
            <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                bate FORTE nele
              </h2>
              <p :if={@entry.weak_to == []} class="text-[11px] text-[#7f8992]">nada mapeado</p>
              <p class="flex flex-wrap gap-1">
                <span
                  :for={el <- @entry.weak_to}
                  class="rounded bg-[#0d3822] px-1.5 py-0.5 font-mono text-[11px] text-[#3de083]"
                >
                  {el}
                </span>
              </p>
            </section>

            <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                ele RESISTE
              </h2>
              <p :if={@entry.resists == []} class="text-[11px] text-[#7f8992]">nada mapeado</p>
              <p class="flex flex-wrap gap-1">
                <span
                  :for={el <- @entry.resists}
                  class="rounded bg-[#241114] px-1.5 py-0.5 font-mono text-[11px] text-[#ff9ca4]"
                >
                  {el}
                </span>
              </p>
            </section>

            <section
              :if={@entry.neutral != []}
              id="entry-neutral"
              class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
            >
              <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
                dano neutro
              </h2>
              <p class="flex flex-wrap gap-1">
                <span
                  :for={el <- @entry.neutral}
                  class="rounded bg-[#161b1f] px-1.5 py-0.5 font-mono text-[10px] text-[#737d85]"
                >
                  {el}
                </span>
              </p>
            </section>
          </div>

          <section
            :if={@entry.habilidades != [] or @entry.evolution_stones != [] or @entry.materia}
            id="entry-info"
            class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
          >
            <h2 class="mb-1.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
              habilidades &amp; itens
            </h2>
            <div class="flex flex-wrap items-center gap-x-4 gap-y-1.5">
              <p :if={@entry.habilidades != []} class="flex flex-wrap items-center gap-1">
                <span class="font-mono text-[9px] text-[#59636b]">habilidades</span>
                <span
                  :for={hab <- @entry.habilidades}
                  class="rounded bg-[#101d24] px-1.5 py-0.5 font-mono text-[11px] text-[#7cc0e8]"
                >
                  {hab}
                </span>
              </p>
              <p :if={@entry.evolution_stones != []} class="flex flex-wrap items-center gap-1">
                <span class="font-mono text-[9px] text-[#59636b]">pedra de evolução</span>
                <span
                  :for={stone <- @entry.evolution_stones}
                  class="rounded bg-[#211b0d] px-1.5 py-0.5 font-mono text-[11px] text-[#f3ba4e]"
                >
                  {stone}
                </span>
              </p>
              <p :if={@entry.materia} class="flex items-center gap-1">
                <span class="font-mono text-[9px] text-[#59636b]">matéria</span>
                <span class="rounded bg-[#161b1f] px-1.5 py-0.5 font-mono text-[11px] text-[#aeb6bd]">
                  {@entry.materia}
                </span>
              </p>
            </div>
          </section>

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
                {lure.lure} · pesca lv {lure.fishing_level}
              </span>
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
        </article>
      </div>
    </div>
    """
  end
end
