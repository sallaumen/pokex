defmodule PokexWeb.AppHeaderTest do
  @moduledoc """
  O header é o mesmo em TODA página — é a regra que este arquivo guarda.

  Antes, cada página inventava o seu: o painel tinha o bom (marca, personagem,
  ligado/parado, navegação), seis páginas tinham um nav antigo com botão de tema,
  e a Pokédex/Time nem shell tinham — só links soltos "← painel". Um teste por
  página não pega isso; o que pega é varrer TODAS as rotas exigindo os mesmos
  marcadores.
  """
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  @routes [
    {"/", :panel},
    {"/calibration", :calibration},
    {"/diagnostics", :diagnostics},
    {"/fishing-lab", :fishing_lab},
    {"/mini-game", :mini_game},
    {"/world", :world},
    {"/cavebot", :cavebot},
    {"/pokedex", :pokedex},
    {"/time", :team}
  ]

  @nav_ids ~w(
    app-nav-panel app-nav-calibration app-nav-diagnostics app-nav-fishing-lab
    app-nav-mini-game app-nav-world app-nav-cavebot app-nav-pokedex app-nav-team
  )

  test "toda página monta o MESMO header", %{conn: conn} do
    for {path, _page} <- @routes do
      {:ok, view, html} = live(conn, path)

      assert has_element?(view, "#app-header"), "#{path} não tem o header padrão"
      assert html =~ "Pokex", "#{path} não mostra o nome do software no topo"
      assert has_element?(view, "#character-picker"), "#{path} não tem o personagem ativo"
      assert has_element?(view, "#app-bot-state"), "#{path} não diz se o bot roda ou está parado"

      assert has_element?(view, "#app-navigation-toggle"),
             "#{path} não tem a navegação"

      for id <- @nav_ids do
        assert has_element?(view, "##{id}"), "#{path}: falta #{id} no menu"
      end
    end
  end

  test "o menu marca a página em que você está", %{conn: conn} do
    for {path, page} <- @routes do
      {:ok, view, _html} = live(conn, path)
      id = "app-nav-" <> String.replace(to_string(page), "_", "-")

      assert has_element?(view, "##{id}[aria-current=page]"),
             "#{path} não se marca como página atual no menu"
    end
  end

  test "não existe mais troca de tema em página nenhuma", %{conn: conn} do
    for {path, _page} <- @routes do
      {:ok, _view, html} = live(conn, path)

      refute html =~ "data-phx-theme", "#{path} ainda tem o botão de tema"
      refute html =~ "phx:set-theme", "#{path} ainda dispara troca de tema"
      refute html =~ ~s(data-theme="light"), "#{path} ainda pode ficar claro"
    end
  end

  test "o tema escuro é cravado no documento, sem script", %{conn: conn} do
    html = conn |> get("/") |> html_response(200)

    assert html =~ ~s(lang="pt-br")
    assert html =~ ~s(data-theme="dark")
    refute html =~ "phx:theme"
  end

  test "o pill ligado/parado segue os workers FORA do painel", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/pokedex")
    assert view |> element("#app-bot-state") |> render() =~ "Parado"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "fishing",
      {:fishing, %{state: :pescando, counters: %{}, error: nil}}
    )

    assert render(view) =~ "Ativo"
  end

  # A caracterização da Etapa 0 cravava a divergência (o header não assinava a
  # caçada e jurava "Parado" com o cavebot andando) e prometia virar quando a
  # Frente 1 unificasse o snapshot. Virou: o header acompanha a mesma frota que
  # o painel, com a mesma régua — andando acende, parado-com-motivo NUNCA.
  test "FRENTE 1: a caçada anda e o header diz Ativo; travada, diz Parado", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/pokedex")
    assert view |> element("#app-bot-state") |> render() =~ "Parado"

    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "cavebot",
      {:cavebot, %{state: :walking, wp_index: 2, wp_total: 9, counters: %{}}}
    )

    assert eventually_renders(view, "Ativo")

    # a caçada TRAVOU (parada-com-motivo): verde aqui seria pintar de saúde o
    # exato instante em que algo deu errado
    Phoenix.PubSub.broadcast(
      Pokex.PubSub,
      "cavebot",
      {:cavebot, %{state: :blocked, wp_index: 2, wp_total: 9, counters: %{}}}
    )

    assert eventually_renders(view, "Parado")
  end

  defp eventually_renders(view, texto, tries \\ 50) do
    cond do
      view |> element("#app-bot-state") |> render() =~ texto -> true
      tries == 0 -> false
      true -> Process.sleep(10) && eventually_renders(view, texto, tries - 1)
    end
  end

  @tag :tmp_dir
  test "trocar de personagem funciona FORA do painel", %{conn: conn, tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)

    # Settings é um cache global: deixar :active_character setado faz o PRÓXIMO
    # Settings.put de qualquer teste regravar o arquivo do test-home com este
    # personagem — e aí Team.file() passa a apontar pra chars/<slug>/team.json
    # em execuções futuras. Desliga antes de soltar o home_dir.
    on_exit(fn ->
      Pokex.Characters.set_active("")
      Application.delete_env(:pokex, :home_dir)
    end)

    {:ok, slug} = Pokex.Characters.create("Header Teste")

    {:ok, view, _html} = live(conn, "/world")

    view
    |> form("#character-picker-form", %{"character" => slug})
    |> render_change()

    assert Pokex.Characters.active() == slug
  end

  test "o aviso de foco perdido aparece em qualquer página", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/diagnostics")
    refute has_element?(view, "#focus-pause-badge")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: false}})
    assert has_element?(view, "#focus-pause-badge")

    Phoenix.PubSub.broadcast(Pokex.PubSub, "focus", {:focus, %{focused?: true}})
    refute has_element?(view, "#focus-pause-badge")
  end

  test "a Pokédex diz Pokex no topo e sincroniza a wiki pelo CORPO da página", %{conn: conn} do
    {:ok, view, html} = live(conn, "/pokedex")

    # a ferramenta desceu do header pro corpo: continua existindo, mas dentro da página
    assert has_element?(view, "#pokedex-tools #sync-form")
    refute has_element?(view, "#app-header #sync-form")

    # e o topo é a marca do software, não o nome da página
    assert html =~ "Pokex"
    assert has_element?(view, "#app-page-label")
  end
end
