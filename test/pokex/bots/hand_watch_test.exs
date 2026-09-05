defmodule Pokex.Bots.HandWatchTest do
  @moduledoc """
  A mão dele vira fato: apertos DELE no teclado carimbam o relógio das teclas
  como se o bot tivesse apertado, e o F4 dele faz o efeito INTEIRO de um
  revive (R3 + caderninho). Pedido de 28/08: "quando eu aperto F4 no meu
  teclado, é como se fosse um ressurrect que a IA fez".
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.{HandWatch, ReviveLedger, SkillClock}
  alias Pokex.Rig.Mac.Commands

  @now System.monotonic_time(:millisecond)

  defp ctx(overrides \\ %{}) do
    {:ok, f4} = Commands.keycode("f4")

    Map.merge(
      %{
        focus_ok?: true,
        rescue_code: f4,
        last_press: fn _key -> nil end,
        revive_noted?: false,
        now: @now
      },
      overrides
    )
  end

  defp code!(key) do
    {:ok, code} = Commands.keycode(key)
    code
  end

  describe "judge/2 — de quem foi o aperto, e o que ele significa" do
    test "a skill key from his hand becomes a stamp" do
      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == [{:stamp, "4"}]
    end

    test "a tecla do resgate vira o efeito inteiro de um revive" do
      events = [%{code: code!("f4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == [:revive]
    end

    # O reset do :rescue_done apaga o carimbo do F4 do próprio bot — num drain
    # atrasado a sighting ficaria sem dono. O caderninho é a testemunha que
    # sobra: revive anotado há pouco = aquele F4 já tem dono.
    test "an F4 right after a noted revive does not count twice" do
      events = [%{code: code!("f4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{revive_noted?: true})) == []
    end

    test "game out of focus: a '4' is him typing elsewhere, not a skill" do
      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{focus_ok?: false})) == []
    end

    test "shift+key is a stance switch, never a skill" do
      events = [
        %{code: code!("1"), shift?: true, at: 1_000},
        %{code: code!("3"), shift?: true, at: 2_000}
      ]

      assert HandWatch.judge(events, ctx()) == []
    end

    test "our own CGEvent coming back through the window does not count twice" do
      # o Body carimbou a 4 há 200ms; a sighting é o aperto do BOT sendo visto
      last_press = fn
        "4" -> @now - 200
        _key -> nil
      end

      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{last_press: last_press})) == []
    end

    test "an old stamp does not swallow his new press on the same key" do
      last_press = fn
        "4" -> @now - 30_000
        _key -> nil
      end

      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{last_press: last_press})) == [{:stamp, "4"}]
    end

    test "a code that is neither the row nor the rescue belongs to another conversation" do
      # um keycode qualquer fora da fileira e do resgate (a tabela de Commands
      # nem mapeia letras — o helper só vigia o que a gente armou)
      events = [%{code: 999, shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == []
    end

    test "repeated presses in one drain become ONE verdict: narration without echo" do
      events = [
        %{code: code!("4"), shift?: false, at: 1_000},
        %{code: code!("4"), shift?: false, at: 1_200}
      ]

      assert HandWatch.judge(events, ctx()) == [{:stamp, "4"}]
    end
  end

  describe "o laço contra um rig de mentira" do
    defmodule ScriptedRig do
      use Pokex.RigDouble

      # Like the real helper, every call empties the buffer: the FIRST returns the backlog
      # (empty here; the watcher discards it on purpose) and the next one returns the
      # test's script. The table dies with the test process while a `:drain` may still be
      # queued in the watcher, so a missing table is an empty buffer, never a crash.
      def key_watch(_codes) do
        if :ets.whereis(:hand_watch_test_script) == :undefined do
          {:ok, []}
        else
          case :ets.take(:hand_watch_test_script, :events) do
            [{:events, events}] -> {:ok, events}
            [] -> {:ok, []}
          end
        end
      end
    end

    setup do
      previous_rig = Application.get_env(:pokex, :rig)
      Application.put_env(:pokex, :rig, ScriptedRig)
      Application.put_env(:pokex, :hand_watch_active, true)

      if :ets.whereis(:hand_watch_test_script) == :undefined,
        do: :ets.new(:hand_watch_test_script, [:set, :public, :named_table])

      SkillClock.wipe()
      ReviveLedger.reset()

      on_exit(fn ->
        Application.put_env(:pokex, :rig, previous_rig)
        Application.put_env(:pokex, :hand_watch_active, false)
        SkillClock.wipe()
        ReviveLedger.reset()
      end)

      {:ok, watch} = HandWatch.start_link(name: nil)
      %{watch: watch}
    end

    test "a press of his on a skill stamps the real clock", %{watch: watch} do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
      assert HandWatch.attach(watch) == :ok

      # o roteiro entra DEPOIS da primeira drenagem (que é descartada)
      Process.sleep(250)

      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("7"), shift?: false, at: 1}]}
      )

      assert_receive {:combat_log, :macro, text}, 2_000
      assert text =~ "tecla 7 da tua mão"
      assert SkillClock.last_press("7")

      assert HandWatch.detach(watch) == :ok
    end

    test "paused, the watcher does not drain, and resume gives it back", %{watch: watch} do
      assert HandWatch.attach(watch) == :ok
      # PAUSA PRIMEIRO, e só então o roteiro entra: pôr o roteiro com o laço
      # correndo é uma corrida com a drenagem, e o teste mediria o agendador.
      assert HandWatch.pause(watch) == :ok

      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("8"), shift?: false, at: 1}]}
      )

      Process.sleep(400)
      assert [{:events, _events}] = :ets.lookup(:hand_watch_test_script, :events)
      refute SkillClock.last_press("8")

      # O resume rearma, e a primeira drenagem depois de armar é descartada de
      # propósito (é backlog); a seguinte é que traz o roteiro.
      assert HandWatch.resume(watch) == :ok
      Process.sleep(250)

      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("8"), shift?: false, at: 1}]}
      )

      await(fn -> SkillClock.last_press("8") end, "o resume não voltou a drenar")
    end

    test "ONE consumer leaving does not turn off the other's light", %{watch: watch} do
      parent = self()

      other =
        spawn(fn ->
          HandWatch.attach(watch)
          send(parent, :attached)

          receive do
            :die -> :ok
          end
        end)

      assert_receive :attached, 1_000
      assert HandWatch.attach(watch) == :ok
      Process.sleep(250)
      assert HandWatch.detach(watch) == :ok

      # o outro consumidor segue vivo: o laço tem que continuar drenando
      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("9"), shift?: false, at: 1}]}
      )

      await(fn -> SkillClock.last_press("9") end, "o detach de um matou o vigia do outro")
      send(other, :die)
    end
  end

  # Espera por condição, nunca por relógio — a lição dos flakies da casa.
  defp await(condition, complaint, deadline \\ System.monotonic_time(:millisecond) + 2_000) do
    cond do
      condition.() -> :ok
      System.monotonic_time(:millisecond) > deadline -> flunk(complaint)
      true -> Process.sleep(50) && await(condition, complaint, deadline)
    end
  end
end
