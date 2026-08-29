defmodule PokexWeb.SimLiveTest do
  @moduledoc """
  The page has to RENDER, armed, with a world in it.

  There was no test at this level, and the gap cost a live crash: the template
  still read `knobs.aoe_damage` after the knob became `aoe_damage_pct`, and
  every unit test stayed green because none of them rendered that branch. The
  first click in a browser was a KeyError page.

  A template is code. It reads keys off structs like any other code, and
  nothing else in the suite type-checks it.
  """
  use PokexWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Pokex.Bots.Cavebot.Store
  alias Pokex.Sim.Fence

  # A route has to EXIST for any of this to render: without one the world is
  # nil and every panel is behind `:if={@world}`. That is correct behaviour on
  # the page and a trap in a test, because the page then renders empty and
  # green while proving nothing.
  setup do
    Store.put([route()])
    on_exit(fn -> Fence.disarm() end)
    :ok
  end

  defp route do
    %Pokex.Bots.Cavebot.Route{
      name: "sim",
      waypoints:
        for {x, y, z} <- [{100, 200, 5}, {110, 200, 5}] do
          %{
            x: x,
            y: y,
            z: z,
            action: :walk,
            stops: [],
            at: nil,
            dwell_ms: nil,
            park_point: nil,
            park_tiles: nil,
            fight_ms: nil,
            gather_ms: 2_000,
            combo: [],
            skills: [],
            gather_wait_ms: nil
          }
        end
    }
  end

  test "the page renders before anything is armed", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "Simulação desarmada"
  end

  # A battle fact left on the shared blackboard by ANOTHER producer carries no
  # `enemies_detail` — and took this page down with a FunctionClauseError while
  # rendering (CI, 2026-08-24). The blackboard is shared; the page reads it.
  test "a battle fact with no detail renders instead of crashing", %{conn: conn} do
    Pokex.Perception.WorldState.put(
      :battle,
      %{enemies: [0, 1], red: [], locked?: false, locked_row: nil},
      System.monotonic_time(:millisecond)
    )

    on_exit(fn -> Pokex.Perception.WorldState.forget(:battle) end)

    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "linha 0"
    assert html =~ "linha 1"
  end

  # O RACK NO LUGAR DO COMBO: ele pediu, em 27/08, ver o cooldown de cada tecla
  # correndo em vez de marcar quais matam juntas.
  test "armed, every panel renders — the map, the key rack and the calibration table", %{
    conn: conn
  } do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Armar") |> render_click()

    refute html =~ "O combo que mata"
    assert html =~ "A barra, agora"
    assert html =~ "Mesa de calibragem"
    assert html =~ "seu pokémon"
  end

  # The table is the answer to "validar vários cenários": one row per scenario,
  # and a template that reads outcome keys is code nothing else type-checks.
  test "rodar TODOS renders one row per scenario, with the knobs it used", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Todos") |> render_click()

    assert html =~ "Todos os cenários"
    assert html =~ "engaja a partir de"

    for scenario <- Pokex.Sim.Scenario.all() do
      assert html =~ scenario.name, "faltou a linha de #{scenario.id}"
    end

    # "Ele cai" is the one run that must not read as a clean night
    assert html =~ "caiu"
  end

  # The scoreboard is the instrument he tunes on, and a template that reads
  # nested outcome keys is code nothing else type-checks.
  test "o placar renderiza os seis mostradores, a comparação e a ressalva", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")

    html = live |> element("button", "Placar") |> render_click()

    assert html =~ "Placar da caçada"

    for label <- ["mortos/min", "quedas/min", "sem cooldown", "no chão", "pilha (mediana)"] do
      assert html =~ label, "faltou o mostrador de #{label}"
    end

    # a comparação existe, é nomeada, e diz quais chaves mudaram
    assert html =~ "Hoje → com o F4 proativo (R3b)"
    assert html =~ "pilhas abandonadas"
    assert html =~ "sua vida no fim"

    for {key, _value} <- Pokex.Sim.Bench.tuning() do
      assert html =~ to_string(key), "o placar não disse qual chave mudou (#{key})"
    end

    # e onde o minuto foi parar, que é a única versão do número da qual dá pra
    # escolher um botão
    assert html =~ "Onde foi o minuto"

    # uma linha por cenário
    for scenario <- Pokex.Sim.Scenario.all() do
      assert html =~ scenario.name, "faltou a linha de #{scenario.id}"
    end

    # e a ressalva honesta sobre o que os números valem
    assert html =~ "Comparação vale"
  end

  # As quatro medições que faltavam pro placar virar absoluto. Sem noite
  # medida, cada uma tem que DIZER que não mediu em vez de mostrar um padrão.
  test "as quatro medições aparecem, e uma noite vazia diz que não mediu", %{conn: conn} do
    {:ok, _live, html} = live(conn, ~p"/sim")

    assert html =~ "As quatro medições do jogo"

    for label <- ["a mordida", "o custo de um bicho", "o preço do F4", "F4 zera cooldown?"] do
      assert html =~ label, "faltou a leitura de #{label}"
    end

    assert html =~ "a noite não mediu"

    assert html =~ "recolhe, usa o revive e devolve",
           "a página tem que dizer COMO medir a quarta, e com qual tecla"
  end

  # A mesa pedia dano de uma tecla de buff e listava "0" antes do "1", sem dizer
  # o que cada tecla faz. "Não tá se adequando ao meu pokémon" (Lucas, 25/08).
  test "a mesa mostra a barra do pokémon, com o trabalho de cada tecla", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")
    live |> element("button", "Armar") |> render_click()

    html = live |> element("button", "Mesa de calibragem") |> render_click()

    assert html =~ "o que faz"
    assert html =~ "área"
    assert html =~ "alvo único"
    assert html =~ "buff", "uma tecla de buff tem que aparecer dizendo que é buff"
    assert html =~ "MESMA", "a mesa tem que dizer que vida e dano estão na mesma unidade"
  end

  test "opening the calibration table renders every field it offers", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")
    live |> element("button", "Armar") |> render_click()

    html = live |> element("button", "Mesa de calibragem") |> render_click()

    for knob <- Pokex.Sim.Setup.tunable() do
      assert html =~ ~s(name="#{knob}"), "faltou o campo de #{knob} na mesa"
    end
  end

  # TRÊS GRAUS, não dois: "hoje o zoom já seria o alto (…) seria legal um
  # intermediário" (27/08). Cada um redesenha a mesma cena com outro viewBox.
  test "os três graus de aproximação desenham o mundo", %{conn: conn} do
    {:ok, live, _html} = live(conn, ~p"/sim")
    live |> element("button", "Armar") |> render_click()

    # PELO CONTROLE, não pelo texto: "perto" é substring de "aperto", que é o
    # rótulo de severidade dos cartões do laboratório — o filtro de texto
    # passou a casar nove botões de uma vez. Um teste que mira o atributo do
    # próprio controle não quebra quando alguém escreve uma palavra na página.
    for nivel <- ~w(perto medio rota) do
      html = live |> element(~s(button[phx-value-level="#{nivel}"])) |> render_click()
      assert html =~ ~s(viewBox=), "o grau #{nivel} não desenhou o mapa"
      assert html =~ ~s(aria-pressed="true")
    end
  end

  # O PLACAR DA NOITE: as mesmas perguntas do placar simulado, feitas ao rastro
  # que o bot deixou. Sem rastro ele não aparece — um número sem noite atrás é
  # um número inventado.
  describe "o placar da noite" do
    test "não aparece quando a noite não deixou rastro", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/sim")

      refute html =~ "O placar da noite"
    end

    @tag :tmp_dir
    test "e mostra o que a noite rendeu quando deixou", %{conn: conn, tmp_dir: tmp} do
      hoje = Date.utc_today()
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Pokex.TestHome.restore() end)

      File.mkdir_p!(Path.join(tmp, "events"))

      linhas = [
        %{kind: "vitals", at: 0, enemies: 3, ready: 0, out: true},
        %{kind: "decision", at: 1_000, phase: "engaged", revive: "now"},
        %{kind: "kill", at: 30_000, n: 1},
        %{
          kind: "receipt",
          at: 31_000,
          gap_ms: 500,
          fired: ["3"],
          missed: ["4"],
          unknown: []
        },
        %{kind: "vitals", at: 60_000, enemies: 0, ready: 2, out: true}
      ]

      File.write!(
        Path.join([tmp, "events", "#{Date.to_iso8601(hoje)}.jsonl"]),
        Enum.map_join(linhas, "\n", &Jason.encode!/1) <> "\n"
      )

      {:ok, _live, html} = live(conn, ~p"/sim")

      assert html =~ "O placar da noite"
      assert html =~ "mortos/min"
      assert html =~ "As pilhas que ele encontrou"
      assert html =~ "As teclas que realmente saíram"
      assert html =~ "Onde foi o minuto, no jogo"
    end
  end

  describe "o guindaste da densidade" do
    # Estes testes ESCREVEM `sim_setup.json`, e o home de teste é um só pra
    # suíte inteira: sem um próprio, dois testes disputam o mesmo arquivo e a
    # falha aparece uma rodada sim, outra não.
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Pokex.TestHome.restore() end)
      Store.put([route()])

      # O MUNDO VEM DO RUNNER, não do mount: `mount/3` faz `world: Runner.world()`
      # e nunca chama `load_route/1`. Sem carregar aqui, a mesa inteira fica
      # atrás de `:if={@world}` e o teste só passava quando um teste ANTERIOR
      # tinha deixado um mundo no processo — dependência de ordem que passava no
      # arquivo inteiro e falhava sozinha.
      :ok = Pokex.Sim.Runner.load(route(), knobs: %{})
      :ok
    end

    test "os knobs de quantidade estão na mesa, não só no código" do
      # "seria legal a gente poder ter mais configuração quanto a quantidade de
      # inimigos... pra você poder ir subindo e descendo" (26/08). Antes disto a
      # única forma de subir a densidade era editar um cenário à mão.
      tunable = Pokex.Sim.Setup.tunable()

      assert :nest_radius in tunable
      assert :respawn_ms in tunable
      assert :nest_size in tunable
    end

    test "pilha fixa em 0 DEVOLVE o sorteio ao cenário, não esvazia o mundo", %{conn: conn} do
      # A caixa só sabe escrever números. Se 0 pinasse, todo ninho de todo
      # cenário passaria a ter zero bicho — um mundo vazio que ainda responde.
      #
      # Pinado ANTES de abrir a página: sem isso o refute passaria sem nada ter
      # acontecido, e o teste diria que funciona mesmo se o 0 nunca chegasse.
      Pokex.Sim.Setup.write(%{nest_size: 12})
      assert Pokex.Sim.Setup.read().nest_size == 12

      {:ok, view, _html} = live(conn, ~p"/sim")

      view
      |> element(~s(button[phx-click="toggle-setup"]))
      |> render_click()

      view |> form("#sim-mesa", %{"nest_size" => "0", "mob_hp" => "100"}) |> render_submit()

      refute Map.has_key?(Pokex.Sim.Setup.read(), :nest_size)
    end

    test "pilha fixa num número PINA, e isso vale pra todo cenário", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sim")

      view
      |> element(~s(button[phx-click="toggle-setup"]))
      |> render_click()

      view |> form("#sim-mesa", %{"nest_size" => "12", "mob_hp" => "100"}) |> render_submit()

      assert Pokex.Sim.Setup.read().nest_size == 12
    end
  end

  describe "os quatro níveis de dano, num clique" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Pokex.TestHome.restore() end)
      Store.put([route()])

      # O MUNDO VEM DO RUNNER, não do mount: `mount/3` faz `world: Runner.world()`
      # e nunca chama `load_route/1`. Sem carregar aqui, a mesa inteira fica
      # atrás de `:if={@world}` e o teste só passava quando um teste ANTERIOR
      # tinha deixado um mundo no processo — dependência de ordem que passava no
      # arquivo inteiro e falhava sozinha.
      :ok = Pokex.Sim.Runner.load(route(), knobs: %{})
      :ok
    end

    defp clicar(view, tecla, nivel) do
      view
      |> element(
        ~s(button[phx-click="dmg_one"][phx-value-key="#{tecla}"][phx-value-level="#{nivel}"])
      )
      |> render_click()
    end

    defp mesa(conn) do
      {:ok, view, _html} = live(conn, ~p"/sim")
      view |> element(~s(button[phx-click="toggle-setup"])) |> render_click()
      view
    end

    test "clicar 'muito' grava 60~80 de HP, não uma porcentagem", %{conn: conn} do
      # A unidade é o ponto: com HP absoluto, subir a vida do bicho de 100 pra
      # 500 realmente o deixa mais duro. Com porcentagem, não deixa.
      view = mesa(conn)

      view
      |> element(~s(button[phx-click="dmg_one"][phx-value-key="3"][phx-value-level="muito"]))
      |> render_click()

      assert Pokex.Sim.Setup.read().skill_damage["3"] == {60, 80}
    end

    test "clicar 'padrão' APAGA a faixa, devolvendo o chute em %", %{conn: conn} do
      view = mesa(conn)
      clicar(view, "3", "muito")
      assert Pokex.Sim.Setup.read().skill_damage["3"] == {60, 80}

      clicar(view, "3", "padrao")

      refute Map.has_key?(Pokex.Sim.Setup.read().skill_damage, "3")
    end

    test "uma tecla não mexida mantém o que tinha", %{conn: conn} do
      view = mesa(conn)

      clicar(view, "3", "muito")
      clicar(view, "4", "baixo")

      clicar(view, "3", "medio")

      damage = Pokex.Sim.Setup.read().skill_damage
      assert damage["3"] == {30, 50}
      assert damage["4"] == {10, 20}
    end

    test "uma faixa que ele digitou à mão sobrevive a um salvamento", %{conn: conn} do
      # Um `sim_setup.json` de antes dos botões, ou um número que ele mediu:
      # apagar em silêncio o que ele mediu seria pior que não ter os botões.
      Pokex.Sim.Setup.write(%{skill_damage: %{"5" => {28, 41}}})

      view = mesa(conn)
      clicar(view, "3", "muito")

      assert Pokex.Sim.Setup.read().skill_damage["5"] == {28, 41}
    end

    test "a barra TODA num clique — ele tem dez teclas", %{conn: conn} do
      # "facilita pra mim" não combina com dez cliques pra montar um
      # experimento que ele vai repetir por vida de monstro.
      view = mesa(conn)

      view |> element(~s(button[phx-click="dmg_all"][phx-value-level="muito"])) |> render_click()

      damage = Pokex.Sim.Setup.read().skill_damage
      assert damage != %{}
      assert Enum.all?(damage, fn {_key, band} -> band == {60, 80} end)
    end

    test "a barra toda em 'padrão' limpa tudo de volta", %{conn: conn} do
      view = mesa(conn)
      view |> element(~s(button[phx-click="dmg_all"][phx-value-level="muito"])) |> render_click()
      refute Pokex.Sim.Setup.read().skill_damage == %{}

      view |> element(~s(button[phx-click="dmg_all"][phx-value-level="padrao"])) |> render_click()

      assert Pokex.Sim.Setup.read().skill_damage == %{}
    end

    test "o atalho NÃO reescreve o resto da mesa", %{conn: conn} do
      # Ele grava direto, sem passar pelo formulário: os outros números não
      # estavam sendo editados e um clique que não é sobre eles não pode
      # sobrescrevê-los.
      Pokex.Sim.Setup.write(%{mob_hp: 500, skill_damage: %{}})

      view = mesa(conn)
      view |> element(~s(button[phx-click="dmg_all"][phx-value-level="medio"])) |> render_click()

      assert Pokex.Sim.Setup.read().mob_hp == 500
    end

    test "a mistura de unidades é AVISADA, com o número que a torna concreta", %{conn: conn} do
      # A armadilha que estragaria o experimento em silêncio: uma tecla em
      # padrão tira uma % da vida, então cresce junto com o monstro.
      view = mesa(conn)

      view |> form("#sim-mesa", %{"mob_hp" => "500"}) |> render_submit()
      html = clicar(view, "3", "muito")

      assert html =~ "CRESCE junto com o monstro"
      # E o número vem de `World.damage_band/2`, o MESMO lugar da coluna
      # "agora" — a primeira versão dizia 170 (34% de 500) para qualquer tecla,
      # inclusive as de alvo único, que tiram 22%.
      assert html =~ "de HP"
    end
  end

  describe "o mapa desenhado" do
    @describetag :tmp_dir

    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Pokex.TestHome.restore() end)
      Store.put([route()])
      :ok = Pokex.Sim.Runner.load(route(), knobs: %{})
      :ok
    end

    test "o chão ganha um quadriculado — sem escala, três tiles e nove desenham igual", %{
      conn: conn
    } do
      {:ok, _view, html} = live(conn, ~p"/sim")

      assert html =~ ~s(id="chao")
      assert html =~ "url(#chao)"
    end

    test "as paredes e as pedras aparecem quando o cenário tem chão", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/sim")

      html = view |> form("#sim-cenario", %{"scenario" => "lotavanon"}) |> render_change()

      # A cor da parede — o que ele não atravessa, desenhado antes da rota.
      # Vem do token, não de um literal: o mapa é pintado com a paleta do
      # console como o resto da página.
      assert html =~ "var(--color-pk-raised)"
    end
  end

  # O RACK DAS TECLAS — o pedido de 27/08: "quero ver ali, individualmente, o
  # cooldown das skills sendo usadas, carregando em contagem regressiva quando
  # foram usadas, recuperando quando o revive for usado, com um identificador
  # claro que brilha".
  describe "a barra, agora" do
    # O mundo é empurrado pelo mesmo broadcast que o Runner usa: é o caminho de
    # verdade, e evita ter que armar a engine inteira só pra ver uma contagem.
    defp empurra(world) do
      Phoenix.PubSub.broadcast(Pokex.PubSub, Pokex.Sim.Runner.topic(), {:sim, world})
      Process.sleep(10)
    end

    defp mundo do
      Pokex.Sim.World.new(route(),
        loadout: Pokex.Sim.Loadout.fallback(),
        knobs: %{skill_cooldown_ms: 45_000}
      )
    end

    test "tecla pronta diz pronta; tecla apertada vira contagem regressiva", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/sim")

      empurra(mundo())
      html = render(live)

      assert html =~ "A barra, agora"
      assert html =~ "pronta"

      gasta = Pokex.Sim.World.press(mundo(), {:press, "3"})
      empurra(Pokex.Sim.World.step(gasta, 3_000))
      html = render(live)

      assert html =~ "42s", "faltou a contagem regressiva da tecla que saiu"
    end

    # "Com um identificador claro que brilha, algo assim, dizendo que revive foi
    # usado" (27/08).
    test "o revive acende o rack e diz por quê", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/sim")

      empurra(mundo())
      refute render(live) =~ "revive — barra zerada"

      revivido =
        mundo()
        |> Pokex.Sim.World.press({:press, "3"})
        |> Pokex.Sim.World.revive()
        |> Pokex.Sim.World.step(600)

      empurra(revivido)
      html = render(live)

      assert html =~ "revive — barra zerada", "o revive tem que se anunciar"
      refute html =~ "42s", "e a barra tem que voltar inteira"
    end
  end

  # O LABORATÓRIO: a gaveta de cenários virou painel. O que estes testes
  # protegem não é o desenho, é a LEITURA — símbolo, cor e selo existem pra
  # responder "qual é o difícil" e "como foi da última vez" sem abrir treze
  # cenários, e qualquer um dos três sumindo devolve a página ao <select>.
  describe "o laboratório de cenários" do
    test "mostra todo cenário com símbolo e severidade, agrupado", %{conn: conn} do
      {:ok, _live, html} = live(conn, ~p"/sim")

      assert html =~ "O laboratório"

      for scenario <- Pokex.Sim.Scenario.all() do
        assert html =~ scenario.icon, "#{scenario.id} sem símbolo na tela"
        assert html =~ scenario.name
      end

      for group <- Pokex.Sim.Scenario.group_order() do
        assert html =~ Pokex.Sim.Scenario.group_label(group)
      end

      assert html =~ "quebrado de propósito"
    end

    test "clicar num cartão carrega o cenário e conta o que ele promete", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/sim")

      html = live |> element(~s(button[phx-value-scenario="couracado"])) |> render_click()

      assert html =~ "Couraçado"
      assert html =~ "promete"
      # a mesa dele não manda num cenário que fixa a dureza, e a tela diz isso
      assert html =~ "fixa a dureza em 8 teclas"
    end

    test "rodar um cenário cobra a promessa e carimba o selo", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/sim")

      live |> element(~s(button[phx-value-scenario="casca-de-ovo"])) |> render_click()
      html = live |> element("button", "1 min") |> render_click()

      assert html =~ "Veredito"
      # as promessas do cenário aparecem julgadas, uma a uma
      assert html =~ "não cai"
      assert html =~ "✅"
    end

    test "um cenário de OBSERVAR não finge ter passado", %{conn: conn} do
      {:ok, live, _html} = live(conn, ~p"/sim")

      live |> element(~s(button[phx-value-scenario="tecla-morta"])) |> render_click()
      html = live |> element("button", "1 min") |> render_click()

      assert html =~ "cenário de observar"
      assert html =~ "👁"
    end
  end

  # UM NÚMERO APERTADO EM SILÊNCIO é a armadilha que as próprias coerências
  # existem pra fechar: ele digita 10, o mundo usa 8, e a medição responde sobre
  # um mapa que não é o que a tela mostra. Medido em 28/08: raio 10 contra aggro
  # 8 derrubava a caçada de 24,6 para 4,1 mortos/min numa hora.
  describe "a mesa avisa quando o mundo aperta um número" do
    setup do
      previous = Pokex.Sim.Setup.read()
      on_exit(fn -> Pokex.Sim.Setup.write(previous) end)
      :ok
    end

    test "um ninho mais largo que o aggro é dito na mesa", %{conn: conn} do
      Pokex.Sim.Setup.write(%{nest_radius: 10, aggro_tiles: 8, leash_tiles: 12})

      {:ok, live, _html} = live(conn, ~p"/sim")
      live |> element("button", "Armar") |> render_click()
      html = live |> element("button", "Mesa de calibragem") |> render_click()

      assert html =~ "nest_radius"
      assert html =~ "mas o mundo usa"
      assert html =~ "nunca participa da caçada"
    end

    test "uma mesa coerente não inventa aviso nenhum", %{conn: conn} do
      Pokex.Sim.Setup.write(%{nest_radius: 8, aggro_tiles: 8, leash_tiles: 12})

      {:ok, live, _html} = live(conn, ~p"/sim")
      live |> element("button", "Armar") |> render_click()
      html = live |> element("button", "Mesa de calibragem") |> render_click()

      refute html =~ "mas o mundo usa"
    end

    test "e o aggro apertado pela corda também aparece", %{conn: conn} do
      Pokex.Sim.Setup.write(%{aggro_tiles: 20, leash_tiles: 9})

      {:ok, live, _html} = live(conn, ~p"/sim")
      live |> element("button", "Armar") |> render_click()
      html = live |> element("button", "Mesa de calibragem") |> render_click()

      assert html =~ "aggro_tiles"
      assert html =~ "a corda deixa ele vir"
    end
  end
end
