defmodule Pokex.Bots.BodyStillTest do
  @moduledoc """
  A tecla que não anda junto.

  "Ele continuou andando depois de fechar o grupo (…) o próprio teclado
  deveria saber que essa tecla é especial, e com ela não se pode andar junto"
  (Lucas, 02/09). As setas são estado do Body; `:still` na frente de uma
  sequência solta o que está segurado antes de ela sair, no laço do Body.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Body
  alias Pokex.Rig.Fake

  setup do
    start_supervised!({Fake, %{}})
    pid = start_supervised!(%{id: :still_body, start: {Body, :start_link, [[name: :still_body]]}})
    %{body: pid}
  end

  test ":still solta as setas antes da sequência sair", %{body: body} do
    :ok = Body.hold(["up", "left"], body)
    assert :ok = Body.perform([:still, {:press, "f4"}], :critical, body)

    calls = Fake.calls()
    assert Enum.sort(for {:key_up, key} <- calls, do: key) == ["left", "up"]

    solta = Enum.find_index(calls, &(&1 == {:key_up, "up"}))
    prensa = Enum.find_index(calls, &(&1 == {:press, "f4"}))
    assert solta < prensa, "o F4 saiu antes de soltar a seta: #{inspect(calls)}"
    assert Body.held(body) == []
  end

  test "sem :still a sequência sai com as setas como estão", %{body: body} do
    :ok = Body.hold(["up"], body)
    assert :ok = Body.perform([{:press, "3"}], :high, body)

    refute Enum.any?(Fake.calls(), &match?({:key_up, _}, &1))
    assert Body.held(body) == ["up"]
  end
end
