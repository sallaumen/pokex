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
  attr :arena_region, :any, default: nil
  attr :skill_bar_region, :any, default: nil
  attr :neutral_point, :any, default: nil
  attr :player_point, :any, default: nil
  attr :bands, :list, default: []

  def overlays(assigns) do
    ~H"""
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
      :if={@arena_region}
      class="absolute rounded border-2 border-success bg-success/10"
      style={region_style(@arena_region, @screen)}
    >
      <span class="absolute -top-4 left-0 rounded bg-success px-1 text-[10px] font-bold text-success-content">
        arena
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
      <span class="flex items-center gap-1">
        <span class="size-2.5 rounded-sm border-2 border-success" /> arena
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
    </div>
    """
  end
end
