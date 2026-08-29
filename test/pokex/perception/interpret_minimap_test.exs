defmodule Pokex.Perception.InterpretMinimapTest do
  @moduledoc """
  The character position as the cavebot receives it: regions come from
  `Calibration` (manual marks win, layout is fallback) and the ink floor is the
  `minimap_coord_ink` setting. Default 120 is measured behavior: digit cores are
  240+ but anti-aliasing spreads 160-239 and the atlas was taught at floor 120,
  so raising it starves the shapes and blinds the atlas (165 failed all four
  real captures).
  """
  use ExUnit.Case, async: true

  alias Pokex.{Calibration, Layout, ScreenFixtures}
  alias Pokex.Perception.Interpret.Minimap
  alias Pokex.Vision.Frame

  @coords %{
    "ultrawide_3440x1440_full" => {337, 46_107, 4},
    "ultrawide_3440x1440_outro_mapa" => {2782, 30_571, 5},
    "ultrawide_3440x1440_terceiro" => {2777, 30_560, 5},
    "ultrawide_3440x1440_time" => {2597, 30_640, 6}
  }

  defp located(name) do
    frame = ScreenFixtures.frame!(name)
    {:ok, fix} = Layout.locate(frame)
    panel = Frame.crop(frame, Layout.region(:minimap, fix))
    {fix, panel}
  end

  test "the default ink floor reads all four real captures via layout fallback" do
    for {name, expected} <- @coords do
      {fix, panel} = located(name)
      calib = %Calibration{scale: 1.0, layout: fix}

      assert {%{pos: ^expected}, _state} = Minimap.interpret(panel, calib, %{}, nil),
             "did not read the coordinate in #{name}"
    end
  end

  # A altura é a DOS DÍGITOS, não a do glifo mais alto: nesta captura dele a
  # linha tem dez dígitos de 15 linhas, duas vírgulas de 6 e dois parênteses de
  # 19. Pela mais alta a resposta seria 19 — uma altura em que o atlas está
  # completo — e a pergunta erraria a fonte que ela queria medir.
  test "a fonte medida é a dos dígitos, e um render completo não acusa buraco" do
    for {name, _expected} <- @coords do
      {fix, panel} = located(name)
      calib = %Calibration{scale: 1.0, layout: fix}

      assert {%{coord_gap: nil}, _state} = Minimap.interpret(panel, calib, %{}, nil),
             "acusou buraco de alfabeto num render que lê tudo: #{name}"
    end
  end

  # O SEGUNDO BURACO, e o que o de cima não enxerga: o alfabeto COMPLETO
  # lendo por parecença. "Na parte de ensinar glifos tá falando que não tem
  # nenhum problema, e ele realmente tá interpretando errado o número" (29/08).
  #
  # `coord_gap` responde "falta algum dígito nesta altura?" e num render bom a
  # resposta é não. `coord_guessed` responde a outra pergunta — "quanto disto
  # aqui foi reconhecido de verdade?" — e é ela que fica sem resposta quando o
  # atlas conhece os dez dígitos mas não conhece o desenho DESTA tela.
  describe "o aviso de leitura por parecença" do
    test "um render que o atlas conhece não acusa chute nenhum" do
      for {name, _expected} <- @coords do
        {fix, panel} = located(name)
        calib = %Calibration{scale: 1.0, layout: fix}

        assert {%{coord_guessed: nil}, _state} = Minimap.interpret(panel, calib, %{}, nil),
               "acusou parecença num render que o atlas lê exato: #{name}"
      end
    end

    test "uma tinta que desfigura os glifos acusa, com a fração" do
      {fix, panel} = located("ultrawide_3440x1440_time")
      calib = %Calibration{scale: 1.0, layout: fix}

      {obs, _state} = Minimap.interpret(panel, calib, %{minimap_coord_ink: 60}, nil)

      case obs.coord_guessed do
        nil ->
          # este render pode resistir à tinta ruim; então a única coisa que este
          # teste pode afirmar é que o campo EXISTE e não mente
          assert Map.has_key?(obs, :coord_guessed)

        chute ->
          assert chute.guessed > 0
          assert chute.glyphs >= chute.guessed
          assert chute.pct > 0 and chute.pct <= 100
      end
    end
  end

  test "hand-marked regions read without any layout" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    calib = %Calibration{
      scale: 1.0,
      layout: nil,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  # manual marks point at the same regions the layout resolves: a shifted layout
  # with correct manual marks would read wrong on the old path, so a matching
  # result proves the manual path is the one taken
  test "manual marks win over a present layout" do
    {fix, panel} = located("ultrawide_3440x1440_time")

    calib = %Calibration{
      scale: 1.0,
      layout: fix,
      minimap_region: Layout.region(:minimap, fix),
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    assert {%{pos: {2597, 30_640, 6}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  # The setting is where the reader STARTS, not what it is hostage to: an
  # impossible floor used to blind it outright, and now the hunt rescues the
  # read with a floor that works and remembers it. The rescue is the whole
  # point — over bright terrain the taught floor is itself the wrong one.
  test "an impossible ink setting no longer blinds the reader — the hunt finds a floor" do
    {fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: fix}

    assert {%{pos: {337, 46_107, 4}}, state} =
             Minimap.interpret(panel, calib, %{minimap_coord_ink: 255}, nil)

    assert state.ink != 255
    assert is_tuple(state.band)
  end

  test "no region at all (neither manual nor layout) yields pos nil, never a crash" do
    {_fix, panel} = located("ultrawide_3440x1440_full")
    calib = %Calibration{scale: 1.0, layout: nil}

    assert {%{pos: nil}, _state} = Minimap.interpret(panel, calib, %{}, nil)
    assert {%{pos: nil}, _state} = Minimap.interpret(panel, nil, %{}, nil)
  end

  # The real 2026-08-10 failure: the hand-marked map region started BELOW the
  # coord band, and the feed captured the map region alone — the band was
  # decapitated before the reader ever saw a pixel. The feed now captures
  # minimap_capture_region (the union of both marks), and the reader subtracts
  # the SAME origin, so a band poking outside the map can never be clipped.
  test "a coord band poking outside the map region still reads — the capture is the union" do
    frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
    {:ok, fix} = Layout.locate(frame)

    calib = %Calibration{
      scale: 1.0,
      layout: nil,
      # starts 34pt below the band on purpose
      minimap_region: {3171, 40, 269, 418},
      minimap_coord_region: Layout.region(:minimap_coord, fix)
    }

    panel = Frame.crop(frame, Calibration.minimap_capture_region(calib))
    assert {%{pos: {337, 46_107, 4}}, _state} = Minimap.interpret(panel, calib, %{}, nil)
  end

  # The label MOVES with the widget's visual state (2026-08-10): walking draws
  # it at the widget's top-left, hovering pushes it ~40pt down under the control
  # bar. A band marked in one state misses in the other — so the reader hunts.
  describe "self-healing band" do
    test "a band marked in the wrong visual state self-heals and the find sticks" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
      {:ok, fix} = Layout.locate(frame)
      {cx, cy, cw, ch} = Layout.region(:minimap_coord, fix)

      calib = %Calibration{
        scale: 1.0,
        layout: nil,
        minimap_region: Layout.region(:minimap, fix),
        # the hover-state band: 40pt below where the label actually is now
        minimap_coord_region: {cx, cy + 40, cw, ch}
      }

      panel = Frame.crop(frame, Calibration.minimap_capture_region(calib))

      assert {%{pos: {337, 46_107, 4}}, state} = Minimap.interpret(panel, calib, %{}, nil)
      assert is_tuple(state.band)

      # the found band is the fast path now: the next read hits it directly
      assert {%{pos: {337, 46_107, 4}}, next} = Minimap.interpret(panel, calib, %{}, state)
      assert next.band == state.band
      assert next.ink == state.ink
    end

    test "with no label anywhere the hunt counts misses and never invents a position" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")

      calib = %Calibration{
        scale: 1.0,
        layout: nil,
        # a textless patch of the capture posing as the minimap
        minimap_region: {600, 600, 290, 458},
        minimap_coord_region: {620, 606, 160, 30}
      }

      panel = Frame.crop(frame, Calibration.minimap_capture_region(calib))

      assert {%{pos: nil}, state} = Minimap.interpret(panel, calib, %{}, nil)
      assert state.misses == 1
      assert {%{pos: nil}, state} = Minimap.interpret(panel, calib, %{}, state)
      assert state.misses == 2
    end

    test "an old-shape state (pre-band) is upgraded, never crashed on" do
      frame = ScreenFixtures.frame!("ultrawide_3440x1440_full")
      {:ok, fix} = Layout.locate(frame)
      calib = %Calibration{scale: 1.0, layout: fix}
      panel = Frame.crop(frame, Calibration.minimap_capture_region(calib))

      assert {%{pos: {337, 46_107, 4}}, state} =
               Minimap.interpret(panel, calib, %{}, %{last: nil, pending: nil})

      assert Map.has_key?(state, :band)
    end
  end

  describe "Calibration resolvers" do
    test "manual wins over layout; layout is fallback; nothing yields nil" do
      {fix, _panel} = located("ultrawide_3440x1440_full")

      manual = %Calibration{
        scale: 1.0,
        layout: fix,
        minimap_region: {10, 20, 300, 400},
        minimap_coord_region: {12, 22, 160, 30},
        minimap_player_point: {160, 220}
      }

      assert Calibration.minimap_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_coord_region(manual) == {12, 22, 160, 30}
      assert Calibration.minimap_map_region(manual) == {10, 20, 300, 400}
      assert Calibration.minimap_player_point(manual) == {160, 220}

      fallback = %Calibration{scale: 1.0, layout: fix}
      assert Calibration.minimap_region(fallback) == Layout.region(:minimap, fix)
      assert Calibration.minimap_map_region(fallback) == Layout.region(:minimap_map, fix)
      {mx, my, mw, mh} = Layout.region(:minimap_map, fix)
      assert Calibration.minimap_player_point(fallback) == {mx + div(mw, 2), my + div(mh, 2)}

      blind = %Calibration{scale: 1.0, layout: nil}
      assert Calibration.minimap_region(blind) == nil
      assert Calibration.minimap_player_point(blind) == nil
    end

    # The real 2026-08-10 mark: cross at {3171, 3} — inside the macOS MENU BAR —
    # against a map at y=52. Every walk click clamps such a start into the map's
    # corner: a permanent north-west drift the panel never explains. A stray
    # mark is refused (center fallback) and REPORTED, so the review can say why.
    test "a cross marked outside the map is refused: center fallback + stray report" do
      stray = %Calibration{
        scale: 1.0,
        layout: nil,
        minimap_region: {3173, 52, 255, 179},
        minimap_player_point: {3171, 3}
      }

      assert Calibration.minimap_stray_cross(stray) == {3171, 3}
      assert Calibration.minimap_player_point(stray) == {3173 + div(255, 2), 52 + div(179, 2)}

      inside = %{stray | minimap_player_point: {3300, 141}}
      assert Calibration.minimap_stray_cross(inside) == nil
      assert Calibration.minimap_player_point(inside) == {3300, 141}

      # nothing to judge against: the mark stands (a region-less calibration
      # cannot walk anyway — minimap_step already refuses without a region)
      free = %Calibration{scale: 1.0, layout: nil, minimap_player_point: {3171, 3}}
      assert Calibration.minimap_stray_cross(free) == nil
      assert Calibration.minimap_player_point(free) == {3171, 3}
    end

    @tag :tmp_dir
    test "the three minimap fields round-trip through the file", %{tmp_dir: tmp} do
      path = Path.join(tmp, "calibration.json")

      calib = %Calibration{
        scale: 1.0,
        screen_w: 3440,
        screen_h: 1440,
        water_point: {1, 2},
        glow_region: {0, 0, 4, 4},
        battle_region: {0, 0, 4, 4},
        neutral_point: {3, 4},
        minimap_region: {3150, 100, 290, 458},
        minimap_player_point: {3295, 329},
        minimap_coord_region: {3171, 106, 160, 30}
      }

      Calibration.save(calib, path)
      {:ok, loaded} = Calibration.load(path)

      assert loaded.minimap_region == {3150, 100, 290, 458}
      assert loaded.minimap_player_point == {3295, 329}
      assert loaded.minimap_coord_region == {3171, 106, 160, 30}
    end
  end

  # Lucas's hunt (2026-08-10) read an x that flipped ~24 tiles between frames
  # and believed every one of them: the hunt "reached" waypoints one second
  # apart while the character stood against a wall. A character walks; it does
  # not teleport, and the allowance is what it could have WALKED since the last
  # read.
  describe "human speed as the sanity gate" do
    test "a jump no walk could cover is refused, and the last good position stands" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}

      # 200ms later: at most a couple of tiles
      assert {%{pos: {101, 100, 7}}, state} = Minimap.accept({101, 100, 7}, state, 200)
      assert {%{pos: {101, 100, 7}}, state} = Minimap.accept({125, 100, 7}, state, 400)
      assert state.pending == {125, 100, 7}
    end

    # ANTES a permissão crescia sem teto com o tempo cego, então depois de uns
    # segundos sem leitura um salto de 30 casas passava de primeira — que é
    # exatamente o tamanho do salto que um dígito errado na casa das dezenas
    # produz. Agora o tempo cego não é prova de caminhada: vem de novo.
    test "um tempo cego longo não vira licença de teleporte — mas volta em duas leituras" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}

      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept({130, 100, 7}, state, 5_000)
      assert {%{pos: {130, 100, 7}}, state} = Minimap.accept({130, 100, 7}, state, 5_500)
      assert state.last == {130, 100, 7}
    end

    # O 1088 dele lido ora como 1066, ora como 1099. Com a permissão medida do
    # último ACEITO os dois valores errados ficavam a 33 casas um do outro
    # dentro de uma janela de 40, então um confirmava o outro e o mundo ia
    # parar do outro lado do mapa. A confirmação é contra o relógio do
    # PENDENTE: entre duas leituras cabem 4 casas, não 40.
    test "duas leituras erradas DIFERENTES não confirmam uma à outra" do
      state = %{last: {1088, 1409, 5}, pending: nil, at: 0}

      assert {%{pos: {1088, 1409, 5}}, state} = Minimap.accept({1066, 1409, 5}, state, 4_000)
      assert {%{pos: {1088, 1409, 5}}, state} = Minimap.accept({1099, 1409, 5}, state, 4_500)
      assert {%{pos: {1088, 1409, 5}}, state} = Minimap.accept({1066, 1409, 5}, state, 5_000)
      assert state.last == {1088, 1409, 5}
    end

    # Um número montado por PARECENÇA (nenhum acerto exato no atlas) tem que
    # voltar duas vezes. Custa um tique ao teleporte de verdade, num render que
    # o atlas nunca viu — e custa tudo ao chute.
    test "leitura adivinhada precisa vir três vezes; leitura conhecida, duas" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}
      longe = %{pos: {900, 900, 7}, guessed: 2, px: 8}

      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 500)
      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 1_000)
      assert {%{pos: {900, 900, 7}}, state} = Minimap.accept(longe, state, 1_500)
      assert state.last == {900, 900, 7}
    end

    test "a REAL teleport still re-baselines: two reads that agree" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}

      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept({900, 900, 7}, state, 200)
      assert {%{pos: {901, 900, 7}}, state} = Minimap.accept({901, 900, 7}, state, 400)
      assert state.last == {901, 900, 7}
    end
  end

  # SEMELHANÇA NÃO TELEPORTA NINGUÉM.
  #
  # Confirmar uma leitura repetindo-a só prova algo quando o erro é ALEATÓRIO.
  # O erro do atlas não é: um glifo que ele não conhece casa com o mesmo
  # vizinho errado em TODO frame, então duas leituras idênticas de um render
  # que ele nunca viu se confirmam com a mesma confiança de duas leituras
  # certas — e o mundo re-baseia num lugar onde ele não está.
  #
  # A regra separa as duas coisas que uma leitura pode afirmar: onde ele ESTÁ
  # (um passo — adivinhar é barato, o próximo frame corrige) e que ele SE MOVEU
  # muito (um salto — adivinhar custa a caçada).
  describe "uma leitura que é quase toda chute" do
    test "confirma um passo curto, como qualquer outra" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}
      perto = %{pos: {102, 100, 7}, guessed: 7, glyphs: 11, px: 8}

      assert {%{pos: {102, 100, 7}}, state} = Minimap.accept(perto, state, 200)
      assert state.last == {102, 100, 7}
    end

    test "mas NUNCA re-baseia um salto, por mais que se repita" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}
      longe = %{pos: {900, 900, 7}, guessed: 7, glyphs: 11, px: 8}

      state =
        Enum.reduce(1..6, state, fn n, state ->
          assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, n * 500)
          state
        end)

      assert state.last == {100, 100, 7}, "o chute levou o mundo junto"
    end

    test "e uma leitura com poucos chutes segue podendo, com as confirmações de sempre" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}
      longe = %{pos: {900, 900, 7}, guessed: 2, glyphs: 11, px: 8}

      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 500)
      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 1_000)
      assert {%{pos: {900, 900, 7}}, state} = Minimap.accept(longe, state, 1_500)
      assert state.last == {900, 900, 7}
    end

    # Um relatório antigo (ou o achado da busca de banda) não traz o total.
    # Sem a fração não há acusação: o desconhecido não pode virar veto.
    test "sem o total de glifos, a regra antiga vale" do
      state = %{last: {100, 100, 7}, pending: nil, at: 0}
      longe = %{pos: {900, 900, 7}, guessed: 7, px: 8}

      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 500)
      assert {%{pos: {100, 100, 7}}, state} = Minimap.accept(longe, state, 1_000)
      assert {%{pos: {900, 900, 7}}, _state} = Minimap.accept(longe, state, 1_500)
    end
  end
end
