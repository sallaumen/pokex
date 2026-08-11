defmodule PokexWeb.TimersLiveTest do
  # async: false — scopes the global :home_dir env per test.
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Timers.{Store, Timer}

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    File.write!(
      Path.join(tmp, "pokedex.json"),
      JSON.encode!(%{
        "species" => [%{"name" => "Venusaur", "number" => 3, "elements" => ["Grass"]}],
        "lures" => []
      })
    )

    Application.put_env(:pokex, :pokedex_path, Path.join(tmp, "pokedex.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.delete_env(:pokex, :pokedex_path)
      Application.delete_env(:pokex, :home_dir)
    end)

    :ok
  end

  test "a fresh install already has the aura he asked for, and says what it does", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    row = view |> element("#timer-aura-na-mobada") |> render()

    assert row =~ "aura na mobada"
    assert row =~ "8s depois de começar a mobar"
  end

  # The LIST is configuration and must come from the store: it is what makes a
  # timer he just added appear at once, and it is why the page does not go blank
  # just because the fleet is stopped.
  test "the list is what is configured, whatever the worker holds", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/timers")

    assert has_element?(view, "#timer-aura-na-mobada")
    refute html =~ "nada agendado"
  end

  test "scheduling a berry every 55 minutes", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    view
    |> form("#timer-form", %{
      "name" => "berry de XP",
      "trigger" => "every",
      "after" => "55",
      "unit" => "min",
      "category" => "",
      "keys" => "8"
    })
    |> render_submit()

    assert %Timer{trigger: :every, after_ms: 3_300_000, keys: ["8"], category: nil} =
             Enum.find(Store.all(), &(&1.id == "berry-de-xp"))

    assert view |> element("#timer-berry-de-xp") |> render() =~ "a cada 55min"
  end

  test "a job follows the pokémon in the field instead of naming a key", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    view
    |> form("#timer-form", %{
      "name" => "escudo",
      "trigger" => "after_mob",
      "after" => "5",
      "unit" => "s",
      "category" => "buffs",
      "keys" => ""
    })
    |> render_submit()

    assert %Timer{category: :buffs, keys: [], after_ms: 5_000} =
             Enum.find(Store.all(), &(&1.id == "escudo"))
  end

  # A schedule that saves half a rule sits on the page looking configured and
  # never goes off.
  test "a form with nothing to press is REFUSED, and says what is missing", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")
    before = length(Store.all())

    view
    |> form("#timer-form", %{
      "name" => "vazio",
      "trigger" => "every",
      "after" => "10",
      "unit" => "min",
      "category" => "",
      "keys" => ""
    })
    |> render_submit()

    assert view |> element("#timer-form-error") |> render() =~ "faltou"
    assert length(Store.all()) == before
  end

  # Zero is meaningful on a mob stretch (it fires once, at the start) and is a
  # stuck button on `:every`.
  test "every-zero is refused; mob-zero is accepted", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    view
    |> form("#timer-form", %{
      "name" => "spam",
      "trigger" => "every",
      "after" => "0",
      "unit" => "s",
      "category" => "",
      "keys" => "8"
    })
    |> render_submit()

    assert Enum.find(Store.all(), &(&1.id == "spam")) == nil

    view
    |> form("#timer-form", %{
      "name" => "na hora",
      "trigger" => "after_mob",
      "after" => "0",
      "unit" => "s",
      "category" => "buffs",
      "keys" => ""
    })
    |> render_submit()

    assert %Timer{after_ms: 0} = Enum.find(Store.all(), &(&1.id == "na-hora"))
  end

  test "turning one off keeps it, and deleting removes it", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    view
    |> element(~s(#timer-aura-na-mobada button[phx-click="toggle"]))
    |> render_click()

    assert [%Timer{id: "aura-na-mobada", enabled?: false}] = Store.all()
    assert view |> element("#timer-aura-na-mobada") |> render() =~ "desligado"

    view
    |> element(~s(#timer-aura-na-mobada button[phx-click="delete"]))
    |> render_click()

    assert Store.all() == []
    assert render(view) =~ "nada agendado"
  end

  test "a job with nobody in the field shows what is missing, not a blank", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/timers")

    assert view |> element("#timer-aura-na-mobada") |> render() =~ "sem aura"
  end

  # It used to say "sem aura" about a pokémon whose aura IS classified: the page
  # being wrong about the configuration, not honest about the bot.
  test "it resolves the job against the pokémon he chose, running or not", %{conn: conn} do
    {:ok, _} = Pokex.Pokedex.Team.add("Venusaur")
    Pokex.Pokedex.Team.set_skills("Venusaur", %{"1" => :buffs, "3" => :aoe})
    Pokex.Pokedex.Team.set_active("Venusaur")

    {:ok, view, _html} = live(conn, ~p"/timers")

    row = view |> element("#timer-aura-na-mobada") |> render()
    assert row =~ "1"
    refute row =~ "sem aura"
  end
end
