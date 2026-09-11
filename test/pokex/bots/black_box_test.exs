defmodule Pokex.Bots.BlackBoxTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.BlackBox
  alias Pokex.Calibration
  alias Pokex.Vision.Frame

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      tile_px: 100,
      player_point: {500, 350},
      water_point: {400, 300},
      glow_region: {0, 0, 20, 20},
      battle_region: {900, 0, 80, 400},
      neutral_point: {500, 500}
    })

    Phoenix.PubSub.subscribe(Pokex.PubSub, "catcher")
    :ok
  end

  defp frame(w, h),
    do: %Frame{width: w, height: h, rgba: :binary.copy(<<40, 40, 40, 255>>, w * h)}

  defp start_box(opts \\ []) do
    capture = fn {_x, _y, w, h}, _name -> {:ok, frame(w, h)} end

    start_supervised!(
      {BlackBox, [name: nil, active: true, capture: capture, quiet_to_close_ms: 200] ++ opts}
    )
  end

  defp orders(why, extra \\ %{}),
    do:
      Map.merge(
        %{phase: :engaged, route: :hold, revive: :hold, fire: :free, why: why, capture: :none},
        extra
      )

  defp picture(enemies), do: %{enemies: enemies, rows: enemies, own_hp: 80, named: []}

  defp incidents(tmp), do: Path.join([tmp, "captures", "incidents"])

  @tag :tmp_dir
  test "the survivor of the chain opens an episode: a whole frame, the film, the manifest", %{
    tmp_dir: tmp
  } do
    box = start_box()

    send(
      box,
      {:engine, picture(2),
       orders("combo acabou — sobrevivente da corrente (1 de 6): revive e de novo em cima")}
    )

    assert_receive {:catcher_log, :macro, "captura: 📼 caixa-preta gravando (sobrevivente)" <> _},
                   1_000

    # the line goes out before the frame is written: wait for the mailbox to drain
    :sys.get_state(box)
    assert [dir] = File.ls!(incidents(tmp))
    assert dir =~ "-sobrevivente"
    files = File.ls!(Path.join(incidents(tmp), dir))
    assert "000-abertura.raw.z" in files
    assert "manifest.jsonl" in files

    # a whole frame at the revive, the film every 2 s, the ball's moment
    send(box, {:engine, picture(2), orders("revive agora", %{revive: :now})})
    send(box, {:engine, picture(0), orders("hora da bola — segurando", %{phase: :capturing})})
    :sys.get_state(box)

    files = File.ls!(Path.join(incidents(tmp), dir))
    assert Enum.any?(files, &String.ends_with?(&1, "-revive.raw.z"))
    assert Enum.any?(files, &String.ends_with?(&1, "-hora-da-bola.raw.z"))

    [first | _] =
      File.read!(Path.join([incidents(tmp), dir, "manifest.jsonl"]))
      |> String.split("\n", trim: true)

    line = Jason.decode!(first)
    assert line["tag"] == "abertura"
    assert line["frame"]["ok?"] == true
    assert line["orders"]["why"] =~ "sobrevivente"
    assert line["picture"]["enemies"] == 2
    assert Map.has_key?(line, "crowd") and Map.has_key?(line, "rules")

    # the frame on disk is the arena, zlib-packed PXRW
    packed = File.read!(Path.join([incidents(tmp), dir, "000-abertura.raw.z"]))
    assert <<"PXRW", 1, _::binary>> = :zlib.uncompress(packed)
  end

  @tag :tmp_dir
  test "a clean screen after the ball's moment closes it, with the count", %{tmp_dir: tmp} do
    box = start_box()

    send(
      box,
      {:engine, picture(1), orders("sobrevivente da corrente (2 de 6): revive e de novo em cima")}
    )

    send(box, {:engine, picture(0), orders("hora da bola", %{phase: :capturing})})
    assert_receive {:catcher_log, :macro, "captura: 📼 caixa-preta gravando" <> _}, 1_000

    Process.sleep(250)

    send(
      box,
      {:engine, picture(0),
       orders("nada aqui — seguindo a rota", %{phase: :travelling, route: :go})}
    )

    assert_receive {:catcher_log, :macro, "captura: 📼 caixa-preta: " <> resto}, 1_000
    assert resto =~ "tela limpa"
    assert BlackBox.status(box) == nil

    [dir] = File.ls!(incidents(tmp))

    assert Enum.any?(
             File.ls!(Path.join(incidents(tmp), dir)),
             &String.ends_with?(&1, "-fim.raw.z")
           )
  end

  @tag :tmp_dir
  test "the guard's sighting and the fallen bar open it too; a ball inside is a whole frame", %{
    tmp_dir: tmp
  } do
    box = start_box()

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "shiny",
      {:shiny_on_screen, %{vistos: [%{name: "Shiny Golem", px: 300, point: {1, 1}}]}}
    )

    assert_receive {:catcher_log, :macro, "captura: 📼 caixa-preta gravando (shiny)" <> _}, 1_000

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "catcher",
      {:catcher_log, :macro, "captura: 🌟 bola na âncora do Shiny Golem em 10,10"}
    )

    :sys.get_state(box)

    [dir] = File.ls!(incidents(tmp))

    assert Enum.any?(
             File.ls!(Path.join(incidents(tmp), dir)),
             &String.ends_with?(&1, "-bola.raw.z")
           )
  end

  @tag :tmp_dir
  test "only the last six episodes are kept", %{tmp_dir: tmp} do
    root = incidents(tmp)
    File.mkdir_p!(root)
    for n <- 1..7, do: File.mkdir_p!(Path.join(root, "20260911T0#{n}0000Z-velho"))

    box = start_box()
    send(box, {:engine, picture(3), orders("sobrevivente da corrente (1 de 6)")})
    assert_receive {:catcher_log, :macro, "captura: 📼 caixa-preta gravando" <> _}, 1_000
    :sys.get_state(box)

    assert length(File.ls!(root)) == 6
  end

  @tag :tmp_dir
  test "shrinking halves the frame" do
    small = BlackBox.shrink(frame(6, 4), 2)
    assert {small.width, small.height, byte_size(small.rgba)} == {3, 2, 3 * 2 * 4}
  end
end
