defmodule Pokex.Bots.LogoutTest do
  # async: false — mexe no latch global do InputGate, que outras suítes leem.
  use ExUnit.Case, async: false

  alias Pokex.Bots.{InputGate, Logout}
  alias Pokex.SettingsStash

  setup do
    # :test é campo RESERVADO do contexto do ExUnit — daí o nome esquisito.
    dono = self()

    # A espera real de 1,5s pra tela trocar vale no jogo, não aqui: um caso de
    # falha com duas tentativas levaria 5,4s. O ritmo entre leituras é injetado
    # no start_logout/2 abaixo.
    #
    # logout_confirm_delay_ms fica no padrão de propósito: o Body falso só GRAVA
    # a sequência, não dorme nela — e o teste do caminho feliz asserta o valor.
    SettingsStash.stash!(logout_verify_delay_ms: 20)

    on_exit(fn -> InputGate.set_panic_latch(false) end)
    Phoenix.PubSub.subscribe(Pokex.PubSub, Logout.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, "combat")

    {:ok, body} = start_supervised({Agent, fn -> %{reply: :ok, calls: []} end})

    perform = fn actions, priority ->
      Agent.get_and_update(body, fn s ->
        {s.reply, %{s | calls: s.calls ++ [{actions, priority}]}}
      end)
    end

    %{dono: dono, body: body, perform: perform}
  end

  defp calls(body), do: Agent.get(body, & &1.calls)

  # Um leitor de tela que devolve a LINHA DE BASE na primeira chamada e depois
  # sempre `depois`. É o formato honesto: no jogo real a barra de baixo está
  # legível antes do Ctrl+Q, e é justamente isso que dá testemunha pro "sumiu"
  # significar alguma coisa.
  defp leitor(depois, baseline \\ :present) do
    {:ok, agente} = Agent.start_link(fn -> :primeira end)

    fn ->
      Agent.get_and_update(agente, fn
        :primeira -> {baseline, :resto}
        :resto -> {depois, :resto}
      end)
    end
  end

  # Sobe um Logout isolado (sem nome registrado) com tudo injetado.
  defp start_logout(ctx, opts) do
    dono = ctx.dono

    defaults = [
      name: nil,
      active: true,
      perform_fun: ctx.perform,
      stop_fun: fn -> send(dono, :stopped) end,
      front_fun: fn -> :ok end,
      read_gap_ms: 5
    ]

    {:ok, pid} = Logout.start_link(Keyword.merge(defaults, opts))
    pid
  end

  # Espera o processo chegar num estado terminal, sem depender de sleep fixo.
  defp await_state(pid, wanted, timeout \\ 2_000) do
    deadline = System.monotonic_time(:millisecond) + timeout

    poll = fn poll ->
      snap = Logout.status(pid)

      cond do
        snap.state == wanted ->
          snap

        System.monotonic_time(:millisecond) > deadline ->
          flunk("ficou em #{snap.state}, esperava #{wanted}")

        true ->
          Process.sleep(10) && poll.(poll)
      end
    end

    poll.(poll)
  end

  test "caminho feliz: trava o latch, para a frota, aperta na ordem e confirma", ctx do
    pid = start_logout(ctx, read_fun: leitor(:gone))

    Logout.request("manual", pid)

    snap = await_state(pid, :out)
    assert snap.reason == "manual"
    assert_received :stopped
    assert InputGate.panic_latched?()

    assert [{actions, :critical}] = calls(ctx.body)
    assert [{:press, "ctrl+q"}, {:wait, 300}, {:press, "enter"}] = actions

    assert_receive {:logout, %{state: :out}}, 1_000
  end

  test "HUD que continua legível vira falha ruidosa depois das tentativas", ctx do
    pid = start_logout(ctx, read_fun: leitor(:present), attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ainda_logado
    assert snap.attempt == 2

    assert_receive {:rule_alarm, :logout, texto}, 1_000
    assert texto =~ "logout"
  end

  test "leitura sempre ilegível NUNCA reporta deslogado", ctx do
    pid = start_logout(ctx, read_fun: leitor(:unreadable), attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ilegivel
    refute snap.state == :out
  end

  test "um pedido durante um logout em voo é ignorado e contado", ctx do
    pid = start_logout(ctx, read_fun: leitor(:present), attempts_override: 3)

    Logout.request("primeiro", pid)
    Logout.request("segundo", pid)
    Logout.request("terceiro", pid)

    snap = await_state(pid, :failed)
    assert snap.reason == "primeiro"
    assert snap.duplicates == 2
  end

  test "canto do pânico acionado: falha sem NUNCA tocar no Body", ctx do
    pid =
      start_logout(ctx,
        read_fun: leitor(:gone),
        front_fun: fn -> {:error, :panic_corner} end,
        attempts_override: 2
      )

    Logout.request("manual", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :panic_corner
    assert calls(ctx.body) == []
  end

  test "o latch continua travado depois de um logout bem-sucedido", ctx do
    pid = start_logout(ctx, read_fun: leitor(:gone))

    Logout.request("manual", pid)
    await_state(pid, :out)

    assert InputGate.panic_latched?()
  end

  test "HUD já ilegível ANTES de apertar não vira prova de logout", ctx do
    # O cenário real: sub-região descalibrada, ou o atlas sem algum dígito (o
    # "9" que faltava). A HUD devolve nil nos três campos o tempo todo, e sem a
    # linha de base o bot juraria ter deslogado sem nada ter acontecido.
    pid =
      start_logout(ctx,
        read_fun: leitor(:gone, :gone),
        attempts_override: 2
      )

    Logout.request("manual", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :sem_testemunha
    refute snap.state == :out

    # e as teclas foram enviadas do mesmo jeito — só não dá pra AFIRMAR que
    # funcionaram; o alarme é que acorda o Lucas
    assert [{_actions, :critical} | _] = calls(ctx.body)
    assert_receive {:rule_alarm, :logout, texto}, 1_000
    assert texto =~ "sem_testemunha"
  end
end
