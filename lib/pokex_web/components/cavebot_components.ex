defmodule PokexWeb.CavebotComponents do
  @moduledoc """
  The hunt's control room: the world as it is RIGHT NOW, and the route as a
  drawing instead of a column of coordinates.

  Two rules this page is built on, both learned the hard way elsewhere in this
  app: state is never colour alone (every tile carries its own words), and the
  drawing is never the only copy of the data (the waypoint list below it is the
  text alternative, and the one you can edit).
  """
  use PokexWeb, :html

  alias Pokex.Bots.Cavebot.Route
  alias PokexWeb.CavebotMap

  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :note, :string, default: nil
  attr :tone, :atom, default: :neutral, values: [:neutral, :ok, :warn, :danger]
  attr :icon, :string, required: true
  attr :id, :string, default: nil

  @doc """
  One reading of the world. The tone paints the VALUE; the note always spells
  the same thing out in words, because a green number and a grey number look
  identical to a third of the men who will ever read this screen.
  """
  def world_tile(assigns) do
    ~H"""
    <div id={@id} class="min-w-0 rounded-lg border border-pk-line bg-pk-sunken px-2 py-1">
      <%!-- label and value share a LINE, and the note truncates: three stacked
           lines per tile cost a tenth of the fold for six short numbers, and
           the long notes wrapped to a fourth (2026-08-15). --%>
      <p class="flex items-center gap-1 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
        <.icon name={@icon} class="size-3 shrink-0" />{@label}
        <span class={["pk-num ml-auto font-bold normal-case", tone_text(@tone)]}>{@value}</span>
      </p>
      <p
        :if={@note}
        title={@note}
        class="truncate font-mono text-pk-meta leading-tight text-pk-text-3"
      >
        {@note}
      </p>
    </div>
    """
  end

  attr :label, :string, required: true
  attr :pct, :integer, default: nil
  attr :note, :string, default: nil
  attr :tone, :atom, default: :ok

  @doc """
  Uma vida como BARRA, não como número solto.

  "Queria conseguir JOGAR o jogo totalmente pela tela do cave bot" (28/08) — e
  uma barra é o que se lê sem ler: de canto de olho ela é comprimento, e o
  número fica pra quando ele quiser o valor exato.

  `nil` é uma resposta legítima e diferente de zero: sem leitura o trilho fica
  vazio e o texto diz "sem leitura", porque uma barra vazia com cara de 0% é
  como uma janela minimizada vira "meu pokémon está morrendo".
  """
  def hp_bar(assigns) do
    ~H"""
    <div class="min-w-0">
      <p class="flex items-baseline gap-1.5 font-mono text-pk-meta">
        <span class="shrink-0 uppercase tracking-[0.1em] text-pk-text-3">{@label}</span>
        <span :if={@note} class="truncate text-pk-text-3">{@note}</span>
        <span class={["pk-num ml-auto shrink-0 font-bold tabular-nums", bar_text(@pct, @tone)]}>
          {if @pct, do: "#{@pct}%", else: "sem leitura"}
        </span>
      </p>
      <div class="mt-0.5 h-1.5 overflow-hidden rounded-full bg-pk-line">
        <div
          class={["h-full rounded-full transition-[width] duration-500", bar_fill(@pct, @tone)]}
          style={"width: #{@pct || 0}%"}
        >
        </div>
      </div>
    </div>
    """
  end

  # A cor sai da própria vida quando ninguém mandou um tom: vermelho e âmbar
  # são as faixas que o cérebro usa, e a barra tem que contar a mesma história
  # que a decisão.
  defp bar_tone(nil, _tone), do: :unknown
  defp bar_tone(pct, _tone) when pct < 30, do: :danger
  defp bar_tone(pct, _tone) when pct < 60, do: :warn
  defp bar_tone(_pct, tone), do: tone

  defp bar_text(pct, tone), do: tone_text(bar_tone(pct, tone))

  defp bar_fill(pct, tone) do
    case bar_tone(pct, tone) do
      :danger -> "bg-pk-danger"
      :warn -> "bg-pk-warn"
      :unknown -> "bg-pk-line-strong"
      _ok -> "bg-pk-ok"
    end
  end

  defp tone_text(:unknown), do: "text-pk-text-3"
  defp tone_text(:ok), do: "text-pk-ok"
  defp tone_text(:warn), do: "text-pk-warn"
  defp tone_text(:danger), do: "text-pk-danger"
  defp tone_text(_neutral), do: "text-pk-text"

  attr :id, :string, required: true
  attr :key, :string, required: true
  attr :armed?, :boolean, required: true
  attr :icon, :string, required: true
  attr :on, :string, required: true
  attr :off, :string, required: true

  @doc """
  One net of the hunt's safety, as a switch: the state IS the label ("resgate
  armado", never a lone green dot), same rule as the tiles above.
  """
  def safety_toggle(assigns) do
    ~H"""
    <button
      id={@id}
      phx-click="toggle_safety"
      phx-value-key={@key}
      aria-pressed={to_string(@armed?)}
      class={[
        "flex h-7 cursor-pointer items-center gap-1 rounded border px-2 font-mono",
        "text-pk-meta font-semibold transition",
        if(@armed?,
          do: "border-pk-ok/60 bg-pk-ok-dim text-pk-ok hover:border-pk-ok",
          else: "border-pk-line-strong text-pk-text-3 hover:border-pk-warn/60 hover:text-pk-text"
        )
      ]}
    >
      <.icon name={@icon} class="size-3.5" />{if @armed?, do: @on, else: @off}
    </button>
    """
  end

  attr :waypoints, :list, required: true
  attr :pos, :any, default: nil
  attr :selected, :any, default: nil
  attr :recording?, :boolean, default: false
  attr :floor, :any, default: nil
  attr :heading_to, :any, default: nil, doc: "the corner the RUNNING hunt is walking to"

  @doc """
  The route, drawn in the game's own coordinate space (x east, y south) with
  the character on top of it.

  A waypoint list cannot show SHAPE, and shape is the whole point of a recorded
  walk: a corner marked one tile off reads identical in text and jumps out
  here. Clicking a waypoint selects it in the editor below — the drawing is a
  control, not a picture.
  """
  def route_map(assigns) do
    points = assigns.waypoints ++ List.wrap(assigns.pos && point_of(assigns.pos))

    assigns =
      assigns
      |> assign(:view, CavebotMap.view(points))
      |> assign(:here, assigns.pos && point_of(assigns.pos))
      |> assign(:legs, legs(assigns.waypoints))

    ~H"""
    <div
      id="route-map"
      class="relative aspect-square w-full overflow-hidden rounded-lg border border-pk-line bg-pk-sunken"
    >
      <svg
        :if={@view}
        viewBox={CavebotMap.box_attr(@view)}
        class="size-full"
        role="img"
        aria-label={map_summary(@waypoints, @pos)}
      >
        <defs>
          <pattern id="map-grid" width="10" height="10" patternUnits="userSpaceOnUse">
            <path
              d="M 10 0 L 0 0 0 10"
              fill="none"
              stroke="var(--color-pk-line)"
              stroke-width="0.5"
              vector-effect="non-scaling-stroke"
            />
          </pattern>
        </defs>
        <rect
          x={elem(@view.box, 0)}
          y={elem(@view.box, 1)}
          width={elem(@view.box, 2)}
          height={elem(@view.box, 3)}
          fill="url(#map-grid)"
        />

        <%!-- Leg by leg, because they are not all the same leg: the closing one
             is dashed (the loop is real, the hunt walks back to the first
             waypoint) and a MOB stretch is blue. --%>
        <line
          :for={leg <- @legs}
          x1={leg.from.x}
          y1={leg.from.y}
          x2={leg.to.x}
          y2={leg.to.y}
          stroke={if leg.luring?, do: "var(--color-pk-info)", else: "var(--color-pk-ok-line)"}
          stroke-width={leg_width(leg)}
          stroke-linecap="round"
          stroke-dasharray={leg_dash(leg)}
          opacity={
            if on_floor?(leg.from, @floor) and on_floor?(leg.to, @floor), do: "1", else: "0.25"
          }
          vector-effect="non-scaling-stroke"
        />

        <%!-- A leg that CLIMBS: on a flat drawing, two floors sit on top of each
             other, so the one thing that must be written is which floor this
             leg lands on. --%>
        <text
          :for={leg <- Enum.filter(@legs, & &1.climb_to)}
          x={leg.arrow.x}
          y={leg.arrow.y - @view.unit * 0.9}
          text-anchor="middle"
          fill="var(--color-pk-text-2)"
          font-size={@view.unit * 1.4}
          class="pointer-events-none font-mono"
        >
          ⇅ {leg.climb_to}
        </text>

        <%!-- Which WAY the hunt runs — the one thing coordinates never say. --%>
        <polygon
          :for={leg <- @legs}
          points="0,-1 0,1 2,0"
          fill={if leg.luring?, do: "var(--color-pk-info)", else: "var(--color-pk-ok)"}
          opacity={
            if on_floor?(leg.from, @floor) and on_floor?(leg.to, @floor), do: "0.7", else: "0.2"
          }
          transform={"translate(#{leg.arrow.x} #{leg.arrow.y}) rotate(#{leg.arrow.angle}) scale(#{@view.unit * 0.9})"}
        />

        <g
          :for={{wp, index} <- Enum.with_index(@waypoints)}
          opacity={if on_floor?(wp, @floor), do: "1", else: "0.3"}
        >
          <%!-- WHERE THE HUNT IS. "não consigo ver direito em que momento ele
               está na rota" (Lucas, 2026-08-14): the drawing marked the corner
               being EDITED and never the one being walked to, so the running
               bot was invisible on its own map. A pulsing ring, because a
               colour alone would collide with the selection. --%>
          <circle
            :if={@heading_to == index}
            id={"map-heading-#{index}"}
            cx={wp.x}
            cy={wp.y}
            r={@view.unit * 2.4}
            fill="none"
            stroke="var(--color-pk-ok)"
            stroke-width="2"
            vector-effect="non-scaling-stroke"
            class="pointer-events-none motion-safe:animate-pulse"
          />
          <circle
            id={"map-waypoint-#{index}"}
            cx={wp.x}
            cy={wp.y}
            r={@view.unit * if @selected == index, do: 1.6, else: 1.1}
            fill={dot_fill(wp, index)}
            stroke={dot_stroke(wp, @selected == index)}
            stroke-width={if wp.action == :walk, do: "2", else: "3"}
            vector-effect="non-scaling-stroke"
            class="cursor-pointer"
            phx-click="select_waypoint"
            phx-value-index={index}
          >
            <title>{"waypoint #{index + 1}: #{wp.x}, #{wp.y}#{job_suffix(wp)}"}</title>
          </circle>
          <text
            :if={length(@waypoints) <= 24}
            x={wp.x}
            y={wp.y + @view.unit * 0.55}
            text-anchor="middle"
            fill="var(--color-pk-text-2)"
            font-size={@view.unit * 1.5}
            class="pointer-events-none font-mono"
          >
            {index + 1}
          </text>
        </g>

        <g :if={@here}>
          <circle
            cx={@here.x}
            cy={@here.y}
            r={@view.unit * 2.2}
            fill="var(--color-pk-warn)"
            opacity="0.18"
            class={@recording? && "motion-safe:animate-ping"}
          />
          <circle
            id="map-here"
            cx={@here.x}
            cy={@here.y}
            r={@view.unit * 0.9}
            fill="var(--color-pk-warn)"
            stroke="var(--color-pk-bg)"
            stroke-width="1.5"
            vector-effect="non-scaling-stroke"
          >
            <title>{"você está aqui: #{@here.x}, #{@here.y}"}</title>
          </circle>
        </g>
      </svg>

      <p
        :if={!@view}
        class="absolute inset-0 grid place-items-center px-6 text-center text-pk-body text-pk-text-3"
      >
        Sem rota e sem posição pra desenhar — grave uma rota andando e ela aparece aqui.
      </p>

      <p
        :if={@floor && Enum.any?(@waypoints, &(!on_floor?(&1, @floor)))}
        id="map-floor-legend"
        class="pointer-events-none absolute left-3 top-2 font-mono text-pk-meta text-pk-text-2"
      >
        andar {@floor} · outros apagados
      </p>

      <%!-- ONE bottom row, not two corners. Pinned left and right, the scale and
           the mob legend ran into each other the moment the drawing was drawn
           smaller than the sentence — which is every time the map shares its
           column with the corner being edited. --%>
      <div class="pointer-events-none absolute inset-x-3 bottom-2 flex flex-wrap items-center justify-between gap-x-3 gap-y-0.5 font-mono text-pk-meta">
        <p class="text-pk-text-3">
          {if @view, do: "#{round(elem(@view.box, 2))} tiles de ponta a ponta", else: ""}
        </p>

        <p
          :if={Enum.any?(@legs, & &1.luring?) or Enum.any?(@waypoints, &(&1.action == :lure_end))}
          id="map-lure-legend"
          class="flex items-center gap-1.5 text-pk-info"
        >
          <span class="h-0.5 w-4 rounded-full bg-pk-info"></span>
          trecho de mob <span class="ml-1.5 size-2 rounded-full bg-pk-info"></span>
          matança
        </p>
      </div>
    </div>
    """
  end

  defp point_of({x, y, _z}), do: %{x: x, y: y}

  # The drawing is flat, so floors sit on top of each other: everything that is
  # NOT on the floor being looked at is faded, which is what gives the route a
  # sense of height at a glance.
  defp on_floor?(_waypoint, nil), do: true
  defp on_floor?(%{z: z}, floor), do: z == floor
  defp on_floor?(_no_floor, _floor), do: true

  defp leg_width(%{luring?: true}), do: "3"
  defp leg_width(%{closing?: true}), do: "1.5"
  defp leg_width(_plain), do: "2"

  # A climb is not a walk: the two ends sit on top of each other on a flat
  # drawing, and a solid line between them would read as a corridor.
  defp leg_dash(%{climb_to: floor}) when is_integer(floor), do: "1 2"
  defp leg_dash(%{closing?: true}), do: "4 4"
  defp leg_dash(_plain), do: nil

  # The kill spot is SOLID: "mobar daqui" and "até aqui" carried the same dot,
  # and the one place everything dies is the one place worth spotting first.
  defp dot_fill(%{action: :lure_end}, _index), do: "var(--color-pk-info)"
  defp dot_fill(%{action: :walk}, 0), do: "var(--color-pk-ok-dim)"
  defp dot_fill(%{action: :walk}, _index), do: "var(--color-pk-surface)"
  defp dot_fill(_marked, _index), do: "var(--color-pk-info-dim)"

  defp dot_stroke(_wp, true), do: "var(--color-pk-warn)"
  defp dot_stroke(%{action: :walk}, _selected), do: "var(--color-pk-ok)"
  defp dot_stroke(_marked, _selected), do: "var(--color-pk-info)"

  defp job_suffix(%{action: :lure_start} = wp), do: " (andar #{wp.z}) — mobar daqui"
  defp job_suffix(%{action: :lure_end} = wp), do: " (andar #{wp.z}) — mobar até aqui"
  defp job_suffix(wp), do: " (andar #{wp.z})"

  # Every leg the hunt walks, INCLUDING the one that closes the loop: they are
  # drawn one by one because they are not all alike (the closing leg is dashed,
  # a mob stretch is blue). With two waypoints the closing leg retraces the
  # only segment there is, so it is left out.
  defp legs(waypoints) when length(waypoints) > 1 do
    count = length(waypoints)

    waypoints
    |> Enum.with_index()
    |> Enum.map(fn {from, index} ->
      to = Enum.at(waypoints, rem(index + 1, count))

      %{
        from: from,
        to: to,
        arrow: CavebotMap.arrow(from, to),
        luring?: Route.lure_leg?(waypoints, index),
        climb_to: Route.floor_change(waypoints, index),
        closing?: index == count - 1
      }
    end)
    |> Enum.reject(&(&1.closing? and count < 3))
  end

  defp legs(_short), do: []

  # Colour is never the only carrier: what the drawing shows in blue, the
  # screen reader hears in words.
  defp map_summary(waypoints, pos) do
    lured = Enum.count(0..(length(waypoints) - 1)//1, &Route.lure_leg?(waypoints, &1))

    base =
      "Mapa da rota: #{length(waypoints)} waypoints, #{CavebotMap.total_tiles(waypoints)} tiles"

    floors = waypoints |> Enum.map(& &1.z) |> Enum.uniq() |> Enum.sort()

    base
    |> then(&if length(floors) > 1, do: &1 <> ", andares #{Enum.join(floors, " e ")}", else: &1)
    |> then(&if lured > 0, do: &1 <> ", #{lured} perna(s) em modo mob", else: &1)
    |> then(&if pos, do: &1 <> ", personagem em #{elem(pos, 0)}, #{elem(pos, 1)}", else: &1)
  end

  attr :kind, :atom, required: true
  attr :url, :string, default: nil
  attr :busy?, :boolean, default: false

  @doc """
  What the start (or the end) of the route LOOKS like. Coordinates say where a
  route begins; a picture says what is there — which is what a route recorded
  last week actually needs.
  """
  def route_photo(assigns) do
    ~H"""
    <figure class="min-w-0 flex-1 space-y-1">
      <figcaption class="flex items-center justify-between gap-2">
        <span class="font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
          {if @kind == :start, do: "início da rota", else: "fim da rota"}
        </span>
        <button
          id={"retake-photo-#{@kind}"}
          phx-click="retake_photo"
          phx-value-kind={@kind}
          disabled={@busy?}
          aria-label={"Tirar foto do #{if @kind == :start, do: "início", else: "fim"} da rota agora"}
          class="cursor-pointer font-mono text-pk-meta text-pk-text-2 transition hover:text-pk-ok disabled:cursor-not-allowed disabled:opacity-50"
        >
          {if @url, do: "refazer", else: "tirar agora"}
        </button>
      </figcaption>
      <img
        :if={@url}
        src={@url}
        alt={"Foto do #{if @kind == :start, do: "início", else: "fim"} da rota"}
        loading="lazy"
        class="aspect-video w-full rounded border border-pk-line object-cover"
      />
      <p
        :if={!@url}
        class="grid aspect-video w-full place-items-center rounded border border-dashed border-pk-line px-2 text-center font-mono text-pk-meta text-pk-text-3"
      >
        sai sozinha quando você gravar
      </p>
    </figure>
    """
  end

  attr :route, :any, required: true
  attr :tolerance, :integer, required: true

  @doc """
  What the ROUTE asks that the walking cannot deliver.

  Found in his own journal (2026-08-15) and REPORTED, never fixed on his behalf:
  which of two corners deserves to stay is a decision about the road, and
  "otimizar rota" promises it never touches the road.

  Renders nothing when the route is healthy — a permanent empty box teaches the
  eye to skip the very place the warning will appear.
  """
  def route_doctor(assigns) do
    assigns = assign(assigns, :findings, doctor_findings(assigns.route, assigns.tolerance))

    ~H"""
    <p
      :if={@findings}
      id="route-doctor"
      class="mt-2 flex items-start gap-1.5 rounded-lg border border-pk-info-line bg-pk-info-dim px-3 py-2 text-pk-meta text-pk-text-2"
    >
      <.icon name="hero-wrench-screwdriver" class="mt-0.5 size-3.5 shrink-0" />
      {@findings}
    </p>
    """
  end

  defp doctor_findings(%Route{} = route, tolerance) do
    [
      case Route.unwalkable_pairs(route, tolerance) do
        [] ->
          nil

        pairs ->
          "#{length(pairs)} canto(s) em cima do anterior (a #{tolerance} tile ou menos): " <>
            "o bot chega neles sem andar — #{corner_list(pairs)}"
      end,
      case Route.stair_round_trips(route) do
        [] -> nil
        trips -> "escada de ida e volta em #{corner_list(trips)}: sobe e desce no mesmo tile"
      end
    ]
    |> Enum.reject(&is_nil/1)
    |> case do
      [] -> nil
      findings -> Enum.join(findings, " · ")
    end
  end

  defp doctor_findings(_no_route, _tolerance), do: nil

  # 1-based, and never a wall of numbers: the first few plus a count.
  defp corner_list(indexes) do
    shown = indexes |> Enum.take(6) |> Enum.map_join(", ", &"#{&1 + 1}")

    if length(indexes) > 6, do: shown <> "…", else: shown
  end

  attr :hunt, :any, required: true
  attr :combat, :any, default: nil
  attr :catcher, :any, default: nil
  attr :support, :any, default: nil
  attr :revives_left, :any, default: nil
  attr :wp_total, :integer, default: 0
  attr :now, :integer, required: true

  @doc """
  O RESUMO DA NOITE: quanto tempo faz que ela roda, e o que ela rendeu.

  A tela inteira responde "o que está acontecendo AGORA" — o mapa, a fileira de
  cooldowns, a lista de batalha, o feed. Nenhum pedaço dela respondia a pergunta
  que se faz de longe, encostado na janela lateral: *isso ainda está rodando, e
  está indo bem?* Era preciso ler o feed rolando pra deduzir a primeira e não
  havia como responder a segunda.

  Todo número aqui já era fato publicado — os contadores da caçada, do combate,
  do capturador e do suporte, e o relógio que o worker passou a carimbar no
  `run`. Nada disto custa uma captura: é aritmética sobre o que já chega por
  broadcast.

  O relógio é o único elemento da casa fora dos três degraus de texto, e é de
  propósito (`--text-pk-clock`): ele é um mostrador, não um texto.
  """
  def hunt_summary(assigns) do
    assigns = assign(assigns, :run, run_of(assigns))

    ~H"""
    <section
      id="cavebot-resumo"
      class="rounded-lg border border-pk-line bg-pk-surface px-3 py-2"
      aria-label="Resumo da caçada"
    >
      <div class="flex flex-wrap items-center gap-x-4 gap-y-2">
        <%!-- O RELÓGIO. Um ponto que respira enquanto ela anda, e a duração em
             mostrador — a única coisa nesta tela feita pra ser lida de longe. --%>
        <div class="flex shrink-0 items-center gap-2.5">
          <span class="relative flex size-2.5 shrink-0" aria-hidden="true">
            <span
              :if={@run.live?}
              class={[
                "absolute inline-flex size-full rounded-full opacity-70",
                "motion-safe:animate-ping motion-reduce:hidden",
                dot_bg(@run.tone)
              ]}
            ></span>
            <span class={["relative inline-flex size-2.5 rounded-full", dot_bg(@run.tone)]}></span>
          </span>

          <div class="min-w-0">
            <p class={[
              "pk-num font-mono text-pk-clock font-bold leading-none tabular-nums",
              tone_text(@run.tone)
            ]}>
              {@run.clock}
            </p>
            <%!-- A COR NUNCA SOZINHA: o ponto verde e o ponto cinza são a mesma
                 mancha pra quem não distingue os dois, e esta é a linha que diz
                 em qual dos dois estados a noite está. --%>
            <p class="mt-1 truncate font-mono text-pk-meta text-pk-text-3">{@run.since}</p>
          </div>
        </div>

        <div class="grid min-w-0 flex-1 grid-cols-3 gap-1.5 sm:grid-cols-6">
          <.world_tile
            id="resumo-voltas"
            icon="hero-arrow-path"
            label="voltas"
            value={num(@run.laps)}
            note={"#{num(@run.waypoints)} canto(s)"}
          />
          <.world_tile
            id="resumo-passos"
            icon="hero-map"
            label="passos"
            value={num(@run.steps)}
            note={rate_note(@run.steps, @run.elapsed_ms)}
          />
          <.world_tile
            id="resumo-lutas"
            icon="hero-bolt-solid"
            label="lutas"
            value={num(@run.fights)}
            note={rate_note(@run.fights, @run.elapsed_ms)}
          />
          <.world_tile
            id="resumo-capturas"
            icon="hero-inbox-arrow-down"
            label="capturas"
            value={num(@run.captures)}
            note={rate_note(@run.captures, @run.elapsed_ms)}
          />
          <%!-- O revive é o item que já acabou no meio de uma noite e deixou o
               bot moer 4,9 horas com o pokémon no chão (27→28/08). Aqui ele
               aparece com o que SOBROU do lado, e fica âmbar quando o bolso
               está no fim. --%>
          <.world_tile
            id="resumo-revives"
            icon="hero-lifebuoy"
            label="revives"
            value={num(@run.revives)}
            note={stock_note(@revives_left)}
            tone={stock_tone(@revives_left)}
          />
          <.world_tile
            id="resumo-paradas"
            icon="hero-hand-raised"
            label="paradas"
            value={num(@run.blocks)}
            note={incident_note(@run)}
            tone={if @run.blocks > 0, do: :warn, else: :neutral}
          />
        </div>
      </div>
    </section>
    """
  end

  # Tudo que o resumo desenha, derivado UMA vez: o template pergunta por dez
  # números e cada pergunta repetida é uma chance de dois pedaços da mesma tira
  # discordarem entre si dentro do mesmo desenho.
  defp run_of(assigns) do
    hunt = assigns.hunt || %{}
    counters = Map.get(hunt, :counters) || %{}
    started = Map.get(hunt, :started_at)
    ended = Map.get(hunt, :ended_at)
    elapsed = started && max((ended || assigns.now) - started, 0)
    live? = is_integer(started) and is_nil(ended)
    waypoints = Map.get(counters, :waypoints, 0)

    %{
      live?: live?,
      tone: run_tone(live?, started, hunt),
      clock: clock_text(elapsed),
      since: since_text(live?, started, ended, hunt),
      elapsed_ms: elapsed,
      waypoints: waypoints,
      laps: laps(waypoints, assigns.wp_total),
      steps: Map.get(counters, :steps, 0),
      blocks: Map.get(counters, :blocks, 0),
      aborts: Map.get(counters, :aborts, 0),
      comebacks: Map.get(counters, :comebacks, 0),
      fights: counter(assigns.combat, :fights),
      captures: counter(assigns.catcher, :captures),
      revives: counter(assigns.support, :rescues)
    }
  end

  # Quatro mil trezentos e doze passos é o que uma noite dá, e `4312` sem ponto
  # é uma parede de dígitos que se lê contando com o dedo. Ponto de milhar como
  # em português, e só a partir de mil.
  defp num(n) when is_integer(n) and n >= 1000 do
    n
    |> Integer.digits()
    |> Enum.reverse()
    |> Enum.chunk_every(3)
    |> Enum.map_join(".", &Enum.join/1)
    |> String.reverse()
  end

  defp num(n), do: to_string(n)

  defp counter(nil, _key), do: 0
  defp counter(snapshot, key), do: snapshot |> Map.get(:counters, %{}) |> Map.get(key, 0)

  # Uma volta é a rota inteira. Sem saber o tamanho dela, os cantos ainda são um
  # número honesto — a volta é que não existe.
  defp laps(_waypoints, total) when not is_integer(total) or total <= 0, do: 0
  defp laps(waypoints, total), do: div(waypoints, total)

  # Parada é cinza, andando é verde, e presa/bloqueada é âmbar: o mesmo verbo
  # que a tira de estados já usa. Nunca vermelho — a caçada travada não é um
  # erro do software, é uma noite que precisa de mão.
  defp run_tone(false, nil, _hunt), do: :neutral
  defp run_tone(false, _started, _hunt), do: :neutral
  defp run_tone(true, _started, %{state: state}) when state in [:blocked, :stuck], do: :warn
  defp run_tone(true, _started, _hunt), do: :ok

  defp dot_bg(:ok), do: "bg-pk-ok"
  defp dot_bg(:warn), do: "bg-pk-warn"
  defp dot_bg(:danger), do: "bg-pk-danger"
  defp dot_bg(_neutral), do: "bg-pk-line-strong"

  # Sem noite nenhuma o mostrador fica em trações, não em zeros: "00:00" é um
  # cronômetro parado no zero, e "nunca rodou" é outra coisa.
  defp clock_text(nil), do: "--:--"

  defp clock_text(ms) do
    total = div(ms, 1000)
    {h, m, s} = {div(total, 3600), rem(div(total, 60), 60), rem(total, 60)}

    if h > 0,
      do: "#{h}:#{pad(m)}:#{pad(s)}",
      else: "#{pad(m)}:#{pad(s)}"
  end

  defp pad(n), do: String.pad_leading(to_string(n), 2, "0")

  # A hora de parede, porque a duração sozinha não responde "isso é de ontem?".
  # Lida do relógio do sistema (`:calendar`), como o resto do app: este projeto
  # não carrega banco de fuso.
  defp since_text(true, started, _ended, hunt),
    do: "#{running_word(hunt)} · desde #{wall_clock(started)}"

  defp since_text(false, nil, _ended, _hunt), do: "sem caçada ainda"
  defp since_text(false, _started, nil, _hunt), do: "parada"
  defp since_text(false, _started, ended, _hunt), do: "parada às #{wall_clock(ended)}"

  defp running_word(%{state: state}) when state in [:blocked, :stuck], do: "parada no lugar"
  defp running_word(%{luring?: true}), do: "mobando"
  defp running_word(_running), do: "rodando"

  defp wall_clock(ms) do
    {_date, {h, m, _s}} = :calendar.system_time_to_local_time(ms, :millisecond)
    "#{pad(h)}:#{pad(m)}"
  end

  # O RITMO, que é o número que diz se a noite está indo bem — e só depois de
  # cinco minutos, porque antes disso a divisão inventa "1.800/h" a partir de
  # dois passos.
  defp rate_note(_count, ms) when not is_integer(ms) or ms < 300_000, do: nil
  defp rate_note(0, _ms), do: nil
  defp rate_note(count, ms), do: "#{num(round(count * 3_600_000 / ms))}/h"

  defp stock_note(nil), do: "sem conta de estoque"
  defp stock_note(left), do: "#{num(left)} no bolso"

  # A conta do caderninho é de DESPACHOS e erra pro lado seguro: âmbar cedo é o
  # comportamento certo, porque quem repõe é ele, com o pote na mão.
  defp stock_tone(nil), do: :neutral
  defp stock_tone(left) when left <= 10, do: :warn
  defp stock_tone(_left), do: :neutral

  # As paradas são o número; o resto do estrago vai na linha de baixo, porque
  # "voltou depois de tropeçar" e "largou a mobada por vida" são BOAS notícias
  # somadas a uma má, e uma soma só apagaria as três.
  defp incident_note(%{aborts: 0, comebacks: 0}), do: "nenhum tropeço"

  defp incident_note(run) do
    [{run.aborts, "largada(s)"}, {run.comebacks, "reentro(s)"}]
    |> Enum.filter(fn {n, _label} -> n > 0 end)
    |> Enum.map_join(" · ", fn {n, label} -> "#{n} #{label}" end)
  end

  attr :situation, :any, default: nil
  attr :orders, :any, default: nil

  @doc """
  What the engine is thinking, in one strip.

  Its reasoning is the one thing on this page with no other way to be seen: the
  hunt's state shows in the tiles and the fight narrates itself, but how many it
  counted, whether they stopped arriving, which band the health is in, and what
  it would do about all three only ever existed inside a process.

  While nobody obeys it, this is a SHADOW: it says what WOULD happen, and the
  feed below carries the same sentence beside what actually did.
  """
  attr :gather_piles, :boolean, default: true
  attr :reset_revive, :boolean, default: false

  def engine_brain(assigns) do
    ~H"""
    <section
      :if={@situation}
      id="engine-brain"
      class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-pk-line bg-pk-surface px-3 py-1.5"
    >
      <h2 class={[
        "flex shrink-0 items-center gap-1 font-mono text-pk-meta font-bold uppercase tracking-[0.12em]",
        band_text(@orders)
      ]}>
        🧠 {band_label(@orders)}
      </h2>

      <p class="min-w-0 flex-1 truncate text-pk-body text-pk-text-2" title={why(@orders)}>
        {why(@orders)}
      </p>

      <p class="flex shrink-0 items-center gap-2 font-mono text-pk-meta text-pk-text-3">
        <span class="pk-num text-pk-text-2">{count_label(@situation)}</span>
        <span aria-hidden="true">·</span>
        <span>{settle_label(@situation)}</span>
      </p>

      <%!-- Juntar pilha vale contra bicho que moba; contra o que aparece de um
            em um, a espera só perde luta. --%>
      <button
        id="toggle-gather-piles"
        type="button"
        phx-click="toggle_gather_piles"
        aria-pressed={to_string(@gather_piles)}
        class={[
          "shrink-0 rounded border px-2 py-0.5 font-mono text-pk-meta",
          if(@gather_piles,
            do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
            else: "border-pk-line-strong text-pk-text-3"
          )
        ]}
      >
        {if @gather_piles, do: "juntando pilha", else: "sem juntar pilha"}
      </button>

      <%!-- R3b: barra vazia na frente de uma pilha que ainda vale é uma rodada
            que já acabou. O revive aqui é o F4, que no Poké Alliance faz a
            coreografia inteira sozinho — recolhe, usa e devolve o pokémon pro
            campo. Desligado até a medição dizer que ele volta com as skills
            prontas: /sim, "As quatro medições do jogo". --%>
      <button
        id="toggle-reset-revive"
        type="button"
        phx-click="toggle_reset_revive"
        aria-pressed={to_string(@reset_revive)}
        title="Tira e traz o pokémon pra zerar cooldown quando a barra acaba com a pilha de pé"
        class={[
          "shrink-0 rounded border px-2 py-0.5 font-mono text-pk-meta",
          if(@reset_revive,
            do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
            else: "border-pk-line-strong text-pk-text-3"
          )
        ]}
      >
        {if @reset_revive, do: "revive reseta cooldown", else: "revive só no resgate"}
      </button>
    </section>
    """
  end

  # The band is health, and health is the one thing here that must never be
  # colour alone: the word rides beside the colour, always.
  defp band_label(%{band: :red}), do: "vermelho"
  defp band_label(%{band: :yellow}), do: "amarelo"
  defp band_label(%{band: :green}), do: "verde"
  defp band_label(_no_orders), do: "pensando"

  defp band_text(%{band: :red}), do: "text-pk-danger"
  defp band_text(%{band: :yellow}), do: "text-pk-warn"
  defp band_text(_green_or_none), do: "text-pk-text-3"

  defp why(%{why: why}), do: why
  defp why(_no_orders), do: "sem ordem — a engine ainda não decidiu nada"

  # Zero and "I cannot see" are opposite facts wearing the same number.
  defp count_label(%{enemies: nil}), do: "não vejo a lista"
  defp count_label(%{enemies: 1}), do: "1 inimigo"
  defp count_label(%{enemies: n}), do: "#{n} inimigos"

  defp settle_label(%{enemies: nil}), do: "sem contagem"
  defp settle_label(%{growing?: true}), do: "ainda chegando"

  defp settle_label(%{stable_for_ms: ms}), do: "parados há #{Float.round(ms / 1000, 1)}s"
end
