defmodule PokexWeb.PokedexLive do
  @moduledoc """
  The local Pokédex (fetched from the wiki's API by `mix pokedex.sync`):
  Lucas's queryable base — search by name, element, WEAKNESS ("which are
  weak to grass?"), level, generation, tier and role. Every card links into
  `/pokedex/:name`; the team and its hunt suggestions live on `/time`.

  FILTERS LIVE IN THE URL: exploring a card and coming BACK restores the
  exact view (the day-to-day flow), and any filtered view is a shareable,
  bookmarkable link.

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
       generations: Pokedex.generations(),
       tiers: Pokedex.tiers(),
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
        elements: multi_param(params, "elements", "element"),
        weak_to: multi_param(params, "weak_to"),
        generations: integer_param(params, "generations"),
        tiers: multi_param(params, "tiers"),
        roles: multi_param(params, "roles"),
        variant: params["variant"] || ""
      }
      |> put_level(:min_level, params["min_level"])
      |> put_level(:max_level, params["max_level"])

    sort = sort_atom(params["sort"])
    desc? = params["desc"] == "1"

    filters =
      filters
      |> Map.put(:sort, sort)
      |> Map.put(:desc, desc?)

    page = Pokedex.page(filters)

    {:noreply,
     socket
     |> assign(
       # the canonical (plural) shape — a legacy singular URL normalises into
       # it on the next navigation instead of lingering half-and-half
       raw_filters:
         params
         |> Map.take(
           ~w(name elements weak_to generations tiers roles variant min_level max_level sort desc)
         )
         |> Map.merge(%{
           "elements" => filters.elements,
           "weak_to" => filters.weak_to,
           "generations" => multi_param(params, "generations"),
           "tiers" => filters.tiers,
           "roles" => filters.roles
         })
         |> clean_query(),
       filters: filters,
       form: filter_form(params),
       sort: sort,
       desc?: desc?,
       cursor: page.cursor,
       total: page.total,
       loaded: length(page.entries)
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
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end

  # A chip toggles its option in or out of the group — "all grass AND all
  # poison" is two chips on. OR inside the group, AND across groups.
  #
  # The param is "option", NOT "value": LiveView's extractMeta reads every
  # phx-value-* attribute and THEN overwrites meta.value with the element's own
  # DOM .value, which on a <button> is "". So phx-value-value silently ships an
  # empty string — and render_click/1 never sees it, because the test client
  # reads the attributes only. Any phx-value-* name is safe except "value".
  def handle_event("toggle_filter", %{"key" => key, "option" => option}, socket)
      when key in ~w(elements weak_to generations tiers roles) do
    current = socket.assigns.raw_filters[key] || []
    updated = if option in current, do: List.delete(current, option), else: current ++ [option]

    {:noreply, patch_with(socket, %{key => updated})}
  end

  def handle_event("clear_filter", %{"key" => key}, socket)
      when key in ~w(elements weak_to generations tiers roles) do
    {:noreply, patch_with(socket, %{key => []})}
  end

  @impl true
  def handle_event("filter", %{"f" => params}, socket) do
    # sort AND the chip groups survive a form change — typing a name must
    # never wipe the elements/tiers he just toggled on
    keep =
      Map.take(
        socket.assigns.raw_filters,
        ~w(sort desc elements weak_to generations tiers roles)
      )

    query = params |> Map.merge(keep) |> clean_query()

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
            if(summary.failed > 0, do: " · #{summary.failed} falharam", else: ""),
        loaded?: Pokedex.loaded?(),
        elements: Pokedex.elements(),
        generations: Pokedex.generations(),
        tiers: Pokedex.tiers(),
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

  # Every filter change goes through here: merge onto the current URL state,
  # drop the empties, patch.
  defp patch_with(socket, changes) do
    query = socket.assigns.raw_filters |> Map.merge(changes) |> clean_query()

    push_patch(socket, to: ~p"/pokedex?#{query}")
  end

  # Only meaningful values reach the URL — clean, shareable links.
  defp clean_query(params) do
    params
    |> Enum.reject(fn {_k, v} -> v in [nil, "", "false", []] end)
    |> Map.new()
  end

  # Multi-value filters ride the URL as lists (?elements[]=Grass&elements[]=
  # Poison). `legacy` reads the pre-chips singular param so old bookmarks keep
  # working; a lone binary under the plural key (hand-typed URL) counts too.
  defp multi_param(params, key, legacy \\ nil) do
    case params[key] || (legacy && params[legacy]) do
      list when is_list(list) -> Enum.reject(list, &(&1 in [nil, ""]))
      value when is_binary(value) and value != "" -> [value]
      _absent -> []
    end
  end

  # Generations ride the URL as strings and the filter compares integers. A
  # hand-typed ?generations[]=abc must narrow nothing, never raise.
  defp integer_param(params, key) do
    params
    |> multi_param(key)
    |> Enum.flat_map(fn raw ->
      case Integer.parse(raw) do
        {number, _rest} -> [number]
        :error -> []
      end
    end)
  end

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
        "min_level" => params["min_level"] || "",
        "max_level" => params["max_level"] || "",
        "variant" => params["variant"] || ""
      },
      as: :f
    )
  end

  defp dom_slug(name), do: name |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-")

  @sorts [
    {:number, "nº"},
    {:name, "nome"},
    {:level, "level"},
    {:element, "tipo"},
    {:weak_to, "fraqueza"},
    {:shiny, "shiny"},
    {:tier, "tier"},
    {:generation, "geração"}
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

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :param, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true
  attr :style_fun, :any, required: true

  # One row of toggle chips = one NON-EXCLUSIVE filter: any number of them on
  # at once, matching entries that have ANY of them. Empty selection = all.
  defp filter_chips(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-1" title={@hint}>
      <span class="mr-0.5 w-24 shrink-0">
        {@label}<span :if={@selected != []} class="text-pk-ok">({length(@selected)})</span>
      </span>
      <button
        :for={option <- @options}
        type="button"
        phx-click="toggle_filter"
        phx-value-key={@param}
        phx-value-option={option}
        style={@style_fun.(option)}
        class={[
          "rounded px-1.5 py-0.5 font-mono text-pk-meta transition",
          if(option in @selected,
            do: "ring-1 ring-pk-ok/70",
            else: "opacity-40 hover:opacity-90"
          )
        ]}
      >
        {option}
      </button>
      <button
        :if={@selected != []}
        type="button"
        phx-click="clear_filter"
        phx-value-key={@param}
        class="rounded px-1 py-0.5 text-pk-text-2 hover:bg-pk-raised hover:text-white"
      >
        limpar ×
      </button>
    </div>
    """
  end

  attr :element, :string, required: true
  attr :class, :string, default: "px-1 py-0.5 text-pk-meta"

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
    <Layouts.app
      flash={@flash}
      current_page={:pokedex}
      {Layouts.header(assigns)}
      max_width="max-w-[1080px]"
    >
      <div class="space-y-4">
        <datalist id="species-names">
          <option :for={name <- @species_names} value={name} />
        </datalist>

        <%!-- Syncing the wiki is THIS page's maintenance, not navigation: that
              is why it lives here in the body, not in the header (which is the
              same on every page). --%>
        <section
          id="pokedex-tools"
          class="flex flex-wrap items-center justify-between gap-3 rounded-lg border border-pk-line bg-pk-surface px-3 py-2.5"
        >
          <div class="min-w-0">
            <h2 class="text-pk-body font-semibold text-pk-text">Sincronizar com a wiki</h2>
            <p class="text-pk-meta text-pk-text-3">
              raspa dados (upsert) + imagens novas. Vazio = base inteira (~10min); com nomes = segundos.
            </p>
          </div>
          <form id="sync-form" phx-submit="sync_wiki" class="flex items-center gap-2">
            <input
              name="only"
              list="species-names"
              placeholder="só estes nomes (vazio = tudo)"
              autocomplete="off"
              class="input input-bordered h-8 w-52 bg-pk-sunken font-mono text-xs"
            />
            <button
              disabled={@sync_running?}
              class="btn h-8 border border-pk-line-strong bg-transparent px-3 text-xs text-pk-text-2 hover:border-pk-ok/60 hover:text-white disabled:opacity-40"
            >
              {if @sync_running?, do: "⏳ sincronizando…", else: "🔄 Sincronizar wiki"}
            </button>
          </form>
        </section>

        <p
          :if={@sync_msg}
          id="sync-status"
          class="rounded-lg border border-pk-line bg-pk-surface px-3 py-1.5 font-mono text-pk-meta text-pk-text-2"
        >
          {@sync_msg}
        </p>

        <section
          :if={not @loaded?}
          class="rounded-lg border border-pk-warn-line bg-pk-warn-dim p-4 text-sm text-pk-warn"
        >
          Sem dados ainda — clica em "🔄 Sincronizar wiki" aí em cima (ou roda
          <code class="font-mono">mix pokedex.sync</code>
          no terminal) pra popular a base.
        </section>

        <section :if={@loaded?} class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <.form
            for={@form}
            id="pokedex-filter-form"
            phx-change="filter"
            class="flex flex-wrap items-end gap-2 font-mono text-pk-meta text-pk-text-2"
          >
            <label class="flex flex-col gap-1">
              nome
              <input
                type="text"
                name="f[name]"
                value={@form[:name].value}
                placeholder='ex.: seadra  (atalho: "/")'
                data-quick-search
                class="input input-bordered h-9 w-40 bg-pk-bg font-mono text-sm"
              />
            </label>
            <label class="flex flex-col gap-1">
              level ≥
              <input
                type="number"
                name="f[min_level]"
                value={@form[:min_level].value}
                class="input input-bordered h-9 w-20 bg-pk-bg font-mono text-sm"
              />
            </label>
            <label class="flex flex-col gap-1">
              level ≤
              <input
                type="number"
                name="f[max_level]"
                value={@form[:max_level].value}
                class="input input-bordered h-9 w-20 bg-pk-bg font-mono text-sm"
              />
            </label>
            <label class="flex flex-col gap-1" title="normais, shinies, ou os dois">
              variante
              <select
                id="filter-variant"
                name="f[variant]"
                class="select select-bordered h-9 w-40 bg-pk-bg font-mono text-sm"
              >
                <option value="" selected={@form[:variant].value == ""}>
                  normais e shinies
                </option>
                <option value="normal" selected={@form[:variant].value == "normal"}>
                  só normais
                </option>
                <option value="shiny" selected={@form[:variant].value == "shiny"}>
                  só shinies ✨
                </option>
              </select>
            </label>
          </.form>

          <div class="mt-2 space-y-1.5 border-t border-pk-raised pt-2 font-mono text-pk-meta text-pk-text-2">
            <.filter_chips
              id="filter-elements"
              label="elemento"
              hint="liga quantos quiser — mostra quem é de QUALQUER um deles"
              param="elements"
              options={@elements}
              selected={@filters.elements}
              style_fun={&PokedexStyle.element_style/1}
            />
            <.filter_chips
              id="filter-weak-to"
              label="fraco contra"
              hint="ataques de QUALQUER um destes elementos batem forte nele"
              param="weak_to"
              options={@elements}
              selected={@filters.weak_to}
              style_fun={&PokedexStyle.element_style/1}
            />
            <.filter_chips
              id="filter-generations"
              label="geração"
              hint="a geração em que o Pokémon entrou no jogo"
              param="generations"
              options={Enum.map(@generations, &Integer.to_string/1)}
              selected={Enum.map(@filters.generations, &Integer.to_string/1)}
              style_fun={fn _generation -> "" end}
            />
            <.filter_chips
              id="filter-tiers"
              label="tier"
              hint="a faixa de força que a wiki dá ao Pokémon"
              param="tiers"
              options={@tiers}
              selected={@filters.tiers}
              style_fun={fn _tier -> "" end}
            />
          </div>

          <div
            id="pokedex-sort"
            class="mt-2 flex flex-wrap items-center gap-1 border-t border-pk-raised pt-2 font-mono text-pk-meta text-pk-text-3"
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
                  do: "bg-pk-ok-dim text-pk-ok ring-1 ring-pk-ok/60",
                  else: "text-pk-text-2 hover:bg-pk-raised hover:text-white"
                )
              ]}
            >
              {label}{if @sort == key, do: if(@desc?, do: " ↓", else: " ↑")}
            </button>
          </div>

          <p id="pokedex-count" class="mt-2 font-mono text-pk-meta text-pk-text-3">
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
                  "block rounded-lg border bg-pk-raised px-2.5 py-2 transition hover:border-pk-ok/60",
                  if(entry.variant == "shiny",
                    do: "border-pk-warn-line",
                    else: "border-pk-line"
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
                    <p class="truncate text-sm font-semibold">
                      {entry.name}<span :if={entry.variant == "shiny"}> ✨</span>
                    </p>
                    <p class="flex flex-wrap items-center gap-1 font-mono text-pk-meta text-pk-text-3">
                      <span :if={entry.number}>#{entry.number}</span>
                      <span class="rounded bg-pk-raised px-1 py-0.5 text-pk-text-2">
                        lv {entry.level || "?"}
                      </span>
                      <span :if={entry.tier} class="rounded bg-pk-raised px-1 py-0.5 text-pk-text-2">
                        tier {entry.tier}
                      </span>
                      <span :if={entry.generation} class="rounded bg-pk-raised px-1 py-0.5">
                        gen {entry.generation}
                      </span>
                      <.element_chip :for={el <- entry.elements} element={el} />
                    </p>
                  </div>
                </div>
                <p
                  :if={entry.weak_to != []}
                  class="mt-1 flex flex-wrap items-center gap-1 font-mono text-pk-meta text-pk-text-3"
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
              class="btn h-8 border border-pk-line bg-transparent px-4 font-mono text-pk-meta text-pk-text-2 hover:border-pk-ok/60 hover:text-white"
            >
              carregar mais ({@total - @loaded} restantes)
            </button>
            <p
              :if={@cursor == nil and @total > Pokedex.page_size()}
              id="list-end"
              class="font-mono text-pk-meta text-pk-text-3"
            >
              — fim da lista ({@total}) —
            </p>
          </div>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
