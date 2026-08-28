defmodule Pokex.Sim.CalibrateTest do
  use ExUnit.Case, async: false

  alias Pokex.Sim.Calibrate

  @date ~D[2020-01-02]

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    File.mkdir_p!(Path.join(tmp, "journal"))
    File.mkdir_p!(Path.join(tmp, "events"))
    :ok
  end

  defp write_journal(tmp, lines) do
    body = Enum.map_join(lines, "\n", &Jason.encode!/1)
    File.write!(Path.join([tmp, "journal", "#{Date.to_iso8601(@date)}.jsonl"]), body <> "\n")
  end

  defp write_events(tmp, records) do
    body = Enum.map_join(records, "\n", &Jason.encode!/1)
    File.write!(Path.join([tmp, "events", "#{Date.to_iso8601(@date)}.jsonl"]), body <> "\n")
  end

  # One tile every 300ms, walking east on one floor.
  defp walk_lines(count, step_ms \\ 300) do
    for i <- 0..count do
      %{
        at: 1_000_000 + i * step_ms,
        text: "caçada: andar walk de #{100 + i},200,5: faltam 4,0 tiles · leitura de 120ms atrás",
        source: "cavebot",
        severity: "macro"
      }
    end
  end

  # A vitals reading, the way the engine files one.
  defp vital(at, fields) do
    Map.merge(
      %{
        kind: "vitals",
        at: at,
        enemies: 0,
        hp: 100,
        out: true,
        spent: false,
        ready: 4,
        keys: 4,
        phase: "travelling",
        revive: "hold"
      },
      fields
    )
  end

  describe "a mordida: quanto a vida cai por bicho na tela" do
    @tag :tmp_dir
    test "mede a queda por segundo por inimigo, e só as quedas", %{tmp_dir: tmp} do
      # 20 leituras de 1s, dois bichos batendo, 4% por segundo (2% por bicho)
      caindo =
        for i <- 0..20,
            do: vital(1_000 + i * 1_000, %{enemies: 2, hp: 100 - i * 4, phase: "engaged"})

      write_events(tmp, caindo)

      bite = Calibrate.report(@date).bite

      assert bite.n == 20
      assert_in_delta bite.median, 2.0, 0.01
    end

    @tag :tmp_dir
    test "uma poção subindo a vida não vira mordida negativa", %{tmp_dir: tmp} do
      subindo =
        for i <- 0..20, do: vital(1_000 + i * 1_000, %{enemies: 2, hp: 40 + i, phase: "engaged"})

      write_events(tmp, subindo)

      assert Calibrate.report(@date).bite == nil
    end

    @tag :tmp_dir
    test "e a vida com o pokémon fora de campo não é vida de ninguém", %{tmp_dir: tmp} do
      na_bola =
        for i <- 0..20,
            do: vital(1_000 + i * 1_000, %{enemies: 2, hp: 100 - i * 4, out: false})

      write_events(tmp, na_bola)

      assert Calibrate.report(@date).bite == nil
    end
  end

  describe "o custo de um bicho: teclas e segundos" do
    @tag :tmp_dir
    test "conta a lista encolhendo em luta, e as teclas gastas na janela", %{tmp_dir: tmp} do
      # quatro bichos, um morrendo por segundo, dois toques por segundo
      lutando =
        for i <- 0..4,
            do: vital(1_000 + i * 1_000, %{enemies: 4 - i, phase: "engaged", spent: true})

      teclas =
        for i <- 0..3, do: %{kind: "press", at: 1_500 + i * 1_000, keys: ["3", "4"], n: 2}

      write_events(tmp, lutando ++ teclas)

      kill = Calibrate.report(@date).kill

      assert kill.n == 4
      assert kill.presses == 8
      assert kill.presses_per_kill == 2.0
      assert kill.ms_per_kill == 1_000
    end

    # Andar embora encolhe a lista do mesmo jeito, e é bicho perdido, não morto.
    @tag :tmp_dir
    test "a lista encolhendo enquanto ele ANDA não conta como morte", %{tmp_dir: tmp} do
      andando =
        for i <- 0..4,
            do: vital(1_000 + i * 1_000, %{enemies: 4 - i, phase: "travelling"})

      write_events(tmp, andando)

      assert Calibrate.report(@date).kill == nil
    end
  end

  describe "o preço do F4" do
    @tag :tmp_dir
    test "mede da barra sumir até a barra voltar", %{tmp_dir: tmp} do
      write_events(tmp, [
        vital(1_000, %{ready: 0, spent: true, enemies: 3, phase: "engaged"}),
        vital(1_200, %{out: false, ready: nil, revive: "now", enemies: 3}),
        vital(2_600, %{ready: 4, enemies: 3, phase: "engaged"})
      ])

      settle = Calibrate.report(@date).revive_settle

      assert settle.n == 1
      assert settle.median == 1_400
    end

    # Um revive que não sai não é um settle lento: é outra falha, com nome.
    @tag :tmp_dir
    test "uma queda que nunca volta não entra na média", %{tmp_dir: tmp} do
      write_events(tmp, [
        vital(1_000, %{ready: 0, spent: true}),
        vital(1_200, %{out: false, ready: nil, revive: "now"}),
        vital(60_000, %{ready: 4})
      ])

      assert Calibrate.report(@date).revive_settle == nil
    end
  end

  describe "a premissa da R3b: voltar zera cooldown?" do
    @tag :tmp_dir
    test "barra vazia antes e cheia depois é um reset", %{tmp_dir: tmp} do
      write_events(tmp, [
        vital(1_000, %{ready: 0, spent: true, enemies: 3, phase: "engaged"}),
        vital(1_200, %{out: false, ready: nil, revive: "now", enemies: 3}),
        vital(2_600, %{ready: 4, enemies: 3, phase: "engaged"})
      ])

      assert %{n: 1, resets: 1, kept: 0} = Calibrate.report(@date).revive_reset
    end

    @tag :tmp_dir
    test "barra vazia antes e vazia depois NÃO é", %{tmp_dir: tmp} do
      write_events(tmp, [
        vital(1_000, %{ready: 0, spent: true, enemies: 3, phase: "engaged"}),
        vital(1_200, %{out: false, ready: nil, revive: "now", enemies: 3}),
        vital(2_600, %{ready: 1, enemies: 3, phase: "engaged"})
      ])

      assert %{n: 1, resets: 0, kept: 1} = Calibrate.report(@date).revive_reset
    end

    # Uma barra que já estava cheia não prova nada sobre reset nenhum.
    @tag :tmp_dir
    test "uma barra cheia antes do revive não vira prova", %{tmp_dir: tmp} do
      write_events(tmp, [
        vital(1_000, %{ready: 4}),
        vital(1_200, %{out: false, ready: nil, revive: "now"}),
        vital(2_600, %{ready: 4})
      ])

      assert Calibrate.report(@date).revive_reset == nil
    end
  end

  describe "as medições viram botões do simulador" do
    @tag :tmp_dir
    test "a mordida vira bite_dmg com cadência fixa, e as teclas viram dano", %{tmp_dir: tmp} do
      caindo =
        for i <- 0..20,
            do: vital(1_000 + i * 1_000, %{enemies: 2, hp: 100 - i * 4, phase: "engaged"})

      lutando =
        for i <- 0..4,
            do: vital(100_000 + i * 1_000, %{enemies: 4 - i, phase: "engaged"})

      teclas =
        for i <- 0..3, do: %{kind: "press", at: 100_500 + i * 1_000, keys: ["3"], n: 4}

      write_events(tmp, caindo ++ lutando ++ teclas)

      knobs = Calibrate.knobs(@date)

      assert knobs.bite_dmg == 2
      assert knobs.bite_every_ms == 1_000
      # 16 teclas / 4 mortes = 4 por morte ⇒ 25% de vida por tecla
      assert knobs.single_damage_pct == 25
      assert knobs.aoe_damage_pct == 25
    end

    @tag :tmp_dir
    test "uma noite que não mediu nada não devolve botão nenhum", %{tmp_dir: tmp} do
      write_events(tmp, [vital(1_000, %{})])

      knobs = Calibrate.knobs(@date)

      refute Map.has_key?(knobs, :bite_dmg)
      refute Map.has_key?(knobs, :single_damage_pct)
      refute Map.has_key?(knobs, :revive_settle_ms)
    end

    # MEDIDO nas noites reais dele: 26/08 deu 0,73 tecla por morto e 27/08 deu
    # 0,69 — a noite dos 2.372 "não saiu", com o recibo mentindo sobre cada
    # disparo. A conta devolvia `aoe_damage_pct: 137` e `145`: uma tecla que
    # mata mais que um monstro inteiro, com cara de medição, e a um clique do
    # botão "usar o que a noite mediu".
    @tag :tmp_dir
    test "menos de uma tecla por morto não vira dano — é defeito, não física", %{tmp_dir: tmp} do
      # quatro mortes e só duas teclas registradas: meia tecla por morto
      lutando =
        for i <- 0..4,
            do: vital(1_000 + i * 1_000, %{enemies: 4 - i, phase: "engaged"})

      teclas = for i <- 0..1, do: %{kind: "press", at: 1_500 + i * 1_000, keys: ["3"], n: 1}

      write_events(tmp, lutando ++ teclas)

      # a medição crua continua à vista, com o número esquisito e tudo
      assert Calibrate.report(@date).kill.presses_per_kill == 0.5

      # …mas ela NÃO vira botão
      knobs = Calibrate.knobs(@date)
      refute Map.has_key?(knobs, :aoe_damage_pct)
      refute Map.has_key?(knobs, :single_damage_pct)
    end

    @tag :tmp_dir
    test "exatamente uma tecla por morto ainda é medição válida", %{tmp_dir: tmp} do
      lutando =
        for i <- 0..4,
            do: vital(1_000 + i * 1_000, %{enemies: 4 - i, phase: "engaged"})

      teclas = for i <- 0..3, do: %{kind: "press", at: 1_500 + i * 1_000, keys: ["3"], n: 1}

      write_events(tmp, lutando ++ teclas)

      assert Calibrate.knobs(@date).aoe_damage_pct == 100
    end
  end

  @tag :tmp_dir
  test "measures milliseconds per tile from consecutive walk lines", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    assert Calibrate.walk_speed(@date).median == 300.0
  end

  @tag :tmp_dir
  test "counts how many samples the measurement rests on", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "refuses to answer a speed from too few hops", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(5))

    assert Calibrate.walk_speed(@date) == nil
  end

  @tag :tmp_dir
  test "drops a pair that changed floor, since a stair is one key and two tiles", %{tmp_dir: tmp} do
    stair = %{
      at: 2_000_000,
      text: "caçada: andar walk de 500,200,6: faltam 1,0 tiles · leitura de 120ms atrás",
      source: "cavebot",
      severity: "macro"
    }

    write_journal(tmp, walk_lines(40) ++ [stair])

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "drops a pair separated by a long gap, since the hunt was doing something else", %{
    tmp_dir: tmp
  } do
    late = %{
      at: 1_000_000 + 40 * 300 + 60_000,
      text: "caçada: andar walk de 200,200,5: faltam 1,0 tiles · leitura de 120ms atrás",
      source: "cavebot",
      severity: "macro"
    }

    write_journal(tmp, walk_lines(40) ++ [late])

    assert Calibrate.walk_speed(@date).n == 40
  end

  @tag :tmp_dir
  test "answers nil for a night that never measured walking", %{tmp_dir: tmp} do
    write_journal(tmp, [%{at: 1, text: "caçada: waypoint 3/67", source: "cavebot"}])

    assert Calibrate.walk_speed(@date) == nil
  end

  @tag :tmp_dir
  test "reads the pile sizes the engine actually opened on", %{tmp_dir: tmp} do
    write_events(tmp, [
      %{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 1_800},
      %{at: 2, kind: "decision", phase: "engaged", enemies: 6, stable_ms: 2_200},
      %{at: 3, kind: "decision", phase: "skipping", enemies: 1, stable_ms: 400}
    ])

    pile = Calibrate.piles(@date)

    assert pile.engagements == 2
    assert pile.engaged.median == 6
    assert pile.skipped == 1
  end

  @tag :tmp_dir
  test "reads how long the piles took to stop arriving", %{tmp_dir: tmp} do
    write_events(tmp, [
      %{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 1_800},
      %{at: 2, kind: "decision", phase: "engaged", enemies: 5, stable_ms: 2_200}
    ])

    assert Calibrate.piles(@date).settled_ms.median == 2_200
  end

  @tag :tmp_dir
  test "answers nil for a night the engine never filed", %{tmp_dir: _tmp} do
    assert Calibrate.piles(@date) == nil
  end

  @tag :tmp_dir
  test "hands over only the knobs the night could actually answer", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))

    knobs = Calibrate.knobs(@date)

    assert knobs.ms_per_tile == 300
    refute Map.has_key?(knobs, :nest_size)
  end

  @tag :tmp_dir
  test "hands over nothing for a night that measured nothing", %{tmp_dir: _tmp} do
    assert Calibrate.knobs(@date) == %{}
  end

  @tag :tmp_dir
  test "the report carries both halves and the date it read", %{tmp_dir: tmp} do
    write_journal(tmp, walk_lines(40))
    write_events(tmp, [%{at: 1, kind: "decision", phase: "engaged", enemies: 4, stable_ms: 900}])

    report = Calibrate.report(@date)

    assert report.date == @date
    assert report.walk.n == 40
    assert report.pile.engagements == 1
  end

  # O recall SAUDÁVEL — a única prensa que a R3b existe pra medir — deixa a barra
  # ilegível sem prova de queda: `out` responde `:unknown`, não `false`.
  describe "o preço do F4 num recall que não é queda" do
    @tag :tmp_dir
    test "mede a janela mesmo quando a queda nunca foi provada" do
      vitals = [
        %{"at" => 0, "out" => true, "ready" => 0, "keys" => 4},
        %{"at" => 400, "out" => :unknown},
        %{"at" => 1_600, "out" => true, "ready" => 4, "keys" => 4}
      ]

      assert %{median: 1_200} = Calibrate.revive_settle(vitals)
      assert %{n: 1, resets: 1} = Calibrate.revive_reset(vitals)
    end

    # A madrugada de 27→28/08: 4,9 horas no chão com o estoque zerado, e o
    # medidor leu essas voltas como "kept" — quase desmentindo o reset que o
    # vídeo de 26/08 viu. Um chão mais longo que o teto do settle não é um
    # F4→volta e não responde NADA sobre o reset.
    @tag :tmp_dir
    test "um chão de minutos não conta como medida do reset" do
      vitals = [
        %{"at" => 0, "out" => true, "ready" => 0, "keys" => 4},
        %{"at" => 400, "out" => false},
        %{"at" => 1_200_000, "out" => true, "ready" => 1, "keys" => 4}
      ]

      assert Calibrate.revive_reset(vitals) == nil
    end
  end
end
