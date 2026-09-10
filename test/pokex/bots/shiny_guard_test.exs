defmodule Pokex.Bots.ShinyGuardTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.SettingsStash
  alias Pokex.Vision.{ColorRules, Frame}

  @moduletag :tmp_dir

  # o verde do Electrode shiny da print de 01/09
  @verde {40, 160, 60}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    :persistent_term.erase({ColorRules, :cache})
    :ets.delete(:pokex_world, :special)
    :ets.delete(:pokex_world, :battle)

    SettingsStash.stash!(
      shiny_guard_enabled: true,
      special_color_scan_ms: 50,
      shiny_needs_creature: true
    )

    on_exit(fn -> Pokex.TestHome.restore() end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {0, 0, 80, 400},
      neutral_point: {500, 500},
      player_point: {500, 350},
      # a measured tile: the square no longer swallows the whole screen, so the
      # region has an origin away from (0,0) and a frame point differs from a screen point
      tile_px: 40
    })

    {:ok, calib} = Calibration.load()
    {:ok, region} = SpotScan.region(calib)
    %{region: region}
  end

  defp frame(w, h, bg, patches) do
    pixels =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = pixel(x, y, bg, patches)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: pixels}
  end

  defp pixel(x, y, bg, patches) do
    Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
      if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
    end)
  end

  # um frame do tamanho da REGIÃO do SpotScan, com a mancha verde LONGE das
  # caixas proibidas (personagem no centro)
  # O QUADRO REALISTA: uma mancha da cor COM a barra de vida do bicho em cima. O
  # vigia so conta cor que esta em cima de bicho VIVO, e quem prova que ha um
  # bicho ali e a barra que o cliente desenha. O corpo fica UM TILE (40 no teste)
  # abaixo do centro da barra.
  #
  # Armadilha: `frame/4` pinta o PRIMEIRO retalho que casa, entao o preenchimento
  # da barra tem que vir ANTES da moldura preta.
  @tile_teste 40

  defp bicho(cx, cy) do
    bar_y = cy - @tile_teste - 2

    [
      {{cx - 5, cy - 7, 14, 14}, @verde},
      {{cx - 12, bar_y + 1, 22, 2}, {0, 188, 0}},
      {{cx - 13, bar_y, 27, 4}, {0, 0, 0}}
    ]
  end

  defp frame_com_mancha({_x, _y, w, h}), do: frame(w, h, {40, 40, 40}, bicho(70, 90))

  # o mesmo bicho, mas com a arte dele pintada do azul que o acervo aprendeu: a
  # sprite ensinada e recortada MEIO tile abaixo da barra (o centro em 70,70)
  @azul_dele {20, 40, 220}

  defp frame_do_pokemon_dele({_x, _y, w, h}),
    do: frame(w, h, {40, 40, 40}, bicho(70, 90) ++ [{{22, 22, 96, 96}, @azul_dele}])

  defp ensina_pokemon_dele(name) do
    {r, g, b} = @azul_dele

    crop = %Frame{
      width: 96,
      height: 96,
      rgba: :binary.copy(<<r, g, b, 255>>, 96 * 96),
      scale: 1.0
    }

    {:ok, _kept} = Pokex.Bots.PokemonSprites.add(name, crop)
    [%{"slug" => slug} | _outros] = Pokex.Bots.PokemonSprites.list()
    slug
  end

  defp regra_provada(attrs \\ %{}) do
    {:ok, %{"slug" => slug}} =
      ColorRules.add(
        Map.merge(
          %{
            "name" => "Electrode shiny",
            "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
            "min_px" => 50
          },
          attrs
        )
      )

    :ok = ColorRules.mark_proven(slug, 3)
    slug
  end

  defp start_guard(capture) do
    start_supervised!({ShinyGuard, name: nil, active: true, capture: capture})
  end

  test "two scans with the blob RECORD: trophy, journal and {:shiny_seen}", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, %{px: px, name: "Electrode shiny"}}, 2_000
    assert px >= 50
    # …E O ALARME, nao uma linha de feed no meio de outras cem. O setor `:shiny`
    # e o primeiro da lista de alarmes e o unico sem botao de mudo desde 30/07, e
    # nunca ninguem o transmitiu: a tarja, a Sirene e o chirp do navegador
    # estavam ligados num avistamento que nao falava.
    assert_receive {:rule_alarm, :shiny, texto}, 500
    assert texto =~ "Electrode shiny"
    assert [%{outcome: "seen", note: "Electrode shiny"}] = ShinyLog.entries()
  end

  test "ONE scan alone does not record: the confirmation asks for the second", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    {:ok, contador} = Agent.start_link(fn -> 0 end)
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])

    start_guard(fn _region, _name ->
      n = Agent.get_and_update(contador, &{&1, &1 + 1})
      # mancha no 1º quadro, tela limpa dali em diante: um vislumbre
      if n == 0, do: {:ok, frame_com_mancha(region)}, else: {:ok, limpo}
    end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "a rule without noise proof does NOT scan", %{region: region} do
    {:ok, _} =
      ColorRules.add(%{
        "name" => "Sem prova",
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
        "min_px" => 50
      })

    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "the refractory holds the machine gun: one record per minute per rule", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, _}, 2_000
    refute_receive {:shiny_seen, _}, 1_000
  end

  test "the blob INSIDE the own pokemon's box does not count", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    # o verde do Torterra: pintado exatamente onde o personagem está
    {rx, ry, w, h} = region
    {:ok, calib} = Calibration.load()
    {px, py} = calib.player_point
    torterra = frame(w, h, {40, 40, 40}, [{{px - rx - 7, py - ry - 7, 14, 14}, @verde}])

    start_guard(fn _region, _name -> {:ok, torterra} end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "guard off neither scans nor records", %{region: region} do
    regra_provada()
    Pokex.Settings.put(:shiny_guard_enabled, false)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "a kill right after the sighting closes the trophy as killed", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    guard = start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, _}, 2_000
    send(guard, {:kill})
    _ = :sys.get_state(guard)

    assert [%{outcome: "killed"}] = ShinyLog.entries()
  end

  test "o medidor do painel recebe a leitura ao vivo", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_reading, %{px: px}}, 2_000
    assert px > 0
  end

  # O FATO pro cérebro: a PRESENÇA, publicada a cada varredura — outro relógio
  # que o troféu (que tem refratário de um minuto). É o que mantém `heavy?` de
  # pé enquanto o especial está na tela e o derruba quando ele sai.
  test "publishes the :special fact while the colour is on screen", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, _}, 2_000

    assert {:ok, %{especial?: true, vistos: [%{name: "Electrode shiny"}]}} =
             WorldState.get(:special, 5_000, System.monotonic_time(:millisecond))
  end

  test "a clean screen publishes special? false: the stance drops when it leaves", %{
    region: region
  } do
    regra_provada()
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])
    guard = start_guard(fn _region, _name -> {:ok, limpo} end)
    _ = :sys.get_state(guard)

    assert eventually(fn ->
             match?(
               {:ok, %{especial?: false}},
               WorldState.get(:special, 5_000, System.monotonic_time(:millisecond))
             )
           end)
  end

  defp eventually(fun, timeout \\ 1_000) do
    limite = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if fun.(), do: true, else: Process.sleep(20) && false
    end)
    |> Enum.find(fn ok -> ok or System.monotonic_time(:millisecond) > limite end)
    |> Kernel.==(true)
  end

  test "status exposes the watcher's state" do
    regra_provada()
    limpo = frame(64, 64, {40, 40, 40}, [])
    guard = start_guard(fn _region, _name -> {:ok, limpo} end)

    assert %{enabled?: true, armed_rules: 1, pending?: false} = ShinyGuard.status(guard)
  end

  # The blob's centre of mass is in FRAME pixels; the fact and the broadcast
  # carry SCREEN points, the only frame a click or the Catcher understands.
  test "the fact and the broadcast carry the blob in screen points", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, %{point: {sx, sy}}}, 2_000

    # o bicho do quadro de teste tem o corpo em (70,90) do quadro
    {rx, ry, _w, _h} = region
    assert_in_delta sx, rx + 70, 6
    assert_in_delta sy, ry + 90, 6

    assert {:ok, %{vistos: [%{point: {^sx, ^sy}}]}} =
             WorldState.get(:special, 5_000, System.monotonic_time(:millisecond))
  end

  # -- a foto da morte ----------------------------------------------------------

  defp photos, do: Home.captures_dir() |> Path.join("shiny") |> Path.join("*") |> Path.wildcard()

  defp tags do
    photos()
    |> Enum.map(&(&1 |> Path.basename() |> String.split("-") |> List.last()))
    |> Enum.sort()
  end

  defp start_guard_journaling(capture) do
    test = self()

    start_supervised!(
      {ShinyGuard,
       name: nil,
       active: true,
       capture: capture,
       journal: fn kind, payload -> send(test, {:journal, kind, payload}) end}
    )
  end

  # The question this whole PR exists to answer — "does the corpse keep the
  # palette?" — is answered by the photo of the moment the colour LEAVES, next
  # to the last photo in which it was still there.
  test "the colour leaving keeps the last frame with it and the first without", %{
    region: region
  } do
    regra_provada(%{"name" => "Electrode shiny"})
    {:ok, contador} = Agent.start_link(fn -> 0 end)
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])

    start_guard_journaling(fn _region, _name ->
      n = Agent.get_and_update(contador, &{&1, &1 + 1})
      if n < 3, do: {:ok, frame_com_mancha(region)}, else: {:ok, limpo}
    end)

    assert_receive {:journal, :special,
                    %{tag: "seen", name: "Electrode shiny", px: px, point: {_, _}}},
                   2_000

    assert px >= 50
    assert_receive {:journal, :special, %{tag: "gone", name: "Electrode shiny"}}, 2_000

    assert eventually(fn ->
             tags() == ["gone.bmp", "gone.raw", "last.bmp", "last.raw", "seen.bmp", "seen.raw"]
           end)

    # the "last" photo is a frame WITH the blob, the "gone" photo one WITHOUT
    [last] = Enum.filter(photos(), &String.ends_with?(&1, "last.raw"))
    [gone] = Enum.filter(photos(), &String.ends_with?(&1, "gone.raw"))
    assert {:ok, %Frame{rgba: com}} = Frame.from_file(last)
    assert {:ok, %Frame{rgba: sem}} = Frame.from_file(gone)
    assert com == frame_com_mancha(region).rgba
    assert sem == limpo.rgba
  end

  # The list shrinking while the colour is still on screen is the shiny most
  # likely dying — the frame of that instant is the corpse, if the palette stays.
  test "the list dropping with the colour on screen keeps a drop photo", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    WorldState.put(:battle, %{enemies: [0, 1]}, System.monotonic_time(:millisecond))

    start_guard_journaling(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:journal, :special, %{tag: "seen", enemies: 2}}, 2_000
    WorldState.put(:battle, %{enemies: [0]}, System.monotonic_time(:millisecond))

    assert_receive {:journal, :special, %{tag: "drop", enemies: 1, name: "Electrode shiny"}},
                   2_000

    assert eventually(fn -> "drop.raw" in tags() end)
  end

  # UMA PROVA É DE UM QUADRO. Medida noutro (ele mexeu no raio da busca, no ponto
  # do personagem, na tela), as caixas do HUD que ela aprendeu tapam chão vazio e
  # o HUD volta a disparar. E o aviso sai UMA vez: na cadência de 700ms, um por
  # varredura seria quase dois por segundo pra sempre.
  # E SEM O PERSONAGEM MARCADO a busca continua acontecendo em volta do meio da
  # tela, mas a proibição lia o campo cru e não proibia caixa nenhuma: o próprio
  # personagem dele virava candidato a shiny.
  test "without a marked player point the screen centre is still forbidden" do
    {:ok, calib} = Calibration.load()
    sem_marca = %{calib | player_point: nil}
    frame = %Frame{width: 200, height: 200, rgba: :binary.copy(<<0, 0, 0, 255>>, 200 * 200)}

    assert ShinyGuard.forbidden_boxes(sem_marca, frame, {400, 250, 200, 200}) != []
  end

  # A PENEIRA MAIS FORTE DE TODAS. O cliente desenha uma barra de vida sobre cada
  # criatura VIVA, e o olho sabe acha-las. Uma mancha de cor SEM bicho embaixo e
  # cenario por definicao — o chao, uma caixa de madeira, um CORPO no chao (que
  # nao tem barra). Era isso que ele estava vendo destacado: "pega os pokemons
  # que estao no chao mortos ali".
  test "colour with no creature under it is scenery, and is not a sighting", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    # a mesma mancha de cor, SEM a barra: cenario
    so_cor = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [{{60, 80, 40, 40}, @verde}])

    start_guard_journaling(fn _region, _name -> {:ok, so_cor} end)

    refute_receive {:journal, :special, _nada}, 800
    assert_receive {:combat_log, :macro, aviso}, 2_000
    assert aviso =~ "sem bicho embaixo"

    # …e UMA VEZ, nao a cada varredura: com a cadencia de 50ms do teste, uma
    # gaveta lida por uma chave e escrita por outra enche o feed de combate.
    refute_receive {:combat_log, :macro, _de_novo}, 600
  end

  # O POKEMON DELE NAO E CACA. "o shiny venossaur e meu proprio pokemon poxa, nao
  # quero que ele tente cacar meu proprio pokemon, inclusive, ele ja esta
  # calibrado!" (10/09). O acervo "Meu pokemon (rastreio)" ja sabia quem e o
  # companheiro dele; o vigia e que nunca perguntou.
  test "a blob on HIS OWN taught pokemon is not a sighting", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    ensina_pokemon_dele("Shiny Venusaur")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard_journaling(fn _region, _name -> {:ok, frame_do_pokemon_dele(region)} end)

    refute_receive {:journal, :special, _nada}, 800
    assert_receive {:combat_log, :macro, aviso}, 2_000
    assert aviso =~ "Shiny Venusaur"
    assert aviso =~ "SEU"
  end

  # UMA VEZ POR ELENCO, nao uma por varredura. As duas recusas — sem bicho, e em
  # cima do pokemon dele — dividiam a mesma gaveta com chaves diferentes na
  # leitura e na escrita, e o feed de combate levava a mesma linha 20 vezes por
  # segundo.
  test "the same refusal is announced once, not on every scan", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    ensina_pokemon_dele("Shiny Venusaur")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard(fn _region, _name -> {:ok, frame_do_pokemon_dele(region)} end)

    assert_receive {:combat_log, :macro, aviso}, 2_000
    assert aviso =~ "SEU"
    refute_receive {:combat_log, :macro, _de_novo}, 600
  end

  # …e desligar a entrada no acervo e o interruptor: "nao rastreie esse" e "esse
  # nao e meu" sao a mesma frase.
  test "with that entry turned off in the collection it counts again", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    slug_dele = ensina_pokemon_dele("Shiny Venusaur")
    Pokex.Bots.PokemonSprites.set_enabled(slug_dele, false)

    start_guard_journaling(fn _region, _name -> {:ok, frame_do_pokemon_dele(region)} end)

    assert_receive {:journal, :special, %{tag: "seen"}}, 2_000
  end

  # …e com o interruptor desligado ele volta a contar, porque a cegueira do olho
  # nao pode ser a unica coisa entre ele e um shiny.
  test "with the switch off, colour alone counts again", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    SettingsStash.stash!(shiny_needs_creature: false)

    so_cor = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [{{60, 80, 40, 40}, @verde}])

    start_guard_journaling(fn _region, _name -> {:ok, so_cor} end)

    assert_receive {:journal, :special, %{tag: "seen"}}, 2_000
  end

  # A LAVA MAIOR TAPAVA O BICHO. (A segunda mancha fica longe do meio: o quadrado
  # de 3×3 tiles do personagem é terreno proibido e engoliria uma mancha ali.) Só a maior mancha era julgada, então o fato, o
  # troféu, o diário e a bola apontavam pro cenário, e o shiny dois tiles ao lado
  # não ficava "abaixo do limiar" — ficava sem ser olhado.
  test "a bigger blob of scenery does not hide the creature's own", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})

    # dois BICHOS, um com muito mais cor casada que o outro: o vigia tem que
    # olhar os dois, e nao so o maior
    frame =
      frame(elem(region, 2), elem(region, 3), {40, 40, 40}, bicho(70, 90) ++ bicho(200, 210))

    start_guard(fn _region, _name -> {:ok, frame} end)

    assert eventually(fn ->
             match?(
               {:ok, %{vistos: [_, _]}},
               WorldState.get(:special, 5_000, System.monotonic_time(:millisecond))
             )
           end),
           "a segunda mancha tem que estar no fato, senão o bicho não foi nem olhado"
  end

  # …e a mesma região com OUTRA ampliação também não serve: o chão é uma contagem
  # e as caixas do HUD são pixels do quadro, e os dois quadruplicam quando o
  # backend de captura troca e serve a mesma região com o dobro da largura.
  test "a proof from another scale does not scan either", %{region: region} do
    slug = regra_provada(%{"name" => "Electrode shiny"})
    :ok = ColorRules.mark_proven(slug, 3, [], region, 2.0)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard_journaling(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:combat_log, :macro, aviso}, 2_000
    assert aviso =~ "ampliação"
    refute_receive {:journal, :special, _nada}, 500
  end

  test "a proof from another frame does not scan, and says so once", %{region: region} do
    slug = regra_provada(%{"name" => "Electrode shiny"})
    :ok = ColorRules.mark_proven(slug, 3, [], {0, 0, 10, 10})
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard_journaling(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:combat_log, :macro, aviso}, 2_000
    assert aviso =~ "medida noutro quadro"

    refute_receive {:combat_log, :macro, _outro}, 500
    refute_receive {:journal, :special, _nada}, 500
  end

  # DESLIGAR É ESQUECER. Parada, a guarda continuava segurando o último quadro
  # com a cor; ao religar numa tela limpa ela escrevia "last" e "gone" de um
  # shiny que tinha saído da tela fazia meia hora.
  test "switching the guard off forgets the frame it was holding", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])
    {:ok, tela} = Agent.start_link(fn -> frame_com_mancha(region) end)

    start_guard_journaling(fn _region, _name -> {:ok, Agent.get(tela, & &1)} end)

    assert_receive {:journal, :special, %{tag: "seen"}}, 2_000

    Pokex.Settings.put(:shiny_guard_enabled, false)
    Process.sleep(200)
    Agent.update(tela, fn _blob -> limpo end)
    Pokex.Settings.put(:shiny_guard_enabled, true)

    refute_receive {:journal, :special, %{tag: "gone"}}, 2_000
    refute "gone.raw" in tags()
  end

  # SEM LEITURA NÃO É ZERO. Fora de combate ninguém lê a lista, e o fato fica
  # velho: contando isso como zero, a guarda "via" a lista cair pra 0 e
  # inventava a foto e a linha de um shiny que ninguém pegou.
  test "an unread battle list is not a list that emptied", %{region: region} do
    regra_provada(%{"name" => "Electrode shiny"})
    WorldState.put(:battle, %{enemies: [0, 1]}, System.monotonic_time(:millisecond))

    start_guard_journaling(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:journal, :special, %{tag: "seen", enemies: 2}}, 2_000
    :ets.delete(:pokex_world, :battle)

    refute_receive {:journal, :special, %{tag: "drop"}}, 500
    refute "drop.raw" in tags()
  end

  # A blob flapping at the threshold must not flood the rotation.
  test "the same moment does not repeat within the photo gap", %{region: region} do
    regra_provada()
    {:ok, contador} = Agent.start_link(fn -> 0 end)
    limpo = frame(elem(region, 2), elem(region, 3), {40, 40, 40}, [])

    # seen, gone, seen, gone... every scan flips
    start_guard_journaling(fn _region, _name ->
      n = Agent.get_and_update(contador, &{&1, &1 + 1})
      if rem(n, 2) == 0, do: {:ok, frame_com_mancha(region)}, else: {:ok, limpo}
    end)

    assert_receive {:journal, :special, %{tag: "seen"}}, 2_000
    assert_receive {:journal, :special, %{tag: "gone"}}, 2_000
    refute_receive {:journal, :special, %{tag: "seen"}}, 500
  end
end
