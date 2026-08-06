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
    assigns = assign(assigns, saved: "#{sw}×#{sh}", current: "#{cw}×#{ch}")

    ~H"""
    <div
      id="other-screen-warning"
      class="rounded-lg border border-warning/40 bg-warning/10 px-3 py-2 text-sm"
    >
      <p class="font-bold text-warning">🖥️ Esta calibração é de outra tela</p>
      <p class="mt-0.5 opacity-80">
        Foi marcada numa tela de {@saved} pontos e a de agora tem {@current}. Cada ponto salvo
        pertence à tela onde foi marcado — nesta aqui eles caem no lugar errado.
        Refaça a calibração completa.
      </p>
    </div>
    """
  end

  def screen_warning(assigns), do: ~H""
end
