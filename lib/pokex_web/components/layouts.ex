defmodule PokexWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PokexWeb, :html

  alias Pokex.Bots.AlarmCategories
  alias Pokex.Calibration
  alias Pokex.Machine.Presence

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  # Data, not repeated markup blocks: the menu is the same on every page, and
  # forgetting a route here is how a page disappears from the app.
  #
  # The two that stay OUT of the groups are the two that are not destinations
  # about a subject — the Painel is where the bot starts and stops, and the ⚙️
  # is not even a page (route /config, same LiveView, the overlay opening on
  # top of the panel). Both are "the app itself", so they sit above the groups.
  @top [
    {:panel, "Painel", "hero-play-circle"},
    {:config, "Configurações", "hero-cog-6-tooth"}
  ]

  # Ten flat destinations turn into a drawer — the eye reads item by item
  # because nothing says what subject each one is about. Grouped, the question
  # you already ask before opening the menu ("my pokémon? what the bot sees?
  # tune the machine?") is already the answer.
  #
  # NO group title repeats a destination's label — not "Configurações" (taken by
  # the ⚙️ above, which is not even in a group) and not "Mundo" (a page). A
  # header echoing the item right under it reads as a duplicate, and echoing an
  # item that is somewhere ELSE is how you click the wrong thing twice. Hence
  # "No jogo" (the game world) against "Máquina" (this Mac) — the same ruler
  # `Pokex.Settings` uses to decide where a key belongs.
  @groups [
    {"Pokémon",
     [
       {:pokedex, "Pokédex", "hero-book-open"},
       {:team, "Time", "hero-user-group"}
     ]},
    {"No jogo",
     [
       {:world, "Mundo", "hero-eye"},
       {:cavebot, "Cavebot", "hero-map"},
       {:timers, "Timers", "hero-clock"}
     ]},
    {"Máquina",
     [
       {:calibration, "Calibração", "hero-viewfinder-circle"},
       {:diagnostics, "Diagnóstico", "hero-beaker"},
       {:fishing_lab, "Laboratório", "hero-sparkles"},
       {:mini_game, "Mini-game", "hero-puzzle-piece"}
     ]}
  ]

  @doc """
  The Pokex shell: background, standard header and the page content.

  The header is IDENTICAL on every page — brand, focus warning, active
  character, running/stopped and the navigation. What it shows comes from
  `PokexWeb.HeaderState`, mounted on the whole `live_session`, so no page
  needs (or may) build its own.

  ## Examples

      <Layouts.app flash={@flash} current_page={:pokedex} {assigns}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_page, :atom,
    default: nil,
    doc: "which nav item is active — one of the `nav_items/0` keys"

  attr :focused?, :boolean, default: true, doc: "the game window is focused (HeaderState)"
  attr :bot_active?, :boolean, default: false, doc: "some worker is running (HeaderState)"
  attr :characters, :list, default: [], doc: "registered characters (HeaderState)"
  attr :active_character, :string, default: "", doc: "active character slug (HeaderState)"
  attr :alarm_sound, :boolean, default: true, doc: "master alarm sound on (HeaderState)"

  attr :alarm_muted_categories, :list,
    default: [],
    doc: "muted alarm sectors, as strings (HeaderState)"

  attr :screen_check, :any,
    default: :unknown,
    doc: "does the saved calibration match this screen (HeaderState)"

  attr :machine_others, :list,
    default: [],
    doc: "other live Pokex VMs on this Mac (HeaderState)"

  attr :machine_first?, :boolean,
    default: true,
    doc: "did THIS VM start before them (HeaderState)"

  attr :max_width, :string,
    default: "max-w-3xl",
    doc: "content width; the only thing that changes page to page"

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

            <%!-- Creating, renaming and deleting live together, one popover
                  away from the picker they affect. `Pokex.Characters` could
                  rename and delete from the start and nothing could reach it:
                  a character created with a typo was permanent. --%>
            <details id="character-manager" class="relative">
              <summary
                class="grid size-8 cursor-pointer list-none place-items-center rounded-lg border border-pk-line-strong text-pk-text-2 transition hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white [&::-webkit-details-marker]:hidden"
                title="Personagens: criar, renomear, apagar"
                aria-label="Gerenciar personagens"
              >
                <.icon name="hero-user-plus" class="size-4" />
              </summary>

              <div class="absolute right-0 top-10 z-50 w-72 space-y-2 rounded-lg border border-pk-line-strong bg-pk-surface p-2 shadow-2xl shadow-black/50">
                <form id="character-create-form" phx-submit="create_character" class="flex gap-2">
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

                <p :if={@characters == []} class="px-1 pb-1 text-pk-meta text-pk-text-3">
                  Nenhum personagem ainda — sem um, o time é o compartilhado.
                </p>

                <div :if={@characters != []} class="max-h-64 space-y-1 overflow-y-auto">
                  <div
                    :for={character <- @characters}
                    id={"character-row-#{character.slug}"}
                    class="flex items-center gap-1"
                  >
                    <%!-- Renaming IS the text field: no edit mode to enter and
                          no Save to find. Enter commits, Esc gives up. --%>
                    <form
                      id={"character-rename-#{character.slug}"}
                      phx-submit="rename_character"
                      class="min-w-0 flex-1"
                    >
                      <input type="hidden" name="slug" value={character.slug} />
                      <input
                        type="text"
                        name="name"
                        value={character.name}
                        aria-label={"Renomear #{character.name}"}
                        autocomplete="off"
                        required
                        class="input h-8 min-h-0 w-full rounded-lg border border-transparent bg-transparent px-2 text-pk-meta text-pk-text hover:border-pk-line-strong focus:border-pk-ok/60 focus:bg-pk-raised focus:outline-none"
                      />
                    </form>
                    <button
                      type="button"
                      id={"character-delete-#{character.slug}"}
                      phx-click="delete_character"
                      phx-value-slug={character.slug}
                      data-confirm={"Apagar #{character.name}? O time dele vai junto."}
                      title={"Apagar #{character.name}"}
                      aria-label={"Apagar #{character.name}"}
                      class="grid size-8 shrink-0 place-items-center rounded-lg border border-transparent text-pk-text-3 transition hover:border-pk-warn-line hover:bg-pk-warn-dim hover:text-pk-warn"
                    >
                      <.icon name="hero-trash" class="size-4" />
                    </button>
                  </div>
                </div>
              </div>
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

            <details id="app-alarm-menu" class="relative">
              <summary
                id="app-alarm-toggle"
                class={[
                  "grid size-8 cursor-pointer list-none place-items-center rounded-lg border transition [&::-webkit-details-marker]:hidden",
                  if(@alarm_sound,
                    do:
                      "border-pk-line-strong text-pk-text-2 hover:border-pk-ok/60 hover:bg-pk-raised hover:text-white",
                    else: "border-pk-warn-line bg-pk-warn-dim text-pk-warn"
                  )
                ]}
                title={
                  if @alarm_sound,
                    do: "Som dos alarmes ligado — clique pra ajustar",
                    else: "Som dos alarmes MUDO — clique pra reativar (o feed 🔔 continua registrando)"
                }
                aria-label="Configurar som dos alarmes"
              >
                <.icon
                  name={if @alarm_sound, do: "hero-bell-alert", else: "hero-bell-slash"}
                  class="size-4"
                />
              </summary>
              <div class="absolute right-0 top-10 z-50 w-72 space-y-2 rounded-lg border border-pk-line-strong bg-pk-surface p-2 shadow-2xl shadow-black/50">
                <button
                  type="button"
                  id="app-alarm-sound-toggle"
                  phx-click="toggle_alarm_sound"
                  class="flex w-full items-center justify-between rounded-md px-2 py-1.5 text-pk-body text-pk-text hover:bg-pk-raised"
                >
                  <span class="font-semibold">Som geral</span>
                  <span class={[
                    "font-mono text-pk-meta",
                    if(@alarm_sound, do: "text-pk-ok", else: "text-pk-warn")
                  ]}>
                    {if @alarm_sound, do: "ligado", else: "mudo"}
                  </span>
                </button>

                <p class="px-2 text-pk-meta text-pk-text-3">
                  Setores (o feed 🔔 sempre registra; isto só decide o SOM):
                </p>

                <div class="max-h-64 space-y-0.5 overflow-y-auto">
                  <label
                    :for={{key, label} <- AlarmCategories.all()}
                    id={"app-alarm-category-#{dashed(key)}"}
                    class="flex cursor-pointer items-center gap-2 rounded-md px-2 py-1 text-pk-body text-pk-text-2 hover:bg-pk-raised"
                  >
                    <input
                      type="checkbox"
                      phx-click="toggle_alarm_category"
                      phx-value-category={key}
                      checked={to_string(key) not in @alarm_muted_categories}
                      class="checkbox checkbox-sm"
                    />
                    {label}
                  </label>
                </div>
              </div>
            </details>

            <%!-- No `phx-update="ignore"` here, and that is the point. It was
                  guarding the <details> open state, which `app.js` already
                  mirrors globally in `onBeforeElUpdated` for EVERY <details>
                  in the app (the alarm menu right above never needed it). What
                  it did instead: an ignored element makes morphdom skip its
                  whole subtree, so the menu rendered at mount was frozen —
                  open the ⚙️ from the menu, close the overlay (a patch, SAME
                  mount) and the menu kept highlighting "Configurações" while
                  you were on the Painel. --%>
            <details id="app-navigation" class="group relative">
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
                <.nav_link :for={entry <- nav_top()} entry={entry} current_page={@current_page} />

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

      <.other_pokex_strip others={@machine_others} first?={@machine_first?} />

      <.screen_mismatch_strip check={@screen_check} current_page={@current_page} />

      <main class={["mx-auto w-full px-2 py-3", @max_width]}>
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  attr :others, :list, required: true, doc: "other live Pokex VMs (Machine.Presence)"
  attr :first?, :boolean, default: true

  @doc """
  Says, on every page, that another Pokex is running on this Mac.

  On 2026-08-12 a second server — opened in a worktree only to review the UI — started fishing
  by itself next to the real one. Nobody had clicked Iniciar: the `Guardian`'s command corner is
  a MOUSE dwell, and the mouse belongs to the machine, so both VMs obeyed it at once.

  This is a warning and nothing more. Both windows get it, and it deliberately promises no
  protection: neither one is read-only, so text implying "the other one is in charge" would be a
  lie that makes the human relax. It names the ports because that is what he needs to know which
  terminal to close.
  """
  def other_pokex_strip(%{others: [_ | _]} = assigns) do
    ~H"""
    <div
      id="other-pokex-strip"
      role="status"
      class="sticky top-12 z-30 border-b border-pk-warn-line bg-pk-warn-dim/95 backdrop-blur"
    >
      <div class="mx-auto flex max-w-[1600px] flex-wrap items-center gap-x-2 gap-y-1 px-2 py-1.5">
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-pk-warn" />
        <p class="flex-1 text-pk-body text-pk-text">
          <b class="text-pk-warn">Tem outro Pokex rodando nesta máquina</b>
          <span class="pk-num text-pk-text-2">
            — {Presence.describe(@others)}. Os dois obedecem o mesmo mouse: o <b>canto de comando</b>
            (mouse no topo-direito) liga e desliga a frota dos DOIS ao mesmo tempo, e as capturas
            de tela disputam a mesma fila. Feche um dos servidores antes de caçar.
          </span>
        </p>
      </div>
    </div>
    """
  end

  def other_pokex_strip(assigns), do: ~H""

  attr :check, :any, required: true, doc: "Calibration.screen_check/2 result"
  attr :current_page, :atom, default: nil

  @doc """
  The one state that makes EVERY reading wrong, said on every page.

  A calibration belongs to the screen it was marked on: on another one the bot
  aims at coordinates that no longer exist. The warning already existed — but
  only inside /calibration, so switching monitors and going straight to the
  panel told him nothing (Lucas, 2026-08-10: "o tamanho da minha tela era
  diferente da última calibragem, nada me foi avisado"). It rides inside the
  sticky header block so scrolling cannot leave it behind, and disappears by
  itself the moment the two agree.
  """
  def screen_mismatch_strip(%{check: {tag, {sw, sh}, {cw, ch}}} = assigns)
      when tag in [:another_screen, :rescalable] do
    assigns =
      assign(assigns,
        saved: "#{sw}×#{sh}",
        current: "#{cw}×#{ch}",
        here?: assigns.current_page == :calibration,
        restorable?: tag == :another_screen and Calibration.last_for_screen({cw, ch}) != :none,
        rescalable?: tag == :rescalable
      )

    ~H"""
    <div
      id="screen-mismatch-strip"
      role="status"
      class="sticky top-12 z-30 border-b border-pk-warn-line bg-pk-warn-dim/95 backdrop-blur"
    >
      <div class="mx-auto flex max-w-[1600px] flex-wrap items-center gap-x-2 gap-y-1 px-2 py-1.5">
        <.icon name="hero-computer-desktop" class="size-4 shrink-0 text-pk-warn" />
        <p class="flex-1 text-pk-body text-pk-text">
          <b class="text-pk-warn">{headline(@rescalable?)}</b>
          <span class="pk-num text-pk-text-2">— {explains(@rescalable?, @saved, @current)}</span>
        </p>

        <.link
          :if={not @here?}
          navigate={~p"/calibration"}
          id="screen-mismatch-fix"
          class="shrink-0 rounded-lg border border-pk-warn-line bg-pk-warn/15 px-2.5 py-1 text-pk-meta font-semibold text-pk-warn hover:bg-pk-warn/25"
        >
          Resolver
        </.link>

        <%!-- On the calibration page the strip IS the fix: repeating the same
              sentence in a box below it was two thirds of what he called
              "poluído". One calibration per MONITOR, remembered — never adapted
              by arithmetic (Lucas, 2026-08-07), so a screen already calibrated
              is one click away and only a new one needs the wizard. --%>
        <button
          :if={@here? and @restorable?}
          id="restore-last-for-screen"
          phx-click="restore_last_calibration"
          class="shrink-0 rounded-lg border border-pk-warn-line bg-pk-warn/15 px-2.5 py-1 text-pk-meta font-bold text-pk-warn hover:bg-pk-warn/25"
        >
          Usar a última calibração desta tela ({@current})
        </button>
        <button
          :if={@here? and @rescalable?}
          phx-click="rescale_calibration"
          class="shrink-0 rounded-lg border border-pk-warn-line bg-pk-warn/15 px-2.5 py-1 text-pk-meta font-bold text-pk-warn hover:bg-pk-warn/25"
        >
          Corrigir para {@current}
        </button>
        <span
          :if={@here? and not @restorable? and not @rescalable?}
          class="text-pk-meta text-pk-text-3"
        >
          esta tela nunca foi calibrada — refaça a calibração completa (ela fica guardada)
        </span>
      </div>
    </div>
    """
  end

  def screen_mismatch_strip(assigns), do: ~H""

  # Two different accidents. Same size and shape = the ruler was wrong and every
  # mark is off by the same factor, which arithmetic CAN undo. A different shape
  # = another monitor, where each mark belongs to the screen it was made on.
  defp headline(true), do: "Esta calibração foi salva com a régua errada"
  defp headline(false), do: "A calibração é de outra tela"

  defp explains(true, saved, current),
    do:
      "ela diz #{saved} pt, mas é a MESMA tela de #{current} pt — dá pra consertar sem remarcar nada."

  defp explains(false, saved, current),
    do: "marcada em #{saved} pt, esta tem #{current} pt. O bot vai ler no lugar errado."

  # One menu destination. It is a component because it renders from two
  # different shapes (the ungrouped top, and each group's entries), and marking
  # an item as the current page in one place and forgetting it in the other is
  # exactly the divergence the unified header exists to kill.
  attr :entry, :any, required: true, doc: "`{key, label, icon}` from `nav_items/0`"
  attr :current_page, :atom, default: nil

  def nav_link(%{entry: {key, label, icon}} = assigns) do
    assigns =
      assign(assigns, key: key, label: label, icon: icon, current?: key == assigns[:current_page])

    ~H"""
    <.link
      id={nav_id(@key)}
      navigate={nav_path(@key)}
      aria-current={@current? && "page"}
      class={[
        "flex items-center gap-2 rounded-md px-3 py-2.5 text-pk-body transition",
        if(@current?,
          do: "bg-pk-ok-dim font-semibold text-pk-ok",
          else: "text-pk-text hover:bg-pk-raised hover:text-white"
        )
      ]}
    >
      <.icon name={@icon} class={["size-4 shrink-0", not @current? && "text-pk-text-2"]} />
      {@label}
    </.link>
    """
  end

  @doc "Every navigation destination, flat, in display order: `{key, label, icon}`."
  def nav_items, do: @top ++ Enum.flat_map(@groups, fn {_title, entries} -> entries end)

  @doc "The destinations that sit ABOVE the groups (Painel and the ⚙️)."
  def nav_top, do: @top

  @doc "The menu groups: `{title, [{key, label, icon}]}`. The top ones are not in here."
  def nav_groups, do: @groups

  @doc """
  The assigns `PokexWeb.HeaderState` maintains, ready to forward as a block:

      <Layouts.app flash={@flash} current_page={:pokedex} {Layouts.header(assigns)}>

  Repeating them by hand on nine pages is how one would end up with a
  half-dead header — no character, or the pill frozen on "Parado".
  """
  def header(assigns),
    do:
      Map.take(assigns, [
        :focused?,
        :bot_active?,
        :characters,
        :active_character,
        :alarm_sound,
        :alarm_muted_categories,
        :screen_check,
        :machine_others,
        :machine_first?
      ])

  # The id becomes DOM: `:fishing_lab` -> "app-nav-fishing-lab" (underscores in
  # markup ids are noise, and a test doing `refute html =~ "mini_game"` would
  # match the id).
  defp nav_id(key), do: "app-nav-" <> dashed(key)

  # Same rule for every id built from an atom — the alarm sectors learned it the
  # same way the nav did, by a `refute html =~ "mini_game"` matching an id.
  defp dashed(key), do: String.replace(to_string(key), "_", "-")

  defp nav_path(:panel), do: ~p"/"
  defp nav_path(:config), do: ~p"/config"
  defp nav_path(:calibration), do: ~p"/calibration"
  defp nav_path(:diagnostics), do: ~p"/diagnostics"
  defp nav_path(:fishing_lab), do: ~p"/fishing-lab"
  defp nav_path(:mini_game), do: ~p"/mini-game"
  defp nav_path(:world), do: ~p"/world"
  defp nav_path(:cavebot), do: ~p"/cavebot"
  defp nav_path(:timers), do: ~p"/timers"
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
