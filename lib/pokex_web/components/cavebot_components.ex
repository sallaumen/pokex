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
    <div id={@id} class="rounded-lg border border-pk-line bg-pk-sunken px-2 py-1.5">
      <p class="flex items-center gap-1 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
        <.icon name={@icon} class="size-3" />{@label}
      </p>
      <%!-- the VALUE dropped a step: six tiles at display size ate a third of
           a laptop screen for six short numbers (2026-08-14). --%>
      <p class={["pk-num font-mono text-pk-body font-bold leading-tight", tone_text(@tone)]}>
        {@value}
      </p>
      <p :if={@note} class="font-mono text-pk-meta leading-tight text-pk-text-3">{@note}</p>
    </div>
    """
  end

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
        "flex h-9 cursor-pointer items-center gap-1.5 rounded-lg border px-3 font-mono",
        "text-pk-meta font-semibold transition",
        if(@armed?,
          do: "border-pk-ok/60 bg-pk-ok-dim text-pk-ok hover:border-pk-ok",
          else: "border-pk-line-strong text-pk-text-3 hover:border-pk-warn/60 hover:text-pk-text"
        )
      ]}
    >
      <.icon name={@icon} class="size-4" />
      {if @armed?, do: @on, else: @off}
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

      <p class="pointer-events-none absolute bottom-2 left-3 font-mono text-pk-meta text-pk-text-3">
        {if @view, do: "#{round(elem(@view.box, 2))} tiles de ponta a ponta", else: ""}
      </p>

      <p
        :if={@floor && Enum.any?(@waypoints, &(!on_floor?(&1, @floor)))}
        id="map-floor-legend"
        class="pointer-events-none absolute left-3 top-2 font-mono text-pk-meta text-pk-text-2"
      >
        andar {@floor} · outros apagados
      </p>

      <p
        :if={Enum.any?(@legs, & &1.luring?) or Enum.any?(@waypoints, &(&1.action == :lure_end))}
        id="map-lure-legend"
        class="pointer-events-none absolute bottom-2 right-3 flex items-center gap-1.5 font-mono text-pk-meta text-pk-info"
      >
        <span class="h-0.5 w-4 rounded-full bg-pk-info"></span>
        trecho de mob <span class="ml-1.5 size-2 rounded-full bg-pk-info"></span>
        matança
      </p>
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
end
