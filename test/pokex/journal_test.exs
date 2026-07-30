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
end
