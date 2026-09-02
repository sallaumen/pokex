defmodule PokexWeb.ConfigLiveTest do
  @moduledoc """
  O /config repaginado: uma página própria, com busca, salvando na hora.

  O caso que pariu a página: "não achei o revive_stock que tu falou!" (28/08).
  Os ajustes novos não tinham campo nenhum, e o overlay antigo era denso demais
  pra achar os que tinham.
  """
  use PokexWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  alias Pokex.Settings
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash_keys!([
      :revive_stock,
      :player_hp_logout,
      :player_hp_floor_pct,
      :rescue_enabled,
      :pokemon_hp_rescue_pct,
      :rescue_cooldown_ms,
      :engine_downed_give_up_ms,
      :engine_engage_from,
      :pokemon_hp_fainted_below_pct,
      :combat_skill_gap_ms,
      :escape_direction,
      :alarm_muted_categories
    ])

    :ok
  end

  test "a linha que ele não achava existe, e diz como repor", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/config")

    assert html =~ "cfg-row-revive_stock"
    assert html =~ "Revives no bolso"
    assert html =~ "botão de repor"
  end

  test "o logout automático do personagem tem a própria linha", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/config")

    assert html =~ "cfg-row-player_hp_logout"
    # A RÉGUA INTEIRA na página (02/09): ele quis subir os "10 passos" e não
    # tinha onde. E a linha diz quando o modo Econômico sobrepõe o número.
    assert html =~ "cfg-row-engine_patience_tiles"
    assert html =~ "cfg-row-engine_size_ceiling_ms"
    assert html =~ "cfg-row-cavebot_gather_wait_ms"
    assert html =~ "econômico força desligado"
    assert html =~ "Logout automático"
  end

  describe "a busca" do
    test "filtra as linhas pelo que ele digitar — inclusive o nome da chave", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      html = view |> element("form[phx-change=search]") |> render_change(%{q: "revive_stock"})

      assert html =~ "Revives no bolso"
      refute html =~ "Tecla da vara"
    end

    test "grupo sem linha casando some inteiro", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      html = view |> element("form[phx-change=search]") |> render_change(%{q: "logout"})

      assert html =~ "cfg-voce"
      refute html =~ "cfg-pesca"
    end
  end

  describe "salvar na hora" do
    test "um número dentro da faixa entra em vigor e ganha o ✓", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      html =
        view
        |> element("#cfg-row-revive_stock form")
        |> render_change(%{"revive_stock" => "40"})

      assert Settings.get(:revive_stock) == 40
      assert html =~ "hero-check-circle"
    end

    test "fora da faixa é recusado COM o motivo, e nada muda", %{conn: conn} do
      antes = Settings.get(:pokemon_hp_rescue_pct)
      {:ok, view, _html} = live(conn, ~p"/config")

      html =
        view
        |> element("#cfg-row-pokemon_hp_rescue_pct form")
        |> render_change(%{"pokemon_hp_rescue_pct" => "500"})

      assert Settings.get(:pokemon_hp_rescue_pct) == antes
      assert html =~ "cfg-error-pokemon_hp_rescue_pct"
    end

    # Guardado em ms, editado em segundos — a conversão é da página, nunca dele.
    test "os segundos viram milissegundos no ajuste", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#cfg-row-rescue_cooldown_ms form")
      |> render_change(%{"rescue_cooldown_ms" => "5"})

      assert Settings.get(:rescue_cooldown_ms) == 5_000
    end

    test "os minutos do freio do chão idem", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#cfg-row-engine_downed_give_up_ms form")
      |> render_change(%{"engine_downed_give_up_ms" => "7"})

      assert Settings.get(:engine_downed_give_up_ms) == 420_000
    end

    test "a linha inteira do liga-desliga é o botão", %{conn: conn} do
      Settings.put(:player_hp_logout, false)
      {:ok, view, _html} = live(conn, ~p"/config")

      view |> element("#cfg-row-player_hp_logout button") |> render_click()
      assert Settings.get(:player_hp_logout) == true

      view |> element("#cfg-row-player_hp_logout button") |> render_click()
      assert Settings.get(:player_hp_logout) == false
    end

    test "um enum vira select com as opções do Settings", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#cfg-row-escape_direction form")
      |> render_change(%{"escape_direction" => "left"})

      assert Settings.get(:escape_direction) == "left"
    end
  end

  test "os setores do alarme ligam e desligam por ficha", %{conn: conn} do
    Settings.put(:alarm_muted_categories, [])
    {:ok, view, _html} = live(conn, ~p"/config")

    view |> element("button[phx-value-cat=shiny]") |> render_click()
    assert "shiny" in Settings.get(:alarm_muted_categories)

    view |> element("button[phx-value-cat=shiny]") |> render_click()
    refute "shiny" in Settings.get(:alarm_muted_categories)
  end

  test "os editores compostos continuam a um clique", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/config")

    assert html =~ "/config/editores"
    assert html =~ "/time"
    assert html =~ "/calibration"
  end

  # O overlay antigo não sumiu: mudou de porta — os formulários compostos
  # (combos, bolas, presets) moram lá até ganharem casa própria.
  test "o overlay dos editores segue vivo em /config/editores", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/config/editores")

    assert html =~ "settings-overlay"
  end

  # "coloca 6, achei que era esse valor que tava (…) 2 é bem baixo, no mapa que
  # caço lota de monstro, mas é legal ser fácil de editar" (Lucas, 28/08). As
  # duas existiam no Settings e em lugar nenhum da interface: mexer nelas era
  # abrir o `settings.json` na mão.
  describe "as duas que só dava pra editar no arquivo" do
    test "de quantos bichos o cérebro encara a luta", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/config")

      assert html =~ "cfg-row-engine_engage_from"
      assert html =~ "Encara a partir de"

      html =
        view
        |> element("#cfg-row-engine_engage_from form")
        |> render_change(%{"engine_engage_from" => "6"})

      assert Settings.get(:engine_engage_from) == 6
      assert html =~ "hero-check-circle"
    end

    test "abaixo de quanto a barra lida conta como pokémon no chão", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/config")

      assert html =~ "cfg-row-pokemon_hp_fainted_below_pct"
      assert html =~ "Caído abaixo de"

      html =
        view
        |> element("#cfg-row-pokemon_hp_fainted_below_pct form")
        |> render_change(%{"pokemon_hp_fainted_below_pct" => "50"})

      assert Settings.get(:pokemon_hp_fainted_below_pct) == 50
      assert html =~ "hero-check-circle"
    end

    # A faixa é 1..12: um 0 aqui seria uma caçada que nunca para pra lutar.
    test "encarar a partir de 0 é recusado, e o ajuste não muda", %{conn: conn} do
      antes = Settings.get(:engine_engage_from)
      {:ok, view, _html} = live(conn, ~p"/config")

      html =
        view
        |> element("#cfg-row-engine_engage_from form")
        |> render_change(%{"engine_engage_from" => "0"})

      assert Settings.get(:engine_engage_from) == antes
      assert html =~ "cfg-error-engine_engage_from"
    end

    # `settings.json` guarda só overrides — um valor igual ao default é apagado
    # do arquivo no boot seguinte. A linha tem que continuar mostrando o número,
    # e não um branco que ele salvaria por cima sem querer.
    test "voltar ao default deixa a linha mostrando o default, não um branco", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/config")

      view
      |> element("#cfg-row-engine_engage_from form")
      |> render_change(%{"engine_engage_from" => "6"})

      html =
        view
        |> element("#cfg-row-engine_engage_from form")
        |> render_change(%{"engine_engage_from" => "2"})

      assert Settings.get(:engine_engage_from) == 2
      assert html =~ ~s(value="2")
    end
  end

  # "eu acredito que você pode encontrar e deixar isso configurável ali pra mim,
  # porque hoje eu não consigo mudar até onde eu sei na parte de settings"
  # (Lucas, 29/08). Ele estava certo: a espera existia no Settings desde o #429
  # e nunca teve linha na tela.
  describe "a espera entre o controle e o revive" do
    test "tem linha, e o número salvo é o número em ms", %{conn: conn} do
      {:ok, view, html} = live(conn, ~p"/config")

      assert html =~ "cfg-row-rescue_stun_settle_ms"
      assert html =~ "espera dormirem"

      html =
        view
        |> element("#cfg-row-rescue_stun_settle_ms form")
        |> render_change(%{"rescue_stun_settle_ms" => "1500"})

      assert Settings.get(:rescue_stun_settle_ms) == 1_500
      assert html =~ "hero-check-circle"
    end

    # O `:sec` é inteiro: 1500ms apareceria como "1" e o primeiro toque na linha
    # salvaria 1000 por cima do ajuste dele, sem avisar. É por isso que esta
    # linha é `:ms` e não segundos.
    test "e a tela mostra 1500, não 1", %{conn: conn} do
      Settings.put(:rescue_stun_settle_ms, 1_500)

      {:ok, _view, html} = live(conn, ~p"/config")

      assert html =~ ~s(value="1500")
    end
  end
end
