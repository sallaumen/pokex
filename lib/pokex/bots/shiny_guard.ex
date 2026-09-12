defmodule Pokex.Bots.ShinyGuard do
  @moduledoc """
  The watcher for SPECIAL COLOURS: the SHINY trigger in this client, which is the same creature
  he used to call a boss (a recolour, far more health and attack, and the night's trophy). One
  concept, one path.

  The old detector waited for the golden star the previous client painted in the battle list;
  this one paints no star. What separates the special from the common here is the PALETTE: a
  shiny Electrode is green where the common one is red, and the hue survives any pose, even an
  upside-down rollout. So the watcher scans the square around the character (the same one
  `SpotScan` uses) for the PROVEN rules of `ColorRules`, with `ColorMark` doing the reading.
  Points leave this module in SCREEN coordinates.

  NO ACTIONS, by his decision: no alarm, no escape; `shiny_action` and the `escape_fun` died
  with the star. Sighted means RECORDED: a journal line, a trophy in `ShinyLog`,
  `{:shiny_seen, info}` on the "shiny" topic (the Catcher arms the guaranteed ball,
  `shiny_always_ball`), and the panel's live meter. The intelligent reaction is born in phase 2
  of the shiny protocol (docs/shiny/plano-shiny-por-cor.md).

  Confirmation is by CONSECUTIVE SCANS (`special_color_confirm_frames`): a single-frame glimpse
  does not record. The per-rule refractory holds the machine gun. The boxes of the character and
  of the STANDING pokémon are forbidden, because his own Torterra's green is nearly a shiny
  Electrode's; the collection's noise proof is the other half of that defence.

  An always-alive child of the application, like the Guardian, because a shiny matters in manual
  play too. `:shiny_guard_active` disables the global instance in tests; test instances opt in
  with `active: true`.
  """

  use GenServer

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Calibration
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.Settings
  alias Pokex.Vision.{ColorMark, ColorRules, CreatureFence, CreatureMarks, Evidence, Frame}
  alias Pokex.Vision.Sparkle

  # O BRILHO AO LADO DO NOME é uma regra sem cor e sem espécie: o cliente
  # desenha a mesma estrela amarela ao lado do nome de todo shiny (11/09). Ela
  # entra no mesmo caminho das regras de cor — confirmação em duas varreduras,
  # refratário, foto da morte, fato `:special`, faixa — com este crachá.
  @sparkle_rule %{slug: "brilho", name: "Shiny (brilho)", min_px: 1}

  @combat_topic "combat"
  # the panel meter and the Catcher listen here
  @reading_topic "shiny"
  @idle_poll_ms 1_000
  @refractory_ms 60_000
  @reading_throttle_ms 700
  # the window in which a kill right after a sighting IS that shiny dying
  @encounter_window_ms 45_000
  # the photos of the three moments: captures/shiny, this many files, this far apart per tag
  @keep_photos 30
  @photo_gap_ms 3_000
  @photo_dir "shiny"

  # the previous scan's edges, as they are before any scan has run
  @blank_prev %{seen: [], frame: nil, enemies: nil}

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :shiny_guard_active, true)),
      capture: Keyword.get(opts, :capture, &Capture.frame/2),
      # consecutive scans with a blob, per rule: the confirmation
      streaks: %{},
      # last trigger per rule: the refractory
      fired_at: %{},
      last_fired_at: nil,
      last_reading_at: nil,
      journal: Keyword.get(opts, :journal, &Pokex.Engine.Events.record/2),
      # the previous scan, for the edges: which rules were seen, with which
      # blob, on which frame, with how many listed enemies
      prev: @blank_prev,
      # last photo per tag: the flood gate
      photographed_at: %{},
      # rules already announced as measured on another frame: say it once
      warned_stale: MapSet.new(),
      # …e a última recusa anunciada por regra (sem bicho embaixo, ou em cima
      # do pokémon dele), também uma vez por elenco
      refused: %{}
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @doc """
  A janela em que um fato desta guarda ainda vale: três varreduras de folga.

  Uma foto perdida — o jogo sem foco, a captura engasgada — não pode despir a postura no meio
  da luta. A cadência é uma configuração que ele mexe, então quem LÊ o fato tem que ler a
  mesma conta que quem o escreve, e essa conta mora aqui uma vez só.
  """
  @spec fact_max_age_ms() :: pos_integer
  def fact_max_age_ms, do: Settings.get(:special_color_scan_ms) * 3

  @doc "Uma cor especial está na tela agora, no que a última varredura fresca sabe?"
  @spec on_screen?(integer) :: boolean
  def on_screen?(now \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:special, fact_max_age_ms(), now) do
      {:ok, %{especial?: true}} -> true
      _stale_or_missing_or_clean -> false
    end
  end

  @doc """
  A ampliação do quadro que a última varredura fresca leu, ou `nil`.

  Quem tem a foto é este módulo. Todo o resto que precisa conferir uma prova contra o mundo
  de agora (o cartão de prontidão) só tem a ampliação CALIBRADA, que é outra coisa — é o
  backend de captura que decide a da foto.
  """
  @spec seen_scale(integer) :: number | nil
  def seen_scale(now \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:special, fact_max_age_ms(), now) do
      {:ok, %{scale: scale}} when is_number(scale) -> scale
      _stale_or_missing -> nil
    end
  end

  @doc "As regras vistas na última varredura fresca, com as manchas delas — `[]` na tela limpa."
  @spec seen(integer) :: [map]
  def seen(now \\ System.monotonic_time(:millisecond)) do
    case WorldState.get(:special, fact_max_age_ms(), now) do
      {:ok, %{vistos: vistos}} when is_list(vistos) -> vistos
      _stale_or_missing -> []
    end
  end

  @impl true
  def init(state) do
    # combat's kill broadcast closes an open encounter as "killed"
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Catcher.Worker.kill_topic())
    schedule(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply,
     %{
       enabled?: state.active? and Settings.get(:shiny_guard_enabled),
       armed_rules: length(ColorRules.armed()),
       sparkle?: sparkle?(),
       pending?: state.streaks != %{}
     }, state}
  end

  @impl true
  def handle_info(:scan, state) do
    state =
      if state.active? and Settings.get(:shiny_guard_enabled),
        do: look(state),
        else: forget(state)

    schedule(state)
    {:noreply, state}
  end

  # A kill right after a sighting IS that shiny dying (Lucas: "se eu matei um
  # Shiny"). Outside the window it is an ordinary kill — ignored.
  def handle_info(kill, state) when kill in [{:kill}, {:kill, nil}] do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info({:kill, _corpse}, state) do
    if recent_sighting?(state), do: ShinyLog.resolve_last("killed")
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # DESLIGAR É ESQUECER. `prev` guardava o último quadro em que a cor estava na
  # tela, uns 17 MB de RGBA presos enquanto a guarda dorme — e, ao religar, a
  # primeira varredura limpa escrevia um "last"/"gone" com a foto de uma hora
  # atrás, como se o shiny tivesse acabado de sair da tela agora.
  defp forget(state),
    do: %{state | streaks: %{}, prev: @blank_prev, warned_stale: MapSet.new(), refused: %{}}

  # -- a varredura -------------------------------------------------------------

  defp look(state) do
    rules = ColorRules.armed()

    # sem regra de cor E sem o brilho não há o que procurar
    if rules == [] and not sparkle?() do
      %{state | streaks: %{}}
    else
      case snapshot(state) do
        {:ok, frame, region, forbidden} -> judge(state, rules, frame, region, forbidden)
        # Blind is not "no boss": without a frame the fact is NOT rewritten; it ages
        # on its own until the brain stops believing it.
        _blind -> state
      end
    end
  end

  defp sparkle?, do: Settings.get(:shiny_sparkle) == true

  defp snapshot(state) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- state.capture.(region, "special_colors.raw") do
      {:ok, frame, region, forbidden_boxes(calib, frame, region)}
    end
  end

  @doc """
  The character's and the STANDING pokémon's 3×3-tile boxes, in FRAME pixels of `region`:
  the own pokémon's green can match a shiny's. The ball (`Catcher.Worker`) refuses the same
  ground. Points in SCREEN coordinates; the frame knows its own scale.
  """
  def forbidden_boxes(calib, %Frame{scale: scale}, {rx, ry, _w, _h}) do
    meia = round(Calibration.tile_px(calib) * 1.5 * scale)

    # O MESMO PONTO QUE CENTRA A BUSCA. Lendo o campo cru, uma calibração sem o
    # personagem marcado varria em volta do meio da tela (o retorno de
    # `player_point/1`) mas não proibia caixa nenhuma — e o próprio personagem
    # dele virava candidato a shiny.
    [Calibration.player_point(calib), calib.pokemon_spot_point]
    |> Enum.reject(&is_nil/1)
    |> Enum.map(fn {sx, sy} ->
      fx = round((sx - rx) * scale)
      fy = round((sy - ry) * scale)
      {fx - meia, fy - meia, fx + meia, fy + meia}
    end)
  end

  defp judge(state, rules, frame, region, forbidden) do
    # UMA PROVA É DE UM QUADRO E DE UMA AMPLIAÇÃO. Medida noutro (ele mexeu no
    # raio da busca, no ponto do personagem, na tela) as caixas do HUD tapam chão
    # vazio e o HUD volta a disparar — em banda escura ele é mais alto que a
    # criatura. E medida noutra ampliação, a região é a MESMA mas toda mancha vem
    # com quatro vezes mais pixels: o gatilho é vencido por chão vazio.
    {rules, fora} = Enum.split_with(rules, &ColorRules.proof_fits?(&1, {region, frame.scale}))
    state = warn_stale(state, fora)

    tile_frame = round(Calibration.tile_px() * frame.scale)

    # SÓ CONTA MANCHA QUE ESTÁ EM CIMA DE UM BICHO VIVO — e nunca em cima do
    # POKÉMON DELE. Uma mancha sem barra de vida acima é cenário por definição
    # (o chão, uma caixa, um CORPO, que não tem barra); e uma mancha em cima de
    # um bicho que o acervo "Meu pokémon (rastreio)" reconhece é o companheiro
    # dele, que o vigia não caça.
    # AS BARRAS UMA VEZ SÓ: a cerca e o brilho olham as mesmas barras.
    marks =
      if Settings.get(:shiny_needs_creature) or sparkle?(),
        do: CreatureMarks.find(frame),
        else: []

    corpos =
      if Settings.get(:shiny_needs_creature),
        do: CreatureFence.bodies(frame, tile_frame, marks: marks),
        else: :anywhere

    {state, best, vistos} =
      Enum.reduce(rules, {state, 0, []}, fn rule, {state, best, vistos} ->
        result =
          ColorMark.scan(frame, rule.specs,
            min_cell_px: rule.min_cell_px,
            # as caixas do personagem e do pokémon MAIS o que a prova do chão
            # aprendeu ser o HUD do jogo (uma banda escura vê o próprio cliente)
            forbidden: forbidden ++ Map.get(rule, :forbidden, []),
            # os pedaços de um bicho são um bicho (o casco do Shiny Golem acende
            # em cinco placas): o gatilho é cobrado do bicho inteiro
            merge_px: tile_frame,
            merge_min_px: div(rule.min_px, 4)
          )

        # TODA MANCHA ACIMA DO GATILHO. Pegar só a maior fazia a lava tapar o
        # bicho: as duas passam do gatilho, mas só a lava era olhada, e o shiny
        # dois tiles ao lado não ficava "abaixo do limiar" — ficava sem ser
        # olhado. O vigia não arremessa, então anunciar todas não custa bola
        # nenhuma, e é o que faz o quadrado certo acender no cartão do cerco.
        # A cerca compara PIXELS DO QUADRO com pixels do quadro: ela vem antes da
        # conversão pra pontos de tela, senão são duas réguas diferentes.
        acima = Enum.filter(result.manchas, &(&1.px >= rule.min_px))

        # O DISJUNTOR DO HOLOFOTE. Um tom que passa do gatilho em muitos lugares
        # ao mesmo tempo não está identificando um bicho: está acendendo a tela.
        # Medido nos quadros de falso alerta dele de 10/09, a banda quase-preta
        # do Shiny Golem passava do gatilho em 4 a 17 manchas por quadro, com a
        # maior 60x acima dele — e um shiny é UMA mancha.
        #
        # Calar aqui vale muito mais que calar o alarme: o fato `:special` liga
        # `heavy?` E `worth_fighting?` no cérebro (Situation), então um tom
        # holofote põe o bot em postura de CHEFE o tempo todo — "não sei por que
        # ele tá usando skill enquanto anda em mobs com poucos inimigos" (10/09).
        # A prova do chão não pega isso: ela mede a cena PARADA e crava o gatilho
        # em 3x o pico dela, então ela sempre passa em si mesma; quem traz a cor
        # é o bicho que entra na tela depois.
        {peneira, state} =
          if length(acima) > Settings.get(:shiny_max_blobs) do
            {CreatureFence.sort([], corpos, tile_frame), note_floodlight(state, rule, acima)}
          else
            {CreatureFence.sort(acima, corpos, tile_frame), state}
          end

        achadas = Enum.map(peneira.quarry, &on_screen(&1, region, frame.scale))

        # A RECUSA TEM VOZ. Uma varredura que achou e jogou fora não pode ser o
        # mesmo silêncio de uma que não achou nada: se o olho ficar cego numa
        # barra nova, é por aqui que ele descobre.
        state =
          state
          |> note_bodyless(rule, peneira.bodyless)
          |> note_mine(rule, peneira.mine)

        # A confirmação e o refratário seguem olhando a MAIOR: uma segunda mancha
        # no mesmo quadro não é um segundo avistamento.
        mancha = result.manchas |> List.first() |> on_screen(region, frame.scale)
        hit? = achadas != []

        # O MEDIDOR MOSTRA O QUE DECIDE. Ele mostrava `result.px` — TODOS os
        # pixels casados na tela — contra um gatilho que se aplica à MAIOR
        # MANCHA. Na tela dele de 09/09 isso era 264.131 contra 85.331: o
        # medidor gritava "shiny!" com a guarda calada, e ele não tinha como
        # saber qual dos dois estava mentindo.
        {advance(state, rule, mancha, hit?), max(best, (mancha && mancha.px) || 0),
         Enum.map(achadas, &{rule, &1}) ++ vistos}
      end)

    {state, vistos} = sparkles(state, frame, marks, tile_frame, region, vistos)

    state = keepsake(state, vistos, frame)
    publish_special(vistos, frame.scale)
    broadcast_reading(state, best)
  end

  # O BRILHO AO LADO DO NOME. A estrela fica ao lado do nome, que fica em cima
  # da barra: a "mancha" que sai daqui é o CORPO do bicho (meio tile abaixo da
  # barra, o mesmo ponto que a cor entregaria), pra que o olho junte o brilho
  # à barra certa (`CrowdScan.mark_special/3`) e o rastro cace esse bicho.
  defp sparkles(state, frame, marks, tile_frame, region, vistos) do
    if sparkle?() do
      hits =
        frame
        |> Sparkle.find(marks)
        |> Enum.map(fn %{bar: {bx, by}, px: px, point: star} ->
          on_screen(
            %{px: px, point: {bx, by + div(tile_frame, 2)}, star: star},
            region,
            frame.scale
          )
        end)

      state = advance(state, @sparkle_rule, List.first(hits), hits != [])
      {state, Enum.map(hits, &{@sparkle_rule, &1}) ++ vistos}
    else
      {state, vistos}
    end
  end

  # …e o holofote também tem voz, uma vez por elenco: calar em silêncio seria a
  # mesma coisa que a regra não existir, e ele ficaria com um vigia armado que
  # nunca apita sem saber por quê.
  defp note_floodlight(state, rule, manchas) do
    chave = {rule.slug, :floodlight}
    marca = length(manchas)

    if marca == Map.get(state.refused, chave) do
      state
    else
      announce(
        "🚨 #{rule.name}: o tom passou do gatilho em #{marca} lugares neste quadro — " <>
          "isso é holofote, não bicho. A regra está calada até você reensinar um tom " <>
          "que só o shiny tem (o preto quase puro é contorno de TODA sprite do jogo)"
      )

      %{state | refused: Map.put(state.refused, chave, marca)}
    end
  end

  # O POKÉMON DELE TEM NOME NA TELA. Calado, isto seria a mesma coisa que a
  # varredura não ter achado nada, e ele ficaria olhando pro medidor sem entender
  # por que o Venusaur não dispara mais.
  defp note_mine(state, _rule, []), do: state

  defp note_mine(state, rule, [{_mancha, name} | _outras] = manchas) do
    chave = {rule.slug, :mine}
    marca = {name, length(manchas)}

    if marca == Map.get(state.refused, chave) do
      state
    else
      announce(
        "🐾 #{rule.name}: a cor está em cima do SEU #{name} — o vigia não caça o " <>
          "seu próprio pokémon (desligue-o no acervo “Meu pokémon” se quiser que caia na conta)"
      )

      %{state | refused: Map.put(state.refused, chave, marca)}
    end
  end

  # Uma vez por elenco também: a mesma cadência de 700ms.
  defp note_bodyless(state, _rule, []), do: state

  defp note_bodyless(state, rule, manchas) do
    chave = {rule.slug, :bodyless}
    marca = length(manchas)

    if marca == Map.get(state.refused, chave) do
      state
    else
      announce(
        "🔎 #{rule.name}: #{length(manchas)} mancha(s) da cor sem bicho embaixo — " <>
          "cenário, ou corpo no chão (o corpo é assunto da bola, não do vigia)"
      )

      %{state | refused: Map.put(state.refused, chave, marca)}
    end
  end

  defp announce(line),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:combat_log, :macro, line})

  # UMA VEZ POR ELENCO, não uma vez por varredura: na cadência de 700ms isto
  # escreveria o mesmo aviso quase duas vezes por segundo, pra sempre, no feed
  # de combate.
  defp warn_stale(state, rules) do
    slugs = MapSet.new(rules, & &1.slug)

    if slugs == state.warned_stale do
      state
    else
      if rules != [] do
        nomes = Enum.map_join(rules, ", ", & &1.name)

        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @combat_topic,
          {:combat_log, :macro,
           "⚠️ #{nomes}: a prova do chão foi medida noutro quadro (ou noutra ampliação de " <>
             "tela) — meça de novo na calibração"}
        )
      end

      %{state | warned_stale: slugs}
    end
  end

  # ColorMark answers in FRAME pixels of the square; everything downstream (the
  # fact, the Catcher, a click) speaks SCREEN points. Converted once, here. The
  # frame pixel stays under `in_frame` for the evidence picture and never
  # leaves the module.
  defp on_screen(nil, _region, _scale), do: nil

  defp on_screen(%{point: {fx, fy}} = mancha, region, scale) do
    mancha
    |> Map.put(:point, Calibration.frame_to_screen(scale, region, {fx, fy}))
    |> Map.put(:in_frame, {fx, fy})
  end

  # The FACT is published on EVERY scan, not every announcement. The trophy has a one-minute
  # refractory, but the brain needs PRESENCE: while the boss is on screen `heavy?` must stand,
  # and fall when it leaves. Different questions, different clocks.
  defp publish_special(vistos, scale) do
    seen = Enum.map(vistos, fn {rule, m} -> %{name: rule.name, px: m.px, point: m.point} end)

    # A TELA GRITA JUNTO. O fato abaixo é o do cérebro; o "✨" do alarme só sai
    # na confirmação (duas fotos) e é uma linha no feed — em 11/09 o Shiny
    # Golem foi visto UMA foto (o Venusaur dele cobriu o bicho na seguinte) e
    # ele "não viu na UI nada falando que tinha um shiny". Cada foto com o
    # shiny de pé acende a faixa do cabeçalho em toda página (`HeaderState`).
    if seen != [],
      do:
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @reading_topic,
          {:shiny_on_screen, %{vistos: seen}}
        )

    WorldState.put(
      :special,
      %{
        especial?: vistos != [],
        vistos: seen,
        # A AMPLIAÇÃO DO QUADRO QUE ELE ACABOU DE LER. Quem confere a prova aqui
        # tem a foto; o cartão de prontidão não tem, e ficaria com a ampliação
        # CALIBRADA, que é outra coisa. Divergindo as duas, o cartão diria "meça
        # o chão de novo" pra sempre enquanto a varredura corre feliz.
        scale: scale
      },
      System.monotonic_time(:millisecond)
    )
  end

  defp advance(state, rule, _mancha, false),
    do: %{state | streaks: Map.delete(state.streaks, rule.slug)}

  defp advance(state, rule, mancha, true) do
    streak = Map.get(state.streaks, rule.slug, 0) + 1
    state = %{state | streaks: Map.put(state.streaks, rule.slug, streak)}

    if streak >= Settings.get(:special_color_confirm_frames) and cooled?(state, rule.slug),
      do: fire(state, rule, mancha),
      else: state
  end

  defp cooled?(state, slug) do
    case Map.get(state.fired_at, slug) do
      nil -> true
      at -> System.monotonic_time(:millisecond) - at > @refractory_ms
    end
  end

  # Sighted: record and announce, no action here. The Catcher listens for {:shiny_seen, _} and
  # arms the guaranteed ball.
  defp fire(state, rule, mancha) do
    reason =
      if rule.slug == @sparkle_rule.slug,
        do: "✨ shiny na tela — o brilho ao lado do nome (#{mancha.px}px)",
        else: "✨ #{rule.name} na tela — mancha de #{mancha.px}px da cor dele"

    # the trophy shelf first: the encounter is logged even if a broadcast fails.
    # `star_px` is the field's historical name (the star is gone, the field stayed): it now
    # holds the BLOB's px.
    ShinyLog.record(star_px: mancha.px, action: nil, outcome: "seen", note: rule.name)

    # O AVISTAMENTO GRITA. Ele era uma linha de feed no meio de outras cem:
    # "estou vendo no minimapa que, se você consegue ver Shiny, eu não estou
    # conseguindo identificar que você realmente conseguiu" (10/09). O setor
    # `:shiny` existe desde 30/07, é o primeiro da lista de alarmes e o único
    # que nasce sem botão de mudo — e ninguém nunca o transmitiu. Um
    # `:rule_alarm` acende a tarja do painel, toca o som nativo pela Sirene,
    # entra no diário e vira linha no feed do cavebot: tudo o que a linha de
    # macro fazia, e mais.
    Phoenix.PubSub.broadcast(Pokex.PubSub, @combat_topic, {:rule_alarm, :shiny, reason})

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      @reading_topic,
      {:shiny_seen, %{px: mancha.px, name: rule.name, point: mancha.point}}
    )

    now = System.monotonic_time(:millisecond)

    %{
      state
      | streaks: Map.delete(state.streaks, rule.slug),
        fired_at: Map.put(state.fired_at, rule.slug, now),
        last_fired_at: now
    }
  end

  # -- a foto da morte ----------------------------------------------------------
  #
  # Three moments answer "does the shiny's corpse keep the palette?": the colour
  # appearing, the colour leaving (with the LAST frame it was still in), and the
  # battle list shrinking while the colour is on screen. Each keeps a raw frame,
  # a BMP with a cross on the blob, and one `kind: :special` line in the journal.
  # Nothing here decides anything.

  defp keepsake(state, vistos, frame) do
    enemies = listed()
    now = System.monotonic_time(:millisecond)
    prev = state.prev

    state =
      cond do
        prev.seen == [] and vistos != [] ->
          keep(state, "seen", vistos, frame, enemies, now)

        prev.seen != [] and vistos == [] ->
          state
          |> keep("last", prev.seen, prev.frame, prev.enemies, now, :quiet)
          |> keep("gone", prev.seen, frame, enemies, now)

        vistos != [] and dropped?(prev.enemies, enemies) ->
          keep(state, "drop", vistos, frame, enemies, now)

        true ->
          state
      end

    %{state | prev: %{seen: vistos, frame: frame, enemies: enemies}}
  end

  # SEM LEITURA NÃO É ZERO. `listed/0` devolve `nil` quando o fato da lista está
  # velho, e velho acontece o tempo todo (a lista só é lida quando há briga).
  # Contando isso como zero, toda varredura fora de combate "via" a lista
  # encolher de 3 pra 0 e inventava a foto e a linha de "drop" de um shiny que
  # ninguém pegou.
  defp dropped?(before, now) when is_integer(before) and is_integer(now), do: now < before
  defp dropped?(_unread, _now), do: false

  # `:quiet` keeps the photo without a journal line: "last" is the companion of
  # "gone", one record for the pair.
  defp keep(state, tag, vistos, frame, enemies, now, voice \\ :loud)

  defp keep(state, tag, [{rule, mancha} | _], %Frame{} = frame, enemies, now, voice) do
    if gap_ok?(state, tag, now) do
      save_photos(frame, mancha, tag)

      if voice == :loud do
        state.journal.(:special, %{
          tag: tag,
          name: rule.name,
          px: mancha.px,
          point: mancha.point,
          enemies: enemies
        })
      end

      %{state | photographed_at: Map.put(state.photographed_at, tag, now)}
    else
      state
    end
  end

  defp keep(state, _tag, _no_blob, _no_frame, _enemies, _now, _voice), do: state

  defp gap_ok?(state, tag, now) do
    case Map.get(state.photographed_at, tag) do
      nil -> true
      at -> now - at >= @photo_gap_ms
    end
  end

  # The same count the eye reads: the battle list's rows, `nil` when the fact is
  # stale — which is NOT the same as an empty list.
  defp listed do
    now = System.monotonic_time(:millisecond)

    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) -> length(enemies)
      _no_list -> nil
    end
  end

  # The raw is the frame the code read; the BMP is the same frame with a cross
  # on the blob, for eyes. Both under captures/shiny, 30 files kept.
  defp save_photos(frame, mancha, tag) do
    dir = Path.join(Home.captures_dir(), @photo_dir)
    File.mkdir_p!(dir)

    stem =
      "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}-#{tag}"

    Home.write!(Path.join(dir, stem <> ".raw"), Frame.to_raw(frame))

    with {:ok, bytes} <- evidence_bytes(frame, mancha) do
      Home.write!(Path.join(dir, stem <> ".bmp"), bytes)
    end

    rotate(dir)
  rescue
    # A photo that cannot be saved is a photo lost, never a scan lost.
    _no_photo -> :ok
  end

  defp evidence_bytes(frame, %{in_frame: {fx, fy}}) do
    url = Evidence.data_url(frame, shrink: 2, marks: [{fx, fy, {255, 0, 255}}])

    case String.split(url, ",", parts: 2) do
      [_head, body] -> Base.decode64(body)
      _no_body -> :error
    end
  end

  defp rotate(dir) do
    dir
    |> Path.join("*")
    |> Path.wildcard()
    |> Enum.sort()
    |> Enum.reverse()
    |> Enum.drop(@keep_photos)
    |> Enum.each(&File.rm/1)
  end

  defp recent_sighting?(%{last_fired_at: nil}), do: false

  defp recent_sighting?(%{last_fired_at: at}),
    do: System.monotonic_time(:millisecond) - at <= @encounter_window_ms

  # Feed the panel's live meter — throttled so the scan cadence doesn't
  # re-render the panel several times a second.
  defp broadcast_reading(state, px) do
    now = System.monotonic_time(:millisecond)

    if state.last_reading_at == nil or now - state.last_reading_at > @reading_throttle_ms do
      Phoenix.PubSub.broadcast(Pokex.PubSub, @reading_topic, {:shiny_reading, %{px: px}})
      %{state | last_reading_at: now}
    else
      state
    end
  end

  # On, the cadence is the scan's; off (or no rule armed), a slow tick just to re-check the
  # switch.
  defp schedule(state) do
    # o brilho ao lado do nome vigia na mesma cadência das cores: sem ele e
    # sem regra armada, o vigia só confere de segundo em segundo se ligaram algo
    armed? = ColorRules.armed() != [] or sparkle?()

    ms =
      if state.active? and Settings.get(:shiny_guard_enabled) and armed?,
        do: Settings.get(:special_color_scan_ms),
        else: @idle_poll_ms

    Process.send_after(self(), :scan, ms)
  end
end
