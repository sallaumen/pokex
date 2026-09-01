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
        "kind" => "shiny",
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 12, "tol_sv" => 30}]
      })

    entry
  end

  test "ensinar guarda, listar devolve, o slug é único" do
    a = regra()
    b = regra()
    assert a["slug"] == "electrode-shiny"
    assert b["slug"] == "electrode-shiny-2"
    assert length(ColorRules.list()) == 2
  end

  test "regra nova NÃO está armada: sem prova de ruído não entra no vigia" do
    regra()
    assert ColorRules.armed() == []
  end

  test "provada e ligada, arma — com as cores compiladas prontas pra varrer" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)

    assert [%{slug: ^slug, min_px: 25, specs: [_spec]}] = ColorRules.armed()
  end

  test "desligar desarma sem apagar" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)
    :ok = ColorRules.set_enabled(slug, false)

    assert ColorRules.armed() == []
    assert [%{"enabled" => false}] = ColorRules.list()
  end

  test "mexer nas cores INVALIDA a prova — tolerância nova, chão novo" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.mark_proven(slug, 3)

    :ok =
      ColorRules.update(slug, %{
        "colors" => [%{"rgb" => [40, 160, 60], "tol_h" => 25, "tol_sv" => 40}]
      })

    assert ColorRules.armed() == []
    assert [%{"proven" => nil}] = ColorRules.list()
  end

  test "apagar apaga; apagar de novo reclama" do
    %{"slug" => slug} = regra()
    :ok = ColorRules.delete(slug)
    assert ColorRules.list() == []
    assert {:error, :not_found} = ColorRules.delete(slug)
  end
end
