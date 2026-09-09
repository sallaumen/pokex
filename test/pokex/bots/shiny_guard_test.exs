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
    SettingsStash.stash!(shiny_guard_enabled: true, special_color_scan_ms: 50)

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
  defp frame_com_mancha({_x, _y, w, h}) do
    frame(w, h, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])
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
    assert_receive {:combat_log, :macro, texto}, 500
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

    # the patch is 14x14 at (10,10) in the frame: its centre is (17,17) from the region origin
    {rx, ry, _w, _h} = region
    assert_in_delta sx, rx + 17, 4
    assert_in_delta sy, ry + 17, 4

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
