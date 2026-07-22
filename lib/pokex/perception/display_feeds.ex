defmodule Pokex.Perception.DisplayFeeds do
  @moduledoc """
  The feeds a WATCHING page needs, attached while it is open.

  Feeds are demand-driven: one that nobody attaches never captures and never
  publishes. `:hud` has a permanent consumer (the stock alerts), but `:team`
  and `:minimap` exist purely so Lucas can SEE his team and position — so
  their demand is a page being open, and it disappears when he closes it. A
  LiveView dying detaches on its own (the feed monitors its consumers), so
  there is nothing to clean up.

  Attaching is best-effort: a feed that is not running yet must never take a
  page down with it.
  """

  require Logger

  alias Pokex.Perception

  @keys [:hud, :team, :minimap]

  def keys, do: @keys

  @doc "Attach the calling process to every display feed. Returns the ones that took."
  def attach_all(keys \\ @keys) do
    Enum.filter(keys, fn key ->
      try do
        Perception.attach(key)
        true
      catch
        kind, reason ->
          Logger.debug("DisplayFeeds: #{key} indisponível (#{inspect({kind, reason})})")
          false
      end
    end)
  end

  @doc "Detach the calling process (a dying LiveView is detached automatically anyway)."
  def detach_all(keys \\ @keys) do
    Enum.each(keys, fn key ->
      try do
        Perception.detach(key)
      catch
        _kind, _reason -> :ok
      end
    end)
  end
end
