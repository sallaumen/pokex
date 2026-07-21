defmodule PokexWeb.PokedexLive do
  @moduledoc """
  The local Pokédex (scraped from the PXG wiki by `mix pokedex.scrape`):
  Lucas's queryable base — search by name, element, WEAKNESS ("quais têm
  fraqueza de planta?") and level — plus the per-lure view that answers
  "pescando com ESTA isca, quais Shinies podem vir?".
  """
  use PokexWeb, :live_view

  alias Pokex.Pokedex
  alias PokexWeb.PanelForms

  @results_cap 120

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     assign(socket,
       page_title: "Pokédex",
       loaded?: Pokedex.loaded?(),
       elements: Pokedex.elements(),
       lures: Pokedex.lures(),
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
        only_shiny: params["only_shiny"] == "true"
      }
      |> put_level(:min_level, params["min_level"])
      |> put_level(:max_level, params["max_level"])

    {:noreply, assign(socket, results: Pokedex.search(filters), form: filter_form(params))}
  end

  def handle_event("select_lure", %{"lure" => name}, socket) do
    lure = Enum.find(socket.assigns.lures, &(&1.name == name))
    {:noreply, assign(socket, selected_lure: lure)}
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
        "element" => params["element"] || "",
        "weak_to" => params["weak_to"] || "",
        "min_level" => params["min_level"] || "",
        "max_level" => params["max_level"] || "",
        "only_shiny" => params["only_shiny"] || "false"
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
        <header class="flex items-center justify-between">
          <h1 class="text-lg font-bold">Pokédex</h1>
          <.link
            navigate={~p"/"}
            class="font-mono text-[11px] text-[#89939a] underline hover:text-white"
          >
            ← painel
          </.link>
        </header>

        <section
          :if={not @loaded?}
          class="rounded-lg border border-[#674f20] bg-[#211b0d] p-4 text-sm text-[#e7ca82]"
        >
          Sem dados ainda — rode <code class="font-mono">mix pokedex.scrape</code>
          e reinicie o servidor pra popular a base a partir da wiki do PXG.
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

          <ul class="mt-2 grid grid-cols-2 gap-1.5 sm:grid-cols-3 lg:grid-cols-4">
            <li
              :for={entry <- @capped}
              class={[
                "rounded-lg border bg-[#101418] px-2.5 py-2",
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
                  <p class="truncate text-sm font-semibold">
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
              <p :if={entry.weak_to != []} class="mt-1 truncate font-mono text-[9px] text-[#8b949d]">
                fraco: {Enum.join(entry.weak_to, ", ")}
              </p>
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
              <span
                :for={name <- tier.pokemon}
                class={[
                  "ml-1 inline-block rounded px-1.5 py-0.5 text-[11px]",
                  if(shiny?(name),
                    do: "bg-[#211b0d] font-semibold text-[#f3ba4e]",
                    else: "bg-[#161b1f] text-[#aeb6bd]"
                  )
                ]}
              >
                {name}{if shiny?(name), do: " ✨"}
              </span>
            </li>
          </ul>
        </section>
      </div>
    </div>
    """
  end
end
