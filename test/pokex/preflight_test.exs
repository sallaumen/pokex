defmodule Pokex.PreflightTest do
  use ExUnit.Case, async: false
  alias Pokex.{Calibration, Preflight}

  @tag :tmp_dir
  test "fails without calibration, passes with it (non-mac rig skips OS checks)", %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    assert {:error, msgs} = Preflight.run(Pokex.Rig.Fake)
    assert Enum.any?(msgs, &(&1 =~ "calibração"))

    calib = %Calibration{
      scale: 2.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {0, 0, 8, 8},
      neutral_point: {1, 1}
    }

    Calibration.save(calib)

    # …and still refuses until somebody on the field owns a bar and its jobs
    assert {:error, [msg]} = Preflight.run(Pokex.Rig.Fake)
    assert msg =~ "nenhum pokémon escolhido"

    Pokex.TeamFixtures.ready!()
    assert Preflight.run(Pokex.Rig.Fake) == :ok
  end

  # The shared bar is gone (see `Pokex.Bots.ActiveBar`): a bot that starts
  # without the pokémon on the field carrying its own bar and the job of every
  # key is a bot reading another creature's icons and rotating keys nobody
  # classified. "Temos que até bloquear de funcionar se não tiver corretamente
  # configurado para o pokémon ativo" (Lucas, 2026-08-24).
  describe "o pokémon em campo" do
    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Pokex.TestHome.restore() end)

      Calibration.save(%Calibration{
        scale: 1.0,
        screen_w: 1000,
        screen_h: 700,
        water_point: {1, 1},
        glow_region: {0, 0, 8, 8},
        battle_region: {0, 0, 8, 8},
        neutral_point: {1, 1}
      })

      :ok
    end

    @tag :tmp_dir
    test "sem ninguém escolhido, não começa" do
      assert {:error, msgs} = Preflight.run(Pokex.Rig.Fake)
      assert Enum.any?(msgs, &(&1 =~ "nenhum pokémon escolhido"))
    end

    @tag :tmp_dir
    test "escolhido mas sem barra calibrada, não começa — e diz de quem" do
      {:ok, _} = Pokex.Pokedex.Team.add("Bulbasaur")
      Pokex.Pokedex.Team.set_active("Bulbasaur")

      assert {:error, msgs} = Preflight.run(Pokex.Rig.Fake)
      assert Enum.any?(msgs, &(&1 =~ "Bulbasaur está sem barra de skills calibrada"))
    end

    @tag :tmp_dir
    test "com barra mas com uma tecla sem trabalho, não começa — e diz qual" do
      Pokex.TeamFixtures.ready!("Bulbasaur", count: 4, skills: %{"1" => :aoe, "2" => :single})

      assert {:error, msgs} = Preflight.run(Pokex.Rig.Fake)
      assert Enum.any?(msgs, &(&1 =~ "as teclas 3, 4"))
    end

    @tag :tmp_dir
    test "com tudo configurado, começa" do
      Pokex.TeamFixtures.ready!("Bulbasaur", count: 4)

      assert Preflight.run(Pokex.Rig.Fake) == :ok
    end

    # A DÉCIMA TECLA É O ZERO, e este check contava 1..10. O Dugtrio dele tem os
    # dez slots todos classificados (0–9) e o preflight procurava uma tecla "10"
    # que não existe em barra nenhuma: recusava o arranque PARA SEMPRE, e a
    # caçada bloqueava sem sair do lugar — "nem andar ele andou" (26/08).
    @tag :tmp_dir
    test "uma barra de dez slots começa: a décima tecla é o 0, não o 10" do
      dez = Map.new(~w(1 2 3 4 5 6 7 8 9 0), &{&1, :single})
      Pokex.TeamFixtures.ready!("Dugtrio", count: 10, skills: dez)

      assert Preflight.run(Pokex.Rig.Fake) == :ok
    end

    @tag :tmp_dir
    test "e sem o 0 ela reclama do 0, não de um 10 que não existe" do
      nove = Map.new(~w(1 2 3 4 5 6 7 8 9), &{&1, :single})
      Pokex.TeamFixtures.ready!("Dugtrio", count: 10, skills: nove)

      assert {:error, msgs} = Preflight.run(Pokex.Rig.Fake)
      assert Enum.any?(msgs, &(&1 =~ "a tecla 0"))
      refute Enum.any?(msgs, &(&1 =~ "tecla 10"))
    end
  end

  # THE REFUSAL THAT STOPPED EVERYTHING (2026-08-07). His calibration was saved
  # by ScreenCaptureKit, which answers in POINTS: 1512×982 with scale 1.0. The
  # old check captured with the CLI, which answers in PIXELS (3024×1964), and
  # compared it to `screen_w * scale` = 1512. It never matched, so `start_all`
  # refused every time and nothing ever ran.
  describe "screen_error/2" do
    @sck_calibration %Calibration{scale: 1.0, screen_w: 1512, screen_h: 982}

    test "the screen it was marked on does NOT refuse" do
      assert Preflight.screen_error(@sck_calibration, {:ok, {1512, 982}}) == []
    end

    test "a screen that cannot be measured is NO PROOF, never a refusal" do
      assert Preflight.screen_error(@sck_calibration, :unknown) == []
    end

    test "a genuinely different screen refuses, naming both and where to fix it" do
      assert [msg] = Preflight.screen_error(@sck_calibration, {:ok, {3440, 1440}})
      assert msg =~ "1512×982"
      assert msg =~ "3440×1440"
      assert msg =~ "/calibration"
    end
  end
end
