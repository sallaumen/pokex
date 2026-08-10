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
    <div id={@id} class="rounded-lg border border-pk-line bg-pk-sunken px-3 py-2">
      <p class="flex items-center gap-1.5 font-mono text-pk-meta uppercase tracking-[0.1em] text-pk-text-3">
        <.icon name={@icon} class="size-3.5" />{@label}
      </p>
      <p class={["pk-num mt-1 font-mono text-pk-title font-bold", tone_text(@tone)]}>{@value}</p>
      <p :if={@note} class="mt-0.5 font-mono text-pk-meta text-pk-text-3">{@note}</p>
    </div>
    """
  end

  defp tone_text(:ok), do: "text-pk-ok"
  defp tone_text(:warn), do: "text-pk-warn"
  defp tone_text(:danger), do: "text-pk-danger"
  defp tone_text(_neutral), do: "text-pk-text"

  attr :waypoints, :list, required: true
  attr :pos, :any, default: nil
  attr :selected, :any, default: nil
  attr :recording?, :boolean, default: false

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

        <polyline
          :if={length(@waypoints) > 1}
          points={CavebotMap.path_attr(@waypoints)}
          fill="none"
          stroke="var(--color-pk-ok-line)"
          stroke-width="2"
          stroke-linejoin="round"
          stroke-linecap="round"
          vector-effect="non-scaling-stroke"
        />
        <%!-- The loop is real: the hunt walks back to the first waypoint. --%>
        <polyline
          :if={length(@waypoints) > 2}
          points={CavebotMap.path_attr([List.last(@waypoints), hd(@waypoints)])}
          fill="none"
          stroke="var(--color-pk-ok-line)"
          stroke-width="1.5"
          stroke-dasharray="4 4"
          vector-effect="non-scaling-stroke"
        />

        <%!-- Which WAY the hunt runs — the one thing coordinates never say. --%>
        <polygon
          :for={arrow <- @legs}
          points="0,-1 0,1 2,0"
          fill="var(--color-pk-ok)"
          opacity="0.7"
          transform={"translate(#{arrow.x} #{arrow.y}) rotate(#{arrow.angle}) scale(#{@view.unit * 0.9})"}
        />

        <g :for={{wp, index} <- Enum.with_index(@waypoints)}>
          <circle
            id={"map-waypoint-#{index}"}
            cx={wp.x}
            cy={wp.y}
            r={@view.unit * if @selected == index, do: 1.6, else: 1.1}
            fill={if index == 0, do: "var(--color-pk-ok-dim)", else: "var(--color-pk-surface)"}
            stroke={if @selected == index, do: "var(--color-pk-warn)", else: "var(--color-pk-ok)"}
            stroke-width="2"
            vector-effect="non-scaling-stroke"
            class="cursor-pointer"
            phx-click="select_waypoint"
            phx-value-index={index}
          >
            <title>{"waypoint #{index + 1}: #{wp.x}, #{wp.y}"}</title>
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
    </div>
    """
  end

  defp point_of({x, y, _z}), do: %{x: x, y: y}

  defp legs(waypoints) when length(waypoints) > 1 do
    waypoints
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> CavebotMap.arrow(a, b) end)
  end

  defp legs(_short), do: []

  defp map_summary(waypoints, pos) do
    base =
      "Mapa da rota: #{length(waypoints)} waypoints, #{CavebotMap.total_tiles(waypoints)} tiles"

    if pos, do: base <> ", personagem em #{elem(pos, 0)}, #{elem(pos, 1)}", else: base
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
