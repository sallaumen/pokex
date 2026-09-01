defmodule Pokex.Bots.ShinyGuardTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Pokedex.ShinyLog
  alias Pokex.SettingsStash
  alias Pokex.Vision.{ColorRules, Frame}

  @moduletag :tmp_dir

  # o verde do Electrode shiny da print de 01/09
  @verde {40, 160, 60}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    :persistent_term.erase({ColorRules, :cache})
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
            "kind" => "shiny",
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

  test "duas varreduras com a mancha REGISTRAM: troféu, diário e {:shiny_seen}", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, %{px: px, name: "Electrode shiny", kind: "shiny"}}, 2_000
    assert px >= 50
    assert_receive {:combat_log, :macro, texto}, 500
    assert texto =~ "Electrode shiny"
    assert [%{outcome: "seen", note: "Electrode shiny"}] = ShinyLog.entries()
  end

  test "UMA varredura só não registra — a confirmação pede a segunda", %{region: region} do
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

  test "regra sem prova de ruído NÃO varre", %{region: region} do
    {:ok, _} =
      ColorRules.add(%{
        "name" => "Sem prova",
        "kind" => "shiny",
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
        "min_px" => 50
      })

    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")
    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "o refratário segura a metralhadora: um registro por minuto por regra", %{region: region} do
    regra_provada()
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    assert_receive {:shiny_seen, _}, 2_000
    refute_receive {:shiny_seen, _}, 1_000
  end

  test "a mancha DENTRO da caixa do próprio pokémon não conta", %{region: region} do
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

  test "guarda desligada não varre nem registra", %{region: region} do
    regra_provada()
    Pokex.Settings.put(:shiny_guard_enabled, false)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "shiny")

    start_guard(fn _region, _name -> {:ok, frame_com_mancha(region)} end)

    refute_receive {:shiny_seen, _}, 1_000
  end

  test "um kill logo depois do avistamento fecha o troféu como killed", %{region: region} do
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

  test "status expõe o estado do vigia" do
    regra_provada()
    limpo = frame(64, 64, {40, 40, 40}, [])
    guard = start_guard(fn _region, _name -> {:ok, limpo} end)

    assert %{enabled?: true, armed_rules: 1, pending?: false} = ShinyGuard.status(guard)
  end
end
