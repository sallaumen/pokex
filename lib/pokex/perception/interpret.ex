defmodule Pokex.Perception.Interpret do
  @moduledoc """
  Pure frame → observation interpreters, one per feed. Ported from the combat half of
  `Fisher.Sensors.Real` (which stays untouched for fishing until phase 2): same slicing,
  same row-band geometry, same thresholds — the ONLY addition is the lock verdict
  (locked?/locked_row), computed here once so every consumer shares one interpretation.
  """

  alias Pokex.Bots.SkillBar
  alias Pokex.{Calibration, Settings, Vision}
  alias Pokex.Vision.{Frame, Glyphs}

  @doc """
  The battle panel: candidate enemy rows (HP bar, no own-pokemon pokeball), per-row
  lock-ring red counts, whether/where the lock ring is up — and, per occupied row,
  how much health is left in it.

  `enemies_detail` used to be empty without a located layout, and that silence
  cost a hunt: on 2026-08-27 the area killed all six Magnetons, his own Steelix
  was the one row left, the brain counted it as an enemy and the bot stood
  there firing at it for nineteen seconds. Everything needed to know better was
  on screen — the row's own health track, reading the same 69% the Pokebar was
  reading from the other side of the HUD.
  """
  def battle(frame, calib, settings) do
    measured = calib && calib.layout && Pokex.Layout.battle_rows()

    {top, band, rows} =
      case measured do
        # The profile carries the geometry MEASURED on real captures. His
        # battle_row_height setting says 52, tuned when the panel sat 173px
        # higher; the rows actually repeat every 46, and bands built from the
        # stale number land between rows.
        %{band_top: t, pitch: p, max_rows: r} ->
          {t, p, r}

        nil ->
          {t, b} =
            Calibration.row_band_geometry(
              frame.scale,
              Settings.value(settings, :battle_row_height),
              Settings.value(settings, :battle_first_row_y)
            )

          {t, b, Settings.value(settings, :battle_max_rows)}
      end

    strip_px = round(Calibration.strip_width() * frame.scale)

    # The strip (the rightmost pokeball column) is cropped OFF the body so its
    # red ball pixels can't read as the lock ring — but a pokeball on a row no
    # longer subtracts it from the enemies: measured live (2026-07-20), a
    # "Catch Pokémon" quest marks the CATCHABLE enemy's row with a pokeball —
    # the very creature the bot must attack — while the own pokemon (out, HP
    # readable) doesn't appear in the list at all. The old "pokeball = own
    # pokemon" subtraction erased the only enemy: battle read 0 forever and
    # combat stood still while the creature beat the player. Every HP-bar row
    # is a candidate; the lock ring (and the game's own Tab, which cannot
    # target your pokemon) confirms real targets.
    body = Frame.crop(frame, {0, 0, frame.width - strip_px, frame.height})

    # The BARS come off the whole frame, never the body: the pokeball strip is
    # cropped by a constant measured on the old client, and on his panel that
    # constant eats the right end of the health track — a full bar read 87%.
    placed = frame |> Vision.hp_bars() |> rows_of(top, band, rows)
    creatures = Enum.map(placed, &elem(&1, 0))
    red = Vision.red_row_counts(body, top: top, band: band, rows: rows)

    locked_row =
      case Vision.locked_row(red, Settings.value(settings, :target_locked_min_pixels)) do
        {:ok, row} -> row
        :none -> nil
      end

    # The old client's golden star died with the migration: this client does not mark
    # shinies in the battle list. Shiny/boss is now seen by COLOUR (`ShinyGuard` +
    # `Vision.ColorMark`), outside this reader.
    detail = enemies_detail(body, measured, placed, [])

    %{
      enemies: Enum.sort(creatures),
      enemies_detail: detail,
      red: red,
      # Per-row HP-bar green, on the SAME bands as the lock ring: how combat
      # tells a fight from a stalemate. Deliberately not `enemies_detail`'s
      # hp_pct — that one needs a located layout, and this must read with or
      # without one.
      hp: Vision.hp_row_counts(body, top: top, band: band, rows: rows),
      locked?: locked_row != nil,
      locked_row: locked_row
    }
  end

  @doc """
  The skill hotbar: per-slot readiness (`:ready | :cooldown`) plus the ready hotbar keys in
  ascending slot order. Both are NIL when the frame is not the bar — the hotkey labels
  the game draws under every slot are missing from most of them (window moved/covered) —
  UNKNOWN, never a guess, so consumers fail open (combat: blind rotation; fishing: the
  hold's own ceiling).
  """
  def skills(frame, _calib, settings) do
    if SkillBar.valid_frame?(frame, settings) do
      slots = SkillBar.slots_from_frame(frame, settings)
      %{states: SkillBar.states(slots), ready_keys: SkillBar.ready_keys(slots)}
    else
      %{states: nil, ready_keys: nil}
    end
  end

  # The star sits right at the name's start (name at x=83 in the measured
  # profile). 20px slack: genuinely golden icons — which the color floor cannot
  # separate (measured: 976/976 px with g<=r on a real golden icon) — end at
  # x<=52, and the slack covers the whole star glyph even if it starts before
  # the name. Without a measured layout, no restriction — the predicate's color
  # floor stands alone as the defense (covers the Shuckle/Vileplume class).

  # Every occupied row is described, WITH OR WITHOUT a located layout. It used
  # to answer `[]` without one, and that silence is what the panel was really
  # costing him: the health of each creature was on screen, his own pokemon's
  # row could not be told apart from an enemy's, and "I killed them all" was
  # unanswerable. Measured on his hunt of 2026-08-27 — one row left, his own
  # Steelix at 69%, counted as an enemy, and the bot stood there firing at it
  # for nineteen seconds.
  #
  # The NAME still needs the located layout and stays nil without one. The
  # HEALTH does not: the bar measures its own box.
  defp enemies_detail(body, measured, placed, shiny_rows) do
    lexicon = Pokex.Pokedex.names()

    for {row, bar} <- Enum.sort_by(placed, &elem(&1, 0)) do
      %{
        row: row,
        name: name_at(body, measured, row, lexicon),
        hp_pct: hp_pct(body, measured, row, bar),
        shiny?: row in shiny_rows
      }
    end
  end

  defp name_at(_body, nil, _row, _lexicon), do: nil

  defp name_at(body, %{name: {[nx, ny], [nw, nh]}, pitch: pitch}, row, lexicon),
    do: Glyphs.read_name(body, {nx, ny + row * pitch, nw, nh}, lexicon)

  # A DECLARED box wins over a measured one, the same way the hand wins over the
  # auto-layout everywhere else here: the profile's box was measured on real
  # captures and it includes the spent part of the track, which is drawn in a
  # neutral grey on the old client and cannot be told from the panel behind it
  # by colour alone. Where no box is declared, the bar answers for itself — the
  # spent track of the new client IS separable (a slate blue), and a self-
  # measured bar is the difference between knowing a creature's health and
  # knowing only that it has a bar.
  defp hp_pct(body, %{bar: {[bx, by], [bw, bh]}, pitch: pitch}, row, _bar),
    do: bar_fill(body, {bx, by + row * pitch, bw, bh})

  defp hp_pct(_body, _no_box, _row, bar), do: Float.round(bar.pct, 3)

  # The fill runs left to right inside a fixed track; where it stops is the
  # health. No fill at all means the row has no bar to read.
  defp bar_fill(%Frame{} = frame, {x, y, w, h}) do
    greens =
      for cy <- y..(y + h - 1)//1,
          cx <- x..(x + w - 1)//1,
          cy >= 0 and cx >= 0 and cy < frame.height and cx < frame.width,
          green?(Frame.at(frame, cx, cy)),
          do: cx

    case greens do
      [] -> nil
      found -> min((Enum.max(found) - x + 1) / w, 1.0)
    end
  end

  defp green?({r, g, b}), do: g >= 90 and g > r + 30 and g > b + 30

  # Bucket bars into distinct 0-based battle rows (same math as the lock sensor).
  defp rows_of(bars, top, band, rows) do
    bars
    |> Enum.map(&{max(0, min(div(&1.y - top, band), rows - 1)), &1})
    |> Enum.uniq_by(&elem(&1, 0))
  end
end
