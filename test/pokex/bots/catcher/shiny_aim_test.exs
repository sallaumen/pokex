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
