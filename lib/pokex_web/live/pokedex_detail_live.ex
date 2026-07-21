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

  @impl true
  def mount(_params, _session, socket), do: {:ok, socket}

  # handle_params (not mount) owns the lookup so evolution/shiny links between
  # detail pages patch in place — no full remount, "bem ágil".
  @impl true
  def handle_params(%{"name" => name}, _uri, socket) do
    entry = Pokedex.get(name)

    {:noreply,
     assign(socket,
       page_title: (entry && entry.name) || "Pokédex",
       entry: entry,
       missing_name: unless(entry, do: name),
       lures: (entry && Pokedex.lures_for(entry.name)) || [],
       base: entry && entry.shiny_of && Pokedex.get(entry.shiny_of),
       shiny: entry && entry.shiny_name && Pokedex.get(entry.shiny_name)
     )}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="min-h-dvh bg-[#080b0d] px-3 py-4 text-[#d9dde1]">
      <div class="mx-auto max-w-[720px] space-y-3">
        <header class="flex items-center justify-between gap-2">
          <.link
            navigate={~p"/pokedex"}
            class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
          >
            ← pokédex
          </.link>
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
          </section>

          <div class="grid gap-3 sm:grid-cols-2">
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
          </div>

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
