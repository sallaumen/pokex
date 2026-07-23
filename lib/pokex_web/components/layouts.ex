defmodule PokexWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PokexWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # O Painel é a BASE: é onde o bot liga e desliga, então fica fora dos grupos —
  # visível no header e no topo do menu, sempre a um clique.
  @home {:panel, "Painel", "hero-play-circle"}

  # Dados, não blocos de markup repetidos: o menu é o mesmo em toda página, e
  # esquecer uma rota aqui é o jeito de uma página sumir do app.
  #
  # Nove destinos numa lista chapada viram uma gaveta — o olho procura item por
  # item. Agrupados, a pergunta que você faz antes de abrir o menu ("meus
  # pokémon? o que o bot vê? ajustar a máquina?") já é a resposta.
  @groups [
    {"Pokémon",
     [
       {:pokedex, "Pokédex", "hero-book-open"},
       {:team, "Time", "hero-user-group"}
     ]},
    {"Mundo",
     [
       {:world, "Mundo", "hero-eye"},
       {:cavebot, "Cavebot", "hero-map"}
     ]},
    {"Configurações",
     [
       {:calibration, "Calibração", "hero-viewfinder-circle"},
       {:diagnostics, "Diagnóstico", "hero-beaker"},
       {:fishing_lab, "Laboratório", "hero-sparkles"},
       {:mini_game, "Mini-game", "hero-puzzle-piece"}
     ]}
  ]

  @doc """
  O shell do Pokex: fundo, header padrão e o conteúdo da página.

  O header é IDÊNTICO em toda página — marca, aviso de foco, personagem ativo,
  ligado/parado e a navegação. O que ele mostra vem do `PokexWeb.HeaderState`,
  montado na `live_session` inteira, então nenhuma página precisa (nem pode)
  montar o seu próprio.

  ## Examples

      <Layouts.app flash={@flash} current_page={:pokedex} {assigns}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_page, :atom,
    default: nil,
    doc: "qual item da navegação está ativo — uma das chaves de `nav_items/0`"

  attr :focused?, :boolean, default: true, doc: "a janela do jogo está em foco (HeaderState)"
  attr :bot_active?, :boolean, default: false, doc: "algum worker rodando (HeaderState)"
  attr :characters, :list, default: [], doc: "personagens cadastrados (HeaderState)"
  attr :active_character, :string, default: "", doc: "slug do personagem ativo (HeaderState)"

  attr :max_width, :string,
    default: "max-w-3xl",
    doc: "largura do conteúdo; só isto muda de página pra página"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh bg-pk-bg text-pk-text">
      <header
        id="app-header"
        class="sticky top-0 z-40 border-b border-pk-line bg-pk-surface/95 backdrop-blur"
      >
        <div class="mx-auto flex h-12 max-w-[1600px] items-center justify-between gap-2 px-2">
          <div class="flex min-w-0 items-center gap-2">
            <.link navigate={~p"/"} class="flex items-center gap-2.5" aria-label="Ir ao painel">
              <span class="grid size-7 shrink-0 place-items-center rounded-lg bg-pk-ok text-pk-title font-black text-pk-bg">
                P
              </span>
              <span class="text-pk-title font-bold">Pokex</span>
            </.link>
            <span
              :if={page_label(@current_page)}
              id="app-page-label"
              class="hidden truncate text-pk-body text-pk-text-3 sm:inline"
            >
              · {page_label(@current_page)}
            </span>
            <span
              :if={not @focused?}
              id="focus-pause-badge"
              class="grid size-6 shrink-0 place-items-center rounded-full border border-pk-warn-line bg-pk-warn-dim text-pk-warn"
              title="Pausado por segurança — a janela do jogo perdeu o foco. Nada é digitado/clicado até você voltar pro jogo; aí os workers religam sozinhos."
              aria-label="Pausado por segurança: a janela do jogo perdeu o foco"
            >
              <.icon name="hero-pause-circle" class="size-4" />
            </span>
          </div>

          <div class="flex shrink-0 items-center gap-2">
            <form id="character-picker-form" phx-change="set_character">
              <select
                id="character-picker"
                name="character"
                aria-label="Personagem ativo"
                class="select h-8 min-h-0 w-36 rounded-lg border border-pk-line-strong bg-pk-surface px-2 text-pk-meta text-pk-text-2 focus:border-pk-ok/60 focus:outline-none"
              >
                <option value="" selected={@active_character == ""}>sem personagem</option>
                <option
                  :for={character <- @characters}
                  value={character.slug}
                  selected={@active_character == character.slug}
                >
                  {character.name}
                </option>
              </select>
            </form>

            <details id="character-create" class="relative">
              <summary
                class="grid size-8 cursor-pointer list-none place-items-center rounded-lg border border-pk-line-strong text-pk-text-2 transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white [&::-webkit-details-marker]:hidden"
                title="Criar personagem"
                aria-label="Criar personagem"
              >
                <.icon name="hero-user-plus" class="size-4" />
              </summary>
              <form
                id="character-create-form"
                phx-submit="create_character"
                class="absolute right-0 top-10 z-50 flex w-56 items-center gap-2 rounded-lg border border-pk-line-strong bg-pk-surface p-2 shadow-2xl shadow-black/50"
              >
                <input
                  type="text"
                  name="name"
                  placeholder="nome do personagem"
                  aria-label="Nome do novo personagem"
                  autocomplete="off"
                  required
                  class="input h-8 min-h-0 w-full rounded-lg border border-pk-line-strong bg-pk-raised px-2 text-pk-meta text-pk-text placeholder:text-pk-text-3 focus:border-pk-ok/60 focus:outline-none"
                />
                <button
                  type="submit"
                  class="btn btn-outline h-8 min-h-0 shrink-0 rounded-lg border-pk-line-strong px-2.5 text-pk-meta font-semibold text-pk-text-2 hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white"
                >
                  Criar
                </button>
              </form>
            </details>

            <span
              id="app-bot-state"
              class="flex items-center gap-2 rounded-full border border-pk-line-strong px-2.5 py-1 font-mono text-pk-meta font-bold uppercase tracking-[0.14em] text-pk-text-2"
            >
              <span class={[
                "size-1.5 rounded-full",
                if(@bot_active?, do: "bg-pk-ok", else: "bg-pk-text-3")
              ]} />
              {if @bot_active?, do: "Ativo", else: "Parado"}
            </span>

            <.nav_link entry={nav_home()} current_page={@current_page} id="app-home" show_label />

            <details id="app-navigation" phx-update="ignore" class="group relative">
              <summary
                id="app-navigation-toggle"
                class="grid size-8 cursor-pointer list-none place-items-center rounded-lg border border-pk-line-strong text-pk-text-2 transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white [&::-webkit-details-marker]:hidden"
                title="Abrir navegação"
                aria-label="Abrir navegação"
              >
                <.icon name="hero-bars-3" class="size-4" />
              </summary>
              <nav
                aria-label="Navegação principal"
                class="absolute right-0 top-10 z-50 w-52 overflow-hidden rounded-lg border border-pk-line-strong bg-pk-surface p-1 shadow-2xl shadow-black/50"
              >
                <.nav_link entry={nav_home()} current_page={@current_page} />

                <div
                  :for={{title, entries} <- nav_groups()}
                  class="mt-1 border-t border-pk-line pt-1"
                >
                  <p class="px-3 pb-0.5 pt-1 text-pk-meta font-semibold uppercase tracking-[0.14em] text-pk-text-3">
                    {title}
                  </p>
                  <.nav_link :for={entry <- entries} entry={entry} current_page={@current_page} />
                </div>
              </nav>
            </details>
          </div>
        </div>
      </header>

      <main class={["mx-auto w-full px-2 py-3", @max_width]}>
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  # Um destino do menu. Existe como componente porque o Painel aparece TRÊS
  # vezes (botão do header, topo do menu) e um item marcado como página atual
  # num lugar e não no outro é exatamente o tipo de divergência que o header
  # unificado veio matar.
  attr :entry, :any, required: true, doc: "`{key, label, icon}` de `nav_items/0`"
  attr :current_page, :atom, default: nil
  attr :id, :string, default: nil, doc: "sobrescreve o id (o menu usa o padrão `app-nav-*`)"
  attr :show_label, :boolean, default: false, doc: "botão compacto: texto some no mobile"

  def nav_link(%{entry: {key, label, icon}} = assigns) do
    assigns =
      assign(assigns,
        key: key,
        label: label,
        icon: icon,
        current?: key == assigns.current_page,
        id: assigns.id || nav_id(key)
      )

    ~H"""
    <.link
      id={@id}
      navigate={nav_path(@key)}
      aria-current={@current? && "page"}
      title={@label}
      class={[
        "flex items-center gap-2 rounded-lg px-3 py-2.5 text-pk-body transition",
        @show_label && "h-8 shrink-0 rounded-lg border px-2.5 py-0 text-pk-meta font-semibold",
        cond do
          @current? and @show_label ->
            "border-pk-ok/60 bg-pk-ok-dim text-pk-ok"

          @current? ->
            "bg-pk-ok-dim font-semibold text-pk-ok"

          @show_label ->
            "border-pk-line-strong text-pk-text-2 hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white"

          true ->
            "text-pk-text hover:bg-pk-raised hover:text-white"
        end
      ]}
    >
      <.icon name={@icon} class={["size-4 shrink-0", not @current? && "text-pk-text-2"]} />
      <span class={@show_label && "hidden sm:inline"}>{@label}</span>
    </.link>
    """
  end

  @doc "Os destinos da navegação, chapados, na ordem em que aparecem: `{key, label, icon}`."
  def nav_items, do: [@home | Enum.flat_map(@groups, fn {_title, entries} -> entries end)]

  @doc "Os grupos do menu (o Painel fica FORA deles): `{título, [{key, label, icon}]}`."
  def nav_groups, do: @groups

  @doc "O destino base — o Painel."
  def nav_home, do: @home

  @doc """
  Os assigns que o `PokexWeb.HeaderState` mantém, prontos pra repassar em bloco:

      <Layouts.app flash={@flash} current_page={:pokedex} {Layouts.header(assigns)}>

  Repetir os quatro à mão em nove páginas é como uma delas acabaria com um header
  meio morto — sem personagem, ou com o pill congelado em "Parado".
  """
  def header(assigns),
    do: Map.take(assigns, [:focused?, :bot_active?, :characters, :active_character])

  # o id vira DOM: `:fishing_lab` -> "app-nav-fishing-lab" (underscore em id de
  # markup é ruído, e um teste que faz `refute html =~ "mini_game"` acha o id)
  defp nav_id(key), do: "app-nav-" <> String.replace(to_string(key), "_", "-")

  defp nav_path(:panel), do: ~p"/"
  defp nav_path(:calibration), do: ~p"/calibration"
  defp nav_path(:diagnostics), do: ~p"/diagnostics"
  defp nav_path(:fishing_lab), do: ~p"/fishing-lab"
  defp nav_path(:mini_game), do: ~p"/mini-game"
  defp nav_path(:world), do: ~p"/world"
  defp nav_path(:cavebot), do: ~p"/cavebot"
  defp nav_path(:pokedex), do: ~p"/pokedex"
  defp nav_path(:team), do: ~p"/time"

  defp page_label(nil), do: nil

  defp page_label(current_page) do
    Enum.find_value(nav_items(), fn {key, label, _icon} -> key == current_page && label end)
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end
end
