defmodule Pokex.Bots.BlackBoxTest do
  use ExUnit.Case, async: false

  import Pokex.TestWait

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
  test "records both health readings and the geometry used for the incident", %{tmp_dir: tmp} do
    Pokex.Perception.WorldState.clear()
    on_exit(fn -> Pokex.Perception.WorldState.clear() end)
    at = System.monotonic_time(:millisecond)
    Pokex.Perception.WorldState.put(:player, %{player_hp: 4, readable?: true}, at)
    Pokex.Perception.WorldState.put(:pokemon, %{hp_pct: 100, readable?: true}, at)
    box = start_box()
    send(box, {:engine, picture(1), orders("sobrevivente da corrente (1 de 6)")})
    :sys.get_state(box)
    [dir] = File.ls!(incidents(tmp))

    line =
      Path.join([incidents(tmp), dir, "manifest.jsonl"])
      |> File.read!()
      |> String.split("\n", trim: true)
      |> hd()
      |> Jason.decode!()

    assert line["player"]["player_hp"] == 4
    assert line["pokemon"]["hp_pct"] == 100
    assert line["calibration"]["tile_px"] == 100
    assert line["calibration"]["screen_w"] == 1000
    assert line["calibration"]["player_point"] == [500, 350]
  end

  @tag :tmp_dir
  test "preserves the incident when repeated sightings arrive after the hunt stops", %{
    tmp_dir: tmp
  } do
    box = start_box()
    send(box, {:engine, picture(1), orders("sobrevivente da corrente (1 de 6)")})
    :sys.get_state(box)
    send(box, {:engine, picture(1), orders("sem caçada rodando", %{phase: :idle})})
    :sys.get_state(box)
    assert BlackBox.status(box) == nil
    [original] = File.ls!(incidents(tmp))

    for _ <- 1..8 do
      send(box, {:shiny_on_screen, %{vistos: [%{name: "Shiny", point: {500, 400}}]}})
      send(box, {:engine, picture(1), orders("sem caçada rodando", %{phase: :idle})})
    end

    :sys.get_state(box)
    assert File.ls!(incidents(tmp)) == [original]
    assert BlackBox.status(box) == nil

    send(box, {:engine, picture(1), orders("lutando")})
    send(box, {:shiny_seen, %{name: "Shiny"}})
    :sys.get_state(box)
    assert BlackBox.status(box) != nil
  end

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

  # O QUADRO DEPOIS DA BOLA.
  #
  # "Ele move o mouse mas acho que ta errando o corpo" (13/09) — e nenhum
  # artefato sabia responder. O quadro da borda sai NO arremesso, antes de o
  # cliente desenhar coisa alguma; este sai depois, com a mira anunciada, o
  # ponto pra onde o mouse foi e o CURSOR de verdade — que é o que separa "o
  # mouse não chegou" de "chegou e o jogo ignorou".
  @tag :tmp_dir
  test "the ball earns a second frame, with the aim and the real cursor", %{tmp_dir: tmp} do
    box = start_box()

    send(
      box,
      {:engine, picture(1), orders("sobrevivente da corrente (2 de 6): revive e de novo em cima")}
    )

    :sys.get_state(box)
    send(box, {:catcher_log, :macro, "captura: 🌟 bola em 1418,617"})
    :sys.get_state(box)

    [dir] = File.ls!(incidents(tmp))

    assert Enum.any?(
             File.ls!(Path.join(incidents(tmp), dir)),
             &String.ends_with?(&1, "-bola.raw.z")
           )

    # o quadro atrasado: espera o recado de volta
    assert eventually(
             fn ->
               Enum.any?(
                 File.ls!(Path.join(incidents(tmp), dir)),
                 &String.ends_with?(&1, "-depois-da-bola.raw.z")
               )
             end,
             3_000
           )

    :sys.get_state(box)

    linha =
      Path.join([incidents(tmp), dir, "manifest.jsonl"])
      |> File.read!()
      |> String.split("\n", trim: true)
      |> Enum.map(&Jason.decode!/1)
      |> Enum.find(&(&1["tag"] == "depois-da-bola"))

    assert linha["ball"]["anunciada"] == [1418, 617]
    # a mira desce pro corpo quando a tela é medida, e nunca é um palpite
    assert [_, _] = linha["ball"]["corpo"]
    assert Map.has_key?(linha["ball"], "cursor")
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

    # the clean-screen clock starts when the ball's tick is PROCESSED (after
    # the frames are written), not when it was sent: drain first, then wait
    :sys.get_state(box)
    Process.sleep(300)

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
  test "a revive that did nothing opens it; the aim's closing count is not a ball", %{
    tmp_dir: tmp
  } do
    box = start_box()

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "game",
      {:game_log, :macro,
       "🩸 revive pago e a barra do pokémon NÃO mexeu (52%) — ou a bag está sem revive"}
    )

    assert_receive {:catcher_log, :macro,
                    "captura: 📼 caixa-preta gravando (revive_sem_efeito)" <> _},
                   1_000

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "catcher",
      {:catcher_log, :macro,
       "captura: 🎯 hora da bola — corpo do shiny pela cor: 3 foto(s) — nenhum corpo"}
    )

    :sys.get_state(box)
    [dir] = File.ls!(incidents(tmp))

    refute Enum.any?(
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
