defmodule Pokex.JournalTest do
  # async: false — os broadcasts vão nos tópicos globais que a instância
  # do app também escuta; os asserts usam a instância ISOLADA.
  use ExUnit.Case, async: false

  alias Pokex.Journal

  setup do
    {:ok, journal} = Journal.start_link(name: nil, max_events: 5)
    %{journal: journal}
  end

  defp emit(topic, msg) do
    Phoenix.PubSub.broadcast(Pokex.PubSub, topic, msg)
    # broadcast é assíncrono: um call subsequente serializa atrás dele
    :ok
  end

  test "um log de worker vira evento com origem, severidade e geração", %{journal: journal} do
    gen = Pokex.Bots.Session.order(:start, "teste journal")
    emit("fishing", {:fishing_log, :macro, "arremesso da isca"})

    assert [event] = Journal.recent([], journal)
    assert event.source == :fishing
    assert event.severity == :macro
    assert event.text == "arremesso da isca"
    assert event.generation >= gen
    assert event.repeats == 1
  end

  test "chatter idêntico consecutivo vira repeats, não linhas novas", %{journal: journal} do
    for _ <- 1..4, do: emit("cavebot", {:cavebot_log, :debug, "passo 90,80"})
    emit("cavebot", {:cavebot_log, :debug, "chegou no wp 2"})

    assert [novo, repetido] = Journal.recent([], journal)
    assert novo.text == "chegou no wp 2"
    assert repetido.text == "passo 90,80"
    assert repetido.repeats == 4
  end

  test "alarmes de regra e pânico entram como :alarm", %{journal: journal} do
    emit("combat", {:rule_alarm, "🎣 3 arremessos sem NENHUMA bolha"})
    emit("combat", {:panic, "kill corner"})

    assert [panico, alarme] = Journal.recent([], journal)
    assert panico.severity == :alarm and panico.text =~ "PÂNICO"
    assert alarme.severity == :alarm and alarme.source == :regra
  end

  test "min_severity :macro esconde o chatter de debug", %{journal: journal} do
    emit("fishing", {:fishing_log, :debug, "bol 23/1150"})
    emit("fishing", {:fishing_log, :macro, "fisgada"})

    assert [%{text: "fisgada"}] = Journal.recent([min_severity: :macro], journal)
    assert length(Journal.recent([], journal)) == 2
  end

  test "o ring é limitado: o mais velho cai", %{journal: journal} do
    for i <- 1..7, do: emit("combat", {:combat_log, :macro, "evento #{i}"})

    events = Journal.recent([], journal)
    assert length(events) == 5
    assert hd(events).text == "evento 7"
    refute Enum.any?(events, &(&1.text == "evento 1"))
  end

  test "filtro por origem", %{journal: journal} do
    emit("fishing", {:fishing_log, :macro, "da pesca"})
    emit("combat", {:combat_log, :macro, "do combate"})

    assert [%{source: :combat}] = Journal.recent([sources: [:combat]], journal)
  end

  test "snapshots e mensagens desconhecidas dos mesmos tópicos são ignorados", %{
    journal: journal
  } do
    emit("fishing", {:fishing, %{state: :pescando, counters: %{}}})
    emit("combat", {:mensagem_que_ninguem_espera, 42})

    assert Journal.recent([], journal) == []
  end

  describe "persistência JSONL (sobrevive ao RESTART)" do
    @tag :tmp_dir
    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
      :ok
    end

    @tag :tmp_dir
    test "macro vira linha JSONL; debug e repeats não" do
      {:ok, journal} = Journal.start_link(name: nil, persist: true)
      emit("fishing", {:fishing_log, :macro, "fisgada"})
      emit("fishing", {:fishing_log, :macro, "fisgada"})
      emit("fishing", {:fishing_log, :debug, "bol 3px"})
      # serializa atrás dos broadcasts
      _ = Journal.recent([], journal)

      arquivo = Path.join(Journal.dir(), Date.to_iso8601(Date.utc_today()) <> ".jsonl")
      linhas = arquivo |> File.read!() |> String.split("\n", trim: true)

      assert [linha] = linhas
      assert %{"text" => "fisgada", "severity" => "macro"} = Jason.decode!(linha)
    end

    @tag :tmp_dir
    test "um journal novo ressemeia o ring do disco — a história sobrevive ao restart" do
      {:ok, primeiro} = Journal.start_link(name: nil, persist: true)
      emit("combat", {:rule_alarm, "alarme da madrugada"})
      _ = Journal.recent([], primeiro)
      GenServer.stop(primeiro)

      {:ok, segundo} = Journal.start_link(name: nil, persist: true)

      assert [evento] = Journal.recent([], segundo)
      assert evento.text == "alarme da madrugada"
      assert evento.severity == :alarm
      assert evento.source == :regra
    end

    @tag :tmp_dir
    test "linha corrompida no arquivo é pulada, nunca derruba o boot" do
      File.mkdir_p!(Journal.dir())

      File.write!(
        Path.join(Journal.dir(), Date.to_iso8601(Date.utc_today()) <> ".jsonl"),
        "isto nao é json\n" <>
          Jason.encode!(%{at: 1, source: "fishing", severity: "macro", text: "sobreviveu"}) <>
          "\n"
      )

      {:ok, journal} = Journal.start_link(name: nil, persist: true)
      assert [%{text: "sobreviveu", source: :fishing}] = Journal.recent([], journal)
    end

    @tag :tmp_dir
    test "arquivos velhos são podados no boot; sem persist nada é escrito" do
      File.mkdir_p!(Journal.dir())
      velho = Path.join(Journal.dir(), "2020-01-01.jsonl")
      File.write!(velho, "{}\n")

      {:ok, _} = Journal.start_link(name: nil, persist: true)
      refute File.exists?(velho)

      {:ok, sem} = Journal.start_link(name: nil, persist: false)
      emit("fishing", {:fishing_log, :macro, "não persiste"})
      _ = Journal.recent([], sem)

      hoje = Path.join(Journal.dir(), Date.to_iso8601(Date.utc_today()) <> ".jsonl")
      refute File.exists?(hoje)
    end
  end
end
