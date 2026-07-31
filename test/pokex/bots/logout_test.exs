defmodule Pokex.Bots.LogoutTest do
  # async: false — touches the global InputGate latch, which other suites read.
  use ExUnit.Case, async: false

  alias Pokex.Bots.{InputGate, Logout}
  alias Pokex.SettingsStash

  setup do
    # :test is a RESERVED ExUnit context field — hence the odd name.
    dono = self()

    # The real 1.5s screen-change wait belongs in the game, not here: a two-attempt failure
    # would take 5.4s. The read cadence is injected in start_logout/2 below.
    #
    # logout_confirm_delay_ms stays at its default on purpose: the fake Body only RECORDS
    # the sequence, never sleeps on it — and the happy-path test asserts the value.
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

  # A screen reader that returns the BASELINE on the first call and then always `depois`.
  # In the real game the bottom bar is readable before Ctrl+Q — exactly what gives "gone"
  # a witness and makes it mean something.
  defp leitor(depois, baseline \\ :present) do
    {:ok, agente} = Agent.start_link(fn -> :primeira end)

    fn ->
      Agent.get_and_update(agente, fn
        :primeira -> {baseline, :resto}
        :resto -> {depois, :resto}
      end)
    end
  end

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

  test "happy path: sets the latch, stops the fleet, presses in order, and confirms", ctx do
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

  test "a HUD that stays readable becomes a loud failure after the attempts", ctx do
    pid = start_logout(ctx, read_fun: leitor(:present), attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ainda_logado
    assert snap.attempt == 2

    assert_receive {:rule_alarm, :logout, texto}, 1_000
    assert texto =~ "logout"
  end

  test "an always-unreadable read never reports logged out", ctx do
    pid = start_logout(ctx, read_fun: leitor(:unreadable), attempts_override: 2)

    Logout.request("estagnação", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :ilegivel
    refute snap.state == :out
  end

  test "a request during an in-flight logout is ignored and counted", ctx do
    pid = start_logout(ctx, read_fun: leitor(:present), attempts_override: 3)

    Logout.request("primeiro", pid)
    Logout.request("segundo", pid)
    Logout.request("terceiro", pid)

    snap = await_state(pid, :failed)
    assert snap.reason == "primeiro"
    assert snap.duplicates == 2
  end

  test "panic corner engaged: fails without ever touching the Body", ctx do
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

  test "the latch stays set after a successful logout", ctx do
    pid = start_logout(ctx, read_fun: leitor(:gone))

    Logout.request("manual", pid)
    await_state(pid, :out)

    assert InputGate.panic_latched?()
  end

  # Real scenario: a miscalibrated sub-region, or the atlas missing a digit (the missing
  # "9") — the HUD returns nil throughout, and without a baseline the bot would swear it
  # logged out when nothing happened.
  test "a HUD already unreadable BEFORE the press is no proof of logout", ctx do
    pid =
      start_logout(ctx,
        read_fun: leitor(:gone, :gone),
        attempts_override: 2
      )

    Logout.request("manual", pid)

    snap = await_state(pid, :failed)
    assert snap.error == :sem_testemunha
    refute snap.state == :out

    assert [{_actions, :critical} | _] = calls(ctx.body)
    assert_receive {:rule_alarm, :logout, texto}, 1_000
    assert texto =~ "sem_testemunha"
  end
end
