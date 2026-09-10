defmodule Pokex.Vision.ColorRulesTest do
  use ExUnit.Case, async: false

  alias Pokex.Vision.ColorRules

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    :persistent_term.erase({ColorRules, :cache})
    on_exit(fn -> Pokex.TestHome.restore() end)
    :ok
  end

  defp regra(name \\ "Electrode shiny") do
    {:ok, entry} =
      ColorRules.add(%{
        "name" => name,
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}]
      })

    entry
  end

  # Shiny e chefe são a MESMA criatura neste jogo (01/09), então não há tipo a
  # escolher — e um arquivo escrito quando havia continua lendo.
  test "an old rule with a kind field on disk keeps working" do
    File.mkdir_p!(Path.dirname(ColorRules.file()))

    File.write!(
      ColorRules.file(),
      Jason.encode!([
        %{
          "slug" => "velha",
          "name" => "Chefe da dungeon",
          "kind" => "chefe",
          "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}],
          "min_px" => 30,
          "min_cell_px" => 6,
          "enabled" => true,
          "proven" => %{"floor_px" => 2, "at" => "2026-09-01T00:00:00Z"}
        }
      ])
    )

    :persistent_term.erase({ColorRules, :cache})

    assert [%{slug: "velha", name: "Chefe da dungeon", min_px: 30}] = ColorRules.armed()
  end

  test "teaching stores, listing returns, the slug is unique" do
    a = regra()
    b = regra()
    assert a["slug"] == "electrode-shiny"
    assert b["slug"] == "electrode-shiny-2"
    assert length(ColorRules.list()) == 2
  end

  test "a new rule is NOT armed: without noise proof it does not enter the watcher" do
    regra()
    assert ColorRules.armed() == []
  end

  test "proven and on, it arms, with the compiled colours ready to scan" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)

    assert [%{slug: ^slug, min_px: 25, specs: [_spec]}] = ColorRules.armed()
  end

  test "turning off disarms without erasing" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)
    :ok = ColorRules.set_enabled(slug, false)

    assert ColorRules.armed() == []
    assert [%{"enabled" => false}] = ColorRules.list()
  end

  test "touching the colours INVALIDATES the proof: new tolerance, new ground" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)

    :ok =
      ColorRules.update(slug, %{
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 25, "tol_sv" => 40}]
      })

    assert ColorRules.armed() == []
    assert [%{"proven" => nil}] = ColorRules.list()
  end

  # O ARQUIVO É DELE. Uma entrada torta derrubava a leitura inteira, e junto
  # com ela a guarda e as duas telas — a página onde ele arrumaria o estrago
  # não abria mais.
  test "a broken entry on disk is dropped and the sound ones still load" do
    File.mkdir_p!(Path.dirname(ColorRules.file()))

    File.write!(
      ColorRules.file(),
      Jason.encode!([
        %{"slug" => "sem-liga", "name" => "Sem liga", "colors" => [%{"rgb" => [1, 2, 3]}]},
        %{"slug" => "sem-cor", "name" => "Sem cor", "colors" => [%{"tol_h" => 12}]},
        %{"name" => "Sem slug", "colors" => [%{"rgb" => [1, 2, 3]}]},
        "isto nem é um mapa",
        %{
          "slug" => "boa",
          "name" => "Charizard preto",
          "colors" => [%{"dark" => 40, "spread" => 10}],
          "min_px" => 300,
          "enabled" => true,
          "proven" => %{"floor_px" => 10}
        }
      ])
    )

    # "sem-cor" some inteira: uma regra sem uma única cor legível não procura nada
    assert Enum.map(ColorRules.list(), & &1["slug"]) == ["sem-liga", "boa"]
    assert [%{"enabled" => false}, _boa] = ColorRules.list()
    assert [%{slug: "boa", min_px: 300}] = ColorRules.armed()
  end

  test "half a proof is no proof: the rule loads unproven instead of crashing" do
    File.mkdir_p!(Path.dirname(ColorRules.file()))

    File.write!(
      ColorRules.file(),
      Jason.encode!([
        %{
          "slug" => "meia-prova",
          "name" => "Meia prova",
          "colors" => [%{"rgb" => [40, 160, 60]}],
          "enabled" => true,
          "proven" => %{"at" => "2026-09-09T00:00:00Z"}
        }
      ])
    )

    assert [%{"proven" => nil}] = ColorRules.list()
    assert ColorRules.armed() == []
  end

  # PIXEL NÃO DIZ NADA A ELE, tile diz. E um gatilho que nenhum bicho alcança é
  # uma regra provada, armada e muda: as duas regras do Charizard dele pediam
  # 14,6 e 6,0 tiles de cor sólida na tela.
  describe "the ruler in tiles" do
    test "counts the trigger in the square he sees, not in pixels" do
      # tile de 151 pontos numa tela sem ampliação: 22.801 px por tile
      assert_in_delta ColorRules.tiles(22_801, 151, 1.0), 1.0, 0.01
      assert_in_delta ColorRules.tiles(332_835, 151, 1.0), 14.6, 0.1

      # a mesma cena no notebook: tile menor, mesma leitura em tiles
      assert_in_delta ColorRules.tiles(4 * 36 * 36, 36, 1.0), 4.0, 0.01

      # a ampliação da tela conta: o mesmo tile rende quatro vezes mais pixels
      assert_in_delta ColorRules.tiles(4 * 22_801, 151, 2.0), 1.0, 0.01
    end

    test "past the size of a creature the trigger is out of reach" do
      um_tile = 151 * 151

      refute ColorRules.unreachable?(um_tile, 151, 1.0)
      refute ColorRules.unreachable?(4 * um_tile, 151, 1.0)
      assert ColorRules.unreachable?(5 * um_tile, 151, 1.0)
      # o gatilho real da regra dele
      assert ColorRules.unreachable?(332_835, 151, 1.0)
    end
  end

  # ZERO É UMA ESCOLHA. O tom preto apertado até a banda mais justa (o corpo do
  # bicho dele mediu mediana 0) era salvo três vezes mais largo do que a prévia
  # que ele acabara de aprovar na tela.
  test "a spread of zero is kept, not rewritten to the default" do
    {:ok, entry} =
      ColorRules.add(%{
        "name" => "Preto",
        "colors" => [%{"dark" => 40, "spread" => 0, "rgb" => [8, 8, 8]}]
      })

    assert [%{"spread" => 0}] = entry["colors"]
    assert [%{"colors" => [%{"spread" => 0}]}] = ColorRules.list()
  end

  # UMA PROVA É DE UM MUNDO. As caixas do HUD são pixels do QUADRO e o chão é uma
  # CONTAGEM: os dois quadruplicam quando o backend de captura troca e serve a
  # mesma região com o dobro da largura. A região não muda, e a porteira deixava
  # passar.
  test "a proof measured at another scale does not fit" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3, [], {0, 0, 100, 100}, 1.0)

    [armada] = ColorRules.armed()

    assert ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 1.0})
    refute ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 2.0})
    refute ColorRules.proof_fits?(armada, {{0, 0, 200, 200}, 1.0})
  end

  test "a proof from before the scale field is still trusted" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3, [], {0, 0, 100, 100})

    [armada] = ColorRules.armed()

    assert ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 2.0})
  end

  test "apagar apaga; apagar de novo reclama" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.delete(slug)
    assert ColorRules.list() == []
    assert {:error, :not_found} = ColorRules.delete(slug)
  end
end
