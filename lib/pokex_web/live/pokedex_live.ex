defmodule PokexWeb.PokedexLive do
  @moduledoc """
  The local Pokédex (scraped from the PXG wiki by `mix pokedex.scrape`):
  Lucas's queryable base — search by name, element, WEAKNESS ("quais têm
  fraqueza de planta?") and level — plus the per-lure view that answers
  "pescando com ESTA isca, quais Shinies podem vir?". Every card links into
  `/pokedex/:name`; the team and its hunt suggestions live on `/time`.

  FILTERS LIVE IN THE URL: exploring a card and coming BACK restores the
  exact view (the day-to-day flow), and any filtered view — including the
  per-lure one (`?isca=Shrimp`) — is a shareable, bookmarkable link.

  RESULTS STREAM IN by CURSOR (`Pokedex.page/3`), 100 at a time, appended to a
  LiveView stream as the viewport reaches the bottom — the DOM grows without
  the socket ever holding the whole list, and a filter/sort change resets the
  stream instead of diffing hundreds of cards.
  """
  use PokexWeb, :live_view

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Sync
  alias PokexWeb.PanelForms
  alias PokexWeb.PokedexStyle

  @impl true
  def mount(_params, _session, socket) do
    if connected?(socket), do: Phoenix.PubSub.subscribe(Pokex.PubSub, Sync.topic())

    {:ok,
     socket
     # entries carry no :id — the NAME is the natural unique key
     |> stream(:species, [], dom_id: &("species-" <> dom_slug(&1.name)))
     |> assign(
       page_title: "Pokédex",
       sync_running?: Sync.running?(),
       sync_msg: nil,
       loaded?: Pokedex.loaded?(),
       elements: Pokedex.elements(),
       lures: Pokedex.lures(),
       species_names: Enum.map(Pokedex.search(%{}), & &1.name)
     )}
  end

  # The URL is the single source of filter truth: form changes push_patch the
  # query, and THIS applies it — so browser back/forward and pasted links all
  # land on the exact same view.
  @impl true
  def handle_params(params, _uri, socket) do
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

    sort = sort_atom(params["sort"])
    desc? = params["desc"] == "1"

    filters =
      filters
      |> Map.put(:sort, sort)
      |> Map.put(:desc, desc?)
      |> Map.put(:only_novelty, params["novidades"] == "true")

    page = Pokedex.page(filters)

    {:noreply,
     socket
     |> assign(
       raw_filters:
         Map.take(
           params,
           ~w(name element weak_to min_level max_level only_shiny edited_after sort desc novidades)
         ),
       filters: filters,
       form: filter_form(params),
       sort: sort,
       desc?: desc?,
       only_novelty?: params["novidades"] == "true",
       cursor: page.cursor,
       total: page.total,
       loaded: length(page.entries),
       novelty_count: Enum.count(Pokedex.search(filters), &(Pokedex.novelty(&1) != nil)),
       selected_lure: Enum.find(socket.assigns.lures, &(&1.name == params["isca"]))
     )
     # a new filter/sort is a NEW list — reset instead of diffing the old cards
     |> stream(:species, page.entries, reset: true)}
  end

  # The infinite scroll: the viewport reached the bottom (or he clicked the
  # fallback button) — append the next cursor page. A nil cursor means the
  # list ended, and the binding is not even rendered then.
  def handle_event("load_more", _params, %{assigns: %{cursor: nil}} = socket),
    do: {:noreply, socket}

  def handle_event("load_more", _params, socket) do
    page = Pokedex.page(socket.assigns.filters, socket.assigns.cursor)

    {:noreply,
     socket
     |> assign(
       cursor: page.cursor,
       total: page.total,
       loaded: socket.assigns.loaded + length(page.entries)
     )
     |> stream(:species, page.entries)}
  end

  # The sort control lives in the URL like every other filter: same back/forward,
  # same shareable link. Clicking the ACTIVE sort flips its direction.
  def handle_event("sort", %{"by" => by}, socket) do
    flip? = to_string(socket.assigns.sort) == by and not socket.assigns.desc?

    query =
      socket.assigns.raw_filters
      |> Map.merge(%{"sort" => by, "desc" => if(flip?, do: "1", else: nil)})
      |> Map.put("isca", current_lure_name(socket))
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end

  def handle_event("toggle_novelty", _params, socket) do
    query =
      socket.assigns.raw_filters
      |> Map.put("novidades", if(socket.assigns.only_novelty?, do: nil, else: "true"))
      |> Map.put("isca", current_lure_name(socket))
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end

  @impl true
  def handle_event("filter", %{"f" => params}, socket) do
    keep = Map.take(socket.assigns.raw_filters, ~w(sort desc novidades))

    query =
      params
      |> Map.merge(keep)
      |> Map.put("isca", current_lure_name(socket))
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end

  def handle_event("select_lure", %{"lure" => name}, socket) do
    query = socket.assigns.raw_filters |> Map.put("isca", name) |> clean_query()
    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
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
            "(#{summary.shinies} shinies)" <>
            if(Map.get(summary, :filled, 0) > 0,
              do: " · #{summary.filled} completadas",
              else: ""
            ),
        loaded?: Pokedex.loaded?(),
        elements: Pokedex.elements(),
        lures: Pokedex.lures(),
        species_names: Enum.map(Pokedex.search(%{}), & &1.name)
      )
      |> push_patch(to: ~p"/pokedex?#{clean_query(socket.assigns.raw_filters)}")

    {:noreply, socket}
  end

  def handle_info({:pokedex_sync, {:failed, reason}}, socket),
    do:
      {:noreply,
       assign(socket,
         sync_running?: false,
         sync_msg: "sync falhou: #{String.slice(reason, 0, 200)}"
       )}

  # Only meaningful values reach the URL — clean, shareable links.
  defp clean_query(params) do
    params
    |> Enum.reject(fn {_k, v} -> v in [nil, "", "false"] end)
    |> Map.new()
  end

  defp current_lure_name(socket),
    do: socket.assigns.selected_lure && socket.assigns.selected_lure.name

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

  defp dom_slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  @sorts [
    {:number, "nº"},
    {:name, "nome"},
    {:level, "level"},
    {:element, "tipo"},
    {:weak_to, "fraqueza"},
    {:shiny, "shiny"},
    {:edited, "edição da wiki"},
    {:changed, "mudou aqui"}
  ]

  defp sorts, do: @sorts

  defp sort_atom(raw) do
    Enum.find_value(@sorts, :number, fn {key, _label} ->
      if to_string(key) == raw, do: key
    end)
  end

  # "2026-07-21T14:03:22Z" → "21/07 14h03" (the sync stamp, human-sized)
  defp short_stamp(nil), do: nil

  defp short_stamp(iso) do
    case DateTime.from_iso8601(iso) do
      {:ok, dt, _offset} ->
        :io_lib.format("~2..0B/~2..0B ~2..0Bh~2..0B", [dt.day, dt.month, dt.hour, dt.minute])
        |> IO.iodata_to_binary()

      _unparsable ->
        String.slice(iso, 0, 10)
    end
  end

  attr :element, :string, required: true
  attr :class, :string, default: "px-1 py-0.5 text-[9px]"

  defp element_chip(assigns) do
    assigns = assign(assigns, :icon, PokedexStyle.element_icon(assigns.element))

    ~H"""
    <span
      class={["inline-flex items-center gap-0.5 rounded font-mono", @class]}
      style={PokedexStyle.element_style(@element)}
    >
      <img :if={@icon} src={@icon} alt="" class="size-3 object-contain" loading="lazy" />
      {@element}
    </span>
    """
  end

  @impl true
  def render(assigns) do
    assigns =
      assigns
      |> assign(:synced_at, Pokedex.synced_at())
      |> assign(:today, Date.utc_today())

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
                placeholder='ex.: seadra  (atalho: "/")'
                data-quick-search
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

          <div
            id="pokedex-sort"
            class="mt-2 flex flex-wrap items-center gap-1 border-t border-[#1d2429] pt-2 font-mono text-[10px] text-[#737d85]"
          >
            <span class="mr-0.5">ordenar</span>
            <button
              :for={{key, label} <- sorts()}
              phx-click="sort"
              phx-value-by={key}
              title={
                if @sort == key,
                  do: "clique de novo pra inverter",
                  else: "ordenar por #{label}"
              }
              class={[
                "rounded px-1.5 py-0.5 transition",
                if(@sort == key,
                  do: "bg-[#17231c] text-[#3de083] ring-1 ring-[#37d07d]/60",
                  else: "text-[#89939a] hover:bg-[#161b1f] hover:text-white"
                )
              ]}
            >
              {label}{if @sort == key, do: if(@desc?, do: " ↓", else: " ↑")}
            </button>

            <button
              phx-click="toggle_novelty"
              title={"só o que a wiki editou nos últimos #{Pokedex.novelty_days()} dias — a lista se recicla sozinha"}
              class={[
                "ml-auto rounded px-1.5 py-0.5 transition",
                if(@only_novelty?,
                  do: "bg-[#211b0d] text-[#f3ba4e] ring-1 ring-[#674f20]",
                  else: "text-[#89939a] hover:bg-[#161b1f] hover:text-white"
                )
              ]}
            >
              🆕 novidades{if @novelty_count > 0 and not @only_novelty?, do: " (#{@novelty_count})"}
            </button>
          </div>

          <p id="pokedex-count" class="mt-2 font-mono text-[10px] text-[#737d85]">
            {@total} resultado(s){if @cursor, do: " — #{@loaded} carregados"}
            <span :if={@synced_at} id="synced-at">
              · sincronizado {short_stamp(@synced_at)}
            </span>
          </p>

          <ul
            id="pokedex-results"
            phx-update="stream"
            phx-viewport-bottom={@cursor && "load_more"}
            class={[
              "mt-2 grid grid-cols-2 gap-1.5 sm:grid-cols-3 lg:grid-cols-4",
              @cursor && "pb-[10vh]"
            ]}
          >
            <li :for={{dom_id, entry} <- @streams.species} id={dom_id}>
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
                      {entry.name}<span :if={entry.shiny_of}> ✨</span><span
                        :if={Pokedex.novelty(entry, @today)}
                        title={"a wiki editou esta página há #{elem(Pokedex.novelty(entry, @today), 1)} dia(s)"}
                        class="ml-1 rounded bg-[#0d3822] px-1 py-0.5 align-middle font-mono text-[8px] text-[#3de083]"
                      >NOVO</span>
                    </p>
                    <p class="flex flex-wrap items-center gap-1 font-mono text-[9px] text-[#737d85]">
                      <span :if={entry.number}>#{entry.number}</span>
                      <span class="rounded bg-[#161b1f] px-1 py-0.5 text-[#aeb6bd]">
                        lv {entry.level || "?"}
                      </span>
                      <.element_chip :for={el <- entry.elements} element={el} />
                    </p>
                    <p
                      :if={@sort in [:edited, :changed] and (entry.edited_at || entry.changed_at)}
                      class="font-mono text-[9px] text-[#59636b]"
                    >
                      {if @sort == :edited,
                        do: "wiki #{entry.edited_at || "?"}",
                        else: "mudou #{short_stamp(entry.changed_at) || "?"}"}
                    </p>
                  </div>
                </div>
                <p
                  :if={entry.weak_to != []}
                  class="mt-1 flex flex-wrap items-center gap-1 font-mono text-[9px] text-[#59636b]"
                >
                  fraco a <.element_chip :for={el <- entry.weak_to} element={el} />
                </p>
              </.link>
            </li>
          </ul>

          <div class="mt-2 flex justify-center">
            <button
              :if={@cursor}
              id="load-more"
              phx-click="load_more"
              class="btn h-8 border border-[#293238] bg-transparent px-4 font-mono text-[10px] text-[#89939a] hover:border-[#37d07d]/60 hover:text-white"
            >
              carregar mais ({@total - @loaded} restantes)
            </button>
            <p
              :if={@cursor == nil and @total > Pokedex.page_size()}
              id="list-end"
              class="font-mono text-[10px] text-[#59636b]"
            >
              — fim da lista ({@total}) —
            </p>
          </div>
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
