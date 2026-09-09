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

  test "apagar apaga; apagar de novo reclama" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.delete(slug)
    assert ColorRules.list() == []
    assert {:error, :not_found} = ColorRules.delete(slug)
  end
end
