defmodule PokexWeb.CalibrationLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Body
  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.{PokemonSprites, PokemonTracker}
  alias Pokex.Vision.Recolor
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Calibration.CoordBandSearch
  alias Pokex.GameFocus
  alias Pokex.Home
  alias Pokex.Perception.Interpret.Minimap
  alias Pokex.Screenshot
  alias PokexWeb.CalibrationClick
  alias PokexWeb.CalibrationLibrary
  alias PokexWeb.CalibrationReview
  alias PokexWeb.CalibrationSteps
  alias PokexWeb.CalibrationZoom
  import PokexWeb.CalibrationOverlay, only: [overlays: 1, legend: 1, crop_style: 2]
  alias Pokex.ScreenScale
  alias Pokex.Settings
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  # Neutral: no turn, no scaling. Also the shape every paint carries, so the
  # template can render three sliders without knowing what any of them mean.
  @neutral_paint %{hue: 0, saturation: 100, brightness: 100}

  @glow_half 32

  # Click-to-zoom magnification: a rough click magnifies the screenshot around it (via CSS
  # transform, which the ImgClick hook's getBoundingClientRect already accounts for), then a
  # precise second click is transcribed back to screen coordinates. Helps a lot on a small screen.
  @zoom_factor 3.5

  @impl true
  def mount(params, _session, socket) do
    # `?bar=<pokémon>` turns the standalone skill-bar fix into that POKÉMON's
    # bar instead of the screen's: the /time page links here per pokémon, and
    # this page keeps the two clicks it already knew how to take.
    bar_target = bar_target(params["bar"])

    # Aimed at a pokémon, the count starts at ITS bar's — not the screen's.
    # Vespiquen carries 8 and the screen says 9: capturing without noticing
    # would have rewritten her bar with a slot she does not have, silently, and
    # the number sitting in the field would have looked like her own.
    #
    # `own?` is false whenever this pokémon has never been calibrated on its
    # own: the number then comes from a GLOBAL leftover (whichever bar was
    # captured last, back when there was only one shared bar) and has nothing
    # to do with this creature. It happens to look plausible, which is exactly
    # why every pokémon without a bar of its own quietly inherited nine.
    {skill_count, skill_count_own?} = configured_skill_count(bar_target)

    # The per-corpse counter (R4) updates on its own: the Catcher publishes the
    # session count on every sweep that finds something new.
    if connected?(socket),
      do: Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

    {:ok,
     assign(socket,
       page_title: "Calibração",
       screen: nil,
       scale: nil,
       step: nil,
       mode: nil,
       saved: nil,
       draft: %{},
       done: false,
       calibrated?: Calibration.exists?(),
       screen_check: screen_check(),
       profiles: load_profiles(),
       review: nil,
       error: nil,
       skillbar_msg: nil,
       zoom_at: nil,
       coord_search: nil,
       coord_teach_msg: nil,
       skill_count: skill_count,
       skill_count_own?: skill_count_own?,
       skill_count_form: skill_count_form(skill_count),
       row_height: Settings.get(:battle_row_height),
       max_rows: Settings.get(:battle_max_rows),
       battle_msg: nil,
       scale_proposals: nil,
       scale_ratio: nil,
       scale_msg: nil,
       click_trace: [],
       corpse_shot: nil,
       corpse_crop: nil,
       corpse_paint: @neutral_paint,
       corpse_msg: nil,
       corpse_list: CorpseLibrary.list(),
       bar_target: bar_target,
       team_names: team_names(),
       pokemon_shot: nil,
       pokemon_crop: nil,
       pokemon_msg: nil,
       pokemon_found: nil,
       pokemon_list: PokemonSprites.list(),
       corpse_counts: %{},
       adjust_target: nil,
       adjust_step: 5,
       tool: nil,
       suggested_mini_game: nil,
       coord_probe: nil
     )}
  end

  # A monitor already calibrated does NOT ask for nine clicks again. The run
  # opens on what is saved for this screen, drawn over a fresh screenshot, and
  # asks a single question: está tudo no lugar? ("quero que ele já sempre
  # sugira a calibração que ele já tem salvo pra usar... só me pedindo pra
  # confirmar", Lucas, 2026-08-25). Confirming re-marks NOTHING — the points
  # are exactly the ones on disk, so a screen that did not change cannot drift
  # by being looked at.
  @impl true
  def handle_event("capture_screen", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        saved = saved_for_screen(screen)
        draft = draft_from(saved, socket.assigns.skill_count)

        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           screen_check: screen_check(shot_points(screen)),
           saved: saved,
           step: if(complete?(draft), do: :confirm_saved, else: :battle_a),
           mode: :full,
           draft: draft,
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil,
           coord_search: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Confirming is the whole run: the draft ALREADY carries every saved mark.
  def handle_event("confirm_saved", _params, socket),
    do: {:noreply, finish(socket, socket.assigns.draft)}

  # "Conferir marca por marca": the same draft, walked step by step, where each
  # step can be kept with one click or replaced with two.
  def handle_event("walk_saved", _params, socket),
    do: {:noreply, assign(socket, step: :battle_a, zoom_at: nil)}

  # Keeping a mark advances over the WHOLE mark (a region is two clicks, one
  # decision) without touching the draft — that is what "nunca mudar esses
  # locais" means in code.
  def handle_event("keep_step", _params, socket) do
    case keep_after(socket.assigns.step) do
      :done -> {:noreply, finish(socket, socket.assigns.draft)}
      next -> {:noreply, assign(socket, step: next, zoom_at: nil)}
    end
  end

  # Standalone correction for an existing calibration. The normal 8-step wizard
  # already includes these two clicks.
  def handle_event("calibrate_skillbar", _params, socket),
    do:
      start_quick_fix(socket, :skill_a, :skillbar_only, %{
        skill_bar_count: socket.assigns.skill_count
      })

  # Standalone correction: re-mark only the character (the mini-game bar anchor)
  # on an existing calibration, without redoing the whole wizard.
  def handle_event("calibrate_player", _params, socket),
    do: start_quick_fix(socket, :player, :player_only)

  # Position & minimap (2026-07-30): minimap (2 clicks) + player cross (1) +
  # coordinate strip (2), saved as MANUAL calibration — the hand wins, the
  # automatic layout becomes the fallback. On save, the coordinate is read
  # FROM THE SAME SHOT with the freshly marked regions: feedback arrives
  # before any field run.
  def handle_event("calibrate_minimap", _params, socket),
    do: start_quick_fix(socket, :minimap_a, :minimap_only)

  # The band search re-run: another hover, another photo, another scan. The
  # game must be visible (a window over the minimap blinds the hover).
  def handle_event("coord_search_again", _params, socket) do
    send(self(), :coord_search)
    {:noreply, assign(socket, coord_search: :searching)}
  end

  # Hand-marking as fallback. The screenshot on file is the HOVER shot by now,
  # so for the first time the numbers are actually IN the picture being marked.
  def handle_event("coord_manual", _params, socket),
    do: {:noreply, assign(socket, step: :minimap_coord_a, coord_search: nil)}

  # The wizard is the only place where the label is ON SCREEN and already
  # segmented, so it is the only place these glyphs can be taught: the teach
  # page photographs on demand, and the client draws the coordinate only while
  # the position CHANGES — standing there, it has nothing to offer.
  #
  # One typed number names every character at once, including the ones
  # `nearest` merely GUESSED right. That is the point: on the 2026-08-17 render
  # not a single glyph was an atlas hit, and a coordinate read by luck is the
  # failure #255 was about.
  def handle_event("coord_teach_line", %{"coord" => typed}, socket) do
    case socket.assigns.coord_search do
      {:unread, band, ink, _text, glyphs} ->
        {:noreply, teach_coord_line(socket, typed, band, ink, glyphs)}

      _not_unread ->
        {:noreply, socket}
    end
  end

  def handle_event("save_found_band", _params, socket) do
    case socket.assigns.coord_search do
      {:found, band, _pos, ink} ->
        # the floor that READ is the floor the reader must start from: over
        # bright terrain the taught 120 welds the map to the strokes
        Settings.put(:minimap_coord_ink, ink)
        {:noreply, socket |> assign(coord_search: nil) |> save_minimap(band)}

      _not_found ->
        {:noreply, socket}
    end
  end

  # Standalone correction: mark only the strip where the mini-game bar shows up
  # (2 corners) on an existing calibration. From then on the mini-game worker
  # watches THAT region instead of hunting the bar inside the arena.
  def handle_event("calibrate_mini_game", _params, socket),
    do: start_quick_fix(socket, :mini_game_a, :mini_game_only)

  # The suggestion is DRAWN on the screenshot before he clicks anything, so
  # accepting it is one button instead of two corners — and he can still mark by
  # hand right there if the box is off (the hand always wins).
  def handle_event("use_suggested_mini_game", _params, socket) do
    case socket.assigns.suggested_mini_game do
      {_x, _y, _w, _h} = region ->
        {:noreply, save_mini_game_region(socket, region)}

      nil ->
        {:noreply, assign(socket, error: "sem personagem marcado — não dá pra sugerir a faixa")}
    end
  end

  # --- calibration profiles: save the current one, apply/delete a saved one ----

  def handle_event("save_profile", %{"profile_name" => name}, socket) do
    case Calibration.save_profile(name) do
      {:ok, slug} ->
        # best-effort thumbnail so the list shows WHICH layout this was; a failed
        # capture just means no image on the card
        Capture.screen(profile_thumb_file(slug))

        {:noreply,
         assign(socket,
           profiles: load_profiles(),
           error: nil,
           skillbar_msg: "Perfil \"#{slug}\" salvo com a calibração atual."
         )}

      {:error, :invalid_name} ->
        {:noreply, assign(socket, error: "nome de perfil inválido — use letras/números")}

      {:error, reason} ->
        {:noreply, assign(socket, error: "não deu pra salvar o perfil: #{inspect(reason)}")}
    end
  end

  def handle_event("apply_profile", %{"name" => name}, socket) do
    case Calibration.apply_profile(name) do
      {:ok, calib, settings} ->
        {:noreply,
         assign(socket,
           calibrated?: true,
           error: nil,
           scale_proposals: nil,
           row_height: Settings.get(:battle_row_height),
           skillbar_msg:
             "Perfil \"#{name}\" aplicado (#{calib.screen_w}×#{calib.screen_h}) " <>
               numbers_note(settings) <> " Reinicie os bots (Parar/Iniciar) pra valer."
         )}

      {:error, reason} ->
        {:noreply, assign(socket, error: "não deu pra aplicar o perfil: #{inspect(reason)}")}
    end
  end

  def handle_event("delete_profile", %{"name" => name}, socket) do
    Calibration.delete_profile(name)
    {:noreply, assign(socket, profiles: load_profiles(), skillbar_msg: "Perfil excluído.")}
  end

  # Standalone correction: mark only where the Pokémon should STAND (the strategic
  # attack tile the support worker middle-clicks after battles).
  def handle_event("calibrate_pokemon_spot", _params, socket),
    do: start_quick_fix(socket, :pokemon_spot, :pokemon_spot_only)

  # Standalone corrections for the wizard's own marks, so EVERY point is
  # repairable without redoing the ten steps (Lucas, 2026-08-07): the window
  # moved -> re-mark just that window.
  def handle_event("calibrate_water", _params, socket),
    do: start_quick_fix(socket, :water, :water_only)

  def handle_event("calibrate_battle", _params, socket),
    do: start_quick_fix(socket, :battle_a, :battle_only)

  def handle_event("calibrate_neutral", _params, socket),
    do: start_quick_fix(socket, :neutral, :neutral_only)

  def handle_event("calibrate_hp", _params, socket),
    do: start_quick_fix(socket, :hp_a, :hp_only)

  # Standalone correction: mark only the escape STAIRCASE tile the
  # emergency-escape protocol click-walks to.
  def handle_event("calibrate_escape_point", _params, socket),
    do: start_quick_fix(socket, :escape_point, :escape_point_only)

  def handle_event("review", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, screen} <- grab_screen() do
      review = screen |> Map.put(:calib, calib) |> with_decoded_frame()

      {:noreply,
       socket
       |> assign(
         review: review,
         screen_check: screen_check(shot_points(screen)),
         coord_probe: coord_probe(review),
         adjust_target: nil,
         tool: nil,
         scale_msg: nil,
         error: nil
       )
       |> measure_screen_scale(calib)}
    else
      error -> {:noreply, assign(socket, error: "não deu pra revisar: #{inspect(error)}")}
    end
  end

  def handle_event("close_review", _params, socket) do
    {:noreply, assign(socket, review: nil, adjust_target: nil, coord_probe: nil, tool: nil)}
  end

  # One tool open at a time: three panels side by side is the pile this page was
  # drowning in. Clicking the open one closes it.
  def handle_event("open_tool", %{"tool" => raw}, socket) do
    tool =
      Enum.find_value(CalibrationReview.tools(), fn {key, _l, _d} ->
        to_string(key) == raw && key
      end)

    {:noreply, assign(socket, tool: tool != socket.assigns.tool && tool)}
  end

  # -- fine-tuning in the review (the nudge pads) ------------------------------
  #
  # Every marked point/region is adjustable RIGHT ON its crop: arrows move it
  # by adjust_step points (regions also grow/shrink), the calibration saves on
  # every click, and the crop redraws from the SAME screenshot — repair guided
  # by the eye, not by redoing a wizard (Lucas, 2026-08-07). The pad writes the
  # MANUAL field even when the shown value came from a layout/derivation:
  # adjusting IS the hand override ("a mão manda").
  def handle_event("adjust_target", %{"target" => raw}, socket) do
    case adjust_key(raw) do
      {:ok, key, _kind} ->
        target = if socket.assigns.adjust_target == key, do: nil, else: key
        {:noreply, assign(socket, adjust_target: target)}

      _unknown ->
        {:noreply, socket}
    end
  end

  def handle_event("adjust_step", %{"step" => raw}, socket) do
    case Integer.parse(raw) do
      {step, ""} when step in [1, 5, 20] -> {:noreply, assign(socket, adjust_step: step)}
      _invalid -> {:noreply, socket}
    end
  end

  def handle_event("adjust", %{"target" => raw} = params, socket) do
    with %{review: %{calib: calib} = review} <- socket.assigns,
         {:ok, key, kind} <- adjust_key(raw),
         value when value != nil <- adjust_value(calib, key) do
      step = socket.assigns.adjust_step
      delta = fn p -> String.to_integer(params[p] || "0") * step end

      moved =
        shift_mark(kind, value, delta.("dx"), delta.("dy"), delta.("dw"), delta.("dh"), calib)

      calib =
        calib
        |> Map.put(key, moved)
        |> resample_after_adjust(key, review)

      Calibration.save(calib)
      review = %{review | calib: calib}

      {:noreply,
       socket
       |> assign(review: review, error: nil)
       |> maybe_reprobe_coord(key, review)}
    else
      _cannot -> {:noreply, socket}
    end
  end

  # "Usar a última calibração desta tela": the monitor was calibrated before,
  # so its snapshot comes back whole — marks AND the screen-dependent numbers.
  # No arithmetic touches any point (Lucas, 2026-08-07: adapting by
  # multiplication "só vai dar cagada"; per-monitor memory is the design).
  def handle_event("restore_last_calibration", _params, socket) do
    with {:another_screen, _saved, current} <- socket.assigns.screen_check,
         {:ok, calib, settings} <- Calibration.restore_last_for_screen(current) do
      {:noreply,
       assign(socket,
         calibrated?: true,
         screen_check: screen_check(),
         error: nil,
         row_height: Settings.get(:battle_row_height),
         skillbar_msg:
           "Última calibração desta tela restaurada (#{calib.screen_w}×#{calib.screen_h}, " <>
             "#{settings} número(s) junto). Reinicie os bots (Parar/Iniciar) pra valer."
       )}
    else
      _no_snapshot ->
        {:noreply, assign(socket, error: "esta tela ainda não tem calibração guardada")}
    end
  end

  # Applying is the HUMAN's click, never a silent transform — a derivation that
  # rewrites settings behind his back is how he would stop trusting the numbers
  # exactly when he needs them most.
  def handle_event("apply_screen_scale", _params, socket) do
    changed = ScreenScale.apply!(socket.assigns.scale_proposals || [])

    socket =
      assign(socket,
        row_height: Settings.get(:battle_row_height),
        scale_msg: "#{changed} ajuste(s) aplicado(s) — os bots leem o novo valor no próximo tique"
      )

    # Re-measure instead of blanking: what is left (nothing, if it all applied)
    # is the honest state, and the alert disappears because it is empty.
    {:noreply, measure_screen_scale(socket, socket.assigns.review.calib)}
  end

  # The battle list's ruler. `battle_row_height` was MEASURED on the ultrawide
  # (52pt) and, like every other pixel-denominated number, it does not survive a
  # change of screen: on Lucas's small screen the same list holds ~10 rows and
  # the bot was drawing 6 fat ones over 3 (2026-08-06). The bands are already on
  # screen right below this form, so changing the number here moves them WHILE
  # HE WATCHES — tuning by eye instead of by guess-and-restart.
  def handle_event("save_battle_rows", params, socket) do
    socket =
      socket
      |> save_setting(params["battle_row_height"], 8..200, :battle_row_height, :row_height)
      |> save_setting(params["battle_max_rows"], 1..12, :battle_max_rows, :max_rows)

    {:noreply, assign(socket, battle_msg: nil)}
  end

  # Better than tuning by eye when the list is populated: the HP bars ARE the
  # rows, so the distance between two of them IS the row height. Needs at least
  # two LIVING creatures on the list (a low-HP bar turns red and this reads the
  # green ones) — and says so instead of writing a number it could not measure.
  def handle_event("measure_battle_rows", _params, socket) do
    case measure_battle_rows(socket.assigns.review) do
      {:ok, height, bars} ->
        Settings.put(:battle_row_height, height)

        {:noreply,
         assign(socket,
           row_height: height,
           battle_msg: "medido em #{bars} barras de vida: linha de #{height}pt"
         )}

      {:error, reason} ->
        {:noreply, assign(socket, battle_msg: reason)}
    end
  end

  # A cell is exactly the unit the reader works in (`Vision.skill_slots/2` cuts
  # the box into `count` equal columns), so nudging by whole cells is the entire
  # repair: same width, same count, the numbers just land on the right icons
  # again. Lucas's bar on the small screen enclosed the ROD and left skill 9
  # out — every cooldown read was the neighbour's, and the fishing gate that
  # waits for a ready skill never opened (2026-08-06). Marking it again by hand
  # is the same trap twice; one cell is one click.
  def handle_event("nudge_skill_bar", %{"cells" => raw}, socket) do
    with %{review: %{calib: calib} = review} <- socket.assigns,
         {x, y, w, h} <- calib.skill_bar_region,
         count when is_integer(count) and count > 0 <- calib.skill_bar_count,
         {cells, _rest} <- Integer.parse(raw) do
      region = {x + cells * div(w, count), y, w, h}

      # The refs are re-sampled from the SAME picture the review is showing —
      # a stale signature would make every slot read "not mine" from here on.
      calib = %{
        calib
        | skill_bar_region: region,
          skill_slot_refs: skill_slot_refs(review, region, count)
      }

      Calibration.save(calib)
      {:noreply, assign(socket, review: %{review | calib: calib}, error: nil)}
    else
      _no_bar -> {:noreply, socket}
    end
  end

  # The clicks were right, the ruler was not: re-express every marked point in
  # the filmed display's coordinates instead of making him redo ten steps.
  # Offered ONLY for a same-shape mismatch (Calibration.screen_check/2), and the
  # review preview right below is the proof — the markers land on the game or
  # they don't.
  def handle_event("rescale_calibration", _params, socket) do
    with {:rescalable, _saved, {w, h}} <- socket.assigns.screen_check,
         {:ok, calib} <- Calibration.load(),
         :ok <- Calibration.save(Calibration.rescale(calib, {w, h})) do
      {:noreply,
       socket
       |> assign(screen_check: screen_check(), review: nil, error: nil)
       |> assign(skillbar_msg: "Calibração corrigida para #{w}×#{h}. Confira em 'Ver áreas'.")}
    else
      error ->
        {:noreply, assign(socket, error: "não deu pra corrigir a escala: #{inspect(error)}")}
    end
  end

  def handle_event("set_skill_count", %{"skill_bar" => %{"count" => raw}}, socket) do
    count = parse_skill_count(raw, socket.assigns.skill_count)

    {:noreply,
     assign(socket,
       skill_count: count,
       # He just told us the number himself — it stops being a borrowed guess
       # the moment he types it, even if it happens to match the old one.
       skill_count_own?: true,
       skill_count_form: skill_count_form(count),
       draft: Map.put(socket.assigns.draft, :skill_bar_count, count)
     )}
  end

  def handle_event(
        "img_click",
        %{"x" => _, "y" => _, "cw" => _, "ch" => _, "nw" => _, "nh" => _} = params,
        socket
      ) do
    # The click→point conversion is PURE (PokexWeb.CalibrationClick) because it
    # crashed this page once already: the browser sends INTEGERS on exact-pixel
    # clicks and the inline trace called Float.round on them (2026-08-07). The
    # module's regression test is that crash's payload, verbatim.
    zoomed? = socket.assigns.zoom_at != nil

    case CalibrationClick.read(params, socket.assigns.scale, zoomed?) do
      {:ok, point, entry} ->
        socket = assign(socket, click_trace: Enum.take([entry | socket.assigns.click_trace], 4))

        socket =
          if zoomed? do
            # A precise click on the magnified view → record it, then drop the zoom.
            socket |> record_point(point) |> assign(zoom_at: nil)
          else
            # A rough first click → magnify around it so the target is easy to hit.
            assign(socket, zoom_at: point)
          end

        {:noreply, socket}

      {:error, :empty_box} ->
        # the <img> had no measurable size yet (still loading) — a point made
        # of zeros would be garbage saved into the calibration
        {:noreply, assign(socket, error: "a imagem ainda não carregou — clique de novo")}
    end
  end

  def handle_event("cancel_zoom", _params, socket) do
    {:noreply, assign(socket, zoom_at: nil)}
  end

  # -- mapped corpses (the teaching that replaced capture guessing) ------------

  # Photographs EXACTLY the region the search sweeps (SpotScan.region/1). It
  # used `arena_region`, which broke teaching once the search became the scan
  # square: a corpse near the character — outside the narrow arena — did not
  # fit in the photo, so it couldn't even be clicked. Lucas hit this head-on
  # teaching a Gyarados cropped at the bottom edge (2026-07-30). Teaching and
  # searching must see the SAME piece of screen.
  def handle_event("corpse_shot", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, region} <- SpotScan.region(calib),
         {:ok, frame, _path} <- Capture.frame_with_path(region, "corpse_teach.png") do
      {:noreply,
       assign(socket,
         corpse_shot: %{frame: frame, v: System.system_time(:millisecond), region: region},
         corpse_crop: nil,
         corpse_msg: nil
       )}
    else
      # Only the scan's OWN reasons get the specific advice; a missing
      # calibration or a dead capture is a different problem and says so.
      {:error, reason} when reason in [:no_anchor, :no_screen, :frame_too_small] ->
        {:noreply, assign(socket, corpse_msg: {:error, photo_error(reason)})}

      _no_calibration_or_capture ->
        {:noreply,
         assign(socket, corpse_msg: {:error, "precisa de calibração e da captura viva"})}
    end
  end

  # --- His OWN pokémon, from several angles -----------------------------------
  #
  # The same photograph-and-name flow as the corpses, over the same square, and
  # deliberately into a DIFFERENT file: a pokémon taught into the corpse library
  # is something the Catcher throws Pokéballs at.
  def handle_event("pokemon_shot", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, region} <- SpotScan.region(calib),
         {:ok, frame, _path} <- Capture.frame_with_path(region, "pokemon_teach.png") do
      {:noreply,
       assign(socket,
         pokemon_shot: %{frame: frame, v: System.system_time(:millisecond), region: region},
         pokemon_crop: nil,
         pokemon_found: nil,
         pokemon_msg: nil
       )}
    else
      {:error, reason} when reason in [:no_anchor, :no_screen, :frame_too_small] ->
        {:noreply, assign(socket, pokemon_msg: {:error, photo_error(reason)})}

      _no_calibration_or_capture ->
        {:noreply,
         assign(socket, pokemon_msg: {:error, "precisa de calibração e da captura viva"})}
    end
  end

  def handle_event("pokemon_click", %{"x" => x, "y" => y, "cw" => cw, "nw" => nw}, socket) do
    case socket.assigns.pokemon_shot do
      nil ->
        {:noreply, socket}

      %{frame: frame} ->
        box = Settings.get(:pokemon_sprite_box_px)
        half = div(box, 2)
        px = round(x * nw / cw)
        py = round(y * nw / cw)
        cx = px |> max(half) |> min(max(frame.width - half, half))
        cy = py |> max(half) |> min(max(frame.height - half, half))

        crop =
          Frame.crop(
            frame,
            {cx - half, cy - half, min(box, frame.width), min(box, frame.height)}
          )

        {:noreply, assign(socket, pokemon_crop: %{frame: crop, at: {cx, cy}}, pokemon_msg: nil)}
    end
  end

  def handle_event("pokemon_save", %{"name" => name}, socket) do
    case socket.assigns.pokemon_crop do
      nil ->
        {:noreply, socket}

      %{frame: crop} ->
        case PokemonSprites.add(name, crop) do
          {:ok, n} ->
            {:noreply,
             assign(socket,
               pokemon_crop: nil,
               pokemon_msg:
                 {:ok,
                  "ângulo #{n}/#{PokemonSprites.max_samples()} de #{String.trim(name)} salvo"},
               pokemon_list: PokemonSprites.list()
             )}

          {:error, :empty_name} ->
            {:noreply, assign(socket, pokemon_msg: {:error, "dê o nome do pokémon"})}
        end
    end
  end

  def handle_event("pokemon_delete", %{"slug" => slug}, socket) do
    PokemonSprites.delete(slug)
    {:noreply, assign(socket, pokemon_list: PokemonSprites.list())}
  end

  def handle_event("pokemon_delete_sample", %{"slug" => slug, "index" => idx}, socket) do
    PokemonSprites.delete_sample(slug, String.to_integer(idx))
    {:noreply, assign(socket, pokemon_list: PokemonSprites.list())}
  end

  # The payoff, and the only honest way to judge the teaching: ask the tracker
  # to find it RIGHT NOW and say where and how sure. A library he cannot test is
  # a library he has to trust.
  def handle_event("pokemon_locate", _params, socket) do
    point =
      case Calibration.load() do
        {:ok, %Calibration{player_point: {_x, _y} = p}} -> p
        _no_point -> nil
      end

    if point do
      seen = PokemonTracker.look_around(point, Settings.get(:pokemon_track_radius_px) * 2)
      {:noreply, assign(socket, pokemon_found: seen, pokemon_msg: nil)}
    else
      {:noreply, assign(socket, pokemon_msg: {:error, "calibra o ponto do personagem antes"})}
    end
  end

  # The click on the photo: crops the sprite box in RAW frame px (the photo is
  # served at natural size, so x*nw/cw already IS the frame coordinate).
  def handle_event("corpse_click", %{"x" => x, "y" => y, "cw" => cw, "nw" => nw}, socket) do
    case socket.assigns.corpse_shot do
      nil ->
        {:noreply, socket}

      %{frame: frame} ->
        px = round(x * nw / cw)
        py = round(y * nw / cw)
        box = Settings.get(:corpse_sprite_box_px)
        half = div(box, 2)
        cx = px |> max(half) |> min(max(frame.width - half, half))
        cy = py |> max(half) |> min(max(frame.height - half, half))

        crop =
          Frame.crop(
            frame,
            {cx - half, cy - half, min(box, frame.width), min(box, frame.height)}
          )

        {:noreply,
         assign(socket,
           corpse_crop: %{frame: crop, at: {cx, cy}},
           corpse_paint: @neutral_paint,
           corpse_msg: nil
         )}
    end
  end

  # A shiny is a RECOLOR: same sprite, different palette. He cannot photograph a
  # corpse he has never made, so he turns the hue of the ordinary species' body
  # until it looks like the shiny he is hunting and teaches THAT. The knobs are
  # deliberately three — this moves a palette, it does not edit an image.
  def handle_event("corpse_paint", params, socket) do
    paint = %{
      hue: paint_value(params, "hue", -180, 180),
      saturation: paint_value(params, "saturation", 0, 200),
      brightness: paint_value(params, "brightness", 50, 150)
    }

    {:noreply, assign(socket, corpse_paint: paint)}
  end

  def handle_event("corpse_paint_reset", _params, socket),
    do: {:noreply, assign(socket, corpse_paint: @neutral_paint)}

  def handle_event("corpse_save", %{"name" => name}, socket) do
    case socket.assigns.corpse_crop do
      nil ->
        {:noreply, socket}

      %{frame: crop} ->
        paint = socket.assigns.corpse_paint
        crop = painted_crop(crop, paint)

        case CorpseLibrary.add(name, crop, painted?: painted?(paint)) do
          {:ok, n} ->
            {:noreply,
             assign(socket,
               corpse_crop: nil,
               corpse_paint: @neutral_paint,
               corpse_msg:
                 {:ok,
                  "amostra #{n}/#{CorpseLibrary.max_samples()} de #{String.trim(name)} salva"},
               corpse_list: CorpseLibrary.list()
             )}

          {:error, :empty_name} ->
            {:noreply, assign(socket, corpse_msg: {:error, "dê um nome ao corpo"})}
        end
    end
  end

  def handle_event("corpse_rename", %{"slug" => slug, "name" => name}, socket) do
    case CorpseLibrary.rename(slug, name) do
      {:ok, _slug} ->
        {:noreply, assign(socket, corpse_list: CorpseLibrary.list(), corpse_msg: nil)}

      {:error, :empty_name} ->
        {:noreply, assign(socket, corpse_msg: {:error, "dê um nome ao corpo"})}

      {:error, :taken} ->
        {:noreply, assign(socket, corpse_msg: {:error, "já existe um corpo com esse nome"})}
    end
  end

  # R4: disabling removes the corpse from the AIM without deleting its samples
  # — previously, silencing a false positive meant re-photographing everything.
  def handle_event("corpse_toggle", %{"slug" => slug}, socket) do
    ligado? =
      socket.assigns.corpse_list
      |> Enum.find(&(&1["slug"] == slug))
      |> then(&(&1 && CorpseLibrary.enabled?(&1)))

    CorpseLibrary.set_enabled(slug, not ligado?)
    {:noreply, assign(socket, corpse_list: CorpseLibrary.list())}
  end

  def handle_event("corpse_delete", %{"slug" => slug}, socket) do
    CorpseLibrary.delete(slug)
    {:noreply, assign(socket, corpse_list: CorpseLibrary.list())}
  end

  def handle_event("corpse_delete_sample", %{"slug" => slug, "idx" => idx}, socket) do
    CorpseLibrary.delete_sample(slug, String.to_integer(idx))
    {:noreply, assign(socket, corpse_list: CorpseLibrary.list())}
  end

  @impl true
  # The band search runs OFF the event that scheduled it, so the "procurando…"
  # state paints before the hover holds the page for ~2s. Only meaningful while
  # the wizard still sits on the search step — a stale message dies quietly.
  def handle_info(:coord_search, %{assigns: %{step: :minimap_coord_search}} = socket),
    do: {:noreply, run_coord_search(socket)}

  def handle_info(:coord_search, socket), do: {:noreply, socket}

  # The per-corpse count the Catcher publishes (R4). The topic's other traffic
  # (snapshots, logs) doesn't matter to this page — the catch-all below
  # swallows it, as the header already does on the other pages.
  def handle_info({:catcher_count, count}, socket),
    do: {:noreply, assign(socket, corpse_counts: count)}

  # The rest of the "catcher" topic traffic (snapshots, logs, alarms) dies
  # here: this page subscribed only for the per-corpse count, and a LiveView
  # without a clause for a message it asked for crashes with
  # FunctionClauseError — the exact bug class of PR #111, with the bot on.
  def handle_info(_msg, socket), do: {:noreply, socket}

  # The last click IS the end of the calibration. The old flow had one more
  # step: cast the line in the game and sit through ~4s of "baselines" that
  # nothing ever read — Vision.glow?/3 has no caller, and fishing detects the
  # cyan bubbles instead. A mandatory step feeding a dead field is the exact
  # "calibração inútil que dificulta a vida" (2026-08-03).
  # The run OVERWRITES what it asked for and keeps everything else. Building a
  # fresh struct here blanked every mark outside the numbered steps — minimapa,
  # faixa da coordenada, tile do pokémon, escada, água — so re-running the
  # wizard to fix the battle list silently blinded the cavebot. Marks a run
  # never asks about are not marks a run may erase.
  defp finish(socket, draft) do
    calib = %Calibration{
      previous_calibration(socket.assigns.screen)
      | scale: socket.assigns.scale,
        screen_w: socket.assigns.screen.w,
        screen_h: socket.assigns.screen.h,
        battle_region: draft.battle_region,
        neutral_point: draft.neutral_point,
        player_point: draft[:player_point],
        skill_bar_region: draft.skill_bar_region,
        skill_bar_count: draft.skill_bar_count,
        skill_slot_refs:
          draft[:skill_slot_refs] ||
            skill_slot_refs(socket.assigns.screen, draft.skill_bar_region, draft.skill_bar_count),
        pokemon_hp_region: draft[:pokemon_hp_region],
        pokemon_photo_point: draft[:pokemon_photo_point]
    }

    Calibration.save(calib)
    persist_skill_settings(draft.skill_bar_count)

    socket
    |> return_focus()
    |> assign(
      done: true,
      step: nil,
      calibrated?: true,
      screen_check: screen_check(shot_points(socket.assigns.screen))
    )
  end

  # Only marks made on THIS screen survive: on another monitor they point at
  # coordinates that no longer exist, and a blind-but-honest nil beats a mark
  # that looks calibrated and is not. The active file first, then this
  # monitor's own snapshot — coming back to a screen he calibrated last week
  # is the same situation as re-running on the one in front of him.
  defp saved_for_screen(%{w: w, h: h}) do
    with {:ok, %Calibration{screen_w: ^w, screen_h: ^h} = calib} <- Calibration.load() do
      calib
    else
      _other_screen_or_none ->
        case Calibration.last_for_screen({w, h}) do
          {:ok, calib} -> calib
          :none -> nil
        end
    end
  end

  defp previous_calibration(screen) do
    case saved_for_screen(screen) do
      %Calibration{} = calib -> calib
      nil -> %Calibration{}
    end
  end

  # The run starts from what is already known, so every step is a confirmation
  # and `finish/2` keeps what it never asked about. `skill_slot_refs` rides
  # along on purpose: kept, they are the colours learned with all skills READY,
  # and re-reading them from a screenshot taken mid-cooldown would teach the
  # reader that "pronta" looks dark. Re-marking the bar drops them (see
  # `record_step(:skill_b, ...)`) and they are learned again.
  defp draft_from(nil, skill_count), do: %{skill_bar_count: skill_count}

  defp draft_from(%Calibration{} = calib, skill_count) do
    %{
      water_point: calib.water_point,
      glow_region: calib.glow_region,
      battle_region: calib.battle_region,
      neutral_point: calib.neutral_point,
      player_point: calib.player_point,
      skill_bar_region: calib.skill_bar_region,
      skill_bar_count: skill_count,
      skill_slot_refs: calib.skill_slot_refs,
      pokemon_hp_region: calib.pokemon_hp_region,
      pokemon_photo_point: calib.pokemon_photo_point,
      minimap_region: calib.minimap_region,
      minimap_player_point: calib.minimap_player_point,
      minimap_coord_region: calib.minimap_coord_region,
      mini_game_region: calib.mini_game_region
    }
    |> Enum.reject(fn {_key, value} -> is_nil(value) end)
    |> Map.new()
  end

  # Every mark the numbered run asks for. Anything missing and the run walks:
  # confirming half a calibration would be confirming a hole.
  @wizard_marks ~w(battle_region neutral_point player_point skill_bar_region
                   pokemon_hp_region pokemon_photo_point)a

  defp complete?(draft), do: Enum.all?(@wizard_marks, &Map.has_key?(draft, &1))

  # Where "manter" lands: past the whole mark, never into its second click.
  defp keep_after(step) when step in [:battle_a, :battle_b], do: :neutral
  defp keep_after(:neutral), do: :player
  defp keep_after(:player), do: :skill_a
  defp keep_after(step) when step in [:skill_a, :skill_b], do: :hp_a
  defp keep_after(step) when step in [:hp_a, :hp_b], do: :photo
  defp keep_after(:photo), do: :done
  defp keep_after(_no_mark_to_keep), do: :done

  # What "manter" would keep at this step — nil hides the button, so a step with
  # nothing saved cannot offer to keep nothing.
  defp keepable(step, draft) when step in [:battle_a, :battle_b], do: draft[:battle_region]
  defp keepable(:neutral, draft), do: draft[:neutral_point]
  defp keepable(:player, draft), do: draft[:player_point]
  defp keepable(step, draft) when step in [:skill_a, :skill_b], do: draft[:skill_bar_region]
  defp keepable(step, draft) when step in [:hp_a, :hp_b], do: draft[:pokemon_hp_region]
  defp keepable(:photo, draft), do: draft[:pokemon_photo_point]
  defp keepable(_step, _draft), do: nil

  defp photo_error(:no_anchor),
    do: "marque o seu personagem na calibração (ou salve a resolução da tela) antes de ensinar"

  defp photo_error(:no_screen), do: "a calibração não sabe o tamanho da tela — refaça o passo 1"

  # Total for the domain the caller's guard allows — add a clause here when a
  # new scan reason joins that list.
  defp photo_error(:frame_too_small),
    do: "o quadro da busca ficou menor que o recorte do corpo"

  # Hand focus back to whatever was frontmost before the baselines fronted the game.
  defp return_focus(socket) do
    case socket.assigns[:return_app] do
      nil ->
        socket

      app ->
        GameFocus.front_app(app)
        assign(socket, return_app: nil)
    end
  end

  # The screenshot the whole wizard marks on, taken while the GAME is fronted
  # (see GameFocus.with_game_front/1). Measuring it is `Pokex.Screenshot`'s job — the same
  # recipe /diagnostics uses, so both pages and the bot share one coordinate space.
  # -- fine-tuning helpers -----------------------------------------------------

  # The whitelist of adjustable marks: UI string -> {calibration field, kind}.
  # Only fields the pads may WRITE — resolved/derived values are read through
  # adjust_value/2 below and materialize as manual on the first nudge.
  @adjustables %{
    "water_point" => {:water_point, :point},
    "neutral_point" => {:neutral_point, :point},
    "player_point" => {:player_point, :point},
    "pokemon_photo_point" => {:pokemon_photo_point, :point},
    "pokemon_spot_point" => {:pokemon_spot_point, :point},
    "escape_point" => {:escape_point, :point},
    "minimap_player_point" => {:minimap_player_point, :point},
    "glow_region" => {:glow_region, :region},
    "battle_region" => {:battle_region, :region},
    "skill_bar_region" => {:skill_bar_region, :region},
    "pokemon_hp_region" => {:pokemon_hp_region, :region},
    "mini_game_region" => {:mini_game_region, :region},
    "minimap_region" => {:minimap_region, :region},
    "minimap_coord_region" => {:minimap_coord_region, :region}
  }

  defp adjust_key(raw) do
    case @adjustables[raw] do
      {key, kind} -> {:ok, key, kind}
      nil -> :error
    end
  end

  # The CURRENT value the pad starts from — resolved (manual > layout >
  # derived), so nudging an automatic area starts from where it actually is.
  defp adjust_value(calib, :player_point), do: Calibration.player_point(calib)
  defp adjust_value(calib, :mini_game_region), do: Calibration.mini_game_region(calib)
  defp adjust_value(calib, :minimap_region), do: Calibration.minimap_region(calib)
  defp adjust_value(calib, :minimap_coord_region), do: Calibration.minimap_coord_region(calib)
  defp adjust_value(calib, :minimap_player_point), do: Calibration.minimap_player_point(calib)
  defp adjust_value(calib, key), do: Map.get(calib, key)

  # Clamped into the calibrated screen so a runaway pad can never push a mark
  # off-display; regions keep at least 4pt of flesh.
  defp shift_mark(:point, {x, y}, dx, dy, _dw, _dh, calib) do
    {clamp_pt(x + dx, calib.screen_w), clamp_pt(y + dy, calib.screen_h)}
  end

  defp shift_mark(:region, {x, y, w, h}, dx, dy, dw, dh, calib) do
    w = w |> Kernel.+(dw) |> max(4)
    h = h |> Kernel.+(dh) |> max(4)
    {clamp_pt(x + dx, calib.screen_w), clamp_pt(y + dy, calib.screen_h), w, h}
  end

  defp clamp_pt(v, nil), do: max(v, 0)
  defp clamp_pt(v, limit), do: v |> max(0) |> min(limit - 1)

  # Moving the skill bar invalidates every per-slot READY reference — resample
  # them from the SAME picture the review is showing (the nudge_skill_bar rule).
  defp resample_after_adjust(calib, :skill_bar_region, review) do
    case calib.skill_bar_count do
      count when is_integer(count) and count > 0 ->
        %{calib | skill_slot_refs: skill_slot_refs(review, calib.skill_bar_region, count)}

      _no_count ->
        calib
    end
  end

  defp resample_after_adjust(calib, _key, _review), do: calib

  @minimap_keys [:minimap_region, :minimap_coord_region, :minimap_player_point]

  defp maybe_reprobe_coord(socket, key, review) when key in @minimap_keys,
    do: assign(socket, coord_probe: coord_probe(review))

  defp maybe_reprobe_coord(socket, _key, _review), do: socket

  # The picture is decoded ONCE, when the review opens, and every probe reads
  # THAT. It used to be decoded per probe, and one screenshot of his screen
  # costs 15-21s to decode in pure Elixir (measured 2026-08-24, 3440x1440): a
  # single arrow click on the coordinate band paid the whole thing, which is
  # what made fine-tuning unusable ("é MUUUUITO lento, cada vez que eu clico em
  # cada botão"). Opening still pays it once — the coord probe already did.
  defp with_decoded_frame(%{path: path, calib: calib} = review) do
    # Only when something is going to READ it: with a minimap marked, the coord
    # probe decodes at open anyway, so this costs nothing and pays for every
    # click after. With nothing to probe, the review stays as cheap as it was.
    if Calibration.minimap_region(calib) do
      case Frame.from_png_file(path) do
        {:ok, frame} -> Map.put(review, :frame, frame)
        _undecodable -> review
      end
    else
      review
    end
  end

  defp with_decoded_frame(review), do: review

  # Falls back to the file for a review built before this cache existed (and
  # for the quick-fix flows, which carry a screen without one).
  defp review_frame(%{frame: %Frame{} = frame}), do: {:ok, frame}
  defp review_frame(%{path: path}), do: Frame.from_png_file(path)
  defp review_frame(_no_picture), do: :error

  # The LIVE proof the coordinate strip is marked right: read it from the very
  # screenshot the review is showing, through the SAME interpreter the cavebot
  # uses. {:ok, "x, y, z"} paints the badge green; :error says "ajusta a faixa".
  defp coord_probe(%{calib: calib, scale: scale} = review) do
    with {mx, my, mw, mh} <- Calibration.minimap_region(calib),
         {:ok, full} <- review_frame(review),
         %Frame{} = mini <-
           Frame.crop(
             full,
             {round(mx * scale), round(my * scale), round(mw * scale), round(mh * scale)}
           ),
         {%{pos: {x, y, z}}, _state} <-
           Minimap.interpret(mini, calib, Settings.all()) do
      {:ok, "#{x}, #{y}, #{z}"}
    else
      _unreadable -> :error
    end
  rescue
    _decode -> :error
  end

  defp coord_probe(_review), do: nil

  # One starter for every "Só o X" flow — the six copies of this block were
  # drifting apart one flow at a time. Marking on a DIFFERENT screen is fine by
  # design: save_mark stamps the CURRENT screen and the per-monitor memory
  # files the previous calibration under its own display ("me dá uma opção de
  # usar a última calibração daquele monitor" — Lucas, 2026-08-07).
  # Straight from the anchors, ignoring whatever is marked: this is the OFFER,
  # and offering him back the mark he already has would say nothing.
  # Only on the mini-game steps: the same box drawn during, say, the water mark
  # would be an area he is not being asked about.
  defp marking_suggestion(step, suggestion) when step in [:mini_game_a, :mini_game_b],
    do: suggestion

  defp marking_suggestion(_step, _suggestion), do: nil

  defp suggested_mini_game do
    case Calibration.load() do
      {:ok, calib} -> Calibration.derived_mini_game_region(calib)
      _no_calibration -> nil
    end
  end

  defp start_quick_fix(socket, first_step, mode, draft \\ %{}) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: first_step,
           mode: mode,
           draft: draft,
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil,
           suggested_mini_game: suggested_mini_game()
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  defp grab_screen do
    with {:ok, shot} <-
           GameFocus.with_game_front(fn -> Screenshot.take("calibration_screen.png") end) do
      {:ok, decorate_shot(shot)}
    end
  end

  defp decorate_shot(shot) do
    Map.put(
      shot,
      :src,
      "/captures/#{Path.basename(shot.path)}?t=#{System.unique_integer([:positive])}"
    )
  end

  # The label is up the moment the position changes; the photo only has to
  # outlast the client's own frame.
  @walk_settle_ms Application.compile_env(:pokex, :coord_walk_settle_ms, 350)
  # macOS gives a window KEY focus on a click, not on `set frontmost` alone:
  # Lucas's arrows landed in the BROWSER (2026-08-10). One click on the
  # calibrated neutral point — his own tile, a click-to-walk no-op — is what
  # hands the keys to the game.
  @focus_settle_ms Application.compile_env(:pokex, :coord_focus_settle_ms, 250)

  # WALKING is the state that matters. Measured 2026-08-10 on Lucas's screen:
  # standing still with the mouse away, the minimap has NO text at all — the
  # client draws the coordinate only while the position CHANGES, or under a
  # hovering mouse. The hover state is ~0% of the bot's life AND puts the label
  # ~40pt lower (under the control bar that slides in), so a band calibrated
  # there is a band the day-to-day reading never looks at. The search only ever
  # photographs a WALK, and a picture that shows the clock — the hover state's
  # own signature — is refused outright.
  @walk_pairs [{"right", "left"}, {"down", "up"}]

  defp run_coord_search(socket) do
    draft = socket.assigns.draft
    focus = focus_point()
    attempts = Enum.map(@walk_pairs, &{:walk, &1, focus})

    Enum.reduce_while(attempts, assign(socket, coord_search: :not_found), fn attempt, socket ->
      attempt |> try_attempt(draft) |> fold(socket)
    end)
  end

  defp fold({:found, shot, band, pos, ink, _mode}, socket) do
    {:halt,
     assign(socket, screen: shot, scale: shot.scale, coord_search: {:found, band, pos, ink})}
  end

  defp fold({:hovered, shot}, socket) do
    {:halt, assign(socket, screen: shot, scale: shot.scale, coord_search: :hovered)}
  end

  # A band proven by shape ends the walking too: no further beat can teach the
  # atlas a glyph, and the answer it needs is the one only Lucas has — the
  # number on his own screen.
  defp fold({:unread, shot, band, ink, text, glyphs}, socket) do
    {:halt,
     assign(socket,
       screen: shot,
       scale: shot.scale,
       coord_search: {:unread, band, ink, text, glyphs},
       coord_teach_msg: nil
     )}
  end

  defp fold({:shot, nil}, socket), do: {:cont, socket}
  defp fold({:shot, shot}, socket), do: {:cont, assign(socket, screen: shot, scale: shot.scale)}

  defp fold({:failed, reason}, socket),
    do: {:cont, assign(socket, coord_search: {:failed, reason})}

  defp try_attempt({:walk, pair, focus}, draft),
    do: GameFocus.with_game_front(fn -> walk_burst(pair, focus, draft) end)

  defp search_band(frame, draft, shot) do
    CoordBandSearch.search(
      frame,
      draft.minimap_region,
      shot.scale || 1.0,
      ink: Settings.get(:minimap_coord_ink)
    )
  end

  # Where the focus click lands: the calibrated NEUTRAL point (his own tile —
  # click-to-walk there lands where he already stands), falling back to the
  # marked character. Never a guessed point: a click on an unknown tile is a
  # walk order.
  defp focus_point do
    case Calibration.load() do
      {:ok, calib} -> calib.neutral_point || calib.player_point
      _no_calibration -> nil
    end
  end

  # A single photo has to GUESS when the label is up, and it guessed wrong on
  # Lucas's machine (2026-08-10): the character visibly walked and every shot
  # came out textless. The coordinate only changes when the step COMPLETES, and
  # the client's step is an animation — one shot lands mid-stride or after the
  # label has already faded. So the search keeps walking and photographs each
  # beat: out, back, out, back — net zero movement, four samples spread over
  # the whole walk, first hit wins.
  defp walk_burst({out_key, back_key}, focus, draft) do
    # INSIDE the front block, never before it: GameFocus.with_game_front restores the
    # browser on the way out, so a click made outside would hand the focus
    # straight back before a single key was pressed.
    if focus, do: Body.perform([{:focus_click, focus}, {:wait, @focus_settle_ms}])

    beats = Enum.with_index([out_key, back_key, out_key, back_key], 1)
    {result, pressed} = Enum.reduce_while(beats, {{:shot, nil}, 0}, &beat(&1, &2, draft))

    # halted on an odd beat: one key still owes its return trip
    if rem(pressed, 2) == 1, do: Body.perform([{:tap, back_key}])

    result
  end

  # `:unread` halts like a hit, not like a miss: it only ever means a glyph the
  # atlas does not know, and no amount of further walking teaches one. Walking
  # on would cost four more photos to fail the same way and then LOSE the band,
  # since the last beat wins the accumulator.
  defp beat({key, index}, _acc, draft) do
    Body.perform([{:tap, key}])
    Process.sleep(@walk_settle_ms)

    case shot_and_search(draft, :walk) do
      {:found, _shot, _band, _pos, _ink, _mode} = hit -> {:halt, {hit, index}}
      {:hovered, _shot} = hovered -> {:halt, {hovered, index}}
      {:unread, _s, _b, _i, _t, _g} = unread -> {:halt, {unread, index}}
      other -> {:cont, {other, index}}
    end
  end

  defp shot_and_search(draft, mode) do
    with {:ok, raw} <- Screenshot.take("calibration_screen.png"),
         shot = decorate_shot(raw),
         {:ok, frame} <- Vision.Frame.from_png_file(shot.path) do
      verdict(search_band(frame, draft, shot), shot, mode)
    else
      error -> {:failed, inspect(error)}
    end
  end

  defp verdict({:ok, band, pos, ink}, shot, mode), do: {:found, shot, band, pos, ink, mode}

  defp verdict({:unread, band, ink, text, glyphs}, shot, _mode),
    do: {:unread, shot, band, ink, text, glyphs}

  defp verdict(:hovered, shot, _mode), do: {:hovered, shot}
  defp verdict(:error, shot, _mode), do: {:shot, shot}

  defp found_band({:found, band, _pos, _ink}), do: band
  defp found_pos_text({:found, _band, {x, y, z}, _ink}), do: "(#{x}, #{y}, #{z})"

  defp unread_band({:unread, band, _ink, _text, _glyphs}), do: band
  defp unread_text({:unread, _band, _ink, text, _glyphs}), do: text

  # Spaces are not glyphs — `read_line` invents them from the gaps — so the
  # number is zipped onto the characters with its spacing stripped, and Lucas
  # can type "(2310, 30804, 6)" or "(2310,30804,6)" and mean the same thing.
  defp teach_coord_line(socket, typed, band, ink, glyphs) do
    chars = typed |> String.replace(~r/\s/, "") |> String.graphemes()

    if length(chars) == length(glyphs) do
      glyphs
      |> Enum.zip(chars)
      |> Enum.each(&teach_glyph/1)

      Vision.Glyphs.clear()
      confirm_taught_band(socket, band, ink)
    else
      assign(socket,
        coord_teach_msg:
          "esse número tem #{length(chars)} caracteres e eu vejo #{length(glyphs)} " <>
            "na faixa — digite exatamente o que está no minimapa, parênteses e vírgulas inclusive"
      )
    end
  end

  defp teach_glyph({glyph, char}),
    do: Vision.Glyphs.teach(Vision.Glyphs.signature(glyph.bitmap), char)

  # Taught is not read: the band must prove itself again on the same photo
  # before the wizard offers to save it, or a typo would be calibrated in.
  defp confirm_taught_band(socket, band, ink) do
    scale = socket.assigns.scale || 1.0

    with %{path: path} <- socket.assigns.screen,
         {:ok, frame} <- Vision.Frame.from_png_file(path),
         {_x, _y, _z} = pos <- Vision.Glyphs.read_coord(frame, scale_rect(band, scale), ink: ink) do
      assign(socket, coord_search: {:found, band, pos, ink}, coord_teach_msg: nil)
    else
      _still_unread ->
        assign(socket,
          coord_teach_msg:
            "aprendi, mas a faixa ainda não lê inteira — confira o número e tente de novo"
        )
    end
  end

  defp scale_rect({x, y, w, h}, scale),
    do: {round(x * scale), round(y * scale), round(w * scale), round(h * scale)}

  defp not_found?(:not_found), do: true
  defp not_found?({:failed, _reason}), do: true
  defp not_found?(_other), do: false

  # Per-slot READY references, cropped from the SAME screenshot the user just marked the bar
  # on (no extra capture, exact same instant): each slot's non-white colour signature becomes
  # its "this is what ready looks like" baseline for SkillBar. The wizard copy tells the user
  # to calibrate with every skill ready — but SkillBar.slot_refs drops any slot that LOOKS
  # like a countdown anyway (nil ref → threshold fallback), so one charging skill at
  # calibration time can't poison its own slot into reading inverted forever. nil (refs are
  # optional) when the crop fails — the reader then falls back to the threshold rules.
  defp skill_slot_refs(%{scale: scale} = review, {x, y, w, h}, count) do
    with {:ok, frame} <- review_frame(review),
         crop = {round(x * scale), round(y * scale), round(w * scale), round(h * scale)},
         %Frame{} = bar <- Frame.crop(frame, crop) do
      bar |> Vision.skill_slots(count: count) |> SkillBar.slot_refs(Settings.all())
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp skill_slot_refs(_screen, _region, _count), do: nil

  # The HP bars ARE the rows: the distance between two of them is the row
  # height. Read from the SAME picture the review is showing, in the battle
  # BODY (the pokeball strip is cropped off, exactly like the lock sensor).
  defp measure_battle_rows(%{scale: scale, calib: %{battle_region: region}} = review)
       when is_tuple(region) do
    {x, y, w, h} = Calibration.battle_body(region)
    crop = {round(x * scale), round(y * scale), round(w * scale), round(h * scale)}

    with {:ok, frame} <- review_frame(review),
         %Frame{} = body <- Frame.crop(frame, crop),
         [_first, _second | _rest] = centers <- Vision.hp_bar_rows(body) do
      {:ok, round(median_gap(centers) / scale), length(centers)}
    else
      _too_few ->
        {:error,
         "não deu pra medir: preciso de pelo menos DOIS pokémon vivos na lista " <>
           "(barra verde) — deixe a lista cheia e clique de novo"}
    end
  end

  defp measure_battle_rows(_no_battle_region),
    do: {:error, "marque a janela Battle primeiro"}

  # Nothing to offer when this screen IS the reference: a "fix" that moves two
  # values by one point each only teaches him to distrust the button.
  # A profile saved before the numbers were carried applies its MARKS and
  # nothing else — saying so is the difference between "pronto" and a bot that
  # reads this screen with the other screen's thresholds.
  defp numbers_note(0),
    do:
      "— só as marcações: este perfil é antigo e não guardou os números. Confira a régua da tela."

  defp numbers_note(count), do: "com os #{count} números desta tela."

  # Inside the noise band this screen IS the reference, so the numbers to offer
  # are the SEEDS themselves — not seed×0.98. Snapping the ratio (instead of the
  # old "return [] and say nothing") is what closes the hole that broke fishing
  # on 2026-08-10: back on the reference monitor after a trip to the MacBook, the
  # ruler matched, the panel had nothing to say, and the bot went on reading the
  # water with the MacBook's thresholds (glow_threshold 496 where the bite was
  # measured at 1100). `proposals/2` still returns [] by itself when the values
  # in force already match, so a clean reference screen proposes nothing.
  # Every pixel-denominated seed was measured once, on the ultrawide. None of
  # them survives a change of screen — that is what "nada funciona em 1 monitor
  # só" was made of (2026-08-06). The ruler is a skill slot, not the display:
  # the display went 0.44 between his two screens while the game went 0.67.
  #
  # Measured when the review OPENS, not behind a "Conferir a régua" button:
  # this is pure arithmetic over the calibration (no capture, no cost), and a
  # check nobody clicks is a check nobody makes — on 2026-08-10 the numbers of
  # the other screen went on breaking fishing with the answer one click away.
  defp measure_screen_scale(socket, calib) do
    case ScreenScale.measure(calib) do
      {:ok, ratio} ->
        assign(socket, scale_ratio: ratio, scale_proposals: proposals_for(ratio))

      :inconsistent ->
        assign(socket,
          scale_ratio: nil,
          scale_proposals: nil,
          scale_msg:
            "a barra de skills não bate com esta tela — confira a região e a contagem de slots " <>
              "antes de mexer nos números (uma tela não mede o dobro de si mesma)"
        )

      :unknown ->
        assign(socket,
          scale_ratio: nil,
          scale_proposals: nil,
          scale_msg: "sem régua: calibre a barra de skills primeiro (é ela que mede a tela)"
        )
    end
  end

  defp proposals_for(ratio) do
    ratio = if ScreenScale.matches_reference?(ratio), do: 1.0, else: ratio
    ScreenScale.proposals(ratio)
  end

  # An out-of-range or half-typed value leaves BOTH the setting and the drawing
  # alone — the bands must never be drawn from a number the bot is not using.
  defp save_setting(socket, raw, range, setting_key, assign_key) do
    case PokexWeb.PanelForms.parse_int(raw, range) do
      {:ok, value} ->
        Settings.put(setting_key, value)
        assign(socket, assign_key, value)

      :error ->
        socket
    end
  end

  # The median, not the mean: one missed bar doubles a single gap, and a doubled
  # gap would drag an average far more than it drags the middle value.
  defp median_gap(centers) do
    gaps =
      centers
      |> Enum.sort()
      |> Enum.chunk_every(2, 1, :discard)
      |> Enum.map(fn [a, b] -> b - a end)
      |> Enum.sort()

    Enum.at(gaps, div(length(gaps), 2))
  end

  # One clause per step: the old single `case` over twenty steps scored 26 on
  # cyclomatic complexity and hid which step did what.
  defp record_point(socket, point),
    do: record_step(socket.assigns.step, socket, point, socket.assigns.draft)

  # Fishing gear, reached only by the água button: the numbered run does not ask
  # for a fishing spot to calibrate a hunt.
  defp record_step(:water, socket, point, _draft) do
    {x, y} = point
    glow = {x - @glow_half, y - @glow_half, @glow_half * 2, @glow_half * 2}

    save_mark(socket, %{water_point: point, glow_region: glow}, %{
      ok: "Água re-marcada em #{inspect(point)} — o brilho da isca acompanhou.",
      error: "não deu pra salvar a água"
    })
  end

  # The old box leaves the picture on the FIRST click of its replacement:
  # drawing yesterday's rectangle while he marks today's corner is the surest
  # way to make him mark it wrong.
  defp record_step(:battle_a, socket, point, draft) do
    draft = draft |> Map.delete(:battle_region) |> Map.put(:battle_a, point)
    assign(socket, draft: draft, step: :battle_b)
  end

  defp record_step(:battle_b, socket, point, draft) do
    region = region_from(draft.battle_a, point)

    case socket.assigns.mode do
      :battle_only ->
        save_mark(socket, %{battle_region: region}, %{
          ok: "Janela Battle re-marcada — confira as bandas do lock no review.",
          error: "não deu pra salvar a Battle"
        })

      _wizard ->
        assign(socket, draft: Map.put(draft, :battle_region, region), step: :neutral)
    end
  end

  defp record_step(:neutral, socket, point, draft) do
    case socket.assigns.mode do
      :neutral_only ->
        save_mark(socket, %{neutral_point: point}, %{
          ok: "Ponto neutro re-marcado em #{inspect(point)}.",
          error: "não deu pra salvar o ponto neutro"
        })

      _wizard ->
        assign(socket, draft: Map.put(draft, :neutral_point, point), step: :player)
    end
  end

  defp record_step(:player, socket, point, draft) do
    case socket.assigns.mode do
      :player_only ->
        save_player_point(socket, point)

      _ ->
        assign(socket, draft: Map.put(draft, :player_point, point), step: :skill_a)
    end
  end

  # Re-marking the bar also drops the READY colours: they belong to the region
  # they were read from, and `finish/2` learns them again from the new one.
  defp record_step(:skill_a, socket, point, draft) do
    draft =
      draft
      |> Map.drop([:skill_bar_region, :skill_slot_refs])
      |> Map.put(:skill_a, point)

    assign(socket, draft: draft, step: :skill_b)
  end

  defp record_step(:skill_b, socket, point, draft) do
    region = region_from(draft.skill_a, point)
    count = draft.skill_bar_count

    case socket.assigns.mode do
      :full ->
        assign(socket,
          draft:
            draft
            |> Map.put(:skill_bar_region, region)
            |> Map.put(:skill_bar_count, count),
          step: :hp_a,
          skillbar_msg: "Barra configurada com #{count} skills."
        )

      :skillbar_only ->
        persist_skill_settings(count)
        save_skill_bar(socket, region, count)

      _ ->
        socket
    end
  end

  defp record_step(:hp_a, socket, point, draft) do
    draft = draft |> Map.delete(:pokemon_hp_region) |> Map.put(:hp_a, point)
    assign(socket, draft: draft, step: :hp_b)
  end

  defp record_step(:hp_b, socket, point, draft) do
    assign(socket,
      draft: Map.put(draft, :pokemon_hp_region, region_from(draft.hp_a, point)),
      step: :photo
    )
  end

  defp record_step(:photo, socket, point, draft) do
    case socket.assigns.mode do
      :hp_only ->
        save_mark(
          socket,
          %{pokemon_hp_region: draft.pokemon_hp_region, pokemon_photo_point: point},
          %{
            ok: "Vida + foto do Pokémon re-marcadas — confira a leitura no painel.",
            error: "não deu pra salvar a vida"
          }
        )

      _wizard ->
        finish(socket, Map.put(draft, :pokemon_photo_point, point))
    end
  end

  defp record_step(:mini_game_a, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :mini_game_a, point), step: :mini_game_b)
  end

  defp record_step(:mini_game_b, socket, point, draft) do
    save_mini_game_region(socket, region_from(draft.mini_game_a, point))
  end

  defp record_step(:minimap_a, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :minimap_a, point), step: :minimap_b)
  end

  defp record_step(:minimap_b, socket, point, draft) do
    assign(socket,
      draft: Map.put(draft, :minimap_region, region_from(draft.minimap_a, point)),
      step: :minimap_cross
    )
  end

  # The cross was the last click: the coordinate band is not clicked at all —
  # the game only draws "(x, y, z)" under a hovering mouse, so the wizard's
  # screenshot never contained it and Lucas marked the band from memory (the
  # real 2026-08-10 band: 13pt tall, clipped, misplaced). The band is FOUND by
  # reading instead; hand-marking stays as the fallback.
  defp record_step(:minimap_cross, socket, point, draft) do
    send(self(), :coord_search)

    assign(socket,
      draft: Map.put(draft, :minimap_player_point, point),
      step: :minimap_coord_search,
      coord_search: :searching
    )
  end

  defp record_step(:minimap_coord_a, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :minimap_coord_a, point), step: :minimap_coord_b)
  end

  defp record_step(:minimap_coord_b, socket, point, draft) do
    save_minimap(socket, region_from(draft.minimap_coord_a, point))
  end

  defp record_step(:pokemon_spot, socket, point, _draft) do
    save_pokemon_spot(socket, point)
  end

  defp record_step(:escape_point, socket, point, _draft), do: save_escape_point(socket, point)

  defp record_step(_unknown_step, socket, _point, _draft), do: socket

  defp region_from({x1, y1}, {x2, y2}), do: {min(x1, x2), min(y1, y2), abs(x2 - x1), abs(y2 - y1)}

  # A pokémon was named: the bar is ITS bar, and the screen calibration is left
  # alone. The refs go with it — they are the skill icons, so they belong to the
  # creature carrying them.
  defp save_skill_bar(%{assigns: %{bar_target: name}} = socket, region, count)
       when is_binary(name) do
    refs = skill_slot_refs(socket.assigns.screen, region, count)
    Pokex.Pokedex.Team.set_bar(name, %{region: region, count: count, refs: refs})

    assign(socket,
      draft: %{},
      step: nil,
      screen: nil,
      skillbar_msg: "Barra de #{name} salva com #{count} skills — só dele."
    )
  end

  defp save_skill_bar(socket, region, count) do
    case Calibration.load() do
      {:ok, calib} ->
        refs = skill_slot_refs(socket.assigns.screen, region, count)

        Calibration.save(%{
          on_this_screen(calib, socket)
          | skill_bar_region: region,
            skill_bar_count: count,
            skill_slot_refs: refs
        })

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg: "Barra salva com #{count} skills. Confira a leitura no painel."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar a barra: #{inspect(reason)}"
        )
    end
  end

  defp save_minimap(socket, coord_region) do
    draft = socket.assigns.draft

    case Calibration.load() do
      {:ok, calib} ->
        calib = %{
          on_this_screen(calib, socket)
          | minimap_region: draft.minimap_region,
            minimap_player_point: draft.minimap_player_point,
            minimap_coord_region: coord_region
        }

        Calibration.save(calib)

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg:
            "Posição & minimapa salvos — " <> minimap_read_verdict(socket, calib, coord_region)
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar o minimapa: #{inspect(reason)}"
        )
    end
  end

  # The on-the-spot verdict: reads the coordinate FROM THE SHOT just marked,
  # with the new regions — "read (x, y, z)" proves the calibration before the
  # bot needs it; "couldn't read" says fix the strip now, not on a blind hunt.
  defp minimap_read_verdict(socket, calib, coord_region) do
    with path when is_binary(path) <- socket.assigns.screen && socket.assigns.screen.path,
         {:ok, frame} <- Vision.Frame.from_png_file(path) do
      # The SAME union the feed captures (PR #180): a band poking outside the
      # map region must not pass here and clip on the hunt — or vice versa.
      {ux, uy, uw, uh} = Calibration.minimap_capture_region(calib)
      {cx, cy, cw, ch} = coord_region
      scale = socket.assigns.scale || 1.0
      to_px = fn v -> round(v * scale) end

      panel =
        Vision.Frame.crop(frame, {to_px.(ux), to_px.(uy), to_px.(uw), to_px.(uh)})

      read =
        Vision.Glyphs.read_coord(
          panel,
          {to_px.(cx - ux), to_px.(cy - uy), to_px.(cw), to_px.(ch)},
          ink: Settings.get(:minimap_coord_ink)
        )

      case read do
        {x, y, z} -> "li a coordenada da foto: (#{x}, #{y}, #{z}) ✓"
        nil -> "mas NÃO li a coordenada da foto — ajuste a faixa do texto e marque de novo."
      end
    else
      _no_frame -> "não deu pra reler a foto pra testar — valide no /world."
    end
  end

  defp save_mini_game_region(socket, region) do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.save(%{on_this_screen(calib, socket) | mini_game_region: region})

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg:
            "Faixa do minigame salva em #{inspect(region)} — o bot agora observa SÓ ela. " <>
              "Reinicie o worker (Parar/Iniciar) pra valer."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar a faixa do minigame: #{inspect(reason)}"
        )
    end
  end

  # A quick-fix card: title + one-line hint, so each button says WHAT it re-marks
  # (the old bare-label row made "Só o minigame" vs "Só o personagem" a guessing game).
  attr :event, :string, required: true
  attr :icon, :string, required: true
  attr :title, :string, required: true
  attr :hint, :string, required: true

  defp quick_fix(assigns) do
    ~H"""
    <button
      phx-click={@event}
      class="flex items-start gap-2.5 rounded-lg border border-pk-line bg-pk-sunken px-3 py-2.5 text-left transition hover:border-pk-ok/50 hover:bg-pk-raised"
    >
      <.icon name={@icon} class="mt-0.5 size-4 shrink-0 text-pk-ok" />
      <span class="min-w-0">
        <span class="block text-pk-body font-semibold text-pk-text">{@title}</span>
        <span class="mt-0.5 block text-pk-meta leading-snug text-pk-text-2">{@hint}</span>
      </span>
    </button>
    """
  end

  # The tracker's answer in one line — including the score it FAILED with, which
  # is the difference between "the aim is off" and "nothing like it on screen".
  defp locate_text(%{found?: true} = seen) do
    {x, y} = seen.point
    "achei #{seen.name} em #{x}, #{y} · #{round(seen.score * 100)}% · #{seen.windows} janelas"
  end

  defp locate_text(%{reason: :no_library}), do: "nenhum pokémon ensinado ainda"
  defp locate_text(%{reason: :not_calibrated}), do: "falta calibração"
  defp locate_text(%{reason: :no_frame}), do: "não consegui capturar a tela"

  defp locate_text(%{score: score}) when is_float(score) do
    precisa = round(Settings.get(:pokemon_track_min_similarity) * 100)
    "não achei — o melhor quadro deu #{round(score * 100)}% (precisa de #{precisa}%)"
  end

  defp locate_text(_unknown), do: "não achei"

  defp crop_sample(%Frame{} = crop),
    do: %{"w" => crop.width, "h" => crop.height, "rgba" => Base.encode64(crop.rgba)}

  defp painted?(%{hue: 0, saturation: 100, brightness: 100}), do: false
  defp painted?(_paint), do: true

  # O placar do acervo: quantos corpos levam bola e quantos estão vetados. Com
  # 25 linhas na tela, "quantos eu desliguei?" não pode ser uma contagem no olho.
  defp corpse_aimed(list), do: Enum.count(list, &CorpseLibrary.enabled?/1)
  defp corpse_vetoed(list), do: length(list) - corpse_aimed(list)

  defp taught_word(1), do: "1 corpo ensinado"
  defp taught_word(n), do: "#{n} corpos ensinados"

  defp vetoed_word(1), do: "1 vetado (nunca leva bola)"
  defp vetoed_word(n), do: "#{n} vetados (nunca levam bola)"

  defp painted_crop(crop, paint),
    do:
      Recolor.apply(crop,
        hue: paint.hue,
        saturation: paint.saturation,
        brightness: paint.brightness
      )

  # The preview is the crop as it will be SAVED — the same repaint the library
  # will store, rendered through the same thumbnail encoder the taught samples
  # use, so what he tunes is exactly what aims.
  defp paint_preview(crop, paint) do
    painted = painted_crop(crop, paint)

    CorpseLibrary.thumb(%{
      "w" => painted.width,
      "h" => painted.height,
      "rgba" => Base.encode64(painted.rgba)
    })
  end

  defp paint_value(params, field, lo, hi) do
    default = Map.fetch!(@neutral_paint, String.to_existing_atom(field))

    case Integer.parse(Map.get(params, field, "")) do
      {value, _rest} -> value |> Kernel.max(lo) |> Kernel.min(hi)
      :error -> default
    end
  end

  defp profile_thumb_file(slug), do: "calib_profile_#{slug}.png"

  defp load_profiles do
    Enum.map(Calibration.list_profiles(), fn profile ->
      thumb = Path.join(Home.captures_dir(), profile_thumb_file(profile.name))

      thumb_src =
        if File.exists?(thumb),
          do:
            "/captures/#{profile_thumb_file(profile.name)}?t=#{System.unique_integer([:positive])}"

      Map.put(profile, :thumb_src, thumb_src)
    end)
  end

  # The saved calibration's screen vs the one in front of him RIGHT NOW. Every
  # coordinate in the file belongs to the screen it was marked on; served on
  # another one, the bot looks broken rather than uncalibrated.
  defp screen_check(display_points \\ display_points()) do
    case Calibration.load() do
      {:ok, calib} -> Calibration.screen_check(calib, display_points)
      _uncalibrated -> :unknown
    end
  end

  # A screenshot in hand IS the measurement — better than asking the backend
  # again, and free. Used right after every grab so the verdict he reads matches
  # the picture he is looking at.
  defp shot_points(%{w: w, h: h}), do: {:ok, {w, h}}
  defp shot_points(_no_shot), do: :unknown

  # The square the corpse search sweeps — derived from the character and the
  # tile radius, never marked by hand. Drawn so he can SEE the automatic area
  # (he had to draw it on a screenshot to ask what it was) and size it with
  # corpse_scan_radius_tiles.
  # Asking must never be able to take the page down: a wedged backend is
  # "I don't know", not a crash. And never QUEUE on the broker either — this
  # runs at mount, where a page opened mid-scan would sit there for seconds.
  # Every path that took a screenshot passes `shot_points/1` instead, which is
  # the authoritative reading straight from the photo.
  defp display_points do
    Capture.display_points_cached()
  catch
    _kind, _reason -> :unknown
  end

  # A quick fix marks a point on the screenshot it JUST took, so the geometry of
  # that screenshot is the geometry the whole file must claim. Merging a fresh
  # point into a calibration that still carries the OLD screen (he calibrated on
  # a 3440-wide ultrawide, then fixed one point on the 1512-wide notebook) leaves
  # a file whose points live in one space and whose screen_w announces another —
  # and every consumer that scales by it reads the wrong place.
  # EVERY mark is saved through here. The `on_this_screen` stamp is the reason:
  # a step that merged straight into the loaded calibration saved the point with
  # the PREVIOUS monitor's dimensions — marking one point on the notebook wrote
  # a file claiming to be the 3440 ultrawide (2026-08-03) — and since the
  # per-monitor snapshots it also decides WHICH monitor the calibration is filed
  # under. One door means the next step someone adds cannot forget it.
  #
  # `struct!/2` over `Map.merge/2` on purpose: an unknown field raises here
  # instead of quietly becoming a map key nothing ever reads.
  defp save_mark(socket, changes, copy) do
    case Calibration.load() do
      {:ok, calib} ->
        calib |> on_this_screen(socket) |> struct!(changes) |> Calibration.save()

        socket
        |> clear_marking()
        |> assign(calibrated?: true, error: nil, skillbar_msg: copy.ok)

      {:error, reason} ->
        socket
        |> clear_marking()
        |> assign(error: "#{copy.error}: #{inspect(reason)}")
    end
  end

  defp clear_marking(socket), do: assign(socket, draft: %{}, step: nil, screen: nil)

  defp save_player_point(socket, point) do
    save_mark(socket, %{player_point: point}, %{
      ok: "Personagem marcado em #{inspect(point)} — o minigame procura a barra a partir daí.",
      error: "não deu pra salvar o personagem"
    })
  end

  defp save_pokemon_spot(socket, point) do
    save_mark(socket, %{pokemon_spot_point: point}, %{
      ok:
        "Posição do Pokémon salva em #{inspect(point)} — ligue \"Reposicionar após lutas\" " <>
          "no painel pra usar.",
      error: "não deu pra salvar a posição do Pokémon"
    })
  end

  defp save_escape_point(socket, point) do
    save_mark(socket, %{escape_point: point}, %{
      ok:
        "Tile de fuga salvo em #{inspect(point)} — configure a DIREÇÃO dos passos no " <>
          "painel (Fuga de emergência) e use \"Testar fuga\" pra validar.",
      error: "não deu pra salvar a escada de fuga"
    })
  end

  defp on_this_screen(calib, %{assigns: %{screen: %{scale: scale, w: w, h: h}}}),
    do: %{calib | scale: scale, screen_w: w, screen_h: h}

  defp on_this_screen(calib, _no_screen), do: calib

  defp persist_skill_settings(count) do
    Settings.put(:skill_bar_count, count)
    Settings.put(:skill_keys, SkillBar.fit_order(Settings.get(:skill_keys), count))
  end

  # Only a pokémon he actually HAS: a name typed into the URL that is not on the
  # team would write a bar nothing will ever read.
  defp bar_target(name) when is_binary(name) do
    if Enum.any?(Pokex.Pokedex.Team.members(), &(&1.name == name)), do: name, else: nil
  end

  defp bar_target(_absent), do: nil

  # Name and, when it has one, the size of its own bar: "Vespiquen ✓ 8" says in
  # three characters what a second page would have to be opened to learn.
  defp team_names do
    Enum.map(Pokex.Pokedex.Team.members(), fn member ->
      {member.name, get_in(member, [Access.key(:bar), Access.key(:count)])}
    end)
  end

  defp configured_skill_count(nil), do: {configured_skill_count(), true}

  defp configured_skill_count(name) do
    case Pokex.Pokedex.Team.bar(name) do
      %{count: count} when count in 1..10 -> {count, true}
      _no_bar_of_its_own -> {configured_skill_count(), false}
    end
  end

  defp configured_skill_count do
    case Calibration.load() do
      {:ok, %Calibration{skill_bar_count: count}} when count in 1..10 -> count
      _ -> Settings.get(:skill_bar_count) |> clamp_skill_count()
    end
  end

  defp parse_skill_count(raw, fallback) do
    case Integer.parse(to_string(raw)) do
      {count, ""} -> clamp_skill_count(count)
      _ -> fallback
    end
  end

  defp clamp_skill_count(count) when is_integer(count), do: min(max(count, 1), 10)
  defp clamp_skill_count(_count), do: 6

  defp skill_count_form(count), do: to_form(%{"count" => to_string(count)}, as: :skill_bar)

  # Any step where the user clicks the screenshot to mark a point/region (the numbered wizard
  # steps AND the standalone quick-fix flows). A step missing here renders the
  # instruction with NO screenshot below it — a black page (2026-07-20 bug: the
  # mini_game quick-fix steps were absent).
  defp step_pill_class(n, step) do
    case CalibrationSteps.index(step) do
      nil -> "border border-pk-line text-pk-text-3"
      current when n < current -> "border border-pk-ok-line bg-pk-ok-dim text-pk-ok"
      current when n == current -> "bg-pk-ok text-pk-bg"
      _ -> "border border-pk-line text-pk-text-3"
    end
  end

  # Preview bands over the draft battle_region as the user marks it, so drift is
  # visible before saving. Empty until the battle corners are placed.
  defp draft_bands(%{battle_region: region}, scale, row_height, rows),
    do:
      Calibration.battle_row_bands(
        region,
        scale,
        row_height,
        rows,
        Settings.get(:battle_first_row_y)
      )

  defp draft_bands(_draft, _scale, _row_height, _rows), do: []

  defp draft_player(%{player_point: point}) when is_tuple(point), do: point
  defp draft_player(_draft), do: nil

  # Steps that draw the screenshot: the ones that take a click, plus the
  # confirmation, which shows the same picture and takes none.
  defp shows_photo?(step), do: CalibrationSteps.marking?(step) or step == :confirm_saved

  @impl true
  def render(assigns) do
    # module attributes are not available inside ~H as @foo (that reads assigns)
    assigns = assign(assigns, total_steps: CalibrationSteps.total(), zoom_factor: @zoom_factor)

    ~H"""
    <Layouts.app
      flash={@flash}
      current_page={:calibration}
      max_width="max-w-[900px] 2xl:max-w-[1600px]"
      {Layouts.header(assigns)}
    >
      <div class="space-y-3">
        <%!-- Título e regra na MESMA linha: a tela é larga, e um parágrafo de
              aviso ocupando uma faixa inteira só empurra o trabalho pra baixo. --%>
        <header class="flex flex-wrap items-baseline gap-x-4 gap-y-1">
          <h1 class="text-base font-bold text-pk-text">Calibração</h1>
          <p class="min-w-0 flex-1 text-pk-body text-pk-text-2">
            Deixe a janela do jogo visível e SEM o navegador na frente. Depois de calibrar,
            não mova nem redimensione a janela do jogo (senão recalibre).
          </p>
        </header>

        <p
          :if={@error}
          class="rounded-lg border border-pk-danger-line bg-pk-danger-dim px-3 py-2 text-pk-body text-pk-danger"
        >
          {@error}
        </p>
        <%!-- Whose bar this is. The page has accepted `?bar=<name>` and saved to
              that pokémon since the feature landed, and said NOTHING about it —
              so a calibration aimed at one creature looked exactly like the
              shared one, and there was no way to tell which you were doing. --%>
        <div
          :if={@bar_target}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-pk-accent-line bg-pk-accent-dim px-3 py-2"
        >
          <p class="min-w-0 flex-1 text-pk-body text-pk-text">
            🎛 Calibrando a barra de <strong>{@bar_target}</strong>
            — {@skill_count} skills. O que
            salvar aqui fica <strong>só dele</strong>; a barra da tela e a dos outros não mudam.
            <span :if={not @skill_count_own?} class="block font-semibold text-pk-warn">
              esse número é sobra de outra calibração, não é de {@bar_target} — confira antes de capturar
            </span>
          </p>
          <%!-- The action lives IN the banner. Reading who you are aiming at and
                then having to hunt for the button is the same gap that hid this
                whole feature: the big green button below starts the ten-step
                calibration, and for one pokémon's bar this is the two-click one. --%>
          <button
            phx-click="calibrate_skillbar"
            class="shrink-0 cursor-pointer rounded-lg border border-pk-accent-line bg-pk-accent-dim px-3 py-1.5 text-pk-body font-semibold text-pk-text hover:brightness-125"
          >
            Marcar a barra dele (2 cliques)
          </button>
          <.link
            navigate={~p"/calibration"}
            class="shrink-0 text-pk-body text-pk-text-2 hover:underline"
          >
            calibrar a da tela
          </.link>
        </div>

        <div
          :if={is_nil(@bar_target) and @team_names != []}
          class="flex flex-wrap items-center gap-x-3 gap-y-1 rounded-lg border border-pk-line bg-pk-surface-2 px-3 py-2"
        >
          <span class="text-pk-body text-pk-text-2">
            🎛 Calibrar a barra de um pokémon do time (fica guardada só dele, e volta sozinha
            quando você trocar):
          </span>
          <.link
            :for={{name, count} <- @team_names}
            navigate={~p"/calibration?#{[bar: name]}"}
            class="rounded border border-pk-line px-2 py-0.5 text-pk-body text-pk-text hover:bg-pk-surface-3"
          >
            {name}<span :if={count} class="ml-1 text-pk-text-2">✓ {count}</span>
          </.link>
        </div>

        <p
          :if={@skillbar_msg}
          class="rounded-lg border border-pk-ok-line bg-pk-ok-dim px-3 py-2 text-pk-body text-pk-ok"
        >
          {@skillbar_msg}
        </p>

        <CalibrationReview.panel
          :if={@review}
          review={@review}
          tool={@tool}
          row_height={@row_height}
          max_rows={@max_rows}
          battle_msg={@battle_msg}
          scale_ratio={@scale_ratio}
          scale_proposals={@scale_proposals}
          scale_msg={@scale_msg}
          adjust_target={@adjust_target}
          adjust_step={@adjust_step}
          coord_probe={@coord_probe}
        />

        <%!-- Duas colunas na tela larga: à ESQUERDA o ato de calibrar (capturar,
              corrigir um ponto, perfis), à DIREITA o que ele já ensinou. Eram
              duas pilhas de 3.200px numa coluna de 768 no meio de um monitor de
              3.440 — o acervo de 25 corpos ficava a três rolagens do botão que
              tira a foto. --%>
        <div
          :if={is_nil(@screen) and is_nil(@review)}
          class="grid items-start gap-3 2xl:grid-cols-2"
        >
          <div class="space-y-3">
            <section class="space-y-4 rounded-xl border border-pk-line bg-pk-surface p-4">
              <div class="flex items-start gap-3">
                <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-pk-ok-dim text-pk-ok">
                  <.icon name="hero-camera" class="size-5" />
                </span>
                <div class="min-w-0">
                  <h2 class="text-pk-title font-bold text-pk-text">Calibração completa</h2>
                  <p class="mt-0.5 max-w-prose text-pk-body leading-relaxed text-pk-text-2">
                    Se esta tela já foi calibrada, eu começo desenhando as marcas salvas em
                    cima da foto nova — você só confirma, e nada se move. Se não, são os
                    9 passos guiados: Battle, ponto neutro, personagem, skills e vida. Pode
                    deixar o jogo em TELA CHEIA — ao capturar, ele vem pra frente por ~1s,
                    tira a foto e volta pra cá sozinho.
                  </p>
                </div>
              </div>
              <div class="flex flex-wrap items-end justify-center gap-3">
                <.form
                  for={@skill_count_form}
                  id="skill-count-form"
                  phx-change="set_skill_count"
                  class="w-40 text-left"
                >
                  <.input
                    field={@skill_count_form[:count]}
                    type="number"
                    min="1"
                    max="10"
                    label="Quantidade de skills"
                  />
                  <p :if={@bar_target && not @skill_count_own?} class="mt-1 text-pk-meta text-pk-warn">
                    sobra de outra calibração — confira antes de capturar
                  </p>
                </.form>
                <button class="btn btn-primary" phx-click="capture_screen">
                  <.icon name="hero-camera" class="size-4" />
                  {if @calibrated?, do: "Capturar tela e conferir", else: "Capturar tela e começar"}
                </button>
              </div>
            </section>

            <section
              :if={@calibrated?}
              class="space-y-3 rounded-xl border border-pk-line bg-pk-surface p-4"
            >
              <div class="flex items-center justify-between gap-2">
                <div>
                  <h2 class="text-pk-title font-bold text-pk-text">Correções rápidas</h2>
                  <p class="mt-0.5 text-pk-body text-pk-text-2">
                    Ajusta UM ponto da calibração atual, sem refazer o resto.
                  </p>
                </div>
                <button class="btn btn-ghost btn-xs shrink-0" phx-click="review">
                  <.icon name="hero-eye" class="size-3.5" /> Revisar áreas salvas
                </button>
              </div>
              <div class="grid gap-2 sm:grid-cols-2">
                <.quick_fix
                  event="calibrate_skillbar"
                  icon="hero-bolt"
                  title="Só as skills"
                  hint="re-marca a barra de skills e a referência de 'pronta' de cada ícone"
                />
                <.quick_fix
                  event="calibrate_player"
                  icon="hero-user"
                  title="Só o personagem"
                  hint="a âncora do mundo: o quadrado onde procura corpos e o reposicionamento"
                />
                <.quick_fix
                  event="calibrate_minimap"
                  icon="hero-map"
                  title="Posição & minimapa"
                  hint="o minimapa e a cruz do personagem (3 cliques) — a faixa da coordenada eu acho sozinho, lendo a foto"
                />
                <.quick_fix
                  event="calibrate_pokemon_spot"
                  icon="hero-map-pin"
                  title="Posição do Pokémon"
                  hint="o tile estratégico pro reposicionamento depois das lutas"
                />
                <.quick_fix
                  event="calibrate_escape_point"
                  icon="hero-arrow-up-on-square"
                  title="Escada de fuga"
                  hint="o tile do caminho COLADO na escada — a fuga anda até ele e entra de seta"
                />
                <.quick_fix
                  event="calibrate_battle"
                  icon="hero-list-bullet"
                  title="Só a Battle"
                  hint="a janela da lista de batalha (2 cliques) — onde o combate lê inimigos e lock"
                />
                <.quick_fix
                  event="calibrate_neutral"
                  icon="hero-cursor-arrow-rays"
                  title="Só o ponto neutro"
                  hint="onde o mouse descansa sem clicar em nada (1 clique)"
                />
                <.quick_fix
                  event="calibrate_hp"
                  icon="hero-heart"
                  title="Só a vida"
                  hint="a barra de vida do Pokémon (2 cliques) + a foto dele (1 clique)"
                />
              </div>

              <%!-- Pesca à parte: nada disso existe numa caçada, e por isso
                    saiu do fluxo numerado. --%>
              <div class="space-y-2 border-t border-pk-line pt-3">
                <p class="text-pk-meta font-semibold uppercase tracking-wide text-pk-text-3">
                  Só pra pesca
                </p>
                <div class="grid gap-2 sm:grid-cols-2">
                  <.quick_fix
                    event="calibrate_water"
                    icon="hero-beaker"
                    title="Ponto da água"
                    hint="onde o bot arremessa (1 clique) — o brilho da isca acompanha sozinho"
                  />
                  <.quick_fix
                    event="calibrate_mini_game"
                    icon="hero-flag"
                    title="Faixa do minigame"
                    hint="onde a barra do minigame aparece (2 cliques) — a cápsula só existe pescando"
                  />
                </div>
              </div>
            </section>

            <section
              :if={@calibrated? or @profiles != []}
              class="space-y-3 rounded-xl border border-pk-line bg-pk-surface p-4"
            >
              <div>
                <h2 class="text-pk-title font-bold text-pk-text">Perfis de calibração</h2>
                <p class="mt-0.5 text-pk-body text-pk-text-2">
                  Um por layout de monitor — trocar de setup vira um clique em "Usar" (+
                  Parar/Iniciar nos bots).
                </p>
              </div>
              <form
                :if={@calibrated?}
                id="profile-form"
                phx-submit="save_profile"
                class="flex max-w-xs gap-2"
              >
                <input
                  name="profile_name"
                  placeholder="ex: 2-monitores"
                  class="input input-bordered input-sm min-w-0 flex-1"
                />
                <button class="btn btn-primary btn-sm">Salvar atual</button>
              </form>
              <ul :if={@profiles != []} class="space-y-1.5">
                <li
                  :for={profile <- @profiles}
                  class="flex items-center gap-3 rounded-lg border border-pk-line bg-pk-sunken px-3 py-2 text-left"
                >
                  <img
                    :if={profile.thumb_src}
                    src={profile.thumb_src}
                    class="h-10 w-16 shrink-0 rounded border border-pk-line-strong object-cover"
                  />
                  <div class="min-w-0 flex-1">
                    <p class="truncate text-pk-body font-semibold text-pk-text">{profile.name}</p>
                    <p class="pk-num font-mono text-pk-meta text-pk-text-3">
                      {profile.screen_w}×{profile.screen_h} pt · escala {profile.scale}
                    </p>
                  </div>
                  <button
                    class="btn btn-success btn-xs"
                    phx-click="apply_profile"
                    phx-value-name={profile.name}
                  >
                    Usar
                  </button>
                  <button
                    class="btn btn-ghost btn-xs text-error"
                    phx-click="delete_profile"
                    phx-value-name={profile.name}
                    data-confirm={"Excluir o perfil \"#{profile.name}\"?"}
                  >
                    <.icon name="hero-trash" class="size-3.5" />
                  </button>
                </li>
              </ul>
            </section>
          </div>

          <div class="space-y-3">
            <%!-- His OWN pokémon, so the bot can SEE where it is instead of
                  assuming the middle click landed. --%>
            <section
              id="pokemon-teach"
              class="space-y-3 rounded-xl border border-pk-line bg-pk-surface p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <h2 class="text-pk-title font-bold text-pk-text">Meu pokémon (rastreio)</h2>
                  <p class="mt-0.5 max-w-prose text-pk-body leading-relaxed text-pk-text-2">
                    Fotografe e clique <b class="text-pk-text">em cima do seu pokémon</b>, de
                    vários ângulos — ele vira, e cada direção é uma paleta diferente. Com isso o
                    bot para de <i>supor</i>
                    que o clique do meio pegou: ele <b class="text-pk-text">olha</b>
                    se o pokémon está onde deveria antes de varrer os corpos.
                    Acervo separado do de corpos de propósito — pokémon no acervo de corpos
                    é coisa em que o bot joga Pokébola.
                  </p>
                </div>
                <div class="flex shrink-0 flex-wrap gap-2">
                  <button id="pokemon-shot-btn" class="btn btn-sm" phx-click="pokemon_shot">
                    📸 Fotografar o quadro
                  </button>
                  <button
                    id="pokemon-locate-btn"
                    class="btn btn-outline btn-sm"
                    phx-click="pokemon_locate"
                    disabled={@pokemon_list == []}
                  >
                    🔎 Onde ele está agora?
                  </button>
                </div>
              </div>

              <p
                :if={@pokemon_found}
                id="pokemon-found"
                class={[
                  "rounded-lg border px-3 py-2 font-mono text-pk-meta",
                  @pokemon_found.found? && "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                  !@pokemon_found.found? && "border-pk-warn-line bg-pk-warn-dim text-pk-warn"
                ]}
              >
                {locate_text(@pokemon_found)}
              </p>

              <p
                :if={@pokemon_msg}
                class={[
                  "rounded-lg border px-3 py-2 text-pk-body",
                  elem(@pokemon_msg, 0) == :ok && "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                  elem(@pokemon_msg, 0) == :error &&
                    "border-pk-danger-line bg-pk-danger-dim text-pk-danger"
                ]}
              >
                {elem(@pokemon_msg, 1)}
              </p>

              <img
                :if={@pokemon_shot}
                id="pokemon-shot"
                src={"/captures/pokemon_teach.png?v=#{@pokemon_shot.v}"}
                phx-hook="ImgClick"
                data-click-event="pokemon_click"
                alt="quadro para ensinar o pokémon"
                class="w-full cursor-crosshair rounded-lg border border-pk-line"
              />

              <div
                :if={@pokemon_crop}
                class="flex flex-wrap items-end gap-3 rounded-lg border border-pk-line bg-pk-sunken p-3"
              >
                <img
                  src={PokemonSprites.thumb(crop_sample(@pokemon_crop.frame))}
                  alt="recorte do pokémon"
                  class="w-24 rounded border border-pk-line [image-rendering:pixelated]"
                />
                <form
                  id="pokemon-name-form"
                  phx-submit="pokemon_save"
                  class="flex flex-wrap items-end gap-2"
                >
                  <label class="flex flex-col gap-1 text-pk-meta text-pk-text-2">
                    nome do pokémon
                    <input
                      name="name"
                      value={Pokex.Pokedex.Team.active()}
                      list="pokemon-team-names"
                      autocomplete="off"
                      class="input input-bordered input-sm w-56"
                    />
                  </label>
                  <datalist id="pokemon-team-names">
                    <option :for={row <- Pokex.Pokedex.Team.members()} value={row.name} />
                  </datalist>
                  <button class="btn btn-primary btn-sm">Salvar ângulo</button>
                </form>
              </div>

              <CalibrationLibrary.taught_pokemon
                :if={@pokemon_list != []}
                entries={@pokemon_list}
              />
            </section>

            <section
              id="corpse-teach"
              class="space-y-3 rounded-xl border border-pk-line bg-pk-surface p-4"
            >
              <div class="flex flex-wrap items-start justify-between gap-3">
                <div class="min-w-0">
                  <h2 class="text-pk-title font-bold text-pk-text">Corpos mapeados (captura)</h2>
                  <p class="mt-0.5 max-w-prose text-pk-body leading-relaxed text-pk-text-2">
                    O acervo É a mira da captura: mate um monstro, deixe o corpo no chão,
                    fotografe e clique EM CIMA do corpo. A foto mostra
                    <b class="text-pk-text">exatamente o
                    quadro que a busca varre</b>
                    — o quadradão ao redor do seu personagem, não uma área marcada à mão. Só
                    corpo conhecido recebe Pokébola; o log da bola diz QUAL pokémon foi
                    reconhecido, e o switch de cada corpo tira ele da mira sem apagar as fotos.
                  </p>
                </div>
                <button id="corpse-shot-btn" class="btn btn-sm shrink-0" phx-click="corpse_shot">
                  📸 Fotografar o quadro da busca
                </button>
              </div>

              <p :if={@corpse_shot[:region]} class="pk-num font-mono text-pk-meta text-pk-text-3">
                quadro varrido: {elem(@corpse_shot.region, 2)}×{elem(@corpse_shot.region, 3)} pt em {elem(
                  @corpse_shot.region,
                  0
                )},{elem(@corpse_shot.region, 1)}
              </p>

              <p
                :if={@corpse_msg}
                class={[
                  "rounded-lg border px-3 py-2 text-pk-body",
                  elem(@corpse_msg, 0) == :ok && "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                  elem(@corpse_msg, 0) == :error &&
                    "border-pk-danger-line bg-pk-danger-dim text-pk-danger"
                ]}
              >
                {elem(@corpse_msg, 1)}
              </p>

              <img
                :if={@corpse_shot}
                id="corpse-shot"
                src={"/captures/corpse_teach.png?v=#{@corpse_shot.v}"}
                phx-hook="ImgClick"
                data-click-event="corpse_click"
                alt="quadro da busca de corpos"
                class="w-full cursor-crosshair rounded-lg border border-pk-line"
              />

              <div
                :if={@corpse_crop}
                class="space-y-3 rounded-lg border border-pk-line bg-pk-sunken p-3"
              >
                <form
                  id="corpse-paint-form"
                  phx-change="corpse_paint"
                  class="flex flex-wrap items-end gap-4"
                >
                  <figure class="flex flex-col items-center gap-1">
                    <img
                      src={paint_preview(@corpse_crop.frame, @corpse_paint)}
                      alt="prévia do corpo como ele vai ser salvo"
                      class="size-20 rounded border border-pk-line [image-rendering:pixelated]"
                    />
                    <figcaption class="pk-num font-mono text-pk-meta text-pk-text-3">
                      {@corpse_crop.frame.width}×{@corpse_crop.frame.height} @ {elem(
                        @corpse_crop.at,
                        0
                      )},{elem(@corpse_crop.at, 1)}
                    </figcaption>
                  </figure>

                  <label
                    :for={
                      {field, label, min, max, value} <- [
                        {"hue", "matiz", -180, 180, @corpse_paint.hue},
                        {"saturation", "saturação", 0, 200, @corpse_paint.saturation},
                        {"brightness", "brilho", 50, 150, @corpse_paint.brightness}
                      ]
                    }
                    class="flex flex-col gap-1"
                  >
                    <span class="pk-num font-mono text-pk-meta text-pk-text-2">
                      {label} {value}
                    </span>
                    <input
                      type="range"
                      name={field}
                      min={min}
                      max={max}
                      value={value}
                      class="range range-xs w-40"
                    />
                  </label>

                  <button
                    :if={painted?(@corpse_paint)}
                    type="button"
                    phx-click="corpse_paint_reset"
                    class="btn btn-ghost btn-xs"
                  >
                    voltar ao original
                  </button>
                </form>

                <p :if={painted?(@corpse_paint)} class="text-pk-meta text-pk-text-2">
                  🎨 este corpo vai entrar como <strong class="text-pk-text">pintado à mão</strong>
                  — serve de mira enquanto o de verdade não aparece. Quando matares um,
                  fotografa e ensina de novo.
                </p>

                <form
                  id="corpse-name-form"
                  phx-submit="corpse_save"
                  class="flex flex-wrap items-center gap-2"
                >
                  <input
                    name="name"
                    placeholder="nome do Pokémon"
                    autocomplete="off"
                    class="input input-sm input-bordered"
                  />
                  <button class="btn btn-sm btn-success">Salvar corpo</button>
                </form>
              </div>

              <p
                :if={@corpse_list != []}
                class="pk-num flex flex-wrap gap-x-3 font-mono text-pk-meta text-pk-text-3"
              >
                <span>{taught_word(length(@corpse_list))}</span>
                <span class="text-pk-ok">{corpse_aimed(@corpse_list)} na mira</span>
                <span :if={corpse_vetoed(@corpse_list) > 0}>
                  {vetoed_word(corpse_vetoed(@corpse_list))}
                </span>
              </p>

              <CalibrationLibrary.taught_corpses
                :if={@corpse_list != []}
                entries={@corpse_list}
                counts={@corpse_counts}
              />
            </section>
          </div>
        </div>

        <div :if={@screen} class="space-y-3">
          <ol
            :if={@mode == :full and CalibrationSteps.index(@step)}
            class="flex flex-wrap items-center gap-1.5"
          >
            <li
              :for={n <- 1..@total_steps}
              class={[
                "flex size-6 items-center justify-center rounded-full text-pk-meta font-bold",
                step_pill_class(n, @step)
              ]}
            >
              {n}
            </li>
          </ol>

          <div
            :if={@step}
            class="rounded-lg border border-pk-info-line bg-pk-info-dim px-3 py-2 text-pk-body font-medium text-pk-text"
          >
            <span :if={@mode == :full and CalibrationSteps.index(@step)} class="font-bold">
              Passo {CalibrationSteps.index(@step)}/{@total_steps} —
            </span>
            {CalibrationSteps.instruction(@step)}
            <button
              :if={keepable(@step, @draft)}
              type="button"
              id="keep-step"
              phx-click="keep_step"
              class="ml-1 rounded-lg border border-pk-ok/60 bg-pk-ok/15 px-2.5 py-1 align-middle text-pk-meta font-bold text-pk-ok hover:bg-pk-ok/25"
            >
              Manter <span class="pk-num font-mono">{inspect(keepable(@step, @draft))}</span>
            </button>
            <.form
              :if={@step in [:skill_a, :skill_b]}
              for={@skill_count_form}
              id="skill-count-form-marking"
              phx-change="set_skill_count"
              class="ml-1 inline-flex items-center gap-1 align-middle font-bold"
            >
              Quantidade:
              <input
                type="number"
                name="skill_bar[count]"
                value={@skill_count}
                min="1"
                max="10"
                class="input input-bordered input-xs w-14 text-center font-bold"
              />
            </.form>
          </div>

          <div
            :if={@step == :confirm_saved}
            id="confirm-saved"
            class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-ok/60 bg-pk-ok/10 px-3 py-2 text-pk-body"
          >
            <span class="flex-1 text-pk-text-2">
              Calibração salva desta tela
              <b class="pk-num font-mono text-pk-text">{@screen.w}×{@screen.h}</b>
              — confirmando, nenhum ponto se move.
            </span>
            <button
              type="button"
              id="confirm-saved-use"
              phx-click="confirm_saved"
              class="rounded-lg border border-pk-ok/60 bg-pk-ok/20 px-2.5 py-1 text-pk-meta font-bold text-pk-ok hover:bg-pk-ok/30"
            >
              Confirmar e usar
            </button>
            <button
              type="button"
              id="confirm-saved-walk"
              phx-click="walk_saved"
              class="rounded-lg border border-pk-line-strong px-2.5 py-1 text-pk-meta font-semibold text-pk-text-2 hover:bg-pk-raised hover:text-white"
            >
              Conferir marca por marca
            </button>
          </div>

          <div
            :if={@step == :mini_game_a and @suggested_mini_game}
            id="mini-game-suggestion"
            class="flex flex-wrap items-center gap-2 rounded-lg border border-pk-line bg-pk-raised px-3 py-2 text-pk-body"
          >
            <span class="flex-1 text-pk-text-2">
              A faixa <b class="text-pk-text">verde</b>
              desenhada na foto é a sugestão pro seu personagem
              <span class="pk-num font-mono text-pk-meta">{inspect(@suggested_mini_game)}</span>
              — se ela já está em cima da barra, aceite e pronto.
            </span>
            <button
              type="button"
              id="use-suggested-mini-game"
              phx-click="use_suggested_mini_game"
              class="rounded-lg border border-pk-ok/60 bg-pk-ok/15 px-2.5 py-1 text-pk-meta font-bold text-pk-ok hover:bg-pk-ok/25"
            >
              Usar esta faixa
            </button>
          </div>

          <p :if={CalibrationSteps.marking?(@step)} class="text-pk-body">
            <span :if={is_nil(@zoom_at)} class="text-pk-text-2">
              Dê um clique APROXIMADO no alvo — a imagem amplia pra você mirar com precisão.
            </span>
            <span :if={@zoom_at} class="font-semibold text-pk-ok">
              Ampliado {@zoom_factor}× — agora clique PRECISO no alvo.
            </span>
            <button
              :if={@zoom_at}
              type="button"
              class="btn btn-ghost btn-xs ml-1 align-middle"
              phx-click="cancel_zoom"
            >
              <.icon name="hero-arrow-uturn-left" class="size-3" /> refazer o clique
            </button>
          </p>

          <.legend :if={shows_photo?(@step)} />

          <div
            :if={shows_photo?(@step)}
            class="overflow-hidden rounded-lg border border-pk-line-strong"
          >
            <div class="relative" style={CalibrationZoom.style(@zoom_at, @screen, @zoom_factor)}>
              <%!-- The confirmation step SHOWS the marks and takes no clicks:
                    a stray click there would re-mark what he came to keep. --%>
              <img
                id="calibration-screen"
                phx-hook={CalibrationSteps.marking?(@step) && "ImgClick"}
                src={@screen.src}
                class={["w-full", CalibrationSteps.marking?(@step) && "cursor-crosshair"]}
              />
              <.overlays
                screen={@screen}
                quiet={@zoom_at != nil}
                water_point={@draft[:water_point]}
                glow_region={@draft[:glow_region]}
                battle_region={@draft[:battle_region]}
                skill_bar_region={@draft[:skill_bar_region]}
                skill_bar_count={@draft[:skill_bar_count] || 0}
                neutral_point={@draft[:neutral_point]}
                player_point={draft_player(@draft)}
                pokemon_hp_region={@draft[:pokemon_hp_region]}
                pokemon_photo_point={@draft[:pokemon_photo_point]}
                mini_game_region={
                  @draft[:mini_game_region] || marking_suggestion(@step, @suggested_mini_game)
                }
                minimap_region={@draft[:minimap_region]}
                minimap_coord_region={@draft[:minimap_coord_region]}
                minimap_player_point={@draft[:minimap_player_point]}
                bands={draft_bands(@draft, @scale, @row_height, @max_rows)}
              />
            </div>
          </div>

          <div :if={@step == :minimap_coord_search} id="coord-band-search" class="space-y-2">
            <p :if={@coord_search == :searching} class="text-pk-body text-pk-text-2">
              Clicando no ponto neutro pra dar foco ao jogo, dando um passinho (seta e volta)
              pra fazer o texto aparecer, e fotografando…
            </p>

            <div :if={match?({:found, _, _, _}, @coord_search)} class="space-y-2">
              <p id="coord-band-found" class="text-pk-body font-semibold text-pk-ok">
                li: {found_pos_text(@coord_search)} ✓ — é onde você está? Então salva.
              </p>
              <div
                class="rounded border border-pk-ok-line bg-pk-sunken"
                style={crop_style(found_band(@coord_search), @screen)}
              />
              <div class="flex flex-wrap gap-2">
                <button class="btn btn-primary btn-sm" phx-click="save_found_band">
                  Salvar assim
                </button>
                <button class="btn btn-ghost btn-sm" phx-click="coord_search_again">
                  Buscar de novo
                </button>
                <button class="btn btn-ghost btn-sm" phx-click="coord_manual">
                  Marcar na mão
                </button>
              </div>
            </div>

            <%!-- The band is PROVEN and the number is not readable yet. Both
                  facts on screen at once, because the fix needs both: the crop
                  shows what the camera saw, the line shows where the reading
                  broke, and the answer is a number only he can read off his
                  own minimap. --%>
            <div :if={match?({:unread, _, _, _, _}, @coord_search)} class="space-y-2">
              <p id="coord-band-unread" class="text-pk-body font-semibold text-pk-warn">
                Achei a faixa da coordenada, mas tem caractere que eu nunca vi: li <b class="font-mono">{unread_text(@coord_search)}</b>. Escreva o número que está
                no seu minimapa — cada <b>?</b> é uma letra que eu aprendo agora, e depois disso
                eu leio essa faixa sem chutar.
              </p>
              <div
                class="rounded border border-pk-warn-line bg-pk-sunken"
                style={crop_style(unread_band(@coord_search), @screen)}
              />
              <form id="coord-teach-form" phx-submit="coord_teach_line" class="flex flex-wrap gap-2">
                <input
                  name="coord"
                  value={unread_text(@coord_search)}
                  autocomplete="off"
                  class="input input-bordered input-sm w-56 font-mono"
                />
                <button class="btn btn-primary btn-sm">Aprender e ler</button>
                <button class="btn btn-ghost btn-sm" type="button" phx-click="coord_search_again">
                  Buscar de novo
                </button>
                <button class="btn btn-ghost btn-sm" type="button" phx-click="coord_manual">
                  Marcar na mão
                </button>
              </form>
              <p :if={@coord_teach_msg} id="coord-teach-msg" class="text-pk-meta text-pk-warn">
                {@coord_teach_msg}
              </p>
            </div>

            <div :if={@coord_search == :hovered} class="space-y-2">
              <p id="coord-band-hovered" class="text-pk-body font-semibold text-pk-warn">
                O relógio apareceu no minimapa — isso só acontece com o MOUSE em cima dele, e
                nesse estado a coordenada é desenhada em outro lugar. Tire o mouse de cima do
                minimapa e busque de novo: eu preciso calibrar o estado do dia a dia.
              </p>
              <button class="btn btn-primary btn-sm" phx-click="coord_search_again">
                Buscar de novo
              </button>
            </div>

            <div :if={not_found?(@coord_search)} class="space-y-2">
              <p id="coord-band-not-found" class="text-pk-body font-semibold text-pk-warn">
                Não achei o texto da coordenada. O jogo só o desenha quando a posição MUDA —
                deixe o personagem livre pra andar um tile (e o minimapa sem nada por cima) e
                busque de novo, ou marque a faixa na mão.
                <span :if={is_nil(focus_point())} class="block font-normal">
                  Dica: o <b>ponto neutro</b>
                  não está calibrado — é nele que eu clico pra dar o foco ao jogo, senão as
                  setas vão parar no navegador.
                </span>
              </p>
              <p
                :if={match?({:failed, _}, @coord_search)}
                class="font-mono text-pk-meta text-pk-text-3"
              >
                {elem(@coord_search, 1)}
              </p>
              <%!-- The evidence, not just the verdict: this is the minimap as
                    the last photo saw it. Text in the crop means the READER
                    missed it; no text means the photo caught the widget with
                    no label up. Two opposite fixes that used to look
                    identical from here. --%>
              <div :if={@screen && @draft[:minimap_region]} class="space-y-1">
                <p class="text-pk-body text-pk-text-2">Foi isto que eu fotografei do minimapa:</p>
                <div
                  id="coord-search-evidence"
                  class="rounded border border-pk-warn-line bg-pk-sunken"
                  style={crop_style(@draft[:minimap_region], @screen)}
                />
              </div>
              <div class="flex flex-wrap gap-2">
                <button class="btn btn-primary btn-sm" phx-click="coord_search_again">
                  Buscar de novo
                </button>
                <button class="btn btn-ghost btn-sm" phx-click="coord_manual">
                  Marcar na mão
                </button>
              </div>
            </div>
          </div>

          <%!-- The X-ray: raw numbers of the last clicks, computed point beside
                them. ✔ = recorded into the draft; ◌ = the rough zoom click. --%>
          <div
            :if={@click_trace != [] and CalibrationSteps.marking?(@step)}
            id="click-trace"
            class="pk-num space-y-0.5 font-mono text-pk-meta text-pk-text-2"
          >
            <p
              :for={{t, i} <- Enum.with_index(@click_trace)}
              class={i == 0 && "font-bold opacity-100"}
            >
              {if t.recorded?, do: "✔", else: "◌"} clique ({elem(t.raw, 0)}, {elem(t.raw, 1)}) em caixa {elem(
                t.box,
                0
              )}×{elem(t.box, 1)}{if t.zoomed?, do: " (zoom)"} → ponto da tela
              <b>({elem(t.point, 0)}, {elem(t.point, 1)})</b>
            </p>
          </div>
        </div>

        <div
          :if={@done}
          class="space-y-3 rounded-xl border border-pk-ok-line bg-pk-ok-dim p-6 text-center"
        >
          <.icon name="hero-check-circle" class="mx-auto size-8 text-pk-ok" />
          <p class="font-semibold">Calibração salva!</p>
          <p class="text-pk-body text-pk-text-2">
            Brilho, {@draft[:skill_bar_count] || Settings.get(:skill_bar_count)} skills e a vida do
            Pokémon gravados. Confira a vida no painel e ligue o combo de sobrevivência.
          </p>
          <div class="flex flex-wrap justify-center gap-2">
            <button class="btn btn-ghost btn-sm" phx-click="review">
              <.icon name="hero-eye" class="size-4" /> Revisar áreas
            </button>
            <.link navigate={~p"/"} class="btn btn-success btn-sm">Ir ao painel →</.link>
          </div>
        </div>
      </div>
    </Layouts.app>
    """
  end
end
