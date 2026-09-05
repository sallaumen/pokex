defmodule Pokex.Bots.ShinyGuardTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
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
      player_point: {500, 350}
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
end
