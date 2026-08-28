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
      %{focus_ok?: true, rescue_code: f4, last_press: fn _key -> nil end, now: @now},
      overrides
    )
  end

  defp code!(key) do
    {:ok, code} = Commands.keycode(key)
    code
  end

  describe "judge/2 — de quem foi o aperto, e o que ele significa" do
    test "tecla de skill da mão dele vira carimbo" do
      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == [{:stamp, "4"}]
    end

    test "a tecla do resgate vira o efeito inteiro de um revive" do
      events = [%{code: code!("f4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == [:revive]
    end

    test "jogo fora de foco: um '4' é ele digitando em outro lugar, não skill" do
      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{focus_ok?: false})) == []
    end

    test "shift+tecla é troca de modo, nunca skill" do
      events = [
        %{code: code!("1"), shift?: true, at: 1_000},
        %{code: code!("3"), shift?: true, at: 2_000}
      ]

      assert HandWatch.judge(events, ctx()) == []
    end

    test "o nosso próprio CGEvent voltando pela janela não conta duas vezes" do
      # o Body carimbou a 4 há 200ms; a sighting é o aperto do BOT sendo visto
      last_press = fn
        "4" -> @now - 200
        _key -> nil
      end

      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{last_press: last_press})) == []
    end

    test "um carimbo velho não engole o aperto novo dele na mesma tecla" do
      last_press = fn
        "4" -> @now - 30_000
        _key -> nil
      end

      events = [%{code: code!("4"), shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx(%{last_press: last_press})) == [{:stamp, "4"}]
    end

    test "código que não é fileira nem resgate é de outra conversa" do
      # um keycode qualquer fora da fileira e do resgate (a tabela de Commands
      # nem mapeia letras — o helper só vigia o que a gente armou)
      events = [%{code: 999, shift?: false, at: 1_000}]
      assert HandWatch.judge(events, ctx()) == []
    end

    test "apertos repetidos num drain viram UM veredito — narração sem eco" do
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

      # devolve o roteiro UMA vez; drains seguintes veem buffer vazio —
      # como o helper de verdade, que esvazia ao drenar
      def key_watch(_codes) do
        case :ets.take(:hand_watch_test_script, :events) do
          [{:events, events}] -> {:ok, events}
          [] -> {:ok, []}
        end
      end
    end

    setup do
      previous_rig = Application.get_env(:pokex, :rig)
      Application.put_env(:pokex, :rig, ScriptedRig)
      Application.put_env(:pokex, :hand_watch_active, true)

      if :ets.whereis(:hand_watch_test_script) == :undefined,
        do: :ets.new(:hand_watch_test_script, [:set, :public, :named_table])

      SkillClock.reset()
      ReviveLedger.reset()

      on_exit(fn ->
        Application.put_env(:pokex, :rig, previous_rig)
        Application.put_env(:pokex, :hand_watch_active, false)
        SkillClock.reset()
        ReviveLedger.reset()
      end)

      {:ok, watch} = HandWatch.start_link(name: nil)
      %{watch: watch}
    end

    test "um aperto dele numa skill carimba o relógio de verdade", %{watch: watch} do
      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("7"), shift?: false, at: 1}]}
      )

      Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Bots.Combat.Worker.topic())
      assert HandWatch.attach(watch) == :ok

      assert_receive {:combat_log, :macro, text}, 2_000
      assert text =~ "tecla 7 da tua mão"
      assert SkillClock.last_press("7")

      assert HandWatch.detach(watch) == :ok
    end

    test "pausado, o vigia não drena — e o resume devolve", %{watch: watch} do
      :ets.insert(
        :hand_watch_test_script,
        {:events, [%{code: code!("8"), shift?: false, at: 1}]}
      )

      assert HandWatch.attach(watch) == :ok
      assert HandWatch.pause(watch) == :ok
      # o roteiro segue lá: ninguém drenou
      Process.sleep(400)
      assert [{:events, _events}] = :ets.lookup(:hand_watch_test_script, :events)
      refute SkillClock.last_press("8")

      assert HandWatch.resume(watch) == :ok
      await(fn -> SkillClock.last_press("8") end, "o resume não voltou a drenar")
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
