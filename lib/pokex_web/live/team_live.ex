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
       # QUEM ESTÁ ARMADO PRA SAIR. Apagar um pokémon era um clique só, num ✕
       # cinza de 10px colado no botão que abre as skills — e ele apagou
       # pokémon sem querer, achando que aquilo FECHAVA o painel (28/08). Agora
       # o ✕ arma, e quem apaga é um botão vermelho que nasce onde não havia
       # nada pra clicar por engano.
       removing: nil,
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

  # ARMAR, não apagar. O segundo clique tem que cair em OUTRO lugar da tela,
  # senão um clique duplo por engano faz o mesmo estrago que o clique único.
  def handle_event("ask_remove", %{"name" => name}, socket),
    do: {:noreply, assign(socket, removing: name)}

  def handle_event("cancel_remove", _params, socket),
    do: {:noreply, assign(socket, removing: nil)}

  def handle_event("remove", %{"name" => name}, socket) do
    Team.remove(name)

    {:noreply,
     socket
     |> assign(removing: nil, open_skills: nil)
     |> assign_team("#{name} saiu da lista — cadastra de novo se foi sem querer")}
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
    # O MESMO FORMULÁRIO carrega as duas respostas sobre a mesma tecla: o que
    # ela faz e de quanto em quanto tempo dá pra usar. Salvar junto é o que
    # impede um lado de ficar velho em relação ao outro.
    Team.set_cooldowns(name, SkillProfile.cooldowns_from_form(params["cd"]))
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

  # A bar of his own, or the shared calibration standing in for it — said as an
  # ACTION, because this text is a link and always was. Written as a status
  # ("sem barra própria — usa a da calibração") it read as information, and he
  # hunted for the feature on two pages without recognising that he was looking
  # straight at the way in.
  defp bar_text(%{count: count}) when is_integer(count),
    do: "🎛 barra própria · #{count} skills — recalibrar"

  defp bar_text(_none), do: "🎛 sem barra própria — calibrar"

  # The long half lives in the tooltip: the row is already dense, and 380px of
  # explanation next to five other scraps is how the link disappeared the first
  # time. The control says what it does; hovering says what happens if you don't.
  defp bar_title(%{count: count}) when is_integer(count),
    do: "A barra de #{count} skills deste pokémon — recalibrar sobrescreve só a dele"

  defp bar_title(_none),
    do:
      "Este pokémon ainda usa a barra da calibração de tela. Calibrar guarda uma só dele, e ela volta sozinha quando você trocar."

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
         {:ok, frame} <- Capture.frame({rx, ry, rw, rh}, "team_portraits.raw") do
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
          cooldowns: Map.get(member, :cooldowns) || %{},
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
        <section class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <form
            id="hunt-window-form"
            phx-change="save_hunt_window"
            class="flex flex-wrap items-center gap-1.5 font-mono text-pk-meta text-pk-text-2"
          >
            <span>meu level</span>
            <input
              name="player_level"
              type="number"
              min="1"
              max="999"
              value={@player_level}
              phx-debounce="500"
              class="h-8 w-16 rounded border border-pk-line bg-pk-bg px-1 text-center font-mono text-pk-title text-pk-text focus:border-pk-ok focus:outline-none"
            />
            <span>· janela ±</span>
            <input
              name="level_margin"
              type="number"
              min="1"
              max="300"
              value={@level_margin}
              phx-debounce="500"
              class="h-8 w-14 rounded border border-pk-line bg-pk-bg px-1 text-center font-mono text-pk-title text-pk-text focus:border-pk-ok focus:outline-none"
            />
            <span class="text-pk-text-3">
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
            class="input input-bordered h-9 w-52 bg-pk-bg font-mono text-pk-title"
          />
          <datalist id="species-names">
            <option :for={name <- @species_names} value={name} />
          </datalist>
          <select
            name="where"
            class="select select-bordered h-9 bg-pk-bg font-mono text-pk-title"
          >
            <option value="team">→ time</option>
            <option value="bank">→ banco</option>
          </select>
          <button class="btn h-9 border-0 bg-pk-ok px-3 text-pk-body font-bold text-pk-bg hover:bg-pk-ok/90">
            Adicionar
          </button>
          <span :if={@team_msg} id="team-msg" class="text-pk-body text-pk-warn">{@team_msg}</span>
        </form>

        <section id="team-list" class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-2 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            🧢 time ({length(@team)})
          </h2>

          <%!-- The three places his keys live, named in one paragraph. He came
                here looking for "o combo de cada um" and found neither the word
                nor a hint of which screen owns it. --%>
          <p id="skills-map" class="mb-2 text-pk-body leading-relaxed text-pk-text-2">
            Tuas teclas vivem em três lugares.
            <.link navigate={~p"/cavebot"} class="text-pk-info hover:underline">
              A rota gravada
            </.link>
            guarda o combo que tuas mãos apertaram em cada matança — as teclas que
            tu repete são <span id="skills-map-recorded" class="font-mono text-pk-text">{keys_text(@used_keys)}</span>,
            e é essa sequência que a caçada dispara hoje.
            <.link navigate={~p"/config"} class="text-pk-info hover:underline">
              O combate
            </.link>
            aperta
            <span id="skills-map-combat" class="font-mono text-pk-text">{keys_text(@combat_keys)}</span>
            sozinho durante a luta. E aqui embaixo tu diz o que cada tecla
            <b class="font-bold text-pk-text">faz</b>
            — é isso que vai deixar o mesmo plano servir quando tu trocar de pokémon.
          </p>

          <%!-- Which one is on the field. The bot cannot read the portrait yet,
                and every rule that depends on knowing (abrir com área, guardar
                o controle) would sit unimplemented waiting for it. --%>
          <form
            id="active-form"
            phx-change="set_active"
            class="mb-2 flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-2.5 py-2"
          >
            <span class="font-mono text-pk-meta text-pk-text-2">caçando com</span>
            <select
              name="active"
              aria-label="Pokémon em campo"
              class="h-8 rounded border border-pk-line bg-pk-bg px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
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
              class="font-mono text-pk-meta text-pk-ok"
            >
              a luta abre com 💥 {Enum.join(Strategy.opening(@loadout), " ")}
            </span>
            <span :if={is_nil(@active)} class="font-mono text-pk-meta text-pk-text-2">
              — sem escolha a luta aperta a lista fixa do /config, sem saber o que cada tecla faz
            </span>
            <span
              :if={@active && !Loadout.attacks?(@loadout)}
              class="font-mono text-pk-meta text-pk-warn"
            >
              — sem skill de área nem de alvo único classificada, a luta cai na lista fixa
            </span>
          </form>

          <p :if={@team == []} class="text-pk-body text-pk-text-2">
            cadastra teus Pokémon e eu te digo quem vale a caçada
          </p>
          <ul class="space-y-1">
            <.member_row
              :for={row <- @team}
              row={row}
              other="bank"
              other_label="→ banco"
              open?={@open_skills == row.name}
              removing?={@removing == row.name}
              keys={hotbar_keys(row)}
              used={@used_keys}
              warn?={true}
            />
          </ul>
        </section>

        <section id="bank-list" class="rounded-lg border border-pk-line bg-pk-surface p-3">
          <h2 class="mb-2 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            🏦 banco ({length(@bank)})
          </h2>
          <p :if={@bank == []} class="text-pk-body text-pk-text-2">
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
              removing?={@removing == row.name}
              keys={hotbar_keys(row)}
              used={@used_keys}
              warn?={false}
            />
          </ul>
        </section>

        <section
          :if={@targets != []}
          id="hunt-card"
          class="rounded-lg border border-pk-line bg-pk-surface p-3"
        >
          <h2 class="mb-0.5 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
            🎯 melhores caçadas pro teu time
          </h2>
          <p
            :if={window_note(@window, @level_margin)}
            id="hunt-window-note"
            class="mb-1.5 font-mono text-pk-meta text-pk-text-2"
          >
            {window_note(@window, @level_margin)}
          </p>
          <ul id="hunt-targets" class="grid gap-1 lg:grid-cols-2">
            <li :for={row <- @targets}>
              <.link
                navigate={~p"/pokedex/#{row.entry.name}"}
                class="block rounded-lg border border-pk-line bg-pk-raised px-2.5 py-1.5 transition hover:border-pk-ok/60"
              >
                <div class="flex items-center gap-2">
                  <img
                    :if={row.entry.sprite}
                    src={"/" <> row.entry.sprite}
                    alt={row.entry.name}
                    onerror="this.style.display='none'"
                    class="size-6 shrink-0 object-contain"
                  />
                  <p class="min-w-0 flex-1 truncate text-pk-title font-semibold">
                    {row.entry.name}
                    <span class="font-mono text-pk-meta font-normal text-pk-text-3">
                      lv {row.entry.level || "?"}
                    </span>
                  </p>
                  <span class="font-mono text-pk-meta font-bold text-pk-ok">+{row.score}</span>
                </div>
                <p class="mt-0.5 flex flex-wrap gap-1 font-mono text-pk-meta">
                  <span class="rounded bg-pk-ok-dim px-1 py-0.5 text-pk-ok">
                    {Enum.join(row.hits, "+")} fere ({row.member})
                  </span>
                  <span
                    :if={row.resisted != []}
                    class="rounded bg-pk-danger-dim px-1 py-0.5 text-pk-danger"
                  >
                    resiste {Enum.join(row.resisted, "+")}
                  </span>
                  <span :if={row.shiny?} class="rounded bg-pk-warn-dim px-1 py-0.5 text-pk-warn">
                    ✨ tem shiny
                  </span>
                  <span
                    :if={row.entry.tier}
                    class="rounded bg-pk-info-dim px-1 py-0.5 text-pk-info"
                  >
                    🏅 tier {row.entry.tier}
                  </span>
                </p>
              </.link>
            </li>
          </ul>
        </section>
        <%!-- OS RETRATOS SÃO TRABALHO DE UMA VEZ POR POKÉMON, e ocupavam o
              topo da página — acima do time, do banco e das caçadas, que são o
              que ele abre esta tela pra ver. Dobrado e no fim: continua a um
              clique, sem custar a primeira tela toda vez. --%>
        <details id="portraits-fold" class="rounded-lg border border-pk-line bg-pk-surface">
          <summary class="flex cursor-pointer list-none items-center gap-2 px-3 py-2.5 text-pk-body font-bold text-pk-text [&::-webkit-details-marker]:hidden">
            <.icon name="hero-user-circle" class="size-4 shrink-0 text-pk-text-3" /> Retratos do time
            <span class="font-mono text-pk-meta font-normal text-pk-text-3">
              ensina o bot a ler quem está em cada C+N · uma vez por pokémon
            </span>
            <.icon name="hero-chevron-down" class="ml-auto size-4 shrink-0 text-pk-text-3" />
          </summary>
          <div class="border-t border-pk-line p-3">
            <section id="portraits">
              <div class="flex items-start justify-between gap-3">
                <div>
                  <h3 class="text-pk-body font-bold">Retratos do time</h3>
                  <p class="mt-0.5 text-pk-body leading-relaxed text-pk-text-2">
                    A ordem dos atalhos C+N muda conforme você joga, então o bot não pode ter o slot
                    configurado — ele LÊ quem está em cada linha, toda vez. Para isso precisa conhecer
                    a carinha de cada um: varra o painel e diga quem é quem. Uma vez só, por pokémon.
                  </p>
                </div>
                <button class="btn btn-sm btn-primary shrink-0" phx-click="scan_portraits">
                  Varrer painel
                </button>
              </div>

              <p :if={@portrait_msg} class="mt-2 font-mono text-pk-meta text-pk-warn">
                {@portrait_msg}
              </p>

              <ul :if={@portraits != []} class="mt-3 space-y-2">
                <li
                  :for={portrait <- @portraits}
                  id={"portrait-#{portrait.slot}"}
                  class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-2.5 py-2"
                >
                  <span class="font-mono text-pk-body font-bold text-pk-text-2">C+{portrait.slot}</span>

                  <span :if={portrait.guess} class="font-mono text-pk-body text-pk-ok">
                    {portrait.guess.name}
                    <span class="text-pk-text-3">({round(portrait.guess.score * 100)}%)</span>
                  </span>
                  <span :if={is_nil(portrait.guess)} class="font-mono text-pk-body text-pk-warn">
                    não sei quem é
                  </span>

                  <form phx-submit="learn_portrait" class="ml-auto flex items-center gap-1.5">
                    <input type="hidden" name="row" value={portrait.row} />
                    <input
                      name="name"
                      list="team-names"
                      placeholder="quem é?"
                      autocomplete="off"
                      class="h-9 w-40 rounded border border-pk-line bg-pk-bg px-2 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
                    />
                    <button class="btn btn-sm h-9">Aprender</button>
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
                  class="cursor-pointer rounded border border-pk-line px-1.5 py-0.5 font-mono text-pk-meta text-pk-text-2 hover:border-pk-danger-line hover:text-pk-danger"
                >
                  {name} ✕
                </button>
              </p>
            </section>
          </div>
        </details>
      </div>
    </Layouts.app>
    """
  end

  attr :row, :map, required: true
  attr :other, :string, required: true
  attr :other_label, :string, required: true

  attr :open?, :boolean, default: false
  attr :removing?, :boolean, default: false
  attr :keys, :list, default: []
  attr :used, :list, default: []
  attr :warn?, :boolean, default: false

  defp member_row(assigns) do
    ~H"""
    <li class="rounded-lg border border-pk-line bg-pk-raised px-2.5 py-1.5">
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
          class="min-w-0 flex-1 truncate text-pk-title font-semibold hover:underline"
        >
          {@row.name}<span :if={@row.entry.shiny_of}> ✨</span>
          <span
            :for={el <- @row.entry.elements}
            class="ml-1 inline-flex items-center gap-0.5 rounded px-1 py-0.5 align-middle font-mono text-pk-meta font-normal"
            style={PokedexStyle.element_style(el)}
          >
            {el}
          </span>
        </.link>
        <form
          id={"level-form-" <> String.replace(@row.name, ~r/\W+/, "-")}
          phx-change="set_level"
          class="flex items-center gap-1 font-mono text-pk-meta text-pk-text-3"
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
            class="h-8 w-16 rounded border border-pk-line bg-pk-bg px-1 text-center font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
          />
        </form>
        <button
          phx-click="move"
          phx-value-name={@row.name}
          phx-value-to={@other}
          aria-label={@row.name <> " " <> @other_label}
          class="h-8 shrink-0 cursor-pointer rounded border border-pk-line px-2 font-mono text-pk-meta text-pk-text-2 transition hover:border-pk-line-strong hover:text-white"
        >
          {@other_label}
        </button>
        <%!-- "COMBO" ERA O NOME ERRADO. Aqui não se escreve um combo: aqui se
              diz o que cada tecla FAZ e quanto ela demora — o combo é o que sai
              disso, e aparece pronto ali dentro ("essa parte de combos na vdd
              não é bom, e sim algo como Skill Details", 28/08).

              E o botão diz FECHAR quando está aberto: procurar como fechar o
              painel foi o que levou o dedo dele até o ✕ de apagar. --%>
        <button
          id={"skills-toggle-" <> String.replace(@row.name, ~r/\W+/, "-")}
          phx-click="toggle_skills"
          phx-value-name={@row.name}
          aria-expanded={to_string(@open?)}
          aria-label={"Skills de " <> @row.name}
          title="o que cada tecla dele faz, o cooldown de cada uma, e o combo que sai disso"
          class={[
            "flex h-8 shrink-0 cursor-pointer items-center gap-1 rounded border px-2 font-mono text-pk-meta transition",
            if(@open?,
              do: "border-pk-ok bg-pk-ok-dim text-pk-ok",
              else: "border-pk-line text-pk-text-2 hover:border-pk-line-strong hover:text-white"
            )
          ]}
        >
          <.icon
            name={if(@open?, do: "hero-chevron-up", else: "hero-adjustments-horizontal")}
            class="size-3.5"
          />
          {if(@open?, do: "fechar", else: "skills")}
        </button>

        <%!-- O DESTRUTIVO, SEPARADO. Ele estava colado no botão de skills, do
              mesmo tamanho e da mesma cor dos dois vizinhos que não apagam
              nada. Agora: alvo de 32px, cor de perigo só dele, um traço de
              separação antes, e um clique que só ARMA. --%>
        <span class="mx-0.5 h-5 w-px shrink-0 bg-pk-line" aria-hidden="true"></span>
        <button
          :if={!@removing?}
          id={"remove-ask-" <> String.replace(@row.name, ~r/\W+/, "-")}
          phx-click="ask_remove"
          phx-value-name={@row.name}
          aria-label={"Tirar " <> @row.name <> " da lista"}
          title={"tirar " <> @row.name <> " da lista"}
          class="grid size-8 shrink-0 cursor-pointer place-items-center rounded text-pk-text-3 transition hover:bg-pk-danger-dim hover:text-pk-danger"
        >
          <.icon name="hero-trash" class="size-4" />
        </button>
      </div>

      <%!-- A PERGUNTA, na linha do bicho de quem ela fala. Inline e não modal:
            o "sim" nasce longe de onde o dedo acabou de clicar, cancelar é a
            saída mais fácil, e clicar em qualquer outro ✕ move a pergunta em
            vez de empilhar duas. --%>
      <div
        :if={@removing?}
        id={"remove-confirm-" <> String.replace(@row.name, ~r/\W+/, "-")}
        role="alertdialog"
        aria-label={"Confirmar a saída de " <> @row.name}
        class="mt-1.5 flex flex-wrap items-center gap-2 rounded-lg border border-pk-danger-line bg-pk-danger-dim px-2.5 py-2"
      >
        <.icon name="hero-exclamation-triangle" class="size-4 shrink-0 text-pk-danger" />
        <span class="min-w-0 flex-1 text-pk-body text-pk-text">
          Tirar <b class="font-bold">{@row.name}</b>
          da lista? As skills e o cooldown que tu escreveu pra ele vão junto.
        </span>
        <button
          phx-click="cancel_remove"
          class="h-8 shrink-0 cursor-pointer rounded-lg border border-pk-line-strong px-3 text-pk-body font-semibold text-pk-text-2 transition hover:text-white"
        >
          cancelar
        </button>
        <button
          phx-click="remove"
          phx-value-name={@row.name}
          class="h-8 shrink-0 cursor-pointer rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 text-pk-body font-bold text-pk-danger transition hover:bg-pk-danger hover:text-pk-bg"
        >
          tirar da lista
        </button>
      </div>

      <%!-- A row with nothing configured used to render NOTHING — six pokémon
            in a row saying nothing reads as "there is nothing to do here",
            which is exactly the opposite of the truth. --%>
      <p
        :if={!@open? and (@row.skills != %{} or @warn?)}
        class="mt-1 flex flex-wrap items-center gap-x-2 pl-8 font-mono text-pk-meta"
      >
        <span :if={@row.skills == %{}} class="text-pk-warn">
          nenhuma skill classificada — abre <b class="font-bold">skills</b> e diz o que cada tecla faz
        </span>

        <span :if={@row.skills != %{} and combo_text(@row.skills)} class="text-pk-text-2">
          💥 {combo_text(@row.skills)}
        </span>
        <span :if={@row.skills != %{} and is_nil(combo_text(@row.skills))} class="text-pk-warn">
          nada pra matar: falta uma skill de área
        </span>

        <%!-- the other moments, dimmer: they are not the kill --%>
        <span :for={{category, keys} <- off_combo(@row.skills)} class="text-pk-text-3">
          {SkillProfile.icon(category)} {Enum.join(keys, "+")}
        </span>

        <%!-- The bar is HIS, not the screen's: different pokémon carry different
              numbers of moves, and the READY references are the skill icons. --%>
        <%!-- A control, not a caption. It was 9px tall in a 14px row, aligned
              right among five other scraps of text — he read the whole page
              twice looking for exactly this and never saw it. Same row, same
              place; a border, a real target and enough contrast to be an offer. --%>
        <.link
          navigate={~p"/calibration?#{[bar: @row.name]}"}
          class={[
            "ml-auto shrink-0 rounded border px-2 py-1 font-mono text-pk-meta transition",
            if(@row.bar,
              do: "border-pk-line text-pk-text-2 hover:border-pk-line-strong hover:text-white",
              else: "border-pk-warn-line text-pk-warn hover:border-pk-warn hover:bg-pk-warn-dim"
            )
          ]}
          title={bar_title(@row.bar)}
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
        class="mt-2 border-t border-pk-line pt-2"
      >
        <input type="hidden" name="name" value={@row.name} />

        <%!-- O QUE ESTE PAINEL É, dito na abertura dele. Sem cabeçalho, o
              painel era uma lista de selects começando com a palavra "combo" —
              e ele lia isso como "a tela do combo", que não é o que ela faz. --%>
        <div class="mb-2 flex flex-wrap items-center gap-x-2 gap-y-1">
          <h3 class="text-pk-body font-bold text-pk-text">
            Skills de {@row.name}
          </h3>
          <p class="text-pk-meta text-pk-text-3">
            o que cada tecla faz · quanto ela demora pra voltar
          </p>
          <button
            type="button"
            phx-click="toggle_skills"
            phx-value-name={@row.name}
            aria-label={"Fechar as skills de " <> @row.name}
            class="ml-auto grid size-8 shrink-0 cursor-pointer place-items-center rounded text-pk-text-3 transition hover:bg-pk-raised hover:text-white"
          >
            <.icon name="hero-x-mark" class="size-4" />
          </button>
        </div>

        <%!-- The kill, and ONLY the kill — e ele é RESULTADO, não entrada: "eu
              seleciono, mas o combo não é uma junção" (2026-08-11). --%>
        <p class="rounded-lg border border-pk-line bg-pk-sunken px-2.5 py-1.5 font-mono text-pk-meta text-pk-text-2">
          na matança:
          <span :if={combo_text(@row.skills)} class="text-pk-body font-bold text-pk-ok">
            💥 {combo_text(@row.skills)}
          </span>
          <span :if={is_nil(combo_text(@row.skills))} class="text-pk-warn">
            ainda nada — classifica pelo menos uma como área
          </span>
        </p>
        <p class="mb-2 mt-1 text-pk-meta text-pk-text-3">
          a área abre tudo de uma vez (não precisa de alvo) e o alvo único fecha, depois de
          marcar · salva sozinho
        </p>
        <%!-- O SEGUNDO NÚMERO DE CADA TECLA. Sem ele o cérebro só sabia se uma
              skill está pronta OLHANDO a barra, então uma leitura ruim virava
              rotação cega e "gastei tudo" era um chute. Com ele o bot conta o
              próprio tempo e só confere a tela. --%>
        <p class="mb-2 text-pk-meta text-pk-text-3">
          o <span class="text-pk-text-2">cooldown</span>
          é em segundos, do jeito que o jogo escreve em cima do ícone — em branco quer dizer
          "não sei", e aí ele volta a confiar só na barra
        </p>

        <div class="grid grid-cols-2 gap-1.5 sm:grid-cols-3">
          <label
            :for={key <- @keys}
            class="flex items-center gap-1.5 font-mono text-pk-meta text-pk-text-2"
          >
            <%!-- nowrap: the used-key dot pushed "1•" onto a second line and
                  every label in the grid lost its baseline. --%>
            <span class="w-12 shrink-0 whitespace-nowrap text-right">
              skill {key}<span
                :if={key in @used}
                title="tu aperta esta tecla nas tuas rotas gravadas"
                class="text-pk-ok"
              >•</span>
            </span>
            <select
              name={"skill[" <> key <> "]"}
              aria-label={"Skill " <> key <> " de " <> @row.name}
              class="h-8 w-full min-w-0 rounded border border-pk-line bg-pk-bg px-1 font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
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
            <input
              type="number"
              inputmode="decimal"
              min="1"
              max="600"
              step="0.5"
              name={"cd[" <> key <> "]"}
              value={SkillProfile.seconds(@row.cooldowns, key)}
              phx-debounce="400"
              placeholder="s"
              title={"Cooldown da skill " <> key <> ", em segundos"}
              aria-label={"Cooldown da skill " <> key <> " de " <> @row.name}
              class="h-8 w-14 shrink-0 rounded border border-pk-line bg-pk-bg px-1 text-right font-mono text-pk-body text-pk-text focus:border-pk-ok focus:outline-none"
            />
          </label>
        </div>

        <%!-- Every job he used that is NOT the kill, each with the moment it
              belongs to. The control one carries its own warning: spending it
              in an ordinary fight is exactly why it is barred from the combo. --%>
        <ul
          :if={off_combo(@row.skills) != []}
          id={"skills-moments-" <> String.replace(@row.name, ~r/\W+/, "-")}
          class="mt-2 space-y-0.5 border-t border-pk-line pt-1.5 font-mono text-pk-meta text-pk-text-3"
        >
          <li :for={{category, keys} <- off_combo(@row.skills)}>
            {SkillProfile.icon(category)}
            <span class="text-pk-text-2">
              {SkillProfile.label(category)} {Enum.join(keys, "+")}
            </span>
            — {SkillProfile.moment(category)}
            <span :if={category == :crowd} class="text-pk-warn">
              (fora do combo de propósito: gasta na luta e ela não está lá pro revive)
            </span>
          </li>
        </ul>

        <%!-- Ten dropdowns, and his hands use four of them. Which four is not
              a question for this page to ask — the recorded routes answer it. --%>
        <p :if={@used != []} class="mt-1.5 font-mono text-pk-meta text-pk-text-3">
          <span class="text-pk-ok">•</span>
          são as teclas que tu repete nas matanças das tuas rotas ({Enum.join(@used, " ")}) —
          começa por elas
        </p>
      </form>
    </li>
    """
  end
end
