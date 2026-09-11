defmodule Pokex.Bots.Catcher.ShinyAimTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.ShinyAim
  alias Pokex.Perception.WorldState
  alias Pokex.Vision.{ColorMark, Frame}

  # the green of the shiny Electrode from the 01/09 screenshot
  @verde {40, 160, 60}
  @region {100, 100, 300, 300}
  @tile 40

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

  # a 14x14 blob at (10,10) of the frame: centre of mass by 8px cells lands at (16,16),
  # screen {116, 116}
  defp frame_com_mancha, do: frame(300, 300, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])

  # uma mancha do tamanho da janela do acervo, pra a assinatura casar
  defp frame_com_corpo, do: frame(300, 300, {40, 40, 40}, [{{8, 8, 32, 32}, @verde}])

  # a lava dele: uma mancha grande da mesma cor, longe do bicho
  defp frame_com_duas_manchas,
    do:
      frame(300, 300, {40, 40, 40}, [
        {{10, 10, 60, 60}, @verde},
        {{200, 200, 14, 14}, @verde}
      ])

  defp rules do
    [
      %{
        slug: "electrode-shiny",
        name: "Electrode shiny",
        min_px: 50,
        min_cell_px: 6,
        specs: ColorMark.compile([%{rgb: @verde, tol_h: 12, tol_sv: 30}])
      }
    ]
  end

  defp crowd(hostiles, pet \\ nil, passive \\ []),
    do: %{
      read?: true,
      hostiles: Enum.map(hostiles, &%{point: &1}),
      pet: pet && %{point: pet},
      passive: length(passive),
      passive_points: passive
    }

  test "a blob with no body near it is a corpse candidate in screen points" do
    assert [%{name: "Electrode shiny", px: px, point: {sx, sy}, in_frame: {fx, fy}}] =
             ShinyAim.judge(frame_com_mancha(), @region, rules(), [], crowd([{300, 300}]), @tile)

    assert px >= 50
    assert_in_delta sx, 117, 2
    assert_in_delta sy, 117, 2
    assert_in_delta fx, 17, 2
    assert_in_delta fy, 17, 2
  end

  # A BOLA NO CENTRO DO CORPO. O alvo era o centro de MASSA dos pixels casados:
  # com a cor casando so um lado da sprite, a massa puxa o alvo pra esse lado e a
  # bola cai fora do bicho.
  test "the ball aims at the middle of the body, not at the mass of matched pixels" do
    # uma sprite cuja cor casa so na METADE ESQUERDA: massa a esquerda, corpo no meio
    meia =
      frame(300, 300, {40, 40, 40}, [
        {{100, 100, 16, 64}, @verde},
        {{116, 100, 48, 64}, {40, 40, 40}}
      ])

    assert [%{point: {sx, _sy}, massa: {mx, _my}, in_frame: {fx, _fy}}] =
             ShinyAim.judge(meia, @region, rules(), [], crowd([]), @tile)

    # a caixa e o alvo tem que coincidir; a massa e outra coisa
    assert fx == sx - elem(@region, 0)
    assert is_integer(mx)
  end

  # A LISTA NEGRA. O veto por corpo ja existia no acervo, mas so era lido na
  # varredura por sprite — e quem joga bola na cacada e este caminho, que nunca
  # consultou o acervo. Um corpo que ele desligou levava bola do mesmo jeito.
  @tag :tmp_dir
  test "a corpse he switched off is refused by the colour aim too", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    Pokex.SettingsStash.stash!(corpse_sprite_box_px: 24, corpse_match_min_similarity: 0.6)

    # ensina a mancha COMO CORPO e desliga: e a lista negra
    recorte = %Frame{width: 24, height: 24, rgba: :binary.copy(<<40, 160, 60, 255>>, 24 * 24)}
    {:ok, _n} = Pokex.Bots.Catcher.CorpseLibrary.add("Corpo rosa", recorte)
    [%{"slug" => slug}] = Pokex.Bots.Catcher.CorpseLibrary.list()
    :ok = Pokex.Bots.Catcher.CorpseLibrary.set_enabled(slug, false)

    assert ShinyAim.judge(frame_com_corpo(), @region, rules(), [], crowd([]), @tile) == []
  end

  # ...EXCEPT THE CREATURE THE RULE IS FOR. His "Shiny Golem" corpse photos fire
  # on the HUD, so he switches them off - and switched off they scored 0.97 on the
  # real corpse and refused the ball the colour rule of the same name exists for.
  @tag :tmp_dir
  test "a corpse switched off under the colour rule's own name is not a veto", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    Pokex.SettingsStash.stash!(corpse_sprite_box_px: 24, corpse_match_min_similarity: 0.6)

    recorte = %Frame{width: 24, height: 24, rgba: :binary.copy(<<40, 160, 60, 255>>, 24 * 24)}
    {:ok, _n} = Pokex.Bots.Catcher.CorpseLibrary.add("electrode SHINY ", recorte)
    [%{"slug" => slug}] = Pokex.Bots.Catcher.CorpseLibrary.list()
    :ok = Pokex.Bots.Catcher.CorpseLibrary.set_enabled(slug, false)

    assert [%{name: "Electrode shiny"}] =
             ShinyAim.judge(frame_com_corpo(), @region, rules(), [], crowd([]), @tile)
  end

  @tag :tmp_dir
  test "a corpse still switched ON does not veto anything", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    Pokex.SettingsStash.stash!(corpse_sprite_box_px: 24, corpse_match_min_similarity: 0.6)

    recorte = %Frame{width: 24, height: 24, rgba: :binary.copy(<<40, 160, 60, 255>>, 24 * 24)}
    {:ok, _n} = Pokex.Bots.Catcher.CorpseLibrary.add("Corpo rosa", recorte)

    assert [_um] = ShinyAim.judge(frame_com_corpo(), @region, rules(), [], crowd([]), @tile)
  end

  # NENHUMA MANCHA MAIOR QUE UM BICHO. O corte por tamanho vinha DEPOIS do teto
  # de candidatos, entao um aglomerado de cenario nao so levava bola: ocupava as
  # vagas e EXPULSAVA o bicho da lista.
  test "a blob bigger than a creature is refused, and frees the slot for the creature" do
    # tile 40 no teste: o teto sao 3 tiles de lado = 120px
    cenario = frame(300, 300, {40, 40, 40}, [{{0, 0, 200, 200}, @verde}])

    assert ShinyAim.judge(cenario, @region, rules(), [], crowd([]), @tile) == []
  end

  test "the ceiling counts only creature-sized blobs" do
    Pokex.SettingsStash.stash!(shiny_aim_max_candidates: 1)

    # um borrao de cenario ENORME primeiro (a lista vem ordenada pela maior) e o
    # bicho depois: com o corte antes do teto, quem fica e o bicho
    dois =
      frame(400, 400, {40, 40, 40}, [{{0, 0, 200, 200}, @verde}, {{250, 250, 30, 30}, @verde}])

    assert [%{px: px}] = ShinyAim.judge(dois, @region, rules(), [], crowd([]), @tile)
    assert px < 2_000, "sobrou o borrao de cenario, nao o bicho"
  end

  # A LAVA MAIOR TAPAVA O BICHO. Pegando só a maior mancha, o shiny dois tiles ao
  # lado não ficava "abaixo do limiar" — ficava sem ser olhado.
  test "every blob past the trigger is a candidate, up to the ceiling" do
    candidatos = ShinyAim.judge(frame_com_duas_manchas(), @region, rules(), [], crowd([]), @tile)

    assert length(candidatos) == 2
    # a maior primeiro: a fila da bola segue a força da prova
    assert [%{px: maior}, %{px: menor}] = candidatos
    assert maior > menor
  end

  # E O TETO, porque cada alvo é uma bola.
  test "the ceiling caps how many balls one scan can queue" do
    Pokex.SettingsStash.stash!(shiny_aim_max_candidates: 1)

    assert [_uma] =
             ShinyAim.judge(frame_com_duas_manchas(), @region, rules(), [], crowd([]), @tile)
  end

  # O RENASCIDO É UM CORPO VIVO. A lista de batalha não o carrega e `hostiles` o
  # separa, então a mancha de cor em cima de um bicho VIVO passava por corpo — e
  # a bola voava nele. Pior: gastas as bolas, o ponto ficava vetado por 45 s e o
  # corpo de verdade daquele bicho, no mesmo tile, não levava bola nenhuma.
  test "a respawned creature is a live body and fences the blob out" do
    assert ShinyAim.judge(
             frame_com_mancha(),
             @region,
             rules(),
             [],
             crowd([], nil, [{117, 117}]),
             @tile
           ) == []
  end

  test "a blob with a hostile body within a tile is a living creature, not a corpse" do
    assert [] =
             ShinyAim.judge(frame_com_mancha(), @region, rules(), [], crowd([{140, 130}]), @tile)
  end

  test "a blob with the pet's body within a tile is not a corpse" do
    assert [] =
             ShinyAim.judge(
               frame_com_mancha(),
               @region,
               rules(),
               [],
               crowd([], {110, 150}),
               @tile
             )
  end

  test "without an eye reading nothing is a corpse" do
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), [], nil, @tile)
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), [], %{read?: false}, @tile)
  end

  test "a blob inside a forbidden box is not seen" do
    forbidden = [{0, 0, 40, 40}]
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), forbidden, crowd([]), @tile)
  end

  test "steady keeps only candidates seen on the previous scan" do
    now = %{name: "x", px: 60, point: {117, 117}, in_frame: {17, 17}}
    assert [] = ShinyAim.steady([now], [], 12)
    assert [^now] = ShinyAim.steady([now], [%{now | point: {120, 115}}], 12)
    assert [] = ShinyAim.steady([now], [%{now | point: {160, 115}}], 12)
  end

  test "obs speaks the Logic's contract" do
    cand = %{name: "Electrode shiny", px: 60, point: {117, 117}, in_frame: {17, 17}}

    assert %{
             scanning?: true,
             source: :shiny_aim,
             corpses: [{117, 117}],
             known: %{{117, 117} => %{name: "Electrode shiny", px: 60}},
             region: @region,
             captured_at: 5
           } = ShinyAim.obs([cand], @region, 5)
  end

  # NADA VIVO NA TELA (09/09, ordem dele): "quando tá vivo temos que matar e
  # quando tá morto temos que capturar". A cerca da barra sozinha mentiu — no
  # quadro real dele o shiny preto de pé não tinha barra nenhuma pro olho achar.
  describe "the screen has to be empty of the living" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      :ets.delete(:pokex_world, :situation)

      on_exit(fn ->
        :ets.delete(:pokex_world, :situation)
        Pokex.TestHome.restore()
      end)

      Pokex.Calibration.save(%Pokex.Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        tile_px: 40,
        water_point: {400, 300},
        glow_region: {0, 0, 20, 20},
        battle_region: {0, 0, 80, 400},
        neutral_point: {500, 500},
        player_point: {500, 350}
      })

      :ok
    end

    defp look(enemies) do
      ShinyAim.scan(
        capture: fn {_x, _y, w, h}, _name ->
          {:ok, frame(w, h, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])}
        end,
        crowd: crowd([{3_000, 3_000}]),
        enemies: enemies
      )
    end

    test "an enemy still listed blocks the whole look" do
      assert %{scanning?: false, reason: {:alive_on_screen, 2}} = look(2)
    end

    test "an empty list lets the look happen" do
      assert %{scanning?: true} = look(0)
    end

    # Sem quadro do cérebro não se sabe se há alguém de pé — e não saber aqui é
    # não jogar: a bola é mais cara que a foto.
    test "no picture at all is not a corpse either" do
      assert %{scanning?: false, reason: :no_picture} =
               ShinyAim.scan(
                 capture: fn {_x, _y, w, h}, _name ->
                   {:ok, frame(w, h, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])}
                 end,
                 crowd: crowd([])
               )
    end

    test "the brain's own count is what answers, and it is read from the blackboard" do
      WorldState.put(:situation, %{enemies: 0}, System.monotonic_time(:millisecond))

      assert %{scanning?: true} =
               ShinyAim.scan(
                 capture: fn {_x, _y, w, h}, _name ->
                   {:ok, frame(w, h, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])}
                 end,
                 crowd: crowd([{3_000, 3_000}])
               )

      WorldState.put(:situation, %{enemies: 3}, System.monotonic_time(:millisecond))

      assert %{scanning?: false, reason: {:alive_on_screen, 3}} =
               ShinyAim.scan(
                 capture: fn {_x, _y, w, h}, _name ->
                   {:ok, frame(w, h, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])}
                 end,
                 crowd: crowd([{3_000, 3_000}])
               )
    end
  end
end
