defmodule PokexWeb.CalibrationOverlay do
  @moduledoc """
  Visual preview of the calibrated regions, drawn as absolutely-positioned boxes
  over a full-screen screenshot. The per-row LOCK BANDS are drawn in RED — they
  are the exact slices the combat sensor samples (see
  `Pokex.Calibration.battle_row_bands/3`), so if they don't sit on the
  battle-list rows, the calibration has drifted and the lock will misread the
  fight. Shared by /calibration (review the saved calibration) and /diagnostics
  (preview against a fresh screenshot).

  Positioning is percentage-based over the screenshot: every coordinate is a
  screen POINT and the `screen` map carries the screen size in points (`w`/`h`),
  so the overlay scales with however wide the browser renders the image.
  """
  use PokexWeb, :html

  @doc "Percentage position of a screen-point over the screenshot (screen w/h in points)."
  def point_style({x, y}, %{w: w, h: h}), do: "left:#{x / w * 100}%;top:#{y / h * 100}%"

  @doc "Percentage position + size of a screen-point rectangle over the screenshot."
  def region_style({x, y, rw, rh}, %{w: w, h: h}),
    do: "left:#{x / w * 100}%;top:#{y / h * 100}%;width:#{rw / w * 100}%;height:#{rh / h * 100}%"

  # A whole screen shrunk into a browser column makes a 19-point-tall region
  # about four pixels tall: at that size a box that starts 40 points early
  # looks exactly like a box that starts right. Both of Lucas's bottom-row
  # regions were marked one element too far left — the HP band opened on the
  # portrait and closed before the bar ended, the skill bar opened on the ROD
  # and closed before skill 9 — and the full-screen preview showed both as
  # "fine" (2026-08-06). So the crops are shown at READING size: this is the
  # pixels the bot reads, nothing else.
  @crop_height 64
  @crop_max_zoom 5.0
  # A point has no size of its own; this is the window drawn around it.
  @point_window 44

  @doc """
  CSS that renders `region` (screen points) as a magnified crop of the
  screenshot — the background trick keeps it free: no second capture, no
  server-side cropping, and it can never disagree with the picture on screen.
  """
  def crop_style({x, y, rw, rh}, %{src: src, w: w, h: h}) when rw > 0 and rh > 0 do
    zoom = min(@crop_height / rh, @crop_max_zoom)

    "width:#{Float.round(rw * zoom, 1)}px;height:#{Float.round(rh * zoom, 1)}px;" <>
      "background-image:url(#{src});background-repeat:no-repeat;" <>
      "background-size:#{Float.round(w * zoom, 1)}px #{Float.round(h * zoom, 1)}px;" <>
      "background-position:-#{Float.round(x * zoom, 1)}px -#{Float.round(y * zoom, 1)}px"
  end

  @doc "The window a POINT is judged by — did the water point land on water?"
  def point_window({x, y}) do
    half = div(@point_window, 2)
    {x - half, y - half, @point_window, @point_window}
  end

  def point_window(_unmarked), do: nil

  attr :screen, :map, required: true
  attr :water_point, :any, default: nil
  attr :glow_region, :any, default: nil
  attr :battle_region, :any, default: nil
  attr :skill_bar_region, :any, default: nil

  attr :skill_bar_count, :integer,
    default: 0,
    doc: "how many cells the bar is cut into — 0 draws the box without the grid"

  attr :neutral_point, :any, default: nil
  attr :player_point, :any, default: nil
  attr :pokemon_hp_region, :any, default: nil
  attr :pokemon_photo_point, :any, default: nil
  attr :mini_game_region, :any, default: nil
  attr :minimap_region, :any, default: nil
  attr :minimap_coord_region, :any, default: nil
  attr :minimap_player_point, :any, default: nil
  attr :scan_region, :any, default: nil
  attr :bands, :list, default: []

  def overlays(assigns) do
    ~H"""
    <div
      :if={@scan_region}
      class="absolute rounded border-2 border-dashed border-success/70"
      style={region_style(@scan_region, @screen)}
    >
      <span class="absolute -top-4 right-0 rounded bg-success px-1 text-[10px] font-bold text-success-content">
        busca de corpos
      </span>
    </div>
    <div
      :if={@glow_region}
      class="absolute rounded border-2 border-info bg-info/10"
      style={region_style(@glow_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-info px-1 text-[10px] font-bold text-info-content">
        brilho
      </span>
    </div>
    <div
      :if={@mini_game_region}
      class="absolute rounded border-2 border-primary bg-primary/10"
      style={region_style(@mini_game_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-primary px-1 text-[10px] font-bold text-primary-content">
        mini game
      </span>
    </div>
    <div
      :if={@minimap_region}
      class="absolute rounded border-2 border-info bg-info/5"
      style={region_style(@minimap_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-info px-1 text-[10px] font-bold text-info-content">
        minimapa
      </span>
    </div>
    <div
      :if={@minimap_coord_region}
      class="absolute rounded border-2 border-error bg-error/10"
      style={region_style(@minimap_coord_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-error px-1 text-[10px] font-bold text-error-content">
        coordenada
      </span>
    </div>
    <div
      :if={@battle_region}
      class="absolute rounded border-2 border-warning bg-warning/10"
      style={region_style(@battle_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-warning px-1 text-[10px] font-bold text-warning-content">
        Battle
      </span>
    </div>
    <div
      :if={@skill_bar_region}
      class="absolute rounded border-2 border-secondary bg-secondary/10"
      style={region_style(@skill_bar_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-secondary px-1 text-[10px] font-bold text-secondary-content">
        skills
      </span>
      <%!-- The CELLS, not just the box. `Vision.skill_slots/2` cuts this
            rectangle into `count` equal columns and calls column i the hotkey
            SkillBar.keys/1 gives it — so a box one cell off makes every skill
            read the neighbour, silently. Lucas's bar on the small screen
            (2026-08-06) enclosed the ROD and left skill 9 outside: every
            cooldown read was one slot to the left, which shut the "só pescar
            quando dá pra matar" gate forever. A box looks right at a glance;
            numbered cells over the real icons cannot lie. --%>
      <span
        :for={{key, i} <- Enum.with_index(Pokex.Bots.SkillBar.keys(@skill_bar_count))}
        class="absolute top-0 bottom-0 flex items-end justify-center border-l border-secondary/60 pb-px text-[9px] font-bold text-secondary first:border-l-0"
        style={"left:#{i * 100 / @skill_bar_count}%;width:#{100 / @skill_bar_count}%"}
      >
        {key}
      </span>
    </div>
    <div
      :if={@pokemon_hp_region}
      class="absolute rounded border-2 border-accent bg-accent/10"
      style={region_style(@pokemon_hp_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-accent px-1 text-[10px] font-bold text-accent-content">
        vida
      </span>
    </div>
    <div
      :for={{band, i} <- Enum.with_index(@bands)}
      class="absolute border-2 border-error bg-error/25"
      style={region_style(band, @screen)}
    >
      <span class="absolute left-0 top-1/2 -translate-y-1/2 rounded-r bg-error px-1 text-[10px] font-bold leading-tight text-error-content">
        L{i}
      </span>
    </div>
    <div
      :if={@water_point}
      class="absolute -ml-1.5 -mt-1.5 size-3 rounded-full border-2 border-white bg-info shadow"
      style={point_style(@water_point, @screen)}
      title="água"
    />
    <div
      :if={@neutral_point}
      class="absolute -ml-1.5 -mt-1.5 size-3 rounded-full border-2 border-white bg-neutral shadow"
      style={point_style(@neutral_point, @screen)}
      title="neutro"
    />
    <div
      :if={@player_point}
      class="absolute -ml-2 -mt-2 size-4 rounded-full border-2 border-error bg-error/40 shadow"
      style={point_style(@player_point, @screen)}
      title="player"
    />
    <div
      :if={@pokemon_photo_point}
      class="absolute -ml-2 -mt-2 size-4 rounded-full border-2 border-white bg-accent shadow"
      style={point_style(@pokemon_photo_point, @screen)}
      title="foto do Pokémon"
    />
    <div
      :if={@minimap_player_point}
      class="absolute -ml-2 -mt-2 grid size-4 place-items-center rounded-full border-2 border-info bg-info/30 text-[10px] font-black leading-none text-info shadow"
      style={point_style(@minimap_player_point, @screen)}
      title="cruz do personagem no minimapa — a origem de todo passo do cavebot"
    >
      +
    </div>
    """
  end

  def legend(assigns) do
    ~H"""
    <div class="flex flex-wrap gap-x-4 gap-y-1 text-xs">
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-error bg-error/25" /> bandas do lock (L0…)
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-warning" /> janela Battle
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-full bg-info" /> água + brilho
      </span>
      <span class="flex items-center gap-1"></span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-primary" /> faixa do mini game
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-secondary" /> barra de skills
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-full border border-error bg-error/40" /> player
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-full bg-neutral" /> ponto neutro
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-accent" /> vida + foto do Pokémon
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-info" /> minimapa + cruz
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-error" /> faixa da coordenada
      </span>
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-dashed border-success/70" />
        busca de corpos (automática)
      </span>
    </div>
    """
  end

  @doc """
  The saved calibration's screen vs the one in front of him now.

  A different SHAPE of screen means the points belong somewhere else and only a
  full recalibration fixes it. The same shape at another size is one screenshot
  measured with two rulers — repairable exactly, in one click.
  """
  attr :check, :any, required: true

  def screen_warning(%{check: {:rescalable, {sw, sh}, {cw, ch}}} = assigns) do
    assigns = assign(assigns, saved: "#{sw}×#{sh}", current: "#{cw}×#{ch}")

    ~H"""
    <div
      id="screen-scale-warning"
      class="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm"
    >
      <p class="font-bold text-warning">📏 Esta calibração foi salva com a régua errada</p>
      <p class="mt-0.5 opacity-80">
        Ela diz {@saved} pontos, mas é a MESMA tela de {@current} — só medida errado, então cada
        ponto ficou fora de lugar na mesma proporção. Dá pra consertar sem remarcar nada.
      </p>
      <button class="btn btn-warning btn-xs mt-2" phx-click="rescale_calibration">
        Corrigir para {@current}
      </button>
    </div>
    """
  end

  def screen_warning(%{check: {:another_screen, {sw, sh}, {cw, ch}}} = assigns) do
    # One calibration per MONITOR, remembered — never adapted by arithmetic
    # (Lucas, 2026-08-07). If this monitor was ever calibrated, its LAST
    # calibration is one click away; only a truly new monitor needs the wizard.
    assigns =
      assign(assigns,
        saved: "#{sw}×#{sh}",
        current: "#{cw}×#{ch}",
        restorable?: Pokex.Calibration.last_for_screen({cw, ch}) != :none
      )

    ~H"""
    <div
      id="other-screen-warning"
      class="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm"
    >
      <p class="font-bold text-warning">🖥️ Esta calibração é de outra tela</p>
      <p class="mt-0.5 opacity-80">
        Foi marcada numa tela de {@saved} pontos e a de agora tem {@current}. Cada ponto salvo
        pertence à tela onde foi marcado — nesta aqui eles caem no lugar errado.
      </p>
      <button
        :if={@restorable?}
        id="restore-last-for-screen"
        class="btn btn-warning btn-xs mt-2"
        phx-click="restore_last_calibration"
      >
        Usar a última calibração desta tela ({@current})
      </button>
      <p :if={!@restorable?} class="mt-0.5 opacity-80">
        Esta tela nunca foi calibrada — refaça a calibração completa (ela fica guardada pra
        próxima troca de monitor).
      </p>
    </div>
    """
  end

  def screen_warning(assigns), do: ~H""

  attr :screen, :map, required: true, doc: "the screenshot: src + w/h in points"
  attr :calib, :map, required: true
  attr :adjustable?, :boolean, default: false, doc: "show the per-area nudge pads (the review)"
  attr :adjust_target, :any, default: nil, doc: "the area key with the pad open, or nil"
  attr :adjust_step, :integer, default: 5, doc: "points per nudge click"
  attr :coord_probe, :any, default: nil, doc: "live coord reading: {:ok, text} | :error | nil"

  @doc """
  Every marked area at READING size — the answer to "está no lugar certo?".

  The full-screen preview cannot answer it: a 19-point band drawn inside a
  browser column is a few pixels tall, so a band 40 points off looks identical
  to a correct one. Here each area is magnified until it is legible, so the
  question becomes "o número 1 está em cima da skill 1?" instead of "a caixa
  parece bem?".

  With `adjustable?` (the review), each area also carries a nudge pad: arrows
  move the mark by `adjust_step` points and regions can grow/shrink — the crop
  redraws from the SAME screenshot on every click, so the repair is guided by
  the eye instead of redoing a wizard. The "coordenada" card shows the LIVE
  reading (`coord_probe`) — the proof that the strip is marked right.
  """
  def read_crops(assigns) do
    assigns = assign(assigns, :crops, crop_list(assigns.calib))

    ~H"""
    <div :if={@crops != []} id="read-crops" class="space-y-2">
      <p class="text-xs opacity-70">
        Isto é <b>exatamente</b>
        o que o bot lê em cada área — ampliado. Se algo aqui estiver
        cortado ou pegando o vizinho, {if @adjustable?,
          do: "ajusta ali mesmo com as setinhas",
          else: "é essa marcação que precisa ser refeita"}.
      </p>
      <div class="flex flex-wrap gap-3">
        <div :for={{key, label, kind, region} <- @crops} class="space-y-1">
          <div class="flex items-center gap-1.5">
            <p class="font-mono text-[10px] opacity-70">{label}</p>
            <button
              :if={@adjustable?}
              id={"adjust-#{key}"}
              class={[
                "btn btn-ghost btn-xs h-5 min-h-0 px-1 text-[10px]",
                @adjust_target == key && "btn-active text-primary"
              ]}
              phx-click="adjust_target"
              phx-value-target={key}
              title="ajustar esta área com as setinhas"
            >
              ✎
            </button>
            <span
              :if={key == :minimap_coord_region and @coord_probe != nil}
              id="coord-probe"
              class={[
                "rounded px-1 font-mono text-[10px] font-bold",
                match?({:ok, _}, @coord_probe) && "bg-success/20 text-success",
                @coord_probe == :error && "bg-error/20 text-error"
              ]}
            >
              {case @coord_probe do
                {:ok, text} -> "li: #{text}"
                :error -> "não li — ajusta a faixa"
              end}
            </span>
          </div>
          <div
            class="rounded border border-base-content/30 bg-base-300"
            style={crop_style(region, @screen)}
          />
          <div
            :if={@adjustable? and @adjust_target == key}
            id={"adjust-pad-#{key}"}
            class="flex flex-wrap items-center gap-1 rounded-lg border border-primary/40 bg-primary/10 p-1.5"
          >
            <.pad_btn target={key} dx={-1} label="◀" title="mover pra esquerda" />
            <.pad_btn target={key} dx={1} label="▶" title="mover pra direita" />
            <.pad_btn target={key} dy={-1} label="▲" title="mover pra cima" />
            <.pad_btn target={key} dy={1} label="▼" title="mover pra baixo" />
            <span :if={kind == :region} class="mx-0.5 opacity-40">·</span>
            <.pad_btn
              :if={kind == :region}
              target={key}
              dw={-1}
              label="⇤largura"
              title="encolher na largura"
            />
            <.pad_btn
              :if={kind == :region}
              target={key}
              dw={1}
              label="largura⇥"
              title="crescer na largura"
            />
            <.pad_btn
              :if={kind == :region}
              target={key}
              dh={-1}
              label="−altura"
              title="encolher na altura"
            />
            <.pad_btn
              :if={kind == :region}
              target={key}
              dh={1}
              label="+altura"
              title="crescer na altura"
            />
            <span class="mx-0.5 opacity-40">·</span>
            <button
              :for={step <- [1, 5, 20]}
              class={[
                "btn btn-xs h-6 min-h-0 px-1.5 font-mono",
                @adjust_step == step && "btn-primary"
              ]}
              phx-click="adjust_step"
              phx-value-step={step}
            >
              {step}pt
            </button>
          </div>
        </div>
      </div>
    </div>
    """
  end

  attr :target, :any, required: true
  attr :label, :string, required: true
  attr :title, :string, required: true
  attr :dx, :integer, default: 0
  attr :dy, :integer, default: 0
  attr :dw, :integer, default: 0
  attr :dh, :integer, default: 0

  defp pad_btn(assigns) do
    ~H"""
    <button
      class="btn btn-xs h-6 min-h-0 px-1.5"
      phx-click="adjust"
      phx-value-target={@target}
      phx-value-dx={@dx}
      phx-value-dy={@dy}
      phx-value-dw={@dw}
      phx-value-dh={@dh}
      title={@title}
    >
      {@label}
    </button>
    """
  end

  # Regions as marked; points as the window around them (a point on its own
  # shows nothing — "o ponto da água caiu na água?" needs the neighbourhood).
  # RESOLVED values (manual > layout > derived) so the automatic areas show up
  # too — adjusting one materializes it as manual, the established "a mão
  # manda" semantics. The key names the CALIBRATION FIELD the pad writes.
  defp crop_list(calib) do
    [
      {:pokemon_hp_region, "vida do Pokémon", :region, calib.pokemon_hp_region},
      {:skill_bar_region, "skills", :region, calib.skill_bar_region},
      {:battle_region, "janela Battle", :region, calib.battle_region},
      {:glow_region, "brilho (isca)", :region, calib.glow_region},
      {:minimap_region, "minimapa", :region, Pokex.Calibration.minimap_region(calib)},
      {:minimap_coord_region, "coordenada", :region,
       Pokex.Calibration.minimap_coord_region(calib)},
      {:minimap_player_point, "cruz do personagem", :point,
       point_window(Pokex.Calibration.minimap_player_point(calib))},
      {:mini_game_region, "faixa do mini game", :region,
       Pokex.Calibration.mini_game_region(calib)},
      {:water_point, "água", :point, point_window(calib.water_point)},
      {:neutral_point, "ponto neutro", :point, point_window(calib.neutral_point)},
      {:player_point, "personagem", :point, point_window(Pokex.Calibration.player_point(calib))},
      {:pokemon_photo_point, "foto do Pokémon", :point, point_window(calib.pokemon_photo_point)},
      {:pokemon_spot_point, "lugar do Pokémon", :point, point_window(calib.pokemon_spot_point)},
      {:escape_point, "escada de fuga", :point, point_window(calib.escape_point)}
    ]
    |> Enum.filter(fn {_key, _label, _kind, region} -> is_tuple(region) end)
  end
end
