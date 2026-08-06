defmodule PokexWeb.CalibrationLive do
  use PokexWeb, :live_view

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.Catcher.Worker
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Home
  alias Pokex.Screenshot
  alias Pokex.Settings
  alias Pokex.Vision
  alias Pokex.Vision.Frame

  import PokexWeb.CalibrationOverlay, only: [overlays: 1, legend: 1, screen_warning: 1]

  @glow_half 32

  @total_steps 10
  # Click-to-zoom magnification: a rough click magnifies the screenshot around it (via CSS
  # transform, which the ImgClick hook's getBoundingClientRect already accounts for), then a
  # precise second click is transcribed back to screen coordinates. Helps a lot on a small screen.
  @zoom_factor 3.5

  @instructions %{
    water: "Clique no PONTO DA ÁGUA onde o bot deve arremessar.",
    battle_a: "Clique no canto SUPERIOR-ESQUERDO da área de criaturas da janela Battle.",
    battle_b:
      "Agora o canto INFERIOR-DIREITO da mesma área (incluindo a coluna do ícone de pokébola).",
    neutral: "Clique num PONTO NEUTRO seguro (sugestão: o tile do seu próprio personagem).",
    player:
      "Clique bem no CENTRO do seu PERSONAGEM — é nele que o bot ancora a barra do minigame de pesca. Fique parado onde vai pescar.",
    skill_a:
      "Canto SUPERIOR-ESQUERDO da barra de skills (bem no início do slot 1). IMPORTANTE: " <>
        "deixe TODAS as skills PRONTAS (sem cooldown) — a foto de cada ícone vira a " <>
        "referência de 'pronta' pro leitor.",
    skill_b:
      "Canto INFERIOR-DIREITO da barra, depois da última skill deste Pokémon. Não inclua outros botões.",
    hp_a:
      "Canto SUPERIOR-ESQUERDO da barra de VIDA do Pokémon principal — bem RENTE à barra, sem pegar o fundo azul acima nem os ícones abaixo.",
    hp_b: "Canto INFERIOR-DIREITO da MESMA barra de vida (colado na barra, só ela).",
    photo: "Centro da FOTO do Pokémon principal (onde o mouse fica pro Shift+Q do revive).",
    mini_game_a:
      "Canto SUPERIOR-ESQUERDO da FAIXA onde a barra do minigame aparece quando você pesca " <>
        "deste lugar (deixe uma folga de 1-2 tiles pra cada lado da barra).",
    mini_game_b:
      "Canto INFERIOR-DIREITO da mesma faixa — cubra a altura TODA da barra, sem pegar os " <>
        "painéis escuros da lateral (Battle/bolsa).",
    pokemon_spot:
      "Clique no TILE onde o seu Pokémon deve FICAR (a posição estratégica de ataque). " <>
        "Depois das lutas, o suporte manda ele de volta pra cá com um clique do meio.",
    escape_point:
      "Clique num TILE LIVRE DO CAMINHO colado na escada (NÃO na escada: clicar nela tenta " <>
        "USÁ-LA, e usar só funciona do lado). A fuga anda até esse tile e aí dá os passos " <>
        "de seta (direção configurada no painel) pra ENTRAR na escada.",
    minimap_a: "Canto SUPERIOR-ESQUERDO do MINIMAPA (só o mapa em si, sem a moldura).",
    minimap_b: "Canto INFERIOR-DIREITO do mesmo minimapa.",
    minimap_cross:
      "Clique bem no CENTRO da CRUZ do personagem no minimapa — ela é fixa (o mapa " <>
        "desliza por baixo), então este ponto vira a origem de todo passo do cavebot.",
    minimap_coord_a:
      "Canto SUPERIOR-ESQUERDO da faixa da COORDENADA — o texto \"(x, y, z)\" no topo do " <>
        "minimapa. Deixe folga pra direita: a faixa precisa caber a coordenada mais " <>
        "LONGA (ex.: \"(2782, 30571, 5)\").",
    minimap_coord_b: "Canto INFERIOR-DIREITO da mesma faixa, fechando o texto inteiro."
  }

  @impl true
  def mount(_params, _session, socket) do
    skill_count = configured_skill_count()

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
       draft: %{},
       done: false,
       calibrated?: Calibration.exists?(),
       screen_check: screen_check(),
       profiles: load_profiles(),
       review: nil,
       error: nil,
       skillbar_msg: nil,
       zoom_at: nil,
       skill_count: skill_count,
       skill_count_form: skill_count_form(skill_count),
       row_height: Settings.get(:battle_row_height),
       max_rows: Settings.get(:battle_max_rows),
       corpse_shot: nil,
       corpse_crop: nil,
       corpse_msg: nil,
       corpse_list: CorpseLibrary.list(),
       corpse_counts: %{}
     )}
  end

  @impl true
  def handle_event("capture_screen", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           screen_check: screen_check(shot_points(screen)),
           step: :water,
           mode: :full,
           draft: %{skill_bar_count: socket.assigns.skill_count},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Standalone correction for an existing calibration. The normal 8-step wizard
  # already includes these two clicks.
  def handle_event("calibrate_skillbar", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :skill_a,
           mode: :skillbar_only,
           draft: %{skill_bar_count: socket.assigns.skill_count},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Standalone correction: re-mark only the character (the mini-game bar anchor)
  # on an existing calibration, without redoing the whole wizard.
  def handle_event("calibrate_player", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :player,
           mode: :player_only,
           draft: %{},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Position & minimap (2026-07-30): minimap (2 clicks) + player cross (1) +
  # coordinate strip (2), saved as MANUAL calibration — the hand wins, the
  # automatic layout becomes the fallback. On save, the coordinate is read
  # FROM THE SAME SHOT with the freshly marked regions: feedback arrives
  # before any field run.
  def handle_event("calibrate_minimap", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :minimap_a,
           mode: :minimap_only,
           draft: %{},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Standalone correction: mark only the strip where the mini-game bar shows up
  # (2 corners) on an existing calibration. From then on the mini-game worker
  # watches THAT region instead of hunting the bar inside the arena.
  def handle_event("calibrate_mini_game", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :mini_game_a,
           mode: :mini_game_only,
           draft: %{},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
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
      {:ok, calib} ->
        {:noreply,
         assign(socket,
           calibrated?: true,
           error: nil,
           skillbar_msg:
             "Perfil \"#{name}\" aplicado (#{calib.screen_w}×#{calib.screen_h}). " <>
               "Reinicie os bots (Parar/Iniciar) pra valer."
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
  def handle_event("calibrate_pokemon_spot", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :pokemon_spot,
           mode: :pokemon_spot_only,
           draft: %{},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  # Standalone correction: mark only the escape STAIRCASE tile the
  # emergency-escape protocol click-walks to.
  def handle_event("calibrate_escape_point", _params, socket) do
    case grab_screen() do
      {:ok, screen} ->
        {:noreply,
         assign(socket,
           scale: screen.scale,
           screen: screen,
           step: :escape_point,
           mode: :escape_point_only,
           draft: %{},
           done: false,
           review: nil,
           error: nil,
           skillbar_msg: nil,
           zoom_at: nil
         )}

      error ->
        {:noreply, assign(socket, error: "captura falhou: #{inspect(error)}")}
    end
  end

  def handle_event("review", _params, socket) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, screen} <- grab_screen() do
      {:noreply,
       assign(socket,
         review: Map.put(screen, :calib, calib),
         screen_check: screen_check(shot_points(screen)),
         error: nil
       )}
    else
      error -> {:noreply, assign(socket, error: "não deu pra revisar: #{inspect(error)}")}
    end
  end

  def handle_event("close_review", _params, socket) do
    {:noreply, assign(socket, review: nil)}
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
       skill_count_form: skill_count_form(count),
       draft: Map.put(socket.assigns.draft, :skill_bar_count, count)
     )}
  end

  def handle_event(
        "img_click",
        %{"x" => x, "y" => y, "cw" => cw, "ch" => ch, "nw" => nw, "nh" => nh},
        socket
      ) do
    scale = socket.assigns.scale
    point = {round(x * nw / cw / scale), round(y * nh / ch / scale)}

    socket =
      if socket.assigns.zoom_at do
        # A precise click on the magnified view → record it, then drop the zoom for the next point.
        socket |> record_point(point) |> assign(zoom_at: nil)
      else
        # A rough first click → magnify around it so the real target is easy to hit on a small screen.
        assign(socket, zoom_at: point)
      end

    {:noreply, socket}
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

        {:noreply, assign(socket, corpse_crop: %{frame: crop, at: {cx, cy}}, corpse_msg: nil)}
    end
  end

  def handle_event("corpse_save", %{"name" => name}, socket) do
    case socket.assigns.corpse_crop do
      nil ->
        {:noreply, socket}

      %{frame: crop} ->
        case CorpseLibrary.add(name, crop) do
          {:ok, n} ->
            {:noreply,
             assign(socket,
               corpse_crop: nil,
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
  defp finish(socket, draft) do
    calib = %Calibration{
      scale: socket.assigns.scale,
      screen_w: socket.assigns.screen.w,
      screen_h: socket.assigns.screen.h,
      water_point: draft.water_point,
      glow_region: draft.glow_region,
      battle_region: draft.battle_region,
      neutral_point: draft.neutral_point,
      player_point: draft[:player_point],
      skill_bar_region: draft.skill_bar_region,
      skill_bar_count: draft.skill_bar_count,
      skill_slot_refs:
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
        front_app(app)
        assign(socket, return_app: nil)
    end
  end

  # On a SINGLE monitor the panel browser covers the game — a naive screenshot calibrates the
  # browser, so Lucas had to shrink the game window to calibrate at all. Instead: bring the game
  # to the FRONT, wait for it to render, run `fun` (the capture), and hand focus back to whatever
  # was frontmost (the browser) so he keeps clicking the wizard. The game can stay fullscreen.
  # Env-gated off in tests (osascript); fail-open — a failed front-switch still captures.
  defp with_game_front(fun) do
    if Application.get_env(:pokex, :calibration_front_game, true) and
         Settings.get(:ensure_game_focus) do
      previous = frontmost_app()
      front_app(Settings.get(:game_app_name))
      Process.sleep(Settings.get(:calibration_front_delay_ms))

      try do
        fun.()
      after
        if previous, do: front_app(previous)
      end
    else
      fun.()
    end
  end

  defp frontmost_app do
    case System.cmd(
           "osascript",
           [
             "-e",
             ~s(tell application "System Events" to name of first application process whose frontmost is true)
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp front_app(nil), do: :ok

  defp front_app(app_name) do
    System.cmd(
      "osascript",
      [
        "-e",
        ~s(tell application "System Events" to set frontmost of application process "#{app_name}" to true)
      ],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _ -> :ok
  end

  # The screenshot the whole wizard marks on, taken while the GAME is fronted
  # (see with_game_front/1). Measuring it is `Pokex.Screenshot`'s job — the same
  # recipe /diagnostics uses, so both pages and the bot share one coordinate space.
  defp grab_screen do
    with {:ok, shot} <- with_game_front(fn -> Screenshot.take("calibration_screen.png") end) do
      {:ok,
       Map.put(
         shot,
         :src,
         "/captures/#{Path.basename(shot.path)}?t=#{System.unique_integer([:positive])}"
       )}
    end
  end

  # Per-slot READY references, cropped from the SAME screenshot the user just marked the bar
  # on (no extra capture, exact same instant): each slot's non-white colour signature becomes
  # its "this is what ready looks like" baseline for SkillBar. The wizard copy tells the user
  # to calibrate with every skill ready — but SkillBar.slot_refs drops any slot that LOOKS
  # like a countdown anyway (nil ref → threshold fallback), so one charging skill at
  # calibration time can't poison its own slot into reading inverted forever. nil (refs are
  # optional) when the crop fails — the reader then falls back to the threshold rules.
  defp skill_slot_refs(%{path: path, scale: scale}, {x, y, w, h}, count) do
    with {:ok, frame} <- Frame.from_png_file(path),
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

  # One clause per step: the old single `case` over twenty steps scored 26 on
  # cyclomatic complexity and hid which step did what.
  defp record_point(socket, point),
    do: record_step(socket.assigns.step, socket, point, socket.assigns.draft)

  defp record_step(:water, socket, point, draft) do
    {x, y} = point

    draft =
      Map.merge(draft, %{
        water_point: point,
        glow_region: {x - @glow_half, y - @glow_half, @glow_half * 2, @glow_half * 2}
      })

    assign(socket, draft: draft, step: :battle_a)
  end

  defp record_step(:battle_a, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :battle_a, point), step: :battle_b)
  end

  defp record_step(:battle_b, socket, point, draft) do
    assign(socket,
      draft: Map.put(draft, :battle_region, region_from(draft.battle_a, point)),
      step: :neutral
    )
  end

  defp record_step(:neutral, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :neutral_point, point), step: :player)
  end

  defp record_step(:player, socket, point, draft) do
    case socket.assigns.mode do
      :player_only ->
        save_player_point(socket, point)

      _ ->
        assign(socket, draft: Map.put(draft, :player_point, point), step: :skill_a)
    end
  end

  defp record_step(:skill_a, socket, point, draft) do
    assign(socket, draft: Map.put(draft, :skill_a, point), step: :skill_b)
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
    assign(socket, draft: Map.put(draft, :hp_a, point), step: :hp_b)
  end

  defp record_step(:hp_b, socket, point, draft) do
    assign(socket,
      draft: Map.put(draft, :pokemon_hp_region, region_from(draft.hp_a, point)),
      step: :photo
    )
  end

  defp record_step(:photo, socket, point, draft) do
    finish(socket, Map.put(draft, :pokemon_photo_point, point))
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

  defp record_step(:minimap_cross, socket, point, draft) do
    assign(socket,
      draft: Map.put(draft, :minimap_player_point, point),
      step: :minimap_coord_a
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

  # CSS transform that magnifies the screenshot around the rough click (a screen point). The
  # transform-origin keeps that point in place while everything around it scales up; the ImgClick
  # hook reads the transformed getBoundingClientRect, so the precise click maps back correctly.
  defp zoom_style(nil, _screen, _factor), do: nil

  # Center-and-clamp pan: scale from the top-left and translate so the clicked point lands
  # mid-container, clamped to keep the scaled image flush with the edges (no blank gutters).
  # The old transform-origin trick PINNED the clicked point at its original container
  # position, leaving only (1-f)/factor of visible margin beyond it — for a target near a
  # screen edge that margin vanishes: the skill bar lives at the BOTTOM of the screen and
  # its bottom-right corner (the skill_b click) fell OUTSIDE the zoom window (measured:
  # corner at 92.85% of the height vs a window ending at 91.9%), which read as "can't
  # click the last skill" (Lucas, 2026-07-20).
  defp zoom_style({x, y}, %{w: w, h: h}, factor) when w > 0 and h > 0 do
    "transform: translate(#{translate_pct(x / w, factor)}%, #{translate_pct(y / h, factor)}%) " <>
      "scale(#{factor}); transform-origin: 0 0"
  end

  defp zoom_style(_zoom_at, _screen, _factor), do: nil

  # The translate (in % of the container) that centers fraction `f` at scale `factor`,
  # clamped into [1 - factor, 0] so the window never runs past the image.
  defp translate_pct(f, factor) do
    Float.round(100 * min(max(0.5 - f * factor, 1.0 - factor), 0.0), 2)
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
      {mx, my, mw, mh} = calib.minimap_region
      {cx, cy, cw, ch} = coord_region
      scale = socket.assigns.scale || 1.0
      to_px = fn v -> round(v * scale) end

      panel =
        Vision.Frame.crop(frame, {to_px.(mx), to_px.(my), to_px.(mw), to_px.(mh)})

      read =
        Vision.Glyphs.read_coord(
          panel,
          {to_px.(cx - mx), to_px.(cy - my), to_px.(cw), to_px.(ch)},
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
      class="flex items-start gap-2.5 rounded-xl border border-base-content/10 bg-base-100 px-3 py-2.5 text-left transition hover:border-primary/40 hover:bg-base-100/60"
    >
      <.icon name={@icon} class="mt-0.5 size-4 shrink-0 text-primary" />
      <span class="min-w-0">
        <span class="block text-xs font-semibold">{@title}</span>
        <span class="mt-0.5 block text-[11px] leading-snug opacity-60">{@hint}</span>
      </span>
    </button>
    """
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

  defp save_pokemon_spot(socket, point) do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.save(%{on_this_screen(calib, socket) | pokemon_spot_point: point})

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg:
            "Posição do Pokémon salva em #{inspect(point)} — ligue \"Reposicionar após lutas\" " <>
              "no painel pra usar."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar a posição do Pokémon: #{inspect(reason)}"
        )
    end
  end

  defp save_escape_point(socket, point) do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.save(%{on_this_screen(calib, socket) | escape_point: point})

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg:
            "Tile de fuga salvo em #{inspect(point)} — configure a DIREÇÃO dos passos no " <>
              "painel (Fuga de emergência) e use \"Testar fuga\" pra validar."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar a escada de fuga: #{inspect(reason)}"
        )
    end
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
  defp scan_region(calib) do
    case SpotScan.region(calib) do
      {:ok, region} -> region
      _uncalibrated -> nil
    end
  end

  # Asking must never be able to take the page down: a wedged backend is
  # "I don't know", not a crash.
  defp display_points do
    Capture.display_points()
  catch
    _kind, _reason -> :unknown
  end

  # A quick fix marks a point on the screenshot it JUST took, so the geometry of
  # that screenshot is the geometry the whole file must claim. Merging a fresh
  # point into a calibration that still carries the OLD screen (he calibrated on
  # a 3440-wide ultrawide, then fixed one point on the 1512-wide notebook) leaves
  # a file whose points live in one space and whose screen_w announces another —
  # and every consumer that scales by it reads the wrong place.
  defp on_this_screen(calib, %{assigns: %{screen: %{scale: scale, w: w, h: h}}}),
    do: %{calib | scale: scale, screen_w: w, screen_h: h}

  defp on_this_screen(calib, _no_screen), do: calib

  defp save_player_point(socket, point) do
    case Calibration.load() do
      {:ok, calib} ->
        Calibration.save(%{on_this_screen(calib, socket) | player_point: point})

        assign(socket,
          draft: %{},
          step: nil,
          screen: nil,
          calibrated?: true,
          skillbar_msg:
            "Personagem marcado em #{inspect(point)} — o minigame procura a barra a partir daí."
        )

      {:error, reason} ->
        assign(socket,
          step: nil,
          screen: nil,
          error: "não deu pra salvar o personagem: #{inspect(reason)}"
        )
    end
  end

  defp persist_skill_settings(count) do
    Settings.put(:skill_bar_count, count)
    Settings.put(:skill_keys, SkillBar.fit_order(Settings.get(:skill_keys), count))
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
  defp marking_step?(step),
    do:
      step in [
        :water,
        :battle_a,
        :battle_b,
        :neutral,
        :player,
        :skill_a,
        :skill_b,
        :hp_a,
        :hp_b,
        :photo,
        :mini_game_a,
        :mini_game_b,
        :minimap_a,
        :minimap_b,
        :minimap_cross,
        :minimap_coord_a,
        :minimap_coord_b,
        :pokemon_spot,
        :escape_point
      ]

  defp step_index(:water), do: 1
  defp step_index(:battle_a), do: 2
  defp step_index(:battle_b), do: 3
  defp step_index(:neutral), do: 4
  defp step_index(:player), do: 5
  defp step_index(:skill_a), do: 6
  defp step_index(:skill_b), do: 7
  defp step_index(:hp_a), do: 8
  defp step_index(:hp_b), do: 9
  defp step_index(:photo), do: 10
  defp step_index(_), do: nil

  defp step_pill_class(n, step) do
    case step_index(step) do
      nil -> "bg-base-300 opacity-50"
      current when n < current -> "bg-success text-success-content"
      current when n == current -> "bg-primary text-primary-content"
      _ -> "bg-base-300 opacity-50"
    end
  end

  # Preview bands over the draft battle_region as the user marks it, so drift is
  # visible before saving. Empty until the battle corners are placed.
  defp draft_bands(%{battle_region: region}, scale, row_height, rows),
    do: Calibration.battle_row_bands(region, scale, row_height, rows)

  defp draft_bands(_draft, _scale, _row_height, _rows), do: []

  defp draft_player(%{player_point: point}) when is_tuple(point), do: point
  defp draft_player(_draft), do: nil

  @impl true
  def render(assigns) do
    # module attributes are not available inside ~H as @foo (that reads
    # assigns), so expose the instruction map as an assign first
    assigns =
      assign(assigns, instr: @instructions, total_steps: @total_steps, zoom_factor: @zoom_factor)

    ~H"""
    <Layouts.app flash={@flash} current_page={:calibration} {Layouts.header(assigns)}>
      <div class="space-y-4">
        <header>
          <h1 class="text-xl font-bold">Calibração</h1>
          <p class="mt-1 text-sm opacity-70">
            Deixe a janela do jogo visível e SEM o navegador na frente. Depois de calibrar,
            não mova nem redimensione a janela do jogo (senão recalibre).
          </p>
        </header>

        <.screen_warning check={@screen_check} />

        <p :if={@error} class="rounded-lg bg-error/15 px-3 py-2 text-sm text-error">{@error}</p>
        <p :if={@skillbar_msg} class="rounded-lg bg-success/15 px-3 py-2 text-sm text-success">
          {@skillbar_msg}
        </p>

        <div
          :if={@review}
          class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-4"
        >
          <div class="flex items-center justify-between">
            <h2 class="text-sm font-semibold">Áreas que o bot está usando</h2>
            <button class="btn btn-ghost btn-xs" phx-click="close_review">Fechar</button>
          </div>
          <.legend />
          <p class="rounded-lg border border-primary/30 bg-primary/10 px-3 py-2 text-xs">
            Duas áreas são <b>automáticas</b>, tiradas do seu personagem: a caixa do <b>mini game</b>
            (3 tiles pra cada lado, de 3 acima a 7 abaixo dele) e a <b>busca de corpos</b>
            (raio em tiles, no ⚙️). Marcar a faixa do mini game à mão
            continua valendo mais — deixa a busca ainda mais barata e certeira.
          </p>
          <%!-- The box is cut into numbered CELLS and cell i IS hotkey i. One
                cell off and every cooldown read is the neighbour's — which
                silently shuts the "só pescar quando dá pra matar" gate. Check
                the numbers against the icons; if they are off, move by whole
                cells instead of redoing the wizard. --%>
          <div
            :if={@review.calib.skill_bar_region && @review.calib.skill_bar_count}
            id="skill-bar-nudge"
            class="flex flex-wrap items-center gap-2 rounded-lg border border-secondary/40 bg-secondary/10 px-3 py-2 text-xs"
          >
            <span class="flex-1">
              Os números <b>1…{@review.calib.skill_bar_count}</b>
              na barra têm que cair em cima das skills certas — é célula por célula que o bot lê o
              cooldown.
            </span>
            <button class="btn btn-xs" phx-click="nudge_skill_bar" phx-value-cells="-1">
              ◀ uma casa
            </button>
            <button class="btn btn-xs" phx-click="nudge_skill_bar" phx-value-cells="1">
              uma casa ▶
            </button>
          </div>
          <PokexWeb.CalibrationOverlay.read_crops screen={@review} calib={@review.calib} />
          <div class="relative overflow-hidden rounded-lg border border-base-content/20">
            <img src={@review.src} class="w-full" />
            <.overlays
              screen={@review}
              water_point={@review.calib.water_point}
              glow_region={@review.calib.glow_region}
              battle_region={@review.calib.battle_region}
              skill_bar_region={@review.calib.skill_bar_region}
              skill_bar_count={@review.calib.skill_bar_count || 0}
              neutral_point={@review.calib.neutral_point}
              player_point={Calibration.player_point(@review.calib)}
              pokemon_hp_region={@review.calib.pokemon_hp_region}
              pokemon_photo_point={@review.calib.pokemon_photo_point}
              mini_game_region={Calibration.mini_game_region(@review.calib)}
              minimap_region={Calibration.minimap_region(@review.calib)}
              minimap_coord_region={Calibration.minimap_coord_region(@review.calib)}
              minimap_player_point={Calibration.minimap_player_point(@review.calib)}
              scan_region={scan_region(@review.calib)}
              bands={Calibration.battle_row_bands(@review.calib, @row_height, @max_rows)}
            />
          </div>
        </div>

        <div :if={is_nil(@screen) and is_nil(@review)} class="space-y-4">
          <section class="space-y-4 rounded-2xl border border-base-content/10 bg-base-200 p-5">
            <div class="flex items-start gap-3">
              <span class="grid size-9 shrink-0 place-items-center rounded-lg bg-primary/15 text-primary">
                <.icon name="hero-camera" class="size-5" />
              </span>
              <div class="min-w-0">
                <h2 class="text-sm font-bold">Calibração completa</h2>
                <p class="mt-0.5 text-xs leading-relaxed opacity-60">
                  Os 10 passos guiados: água, Battle, ponto neutro, personagem, skills e
                  vida. Pode deixar o jogo em TELA CHEIA — ao capturar, ele vem pra frente por
                  ~1s, tira a foto e volta pra cá sozinho.
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
              </.form>
              <button class="btn btn-primary" phx-click="capture_screen">
                <.icon name="hero-camera" class="size-4" /> Capturar tela e começar
              </button>
            </div>
          </section>

          <section
            :if={@calibrated?}
            class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-5"
          >
            <div class="flex items-center justify-between gap-2">
              <div>
                <h2 class="text-sm font-bold">Correções rápidas</h2>
                <p class="mt-0.5 text-xs opacity-60">
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
                hint="âncora da detecção do minigame quando não há faixa dedicada"
              />
              <.quick_fix
                event="calibrate_mini_game"
                icon="hero-flag"
                title="Só o minigame"
                hint="a faixa onde a barra do minigame aparece (2 cliques) — detecção direta"
              />
              <.quick_fix
                event="calibrate_minimap"
                icon="hero-map"
                title="Posição & minimapa"
                hint="o minimapa, a cruz do personagem e a faixa da coordenada (5 cliques) — a fundação do cavebot"
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
            </div>
          </section>

          <section
            :if={@calibrated? or @profiles != []}
            class="space-y-3 rounded-2xl border border-base-content/10 bg-base-200 p-5"
          >
            <div>
              <h2 class="text-sm font-bold">Perfis de calibração</h2>
              <p class="mt-0.5 text-xs opacity-60">
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
                class="flex items-center gap-3 rounded-lg border border-base-content/10 bg-base-100 px-3 py-2 text-left"
              >
                <img
                  :if={profile.thumb_src}
                  src={profile.thumb_src}
                  class="h-10 w-16 shrink-0 rounded border border-base-content/20 object-cover"
                />
                <div class="min-w-0 flex-1">
                  <p class="truncate text-sm font-semibold">{profile.name}</p>
                  <p class="font-mono text-[10px] opacity-60">
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

        <div :if={@screen} class="space-y-3">
          <ol :if={@mode == :full and step_index(@step)} class="flex flex-wrap items-center gap-1.5">
            <li
              :for={n <- 1..@total_steps}
              class={[
                "flex size-6 items-center justify-center rounded-full text-xs font-semibold",
                step_pill_class(n, @step)
              ]}
            >
              {n}
            </li>
          </ol>

          <div
            :if={@step}
            class="rounded-lg bg-info/15 px-3 py-2 text-sm font-medium"
          >
            <span :if={@mode == :full} class="font-bold">
              Passo {step_index(@step)}/{@total_steps} —
            </span>
            {@instr[@step]}
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

          <p :if={marking_step?(@step)} class="text-xs">
            <span :if={is_nil(@zoom_at)} class="opacity-70">
              Dê um clique APROXIMADO no alvo — a imagem amplia pra você mirar com precisão.
            </span>
            <span :if={@zoom_at} class="font-semibold text-primary">
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

          <.legend :if={marking_step?(@step)} />

          <div
            :if={marking_step?(@step)}
            class="overflow-hidden rounded-lg border border-base-content/20"
          >
            <div class="relative" style={zoom_style(@zoom_at, @screen, @zoom_factor)}>
              <img
                id="calibration-screen"
                phx-hook="ImgClick"
                src={@screen.src}
                class="w-full cursor-crosshair"
              />
              <.overlays
                screen={@screen}
                water_point={@draft[:water_point]}
                glow_region={@draft[:glow_region]}
                battle_region={@draft[:battle_region]}
                skill_bar_region={@draft[:skill_bar_region]}
                skill_bar_count={@draft[:skill_bar_count] || 0}
                neutral_point={@draft[:neutral_point]}
                player_point={draft_player(@draft)}
                pokemon_hp_region={@draft[:pokemon_hp_region]}
                pokemon_photo_point={@draft[:pokemon_photo_point]}
                bands={draft_bands(@draft, @scale, @row_height, @max_rows)}
              />
            </div>
          </div>
        </div>

        <div
          :if={@done}
          class="space-y-3 rounded-2xl border border-success/40 bg-success/10 p-6 text-center"
        >
          <.icon name="hero-check-circle" class="mx-auto size-8 text-success" />
          <p class="font-semibold">Calibração salva!</p>
          <p class="text-sm opacity-70">
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

        <section
          id="corpse-teach"
          class="space-y-3 rounded-2xl border border-base-300 p-4"
        >
          <div>
            <h2 class="font-semibold">Corpos mapeados (captura)</h2>
            <p class="mt-1 text-sm opacity-70">
              O acervo É a mira da captura: mate um monstro, deixe o corpo no chão,
              fotografe e clique EM CIMA do corpo. A foto mostra <b>exatamente o
              quadro que a busca varre</b> — o quadradão ao redor do seu personagem,
              não uma área marcada à mão. Só corpo conhecido recebe Pokébola; o log da bola
              diz QUAL pokémon foi reconhecido, e o switch de cada corpo tira ele da
              mira sem apagar as fotos.
            </p>
          </div>

          <button id="corpse-shot-btn" class="btn btn-sm" phx-click="corpse_shot">
            📸 Fotografar o quadro da busca
          </button>

          <p :if={@corpse_shot[:region]} class="font-mono text-xs opacity-60">
            quadro varrido: {elem(@corpse_shot.region, 2)}×{elem(@corpse_shot.region, 3)} pt em {elem(
              @corpse_shot.region,
              0
            )},{elem(@corpse_shot.region, 1)}
          </p>

          <p
            :if={@corpse_msg}
            class={[
              "rounded-lg px-3 py-2 text-sm",
              elem(@corpse_msg, 0) == :ok && "bg-success/15 text-success",
              elem(@corpse_msg, 0) == :error && "bg-error/15 text-error"
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
            class="max-w-full cursor-crosshair rounded-lg border border-base-300"
          />

          <form
            :if={@corpse_crop}
            id="corpse-name-form"
            phx-submit="corpse_save"
            class="flex flex-wrap items-center gap-2"
          >
            <span class="font-mono text-sm opacity-70">
              corpo {@corpse_crop.frame.width}×{@corpse_crop.frame.height} @ {elem(
                @corpse_crop.at,
                0
              )},{elem(@corpse_crop.at, 1)} —
            </span>
            <input
              name="name"
              placeholder="nome do Pokémon"
              autocomplete="off"
              class="input input-sm input-bordered"
            />
            <button class="btn btn-sm btn-success">Salvar corpo</button>
          </form>

          <ul :if={@corpse_list != []} id="corpse-list" class="space-y-2">
            <li
              :for={c <- @corpse_list}
              class="flex flex-wrap items-center gap-2 font-mono text-sm"
            >
              <span class="min-w-24">{c["name"]}</span>
              <span
                :for={{sample, idx} <- Enum.with_index(c["samples"])}
                class="group relative inline-block"
              >
                <img
                  src={CorpseLibrary.thumb(sample)}
                  title={"amostra #{idx + 1} · #{sample["added_at"]}"}
                  class="h-10 w-10 rounded border border-base-300 [image-rendering:pixelated]"
                />
                <button
                  class="absolute -right-1 -top-1 hidden size-4 items-center justify-center rounded-full bg-error text-[10px] leading-none text-white group-hover:flex"
                  phx-click="corpse_delete_sample"
                  phx-value-slug={c["slug"]}
                  phx-value-idx={idx}
                  data-confirm="Apagar esta amostra?"
                >
                  ✕
                </button>
              </span>
              <span class="opacity-50">
                {length(c["samples"])}/{CorpseLibrary.max_samples()} chãos
              </span>
              <button
                id={"corpse-toggle-#{c["slug"]}"}
                class={[
                  "btn btn-xs",
                  if(CorpseLibrary.enabled?(c), do: "btn-success", else: "btn-outline opacity-60")
                ]}
                phx-click="corpse_toggle"
                phx-value-slug={c["slug"]}
                title="Participa da mira da captura?"
              >
                {if CorpseLibrary.enabled?(c), do: "● na mira", else: "○ fora"}
              </button>
              <span
                :if={Map.get(@corpse_counts, c["name"], 0) > 0}
                class="rounded bg-primary/15 px-1.5 text-primary"
                title="encontrados nesta sessão"
              >
                {Map.get(@corpse_counts, c["name"])}× nesta sessão
              </span>
              <button
                class="btn btn-ghost btn-xs text-error"
                phx-click="corpse_delete"
                phx-value-slug={c["slug"]}
                data-confirm={"Apagar o corpo de #{c["name"]} inteiro?"}
              >
                apagar tudo
              </button>
            </li>
          </ul>
        </section>
      </div>
    </Layouts.app>
    """
  end
end
