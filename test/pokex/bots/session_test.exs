defmodule Pokex.Bots.SessionTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Session

  setup do
    {:ok, session} = Session.start_link(name: nil)
    %{session: session}
  end

  test "each order increments the generation and returns it atomically", %{session: session} do
    assert Session.generation(session) == 0
    assert Session.order(:start, "iniciar", session) == 1
    assert Session.order(:stop, "parar", session) == 2
    assert Session.order(:hold, "foco perdido", session) == 3
    assert Session.generation(session) == 3
  end

  test "last_order records who ordered what", %{session: session} do
    assert Session.last_order(session) == nil

    Session.order(:stop, "parar", session)

    assert %{kind: :stop, reason: "parar", generation: 1, at: at} = Session.last_order(session)
    assert is_integer(at)
  end
end
