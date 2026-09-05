defmodule PokexWeb.SiegeComponents do
  @moduledoc """
  The siege, drawn the way the game frames it: the character in the centre,
  everything else in tiles from him.

  Game tiles ARE the drawing's coordinates (x east, y south), the same idiom as
  the route map and the simulator's board, so nothing is transformed twice and
  the evidence photo, which IS the captured box, lines up tile for tile
  underneath.

  State is never colour alone: the headline says in words what the tiles show.
  """
  use PokexWeb, :html

  attr :reading, :map,
    default: nil,
    doc: "the :crowd fact — a CrowdScan reading without the picture"

  attr :photo, :string, default: nil, doc: "evidence data URL, when he asked for one"
  attr :radius, :integer, required: true, doc: "the eye's box, in tiles each way"
  attr :max_age_ms, :integer, required: true
  attr :now_ms, :integer, required: true

  def siege_card(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns.reading, assigns.now_ms, assigns.max_age_ms))
      |> assign(:span, 2 * assigns.radius + 1)
      |> assign(:origin, -assigns.radius - 0.5)

    ~H"""
    <section id="siege-card" class="rounded-lg border border-pk-line bg-pk-surface p-3">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 class="shrink-0 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
          👁 o cerco
        </h2>
        <p id="siege-headline" class="min-w-0 flex-1 text-pk-body text-pk-text-2">
          {headline(@state, @reading, @now_ms)}
        </p>
        <button
          type="button"
          phx-click="crowd_scan"
          class="shrink-0 rounded border border-pk-line px-2 py-0.5 font-mono text-pk-meta text-pk-text-2 hover:bg-pk-raised"
        >
          foto agora
        </button>
      </div>

      <div class="relative mt-2 aspect-[4/3] w-full overflow-hidden rounded border border-pk-line bg-pk-bg">
        <svg
          viewBox={"#{@origin} #{@origin} #{@span} #{@span}"}
          class="size-full"
          role="img"
          aria-label={headline(@state, @reading, @now_ms)}
        >
          <defs>
            <pattern id="siege-ground" width="1" height="1" patternUnits="userSpaceOnUse">
              <rect width="1" height="1" fill="var(--color-pk-bg)" />
              <path
                d="M 1 0 L 0 0 0 1"
                fill="none"
                stroke="var(--color-pk-line)"
                stroke-width="0.04"
              />
            </pattern>
          </defs>

          <image
            :if={@photo && @state == :fresh}
            href={@photo}
            x={photo_x(@reading)}
            y={photo_y(@reading)}
            width={photo_w(@reading)}
            height={photo_h(@reading)}
            preserveAspectRatio="none"
            opacity="0.55"
          />
          <rect
            x={@origin}
            y={@origin}
            width={@span}
            height={@span}
            fill="url(#siege-ground)"
            fill-opacity={if @photo, do: "0.35", else: "1"}
          />

          <%= if @state == :fresh do %>
            <%!-- the bite ring around the pet: the eight tiles a pile can fill --%>
            <rect
              :if={@reading.pet}
              x={@reading.pet.dx - 1.5}
              y={@reading.pet.dy - 1.5}
              width="3"
              height="3"
              fill="none"
              stroke="var(--color-pk-ok)"
              stroke-width="0.08"
              stroke-dasharray="0.4 0.3"
              opacity="0.7"
            />
            <rect
              :for={h <- @reading.hostiles}
              data-hostile
              data-dx={h.dx}
              data-dy={h.dy}
              data-from-me={h.from_me}
              x={h.dx - 0.5}
              y={h.dy - 0.5}
              width="1"
              height="1"
              fill={hp_fill(h.hp_pct)}
              stroke="var(--color-pk-bg)"
              stroke-width="0.08"
            >
              <title>{hostile_title(h)}</title>
            </rect>
            <rect
              :if={@reading.pet}
              data-pet
              x={@reading.pet.dx - 0.5}
              y={@reading.pet.dy - 0.5}
              width="1"
              height="1"
              fill="var(--color-pk-ok)"
              stroke="var(--color-pk-bg)"
              stroke-width="0.12"
            >
              <title>
                seu pokémon a {@reading.pet.tiles} {tiles(@reading.pet.tiles)} · {@reading.pet.hp_pct}% de vida
              </title>
            </rect>
          <% end %>

          <rect
            data-me
            x="-0.5"
            y="-0.5"
            width="1"
            height="1"
            fill="var(--color-pk-info)"
            stroke="var(--color-pk-text)"
            stroke-width="0.18"
          >
            <title>você</title>
          </rect>
        </svg>
      </div>

      <ul class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-pk-meta text-pk-text-2">
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-3 bg-pk-info ring-1 ring-pk-text"></span> você
        </li>
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-3 bg-pk-ok"></span> seu pokémon
        </li>
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-3 border border-dashed border-pk-ok"></span> as oito bocas
        </li>
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-3 bg-pk-danger"></span> monstro (cor = vida)
        </li>
      </ul>
    </section>
    """
  end

  # --- words ---------------------------------------------------------------

  defp state(nil, _now, _max), do: :none
  defp state(%{read?: false}, _now, _max), do: :unread

  defp state(%{at: at}, now, max) do
    if now - at <= max, do: :fresh, else: {:stale, now - at}
  end

  defp headline(:none, _reading, _now), do: "sem olho — nenhuma leitura ainda"
  defp headline({:stale, age}, _reading, _now), do: "sem olho (foto de #{age} ms)"
  defp headline(:unread, %{reason: reason}, _now), do: "não deu pra olhar: #{reason(reason)}"

  defp headline(:fresh, r, now) do
    seen = length(r.hostiles)
    unseen = max((r.listed || 0) - seen, 0)

    Enum.join(
      [
        "vi #{seen} · lista #{r.listed || "?"} · #{unseen} sem ver",
        pet_words(r.pet),
        nearest_words(r.hostiles),
        skull_words(r.hostiles),
        "lido há #{max(now - r.at, 0)} ms"
      ],
      " · "
    )
  end

  defp pet_words(nil), do: "pokémon não visto"
  defp pet_words(%{tiles: t}), do: "pokémon a #{t} #{tiles(t)}"

  defp nearest_words([]), do: "ninguém perto"
  defp nearest_words([%{from_me: t} | _]), do: "mais perto a #{t} #{tiles(t)}"

  defp skull_words(hostiles),
    do: if(Enum.any?(hostiles, & &1.skull?), do: "área com caveira", else: "sem caveira")

  defp tiles(1), do: "tile"
  defp tiles(_n), do: "tiles"

  defp hostile_title(h) do
    "#{h.dx}, #{h.dy} · a #{h.from_me} #{tiles(h.from_me)} de você" <>
      if(h.from_pet, do: " · a #{h.from_pet} do pokémon", else: "") <>
      " · #{h.hp_pct}% de vida" <> if(h.skull?, do: " · caveira", else: "")
  end

  defp reason(:not_calibrated), do: "o /calibrar nunca rodou nesta tela"
  defp reason(:no_player_point), do: "a calibração não marcou onde o personagem fica"
  defp reason(:disabled), do: "o olho está desligado no /config"
  defp reason(:no_hunt), do: "sem caçada rodando"
  defp reason(other), do: to_string(other)

  # --- the palette, the simulator's --------------------------------------------

  defp hp_fill(hp) when hp > 66, do: "var(--color-pk-danger)"
  defp hp_fill(hp) when hp > 33, do: "var(--color-pk-warn)"
  defp hp_fill(_low), do: "var(--color-pk-warn-line)"

  # --- the photo, mapped tile for tile ------------------------------------------

  defp photo_x(%{box: {bx, _by, _w, _h}, me: {px, _py}}), do: (bx - px) / tile() - 0.5
  defp photo_y(%{box: {_bx, by, _w, _h}, me: {_px, py}}), do: (by - py) / tile() - 0.5
  defp photo_w(%{box: {_bx, _by, w, _h}}), do: w / tile()
  defp photo_h(%{box: {_bx, _by, _w, h}}), do: h / tile()

  defp tile, do: Pokex.Calibration.tile_px()
end
