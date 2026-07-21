defmodule PokexWeb.PokedexLive do
  @moduledoc """
  The local Pokédex (scraped from the PXG wiki by `mix pokedex.scrape`):
  Lucas's queryable base — search by name, element, WEAKNESS ("quais têm
  fraqueza de planta?") and level — plus the per-lure view that answers
  "pescando com ESTA isca, quais Shinies podem vir?". Every card links into
  `/pokedex/:name`; the team and its hunt suggestions live on `/time`.
  """
  use PokexWeb, :live_view

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Sync
  alias PokexWeb.PanelForms

  @results_cap 120

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pokex.PubSub, Sync.topic())

    {:ok,
     assign(socket,
       page_title: "Pokédex",
       sync_running?: Sync.running?(),
       sync_msg: nil,
       loaded?: Pokedex.loaded?(),
       elements: Pokedex.elements(),
       lures: Pokedex.lures(),
       species_names: Enum.map(Pokedex.search(%{}), & &1.name),
       form: filter_form(%{}),
       results: Pokedex.search(%{}),
       selected_lure: nil
     )}
  end

  @impl true
  def handle_event("filter", %{"f" => params}, socket) do
    filters =
      %{
        name: params["name"] || "",
        element: params["element"] || "",
        weak_to: params["weak_to"] || "",
        only_shiny: params["only_shiny"] == "true",
        edited_after: params["edited_after"] || ""
      }
      |> put_level(:min_level, params["min_level"])
      |> put_level(:max_level, params["max_level"])

    {:noreply, assign(socket, results: Pokedex.search(filters), form: filter_form(params))}
  end

  def handle_event("select_lure", %{"lure" => name}, socket) do
    lure = Enum.find(socket.assigns.lures, &(&1.name == name))
    {:noreply, assign(socket, selected_lure: lure)}
  end

  # The sync button: empty names = full run; names = surgical refresh. One
  # sync at a time — the double-click loser just sees the running state.
  def handle_event("sync_wiki", %{"only" => only}, socket) do
    case Sync.start(only: String.trim(only)) do
      :ok ->
        {:noreply, assign(socket, sync_running?: true, sync_msg: "sincronizando…")}

      {:error, :already_running} ->
        {:noreply, assign(socket, sync_running?: true, sync_msg: "já tem um sync rodando")}
    end
  end

  @impl true
  def handle_info({:pokedex_sync, {:progress, text}}, socket),
    do: {:noreply, assign(socket, sync_running?: true, sync_msg: text)}

  def handle_info({:pokedex_sync, {:done, summary}}, socket) do
    # the dataset was reloaded by the sync task — refresh EVERYTHING derived
    socket =
      socket
      |> assign(
        sync_running?: false,
        sync_msg:
          "sincronizado: #{summary.updated} atualizadas, #{summary.base} na base " <>
            "(#{summary.shinies} shinies)",
        loaded?: Pokedex.loaded?(),
        elements: Pokedex.elements(),
        lures: Pokedex.lures(),
        species_names: Enum.map(Pokedex.search(%{}), & &1.name),
        form: filter_form(%{}),
        results: Pokedex.search(%{}),
        selected_lure: nil
      )

    {:noreply, socket}
  end

  def handle_info({:pokedex_sync, {:failed, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         sync_running?: false,
         sync_msg: "sync falhou: #{String.slice(reason, 0, 200)}"
       )}

  defp put_level(filters, key, raw) do
    case PanelForms.parse_int(raw, 1..999) do
      {:ok, value} -> Map.put(filters, key, value)
      :error -> filters
    end
  end

  defp filter_form(params) do
    to_form(
      %{
        "name" => params["name"] || "",
        "element" => params["element"] || "",
        "weak_to" => params["weak_to"] || "",
        "min_level" => params["min_level"] || "",
        "max_level" => params["max_level"] || "",
        "only_shiny" => params["only_shiny"] || "false",
        "edited_after" => params["edited_after"] || ""
      },
      as: :f
    )
  end

  defp shiny?(name), do: String.starts_with?(name, "Shiny ")

  @impl true
  def render(assigns) do
    assigns = assign(assigns, :capped, Enum.take(assigns.results, @results_cap))

    ~H"""
    <div class="min-h-dvh bg-[#080b0d] px-3 py-4 text-[#d9dde1]">
      <div class="mx-auto max-w-[1080px] space-y-4">
        <header class="flex flex-wrap items-center justify-between gap-2">
          <h1 class="text-lg font-bold">Pokédex</h1>
          <div class="flex items-center gap-3">
            <form id="sync-form" phx-submit="sync_wiki" class="flex items-center gap-2">
              <input
                name="only"
                list="species-names"
                placeholder="só estes nomes (vazio = tudo)"
                autocomplete="off"
                class="input input-bordered h-8 w-52 bg-[#090d0f] font-mono text-xs"
              />
              <button
                disabled={@sync_running?}
                title="raspa a wiki de novo: dados (upsert) + imagens novas. Vazio = base inteira (~10min); com nomes = segundos."
                class="btn h-8 border border-[#293238] bg-transparent px-3 text-xs text-[#c7cdd2] hover:border-[#37d07d]/60 hover:text-white disabled:opacity-40"
              >
                {if @sync_running?, do: "⏳ sincronizando…", else: "🔄 Sincronizar wiki"}
              </button>
            </form>
            <.link
              navigate={~p"/time"}
              class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
            >
              🧢 time
            </.link>
            <.link
              navigate={~p"/"}
              class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
            >
              ← painel
            </.link>
          </div>
        </header>
        <datalist id="species-names">
          <option :for={name <- @species_names} value={name} />
        </datalist>

        <p
          :if={@sync_msg}
          id="sync-status"
          class="rounded-lg border border-[#232b30] bg-[#111519] px-3 py-1.5 font-mono text-[10px] text-[#8b949d]"
        >
          {@sync_msg}
        </p>

        <section
          :if={not @loaded?}
          class="rounded-lg border border-[#674f20] bg-[#211b0d] p-4 text-sm text-[#e7ca82]"
        >
          Sem dados ainda — clica em "🔄 Sincronizar wiki" aí em cima (ou roda
          <code class="font-mono">mix pokedex.scrape</code>
          no terminal) pra popular a base.
        </section>

        <section :if={@loaded?} class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <.form
            for={@form}
            id="pokedex-filter-form"
            phx-change="filter"
            class="flex flex-wrap items-end gap-2 font-mono text-[10px] text-[#77828a]"
          >
            <label class="flex flex-col gap-1">
              nome
              <input
                type="text"
                name="f[name]"
                value={@form[:name].value}
                placeholder="ex.: seadra"
                class="input input-bordered h-9 w-40 bg-[#090d0f] font-mono text-sm"
              />
            </label>
            <label class="flex flex-col gap-1">
              elemento
              <select
                name="f[element]"
                class="select select-bordered h-9 w-32 bg-[#090d0f] font-mono text-sm"
              >
                <option value="">todos</option>
                <option :for={el <- @elements} value={el} selected={@form[:element].value == el}>
                  {el}
                </option>
              </select>
            </label>
            <label class="flex flex-col gap-1" title="ataques deste elemento batem FORTE nele">
              fraco contra
              <select
                name="f[weak_to]"
                class="select select-bordered h-9 w-32 bg-[#090d0f] font-mono text-sm"
              >
                <option value="">—</option>
                <option :for={el <- @elements} value={el} selected={@form[:weak_to].value == el}>
                  {el}
                </option>
              </select>
            </label>
            <label class="flex flex-col gap-1">
              level ≥
              <input
                type="number"
                name="f[min_level]"
                value={@form[:min_level].value}
                class="input input-bordered h-9 w-20 bg-[#090d0f] font-mono text-sm"
              />
            </label>
            <label class="flex flex-col gap-1">
              level ≤
              <input
                type="number"
                name="f[max_level]"
                value={@form[:max_level].value}
                class="input input-bordered h-9 w-20 bg-[#090d0f] font-mono text-sm"
              />
            </label>
            <label
              class="flex flex-col gap-1"
              title="páginas da wiki editadas a partir desta data — bom pra caçar NOVIDADES do PXG"
            >
              wiki editada após
              <input
                type="date"
                name="f[edited_after]"
                value={@form[:edited_after].value}
                class="input input-bordered h-9 w-36 bg-[#090d0f] font-mono text-sm"
              />
            </label>
            <label class="flex h-9 items-center gap-2">
              <input
                type="checkbox"
                name="f[only_shiny]"
                value="true"
                checked={@form[:only_shiny].value == "true"}
                class="checkbox checkbox-warning checkbox-sm"
              /> só shinies ✨
            </label>
          </.form>

          <p id="pokedex-count" class="mt-2 font-mono text-[10px] text-[#737d85]">
            {length(@results)} resultado(s){if length(@results) > length(@capped),
              do: " — mostrando #{length(@capped)}"}
          </p>

          <ul id="pokedex-results" class="mt-2 grid grid-cols-2 gap-1.5 sm:grid-cols-3 lg:grid-cols-4">
            <li :for={entry <- @capped}>
              <.link
                navigate={~p"/pokedex/#{entry.name}"}
                class={[
                  "block rounded-lg border bg-[#101418] px-2.5 py-2 transition hover:border-[#37d07d]/60",
                  if(entry.shiny_of,
                    do: "border-[#674f20]",
                    else: "border-[#232b30]"
                  )
                ]}
              >
                <div class="flex items-center gap-2">
                  <img
                    :if={entry.sprite}
                    src={"/" <> entry.sprite}
                    alt={entry.name}
                    onerror="this.style.display='none'"
                    class="size-8 shrink-0 object-contain"
                    loading="lazy"
                  />
                  <div class="min-w-0">
                    <p
                      class="truncate text-sm font-semibold"
                      title={entry.edited_at && "wiki editada em #{entry.edited_at}"}
                    >
                      {entry.name}<span :if={entry.shiny_of}> ✨</span>
                    </p>
                    <p class="font-mono text-[9px] text-[#737d85]">
                      <span :if={entry.number}>#{entry.number} · </span>lv {entry.level || "?"} · {Enum.join(
                        entry.elements,
                        "/"
                      )}
                    </p>
                  </div>
                </div>
                <p
                  :if={entry.weak_to != []}
                  class="mt-1 truncate font-mono text-[9px] text-[#8b949d]"
                >
                  fraco: {Enum.join(entry.weak_to, ", ")}
                </p>
              </.link>
            </li>
          </ul>
        </section>

        <section
          :if={@loaded? and @lures != []}
          class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
        >
          <div class="flex flex-wrap items-center gap-2">
            <h2 class="text-sm font-semibold">🎣 Por isca</h2>
            <form id="lure-form" phx-change="select_lure">
              <select
                name="lure"
                class="select select-bordered h-9 bg-[#090d0f] font-mono text-sm"
              >
                <option value="">escolhe a isca…</option>
                <option
                  :for={lure <- @lures}
                  value={lure.name}
                  selected={@selected_lure && @selected_lure.name == lure.name}
                >
                  {lure.name}
                </option>
              </select>
            </form>
            <p
              :if={@selected_lure}
              id="lure-shiny-count"
              class="font-mono text-[10px] text-[#e7ca82]"
            >
              ✨ {length(Pokedex.shinies_for_lure(@selected_lure.name))} shiny(s) possível(is) — fica esperto
            </p>
          </div>

          <ul :if={@selected_lure} id="lure-tiers" class="mt-2 space-y-1">
            <li
              :for={tier <- @selected_lure.tiers}
              class="rounded-lg border border-[#232b30] bg-[#101418] px-3 py-2"
            >
              <span class="font-mono text-[10px] text-[#737d85]">pesca lv {tier.fishing_level}:</span>
              <.link
                :for={name <- tier.pokemon}
                navigate={~p"/pokedex/#{name}"}
                class={[
                  "ml-1 inline-block rounded px-1.5 py-0.5 text-[11px] hover:underline",
                  if(shiny?(name),
                    do: "bg-[#211b0d] font-semibold text-[#f3ba4e]",
                    else: "bg-[#161b1f] text-[#aeb6bd]"
                  )
                ]}
              >
                {name}{if shiny?(name), do: " ✨"}
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end
end
