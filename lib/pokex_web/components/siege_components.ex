defmodule PokexWeb.SiegeComponents do
  @moduledoc """
  The siege, drawn the way the game frames it: the character in the centre,
  everything else in tiles from him.

  Game tiles ARE the drawing's coordinates (x east, y south), the same idiom as
  the route map and the simulator's board, so nothing is transformed twice and
  the evidence photo, which IS the captured box, lines up tile for tile
  underneath.

  State is never colour alone: the headline says in words what the tiles show.

  ## Cada quadrado diz o QUANTO, não só o quê

  "Me mostrar, quando ele identificar qualquer coisa, qual a taxa de confiabilidade que ele
  acha… para eu ajudar a encontrar bugs" (09/09). Um quadrado sem número é uma afirmação sem
  prova, e o que muda por quadrado é justamente o que se pode provar:

    * **o pokémon dele** — a nota da sprite ensinada (0..100%) quando foi ela que o achou, e
      QUAL dos três caminhos achou quando não foi (a caixa de número, ou a vida da Pokebar).
      Ele já disse que "ele muitas vezes troca qual é o pokémon que ele acha que é o meu": saber
      por qual caminho é a diferença entre achar o defeito e adivinhar.
    * **o shiny** — os pixels da cor contra o gatilho provado da regra. Quatro vezes o gatilho é
      uma afirmação diferente de uma que raspou nele.
    * **um monstro comum** — a vida, que é o que a barra realmente mede. A barra ou casa ou não
      casa (borda preta, preenchimento de uma cor só): não existe "70% de barra", e inventar um
      número aqui seria a única mentira que este card poderia contar.

  E os dois se distinguem à primeira vista: **número puro é VIDA, número com `≈` é o quanto ele
  acredita**. Sem isso o 87% de semelhança da sprite lia-se como 87% de vida num pokémon que
  estava com 96 — duas grandezas diferentes com a mesma cara é como se lê um número errado sem
  perceber.
  """
  use PokexWeb, :html

  attr :reading, :map,
    default: nil,
    doc: "the :crowd fact — a CrowdScan reading without the picture"

  attr :photo, :string, default: nil, doc: "evidence data URL, when he asked for one"
  attr :radius, :integer, required: true, doc: "the eye's box, in tiles each way"
  attr :max_age_ms, :integer, required: true
  attr :now_ms, :integer, required: true
  attr :mirror?, :boolean, default: false, doc: "the live screen underneath, refreshing itself"

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
          class="shrink-0 cursor-pointer rounded border border-pk-line px-2 py-0.5 font-mono text-pk-meta text-pk-text-2 hover:bg-pk-raised"
        >
          foto agora
        </button>
        <%!-- O ESPELHO: a tela dele por baixo, renovada sozinha. Nasce
             desligado porque é uma imagem inteira por socket a cada duas
             segundos, e a página tem que continuar servindo pra quem só quer
             ver a caçada andar. --%>
        <button
          id="siege-mirror"
          type="button"
          phx-click="toggle_mirror"
          class={[
            "shrink-0 cursor-pointer rounded border px-2 py-0.5 font-mono text-pk-meta transition-colors",
            if(@mirror?,
              do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
              else: "border-pk-line text-pk-text-2 hover:bg-pk-raised"
            )
          ]}
          title="a sua tela por baixo do desenho, renovada a cada 2s — pra ver se o que ele leu é o que está lá"
        >
          🪞 espelho {if @mirror?, do: "ligado", else: "desligado"}
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

          <%!-- A foto só entra com uma leitura que TEM caixa e âncora: com o
               espelho ligado, uma captura que falha deixa a foto velha no lugar
               e a leitura vira `read?: false` — desenhar aquela foto pedia um
               `box` que não existe e derrubava a página. --%>
          <image
            :if={@photo && placeable?(@reading) && (@state == :fresh or @mirror?)}
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
            <g :for={h <- @reading.hostiles}>
              <rect
                data-hostile
                data-dx={h.dx}
                data-dy={h.dy}
                data-from-me={h.from_me}
                data-special={h[:special?] && "1"}
                x={h.dx - 0.5}
                y={h.dy - 0.5}
                width="1"
                height="1"
                fill={hostile_fill(h)}
                stroke={if h[:special?], do: "var(--color-pk-text)", else: "var(--color-pk-bg)"}
                stroke-width={if h[:special?], do: "0.12", else: "0.08"}
              >
                <title>{hostile_title(h)}</title>
              </rect>
              <text
                data-hostile-label
                x={h.dx}
                y={h.dy + 0.12}
                text-anchor="middle"
                font-size="0.34"
                font-family="ui-monospace, monospace"
                font-weight="700"
                fill="var(--color-pk-bg)"
                pointer-events="none"
              >
                {hostile_label(h)}
              </text>
            </g>
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
              <title>{pet_title(@reading.pet)}</title>
            </rect>
            <text
              :if={@reading.pet}
              data-pet-label
              x={@reading.pet.dx}
              y={@reading.pet.dy + 0.12}
              text-anchor="middle"
              font-size="0.34"
              font-family="ui-monospace, monospace"
              font-weight="700"
              fill="var(--color-pk-bg)"
              pointer-events="none"
            >
              {pet_label(@reading.pet)}
            </text>
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
        <li class="flex items-center gap-1.5">
          <span class="inline-block size-3 bg-pk-shiny ring-1 ring-pk-text"></span> shiny (cor
          ensinada)
        </li>
        <li class="flex items-center gap-1.5">
          <span class="font-mono font-bold text-pk-text-3">42</span> no quadrado: a vida
        </li>
        <li class="flex items-center gap-1.5">
          <span class="font-mono font-bold text-pk-text-3">≈42%</span> o quanto ele acredita
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
    special =
      if h[:special?],
        do: "✨ #{h[:special_name]} · #{h[:special_px]}px da cor ensinada · ",
        else: ""

    special <>
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

  # O SHINY TEM COR PRÓPRIA. Ele é o troféu da noite e não pode dividir a
  # paleta com a vida de um bicho comum: quem olha de longe tem que saber que
  # aquele quadrado é OUTRA COISA sem ler número nenhum.
  defp hostile_fill(%{special?: true}), do: "var(--color-pk-shiny)"
  defp hostile_fill(%{hp_pct: hp}), do: hp_fill(hp)

  # --- o quanto ele acredita ----------------------------------------------------

  defp hostile_label(%{special?: true} = h), do: "≈#{special_pct(h)}"
  defp hostile_label(%{hp_pct: hp}), do: "#{hp}"

  # Os pixels da cor contra o GATILHO PROVADO da regra: 100% é raspar nele.
  # Sem a regra na mão (ela pode ter sido apagada depois da leitura) sobra o
  # número cru, que ainda é melhor que nada.
  defp special_pct(%{special_px: px} = h) do
    case trigger_of(h[:special_name]) do
      nil -> "#{px}px"
      trigger -> "#{round(px * 100 / trigger)}%"
    end
  end

  defp special_pct(_no_px), do: "✨"

  defp trigger_of(name) when is_binary(name) do
    Enum.find_value(Pokex.Vision.ColorRules.armed(), fn rule ->
      if rule.name == name and rule.min_px > 0, do: rule.min_px
    end)
  end

  defp trigger_of(_no_name), do: nil

  # A NOTA DA SPRITE quando foi ela que achou; a inicial do caminho quando não
  # foi. Uma letra é o bastante pra ele ver, de relance, que hoje o pokémon
  # está sendo achado pela VIDA e não pela foto ensinada.
  defp pet_label(%{by: :sprite, score: score}) when is_float(score),
    do: "≈#{round(score * 100)}%"

  defp pet_label(%{by: :box}), do: "nº"
  defp pet_label(%{by: :hp}), do: "vida"
  defp pet_label(_no_method), do: ""

  defp pet_title(pet) do
    "seu pokémon a #{pet.tiles} #{tiles(pet.tiles)} · #{pet.hp_pct}% de vida · " <>
      pet_how(pet)
  end

  defp pet_how(%{by: :sprite, score: score}) when is_float(score),
    do: "achado pela sprite ensinada (#{round(score * 100)}% de semelhança)"

  defp pet_how(%{by: :box}), do: "achado pela caixa de número embaixo da barra"
  defp pet_how(%{by: :hp}), do: "achado pela VIDA batendo com a Pokebar — nem sprite nem caixa"
  defp pet_how(_no_method), do: "não se sabe por qual caminho"

  # --- the photo, mapped tile for tile ------------------------------------------

  defp placeable?(%{box: {_x, _y, _w, _h}, me: {_px, _py}}), do: true
  defp placeable?(_unread), do: false

  defp photo_x(%{box: {bx, _by, _w, _h}, me: {px, _py}}), do: (bx - px) / tile() - 0.5
  defp photo_y(%{box: {_bx, by, _w, _h}, me: {_px, py}}), do: (by - py) / tile() - 0.5
  defp photo_w(%{box: {_bx, _by, w, _h}}), do: w / tile()
  defp photo_h(%{box: {_bx, _by, _w, h}}), do: h / tile()

  defp tile, do: Pokex.Calibration.tile_px()
end
