defmodule PokexWeb.TeamLive do
  @moduledoc """
  Lucas's Pokémon, on their own page (`/time`) — per his review of the first
  Pokédex cut: the team deserves a page of its own, including what he owns
  but keeps stored in the bank. Two lists (Time / Banco, movable both ways,
  each entry with its level), his character level + the hunt window, and the hunt
  suggestions ranked INSIDE that window — no more lv-5 recommendations at
  lv 88. The threats column ("cuidado") is gone by his call; the context
  still computes it for whoever wants it back.
  """
  use PokexWeb, :live_view
  @behaviour PokexWeb.CharacterAware

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Cavebot.Recording
  alias Pokex.Bots.Combat.{Loadout, Strategy}
  alias Pokex.Bots.Cavebot.Store, as: RouteStore
  alias Pokex.Pokedex
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Pokedex.Team
  alias Pokex.Pokedex.TeamIcons
  alias Pokex.Vision.Icons
  alias PokexWeb.PanelForms
  alias PokexWeb.PokedexStyle

  @impl true
  def mount(_params, _session, socket) do
    {:ok,
     socket
     |> assign(
       page_title: "Meu Time",
       portraits: [],
       portrait_msg: nil,
       # whose skill editor is open — one at a time, or six rows of selects
       # per pokémon turn the list into a wall
       open_skills: nil,
       species_names: Enum.map(Pokedex.search(%{}), & &1.name)
     )
     |> assign_hands()
     |> assign_team()}
  end

  # Each character has their OWN team (chars/<slug>/team.json). Switching in the
  # header has to swap the list right here, right now — this is the page that
  # lied the loudest without it.
  @impl PokexWeb.CharacterAware
  def on_character_change(socket), do: socket |> assign_hands() |> assign_team()

  @impl true
  def handle_event("add", %{"member" => name, "where" => where}, socket) do
    where = if where == "bank", do: :bank, else: :team

    case Team.add(String.trim(name), where) do
      {:ok, _data} ->
        {:noreply, assign_team(socket)}

      {:error, :unknown} ->
        {:noreply,
         assign_team(socket, "não conheço \"#{String.trim(name)}\" — usa um nome da Pokédex")}
    end
  end

  def handle_event("remove", %{"name" => name}, socket) do
    Team.remove(name)
    {:noreply, assign_team(socket)}
  end

  def handle_event("move", %{"name" => name, "to" => to}, socket) do
    Team.move(name, if(to == "bank", do: :bank, else: :team))
    {:noreply, assign_team(socket)}
  end

  # Reading the panel to SHOW him what the bot currently sees in each C+N row,
  # so naming a portrait is a matter of looking rather than remembering.
  def handle_event("scan_portraits", _params, socket) do
    {:noreply, assign(socket, portraits: read_portraits(), portrait_msg: nil)}
  end

  def handle_event("learn_portrait", %{"row" => row, "name" => name}, socket) do
    name = String.trim(name)
    row = String.to_integer(row)

    with true <- name != "",
         %{signature: signature} <- Enum.find(socket.assigns.portraits, &(&1.row == row)) do
      TeamIcons.learn(name, signature)

      {:noreply,
       assign(socket,
         portraits: read_portraits(),
         portrait_msg: "aprendi o retrato de #{name} — o slot dele agora é lido, não configurado"
       )}
    else
      _blank_or_missing -> {:noreply, socket}
    end
  end

  def handle_event("forget_portrait", %{"name" => name}, socket) do
    TeamIcons.forget(name)
    {:noreply, assign(socket, portraits: read_portraits(), portrait_msg: "esqueci #{name}")}
  end

  def handle_event("set_level", %{"name" => name} = params, socket) do
    case PanelForms.parse_int(params["level"], 1..999) do
      {:ok, level} -> Team.set_level(name, level)
      # blank clears; garbage changes nothing
      :error -> if params["level"] == "", do: Team.set_level(name, nil)
    end

    {:noreply, assign_team(socket)}
  end

  # What each of a pokémon's skills is FOR. One job per key, so choosing a new
  # one MOVES it — which is why this is a select per key and not a wall of
  # toggles: the exclusivity is the control's shape, not a rule to enforce.
  #
  # The WHOLE form comes back on every change (one select per key, each with
  # its own name) and the profile is rebuilt from it. The first cut sent the
  # changed key in `phx-value-key`, which a form event does not carry — six
  # selects sharing one name, and nothing would have saved in a real browser.
  def handle_event("set_skills", %{"name" => name} = params, socket) do
    Team.set_skills(name, SkillProfile.from_form(params["skill"]))
    {:noreply, assign_team(socket)}
  end

  # Which pokémon is on the field. Reading it off the screen is the honest way
  # and does not exist yet; waiting for it would keep every rule that depends on
  # knowing (open with area, never spend the control) unimplemented behind a
  # calibration. So he says it, and the fight obeys immediately — Team announces
  # the change and Combat re-reads without a restart.
  def handle_event("set_active", %{"active" => name}, socket) do
    Team.set_active(if(name == "", do: nil, else: name))
    {:noreply, assign_team(socket)}
  end

  def handle_event("toggle_skills", %{"name" => name}, socket) do
    open = if socket.assigns.open_skills == name, do: nil, else: name
    {:noreply, assign(socket, open_skills: open)}
  end

  def handle_event("save_hunt_window", params, socket) do
    case PanelForms.parse_int(params["player_level"], 1..999) do
      {:ok, level} -> Team.set_player_level(level)
      :error -> if params["player_level"] == "", do: Team.set_player_level(nil)
    end

    case PanelForms.parse_int(params["level_margin"], 1..300) do
      {:ok, margin} -> Team.set_level_margin(margin)
      :error -> :ok
    end

    {:noreply, assign_team(socket)}
  end

  # Where his keys ALREADY live, so this page stops talking about a different
  # game than the other two: the routes hold the combo his hands recorded, and
  # Settings holds what Combat presses on its own.
  #
  # Read on mount and on a character switch, NOT inside `assign_team/2`: that
  # one runs on every level keystroke, and `RouteStore.all/0` reads and decodes
  # the whole routes file (the disk lesson from the recording audit).
  defp assign_hands(socket) do
    used =
      RouteStore.all()
      |> Recording.habitual_skills()
      |> SkillProfile.in_firing_order()

    assign(socket,
      used_keys: used,
      combat_keys: Pokex.Settings.get(:skill_keys) || []
    )
  end

  # A bar of his own, or the shared calibration standing in for it.
  defp bar_text(%{count: count}) when is_integer(count), do: "🎛 barra própria · #{count} skills"
  defp bar_text(_none), do: "🎛 sem barra própria — usa a da calibração"

  defp keys_text([]), do: "nenhuma"
  defp keys_text(keys), do: Enum.join(keys, " ")

  # The kill, written the way he says it: the area opens because it needs no
  # target, and the single-target skills close once something is marked
  # ("skill single target só funciona se eu estiver marcando um alvo"). `nil`
  # when this pokémon has nothing to kill with — an empty string there would
  # read as a rendering bug instead of as work still to do.
  defp combo_text(profile) do
    case {SkillProfile.keys(profile, :aoe), SkillProfile.keys(profile, :single)} do
      {[], []} -> nil
      {area, []} -> Enum.join(area, "+")
      {[], single} -> "🎯 " <> Enum.join(single, "+")
      {area, single} -> Enum.join(area, "+") <> " → 🎯 " <> Enum.join(single, "+")
    end
  end

  # The jobs that are NOT the kill: the aura he holds while gathering, the heal
  # nobody schedules, and the control that has to survive the fight to be there
  # for the revive.
  defp off_combo(profile) do
    Enum.reject(SkillProfile.moments(profile), fn {category, _keys} ->
      SkillProfile.in_combo?(category)
    end)
  end

  # Everything on this page derives from the saved team file + the Pokédex —
  # one funnel keeps the lists, the window and the suggestions in sync.
  defp assign_team(socket, team_msg \\ nil) do
    members = Team.members()
    bank = Team.bank()
    player_level = Team.player_level()
    margin = Team.level_margin()

    suggestions =
      if members == [] do
        %{targets: [], window: :all}
      else
        Pokedex.hunt_suggestions(Enum.map(members, & &1.name), %{
          player_level: player_level,
          level_margin: margin
        })
      end

    assign(socket,
      team: with_entries(members),
      bank: with_entries(bank),
      active: Team.active(),
      loadout: Loadout.current(),
      player_level: player_level,
      level_margin: margin,
      targets: Enum.take(suggestions.targets, 24),
      window: suggestions.window,
      team_msg: team_msg
    )
  end

  # One capture of the team column, sliced into the five C+N portraits: what
  # the bot sees, its current guess, and the signature that naming would store.
  defp read_portraits do
    with fix when not is_nil(fix) <- Pokex.Layout.current(),
         {cx0, cy0, pw, ph} when not is_nil(cx0) <- Pokex.Layout.region(:team_icon_first, fix),
         {rx, ry, rw, rh} <- Pokex.Layout.region(:team_column, fix),
         {:ok, frame} <- Capture.frame({rx, ry, rw, rh}, "team_portraits.png") do
      learned = TeamIcons.all()

      for row <- 0..4//1 do
        centre =
          {cx0 - rx + div(pw, 2), cy0 - ry + div(ph, 2) + row * 67, div(ph, 2)}

        signature = Icons.signature(frame, centre)

        %{
          row: row,
          slot: row + 2,
          signature: signature,
          guess:
            case Icons.match(signature, learned) do
              {name, score} -> %{name: name, score: score}
              nil -> nil
            end
        }
      end
    else
      _unavailable -> []
    end
  end

  defp with_entries(list) do
    for %{name: name, level: level} = member <- list,
        entry = Pokedex.get(name),
        entry != nil,
        do: %{
          name: name,
          level: level,
          entry: entry,
          skills: Map.get(member, :skills) || %{},
          bar: Map.get(member, :bar)
        }
  end

  # The hotbar as far as THIS pokémon's bar goes: reading past the last slot
  # would offer jobs for keys that do not exist — and stopping short of it hides
  # the ones that do. The row above says "barra própria · 9 skills"; offering
  # six selects under that sentence is the same screen contradicting itself.
  # Only a pokémon with no bar of its own falls back to the shared count.
  defp hotbar_keys(%{bar: %{count: count}}) when is_integer(count) and count in 1..10,
    do: Enum.take(SkillProfile.hotbar_keys(), count)

  defp hotbar_keys(_no_own_bar) do
    count = Pokex.Settings.get(:skill_bar_count) || 6
    Enum.take(SkillProfile.hotbar_keys(), count)
  end

  defp window_note(:all, _margin), do: nil

  defp window_note({:window, lo, hi}, margin),
    do: "alvos entre lv #{lo} e #{hi} (teu level ±#{margin})"

  defp window_note({:below, player_level}, _margin),
    do: "nada na janela — mostrando os mais próximos ABAIXO do teu lv #{player_level}"

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:team}
      {Layouts.header(assigns)}
      max_width="max-w-[900px]"
    >
      <div class="space-y-3">
        <section id="portraits" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <div class="flex items-start justify-between gap-3">
            <div>
              <h2 class="text-sm font-bold">Retratos do time</h2>
              <p class="mt-0.5 text-[11px] leading-relaxed text-[#7f8992]">
                A ordem dos atalhos C+N muda conforme você joga, então o bot não pode ter o slot
                configurado — ele LÊ quem está em cada linha, toda vez. Para isso precisa conhecer
                a carinha de cada um: varra o painel e diga quem é quem. Uma vez só, por pokémon.
              </p>
            </div>
            <button class="btn btn-sm btn-primary shrink-0" phx-click="scan_portraits">
              Varrer painel
            </button>
          </div>

          <p :if={@portrait_msg} class="mt-2 font-mono text-[10px] text-[#e7ca82]">
            {@portrait_msg}
          </p>

          <ul :if={@portraits != []} class="mt-3 space-y-2">
            <li
              :for={portrait <- @portraits}
              id={"portrait-#{portrait.slot}"}
              class="flex flex-wrap items-center gap-2 rounded-lg border border-[#293238] bg-[#101418] px-2.5 py-2"
            >
              <span class="font-mono text-xs font-bold text-[#8b949d]">C+{portrait.slot}</span>

              <span :if={portrait.guess} class="font-mono text-[11px] text-[#37d07d]">
                {portrait.guess.name}
                <span class="text-[#5d6670]">({round(portrait.guess.score * 100)}%)</span>
              </span>
              <span :if={is_nil(portrait.guess)} class="font-mono text-[11px] text-[#f2c45b]">
                não sei quem é
              </span>

              <form phx-submit="learn_portrait" class="ml-auto flex items-center gap-1.5">
                <input type="hidden" name="row" value={portrait.row} />
                <input
                  name="name"
                  list="team-names"
                  placeholder="quem é?"
                  autocomplete="off"
                  class="h-7 w-40 rounded border border-[#293238] bg-[#090d0f] px-2 font-mono text-[11px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
                />
                <button class="btn btn-xs h-7">Aprender</button>
              </form>
            </li>
          </ul>

          <datalist id="team-names">
            <option :for={row <- @team} value={row.name} />
            <option :for={row <- @bank} value={row.name} />
          </datalist>

          <p :if={TeamIcons.known() != []} class="mt-2 flex flex-wrap gap-1.5">
            <button
              :for={name <- TeamIcons.known()}
              phx-click="forget_portrait"
              phx-value-name={name}
              title="esquecer este retrato"
              class="cursor-pointer rounded border border-[#293238] px-1.5 py-0.5 font-mono text-[10px] text-[#8b949d] hover:border-[#5f292f] hover:text-[#ff9ca4]"
            >
              {name} ✕
            </button>
          </p>
        </section>

        <section class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <form
            id="hunt-window-form"
            phx-change="save_hunt_window"
            class="flex flex-wrap items-center gap-1.5 font-mono text-[10px] text-[#77828a]"
          >
            <span>meu level</span>
            <input
              name="player_level"
              type="number"
              min="1"
              max="999"
              value={@player_level}
              phx-debounce="500"
              class="h-8 w-16 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-sm text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            />
            <span>· janela ±</span>
            <input
              name="level_margin"
              type="number"
              min="1"
              max="300"
              value={@level_margin}
              phx-debounce="500"
              class="h-8 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-sm text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            />
            <span class="text-[#59636b]">
              — as sugestões miram caças perto da tua força
            </span>
          </form>
        </section>

        <form id="team-add-form" phx-submit="add" class="flex flex-wrap items-center gap-2">
          <input
            name="member"
            list="species-names"
            placeholder="ex.: Venusaur"
            autocomplete="off"
            class="input input-bordered h-9 w-52 bg-[#090d0f] font-mono text-sm"
          />
          <datalist id="species-names">
            <option :for={name <- @species_names} value={name} />
          </datalist>
          <select
            name="where"
            class="select select-bordered h-9 bg-[#090d0f] font-mono text-sm"
          >
            <option value="team">→ time</option>
            <option value="bank">→ banco</option>
          </select>
          <button class="btn h-9 border-0 bg-[#37d07d] px-3 text-xs font-bold text-[#06140c] hover:bg-[#45dd88]">
            Adicionar
          </button>
          <span :if={@team_msg} id="team-msg" class="text-[11px] text-[#e7ca82]">{@team_msg}</span>
        </form>

        <section id="team-list" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <h2 class="mb-2 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🧢 time ({length(@team)})
          </h2>

          <%!-- The three places his keys live, named in one paragraph. He came
                here looking for "o combo de cada um" and found neither the word
                nor a hint of which screen owns it. --%>
          <p id="skills-map" class="mb-2 text-[11px] leading-relaxed text-[#7f8992]">
            Tuas teclas vivem em três lugares.
            <.link navigate={~p"/cavebot"} class="text-[#7cc0e8] hover:underline">
              A rota gravada
            </.link>
            guarda o combo que tuas mãos apertaram em cada matança — as teclas que
            tu repete são <span id="skills-map-recorded" class="font-mono text-[#dce1e4]">{keys_text(@used_keys)}</span>,
            e é esse combo que a caçada dispara hoje.
            <.link navigate={~p"/config"} class="text-[#7cc0e8] hover:underline">
              O combate
            </.link>
            aperta
            <span id="skills-map-combat" class="font-mono text-[#dce1e4]">{keys_text(@combat_keys)}</span>
            sozinho durante a luta. E aqui embaixo tu diz o que cada tecla
            <b class="font-bold text-[#c3cad0]">faz</b>
            — é isso que vai deixar o mesmo plano servir quando tu trocar de pokémon.
          </p>

          <%!-- Which one is on the field. The bot cannot read the portrait yet,
                and every rule that depends on knowing (abrir com área, guardar
                o controle) would sit unimplemented waiting for it. --%>
          <form
            id="active-form"
            phx-change="set_active"
            class="mb-2 flex flex-wrap items-center gap-2 rounded-lg border border-[#293238] bg-[#101418] px-2.5 py-2"
          >
            <span class="font-mono text-[10px] text-[#8b949d]">caçando com</span>
            <select
              name="active"
              aria-label="Pokémon em campo"
              class="h-8 rounded border border-[#293238] bg-[#090d0f] px-2 font-mono text-[11px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            >
              <option value="" selected={is_nil(@active)}>— nenhum —</option>
              <option :for={row <- @team} value={row.name} selected={@active == row.name}>
                {row.name}
              </option>
            </select>
            <%!-- `attacks?` and not "has a loadout": a pokémon can be classified
                  (an aura, a control) and still have nothing to fight with. --%>
            <span
              :if={Loadout.attacks?(@loadout)}
              id="active-opening"
              class="font-mono text-[10px] text-[#3de083]"
            >
              a luta abre com 💥 {Enum.join(Strategy.opening(@loadout), " ")}
            </span>
            <span :if={is_nil(@active)} class="font-mono text-[10px] text-[#7f8992]">
              — sem escolha a luta aperta a lista fixa do /config, sem saber o que cada tecla faz
            </span>
            <span
              :if={@active && !Loadout.attacks?(@loadout)}
              class="font-mono text-[10px] text-[#f2c45b]"
            >
              — sem skill de área nem de alvo único classificada, a luta cai na lista fixa
            </span>
          </form>

          <p :if={@team == []} class="text-[11px] text-[#7f8992]">
            cadastra teus Pokémon e eu te digo quem vale a caçada
          </p>
          <ul class="space-y-1">
            <.member_row
              :for={row <- @team}
              row={row}
              other="bank"
              other_label="→ banco"
              open?={@open_skills == row.name}
              keys={hotbar_keys(row)}
              used={@used_keys}
              warn?={true}
            />
          </ul>
        </section>

        <section id="bank-list" class="rounded-lg border border-[#232b30] bg-[#111519] p-3">
          <h2 class="mb-2 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🏦 banco ({length(@bank)})
          </h2>
          <p :if={@bank == []} class="text-[11px] text-[#7f8992]">
            o que você tem guardado mas não caça com — pra não perder de vista
          </p>
          <ul class="space-y-1">
            <%!-- No warning down here: the bank is inventory, not the six he
                  hunts with, and fifteen amber lines would drown the ones on
                  the team that mean something. --%>
            <.member_row
              :for={row <- @bank}
              row={row}
              other="team"
              other_label="→ time"
              open?={@open_skills == row.name}
              keys={hotbar_keys(row)}
              used={@used_keys}
              warn?={false}
            />
          </ul>
        </section>

        <section
          :if={@targets != []}
          id="hunt-card"
          class="rounded-lg border border-[#232b30] bg-[#111519] p-3"
        >
          <h2 class="mb-0.5 font-mono text-[10px] font-bold uppercase tracking-[0.12em] text-[#69737b]">
            🎯 melhores caçadas pro teu time
          </h2>
          <p
            :if={window_note(@window, @level_margin)}
            id="hunt-window-note"
            class="mb-1.5 font-mono text-[9px] text-[#8b949d]"
          >
            {window_note(@window, @level_margin)}
          </p>
          <ul id="hunt-targets" class="grid gap-1 lg:grid-cols-2">
            <li :for={row <- @targets}>
              <.link
                navigate={~p"/pokedex/#{row.entry.name}"}
                class="block rounded-lg border border-[#232b30] bg-[#101418] px-2.5 py-1.5 transition hover:border-[#37d07d]/60"
              >
                <div class="flex items-center gap-2">
                  <img
                    :if={row.entry.sprite}
                    src={"/" <> row.entry.sprite}
                    alt={row.entry.name}
                    onerror="this.style.display='none'"
                    class="size-6 shrink-0 object-contain"
                  />
                  <p class="min-w-0 flex-1 truncate text-sm font-semibold">
                    {row.entry.name}
                    <span class="font-mono text-[9px] font-normal text-[#737d85]">
                      lv {row.entry.level || "?"}
                    </span>
                  </p>
                  <span class="font-mono text-[10px] font-bold text-[#37d07d]">+{row.score}</span>
                </div>
                <p class="mt-0.5 flex flex-wrap gap-1 font-mono text-[9px]">
                  <span class="rounded bg-[#0d3822] px-1 py-0.5 text-[#3de083]">
                    {Enum.join(row.hits, "+")} fere ({row.member})
                  </span>
                  <span
                    :if={row.resisted != []}
                    class="rounded bg-[#241114] px-1 py-0.5 text-[#ff9ca4]"
                  >
                    resiste {Enum.join(row.resisted, "+")}
                  </span>
                  <span :if={row.shiny?} class="rounded bg-[#211b0d] px-1 py-0.5 text-[#f3ba4e]">
                    ✨ tem shiny
                  </span>
                  <span
                    :for={lure <- Enum.take(row.lures, 2)}
                    class="rounded bg-[#101d24] px-1 py-0.5 text-[#7cc0e8]"
                  >
                    🎣 {lure.lure} lv{lure.fishing_level}
                  </span>
                </p>
              </.link>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :other, :string, required: true
  attr :other_label, :string, required: true

  attr :open?, :boolean, default: false
  attr :keys, :list, default: []
  attr :used, :list, default: []
  attr :warn?, :boolean, default: false

  defp member_row(assigns) do
    ~H"""
    <li class="rounded-lg border border-[#293238] bg-[#101418] px-2.5 py-1.5">
      <div class="flex items-center gap-2">
        <img
          :if={@row.entry.sprite}
          src={"/" <> @row.entry.sprite}
          alt={@row.name}
          onerror="this.style.display='none'"
          class="size-6 shrink-0 object-contain"
        />
        <.link
          navigate={~p"/pokedex/#{@row.name}"}
          class="min-w-0 flex-1 truncate text-sm font-semibold hover:underline"
        >
          {@row.name}<span :if={@row.entry.shiny_of}> ✨</span>
          <span
            :for={el <- @row.entry.elements}
            class="ml-1 inline-flex items-center gap-0.5 rounded px-1 py-0.5 align-middle font-mono text-[9px] font-normal"
            style={PokedexStyle.element_style(el)}
          >
            {el}
          </span>
        </.link>
        <form
          id={"level-form-" <> String.replace(@row.name, ~r/\W+/, "-")}
          phx-change="set_level"
          class="flex items-center gap-1 font-mono text-[9px] text-[#737d85]"
        >
          <input type="hidden" name="name" value={@row.name} />
          <span>lv</span>
          <input
            name="level"
            type="number"
            min="1"
            max="999"
            value={@row.level}
            phx-debounce="500"
            class="h-7 w-14 rounded border border-[#293238] bg-[#090d0f] px-1 text-center font-mono text-[11px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
          />
        </form>
        <button
          phx-click="move"
          phx-value-name={@row.name}
          phx-value-to={@other}
          class="cursor-pointer font-mono text-[10px] text-[#89939a] hover:text-white"
        >
          {@other_label}
        </button>
        <%!-- It used to be bare grey 10px text between "→ banco" and "×" — the
              one control on the row that opens an editor, dressed exactly like
              the two that do not. A border and his own word for it ("combo")
              are what make it findable. --%>
        <button
          id={"skills-toggle-" <> String.replace(@row.name, ~r/\W+/, "-")}
          phx-click="toggle_skills"
          phx-value-name={@row.name}
          aria-expanded={to_string(@open?)}
          aria-label={"Combo de " <> @row.name}
          title="pra que serve cada skill dele — e o combo que sai disso"
          class={[
            "shrink-0 cursor-pointer rounded border px-2 py-1 font-mono text-[10px] transition",
            if(@open?,
              do: "border-[#37d07d] bg-[#0d3822] text-[#3de083]",
              else: "border-[#293238] text-[#89939a] hover:border-[#4a565e] hover:text-white"
            )
          ]}
        >
          💥 combo
        </button>
        <button
          phx-click="remove"
          phx-value-name={@row.name}
          title="remover"
          class="cursor-pointer text-[#89939a] hover:text-[#ff9ca4]"
        >
          ×
        </button>
      </div>

      <%!-- A row with nothing configured used to render NOTHING — six pokémon
            in a row saying nothing reads as "there is nothing to do here",
            which is exactly the opposite of the truth. --%>
      <p
        :if={!@open? and (@row.skills != %{} or @warn?)}
        class="mt-1 flex flex-wrap items-center gap-x-2 pl-8 font-mono text-[9px]"
      >
        <span :if={@row.skills == %{}} class="text-[#f2c45b]">
          nenhuma skill classificada — abre o 💥 combo e diz o que cada tecla faz
        </span>

        <span :if={@row.skills != %{} and combo_text(@row.skills)} class="text-[#7f8992]">
          💥 {combo_text(@row.skills)}
        </span>
        <span :if={@row.skills != %{} and is_nil(combo_text(@row.skills))} class="text-[#f2c45b]">
          nada pra matar: falta uma skill de área
        </span>

        <%!-- the other moments, dimmer: they are not the kill --%>
        <span :for={{category, keys} <- off_combo(@row.skills)} class="text-[#69737b]">
          {SkillProfile.icon(category)} {Enum.join(keys, "+")}
        </span>

        <%!-- The bar is HIS, not the screen's: different pokémon carry different
              numbers of moves, and the READY references are the skill icons. --%>
        <.link
          navigate={~p"/calibration?#{[bar: @row.name]}"}
          class={[
            "ml-auto",
            if(@row.bar, do: "text-[#69737b] hover:underline", else: "text-[#f2c45b] hover:underline")
          ]}
        >
          {bar_text(@row.bar)}
        </.link>
      </p>

      <%!-- One select per hotbar key: a skill has exactly ONE job, so a
            chooser that can only hold one answer is the honest control. --%>
      <form
        :if={@open?}
        id={"skills-form-" <> String.replace(@row.name, ~r/\W+/, "-")}
        phx-change="set_skills"
        class="mt-2 border-t border-[#293238] pt-2"
      >
        <input type="hidden" name="name" value={@row.name} />

        <%!-- The kill, and ONLY the kill. The first cut printed every
              classified key joined left to right and he threw it back: "eu
              seleciono, mas o combo não é uma junção". --%>
        <p class="font-mono text-[10px] text-[#8b949d]">
          na matança:
          <span :if={combo_text(@row.skills)} class="font-bold text-[#3de083]">
            💥 {combo_text(@row.skills)}
          </span>
          <span :if={is_nil(combo_text(@row.skills))} class="text-[#f2c45b]">
            ainda nada — classifica pelo menos uma como área
          </span>
        </p>
        <p class="mb-2 font-mono text-[9px] text-[#69737b]">
          a área abre tudo de uma vez (não precisa de alvo) e o alvo único fecha, depois de
          marcar · salva sozinho
        </p>

        <div class="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
          <label
            :for={key <- @keys}
            class="flex items-center gap-1.5 font-mono text-[10px] text-[#8b949d]"
          >
            <%!-- nowrap: the used-key dot pushed "1•" onto a second line and
                  every label in the grid lost its baseline. --%>
            <span class="w-12 shrink-0 whitespace-nowrap text-right">
              skill {key}<span
                :if={key in @used}
                title="tu aperta esta tecla nas tuas rotas gravadas"
                class="text-[#3de083]"
              >•</span>
            </span>
            <select
              name={"skill[" <> key <> "]"}
              aria-label={"Skill " <> key <> " de " <> @row.name}
              class="h-7 w-full min-w-0 rounded border border-[#293238] bg-[#090d0f] px-1 font-mono text-[10px] text-[#dce1e4] focus:border-[#36d47c] focus:outline-none"
            >
              <option value="none" selected={@row.skills[key] == nil}>—</option>
              <option
                :for={category <- SkillProfile.categories()}
                value={category}
                title={SkillProfile.moment(category)}
                selected={@row.skills[key] == category}
              >
                {SkillProfile.icon(category)} {SkillProfile.label(category)}
              </option>
            </select>
          </label>
        </div>

        <%!-- Every job he used that is NOT the kill, each with the moment it
              belongs to. The control one carries its own warning: spending it
              in an ordinary fight is exactly why it is barred from the combo. --%>
        <ul
          :if={off_combo(@row.skills) != []}
          id={"skills-moments-" <> String.replace(@row.name, ~r/\W+/, "-")}
          class="mt-2 space-y-0.5 border-t border-[#293238] pt-1.5 font-mono text-[9px] text-[#69737b]"
        >
          <li :for={{category, keys} <- off_combo(@row.skills)}>
            {SkillProfile.icon(category)}
            <span class="text-[#8b949d]">
              {SkillProfile.label(category)} {Enum.join(keys, "+")}
            </span>
            — {SkillProfile.moment(category)}
            <span :if={category == :crowd} class="text-[#e7ca82]">
              (fora do combo de propósito: gasta na luta e ela não está lá pro revive)
            </span>
          </li>
        </ul>

        <%!-- Ten dropdowns, and his hands use four of them. Which four is not
              a question for this page to ask — the recorded routes answer it. --%>
        <p :if={@used != []} class="mt-1.5 font-mono text-[9px] text-[#69737b]">
          <span class="text-[#3de083]">•</span>
          são as teclas que tu repete nas matanças das tuas rotas ({Enum.join(@used, " ")}) —
          começa por elas
        </p>
      </form>
    </li>
    """
  end
end
