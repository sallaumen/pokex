defmodule Pokex.StockProofBody do
  @moduledoc false
  use GenServer

  alias Pokex.Rig.Fake

  def start_link(owner), do: GenServer.start_link(__MODULE__, owner)

  @impl true
  def init(owner), do: {:ok, owner}

  @impl true
  def handle_call({:perform, _actions, :high, _at}, _from, owner) do
    captures = Enum.count(Fake.calls(), &match?({:capture, _, "ball_stock.raw"}, &1))
    send(owner, {:ball_thrown, captures})
    {:reply, :ok, owner}
  end
end
