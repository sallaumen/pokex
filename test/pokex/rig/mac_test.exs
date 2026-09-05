defmodule Pokex.Rig.MacTest do
  use ExUnit.Case, async: true

  alias Pokex.Rig.Mac

  # A CERCA DA CAUDA. Uma rajada leva (n-1) × gap pra sair da mão, e o revive
  # corre num processo próprio: na noite de 30/08, 325 rajadas foram
  # atravessadas por um F4 no meio e 237 teclas aterrissaram DEPOIS dele — na
  # janela cega, quase sempre com a tela já vazia. A cerca vota antes de CADA
  # prensa; verdadeira, as restantes ficam no ar e quem despachou fica sabendo
  # exatamente o que saiu.
  describe "walk_burst/3" do
    defp recorder(reply \\ fn _combo -> :ok end) do
      {:ok, agent} = Agent.start_link(fn -> [] end)

      press = fn combo ->
        Agent.update(agent, &[combo | &1])
        reply.(combo)
      end

      {agent, press}
    end

    defp pressed(agent), do: agent |> Agent.get(& &1) |> Enum.reverse()

    defp steps(combos), do: Enum.flat_map(combos, &[{:press, &1}, {:pause, 0}])

    test "without a fence, the whole burst fires" do
      {agent, press} = recorder()

      assert {:ok, ~w(a b c)} = Mac.walk_burst(steps(~w(a b c)), nil, press)
      assert pressed(agent) == ~w(a b c)
    end

    test "a fence closed from the start holds everything: no press happens" do
      {agent, press} = recorder()

      assert {:halted, []} = Mac.walk_burst(steps(~w(a b c)), fn -> true end, press)
      assert pressed(agent) == []
    end

    # O caso da noite: o F4 aterrissa no MEIO da dormida do gap. As teclas já
    # apertadas ficam apertadas — uma prensa nunca é cancelada no meio — e a
    # cauda para no ar.
    test "the fence closes midway and only the tail stays in the air" do
      {agent, press} = recorder()
      fence = fn -> length(Agent.get(agent, & &1)) >= 2 end

      assert {:halted, ~w(a b)} = Mac.walk_burst(steps(~w(a b c d)), fence, press)
      assert pressed(agent) == ~w(a b)
    end

    test "erro de prensa continua vencendo: para na hora e reporta o erro" do
      {agent, press} =
        recorder(fn
          "b" -> {:error, :teclado_surdo}
          _ok -> :ok
        end)

      assert {:error, :teclado_surdo} = Mac.walk_burst(steps(~w(a b c)), nil, press)
      assert pressed(agent) == ~w(a b)
    end
  end
end
