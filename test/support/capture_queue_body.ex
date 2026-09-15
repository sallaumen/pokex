defmodule Pokex.CaptureQueueBody do
  @moduledoc false
  use GenServer

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  @impl true
  def init(opts), do: {:ok, {Keyword.fetch!(opts, :owner), Keyword.get(opts, :replies, [])}}

  @impl true
  def handle_call({:perform, actions, priority, _at}, _from, {owner, replies}) do
    {result, rest} =
      case replies do
        [result | rest] -> {result, rest}
        [] -> {:ok, []}
      end

    send(owner, {:capture_attempt, priority, actions, result})
    {:reply, result, {owner, rest}}
  end
end
