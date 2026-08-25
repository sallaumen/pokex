defmodule Pokex.Bots.Engine.OrdersTest do
  @moduledoc """
  A forma é um contrato: três workers leem esse fato. Um site que montava a
  ordem à mão e esquecia uma chave ficava com o padrão em vez da intenção.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Engine.Orders

  test "andar é rota indo e mãos baixas" do
    o = Orders.walking(:travelling, :green, "andando a rota")

    assert %{route: :go, fire: :hold, opening: [], revive: :hold, potion: :hold} = o
    assert o.phase == :travelling
    assert o.why == "andando a rota"
  end

  test "andar batendo carrega as teclas que vai gastar" do
    o = Orders.walking_and_firing(:unaided, :yellow, ~w(7 8), "andando sem abrir pilha")

    assert %{route: :go, fire: :free, opening: ~w(7 8)} = o
  end

  test "parar é rota segura e mãos baixas" do
    assert %{route: :hold, fire: :hold} = Orders.standing(:sizing, :green, "contando")
  end

  test "parar batendo é a luta" do
    assert %{route: :hold, fire: :free, opening: ~w(3 4)} =
             Orders.standing_and_firing(:engaged, :green, ~w(3 4), "matando")
  end

  test "o revive pega carona em qualquer postura: não precisa de tecla de ataque" do
    assert %{revive: :now, route: :go, fire: :hold} =
             Orders.walking(:downed, :green, "pedindo de novo", revive: :now)

    assert %{revive: :now, route: :hold, fire: :free} =
             Orders.standing_and_firing(:emergency, :red, ~w(3), "vermelho", revive: :now)
  end

  # O que o chamador passa não pode virar uma postura que ele não pediu: quem
  # escolheu andar, anda.
  test "opts não sobrescrevem a postura que o construtor nomeou" do
    o = Orders.walking(:travelling, :green, "andando", route: :hold, fire: :free)

    assert o.route == :go
    assert o.fire == :hold
  end
end
