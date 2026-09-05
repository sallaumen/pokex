defmodule Pokex.Bots.ReviveLedger do
  @moduledoc """
  The revive stock ledger: how many he said he has, how many have gone out.

  A revive is an ITEM, finite, and the bot used to have no notion of that. One night measured
  the price: 189 revives dispatched in under two hours (~1.7 per minute), the stock ran out at
  23:43, and from then on every rule that "buys" something with a revive (arriving prepared,
  resetting the bar) paid with money that did not exist.

  The contract is the simplest thing that works: **typing the stock IS the restock button**. The
  `revive_stock` setting says how many he has NOW, at the moment he types it; the ledger counts
  every dispatch since then, and when the setting's number CHANGES the count resets by itself (a
  change means he has just counted again). Zero in the setting means "not counted": the whole
  budget switches off and nothing changes behaviour.

  The count is of DISPATCHES, not of consumption: the bot does not read the inventory, and a
  press the game refused counts as spent. It errs on the safe side, the ledger runs out before
  the pocket does, and the floor brake (`:stranded`) is still the net for when the count and
  reality diverge.

  Whoever spends NOTES it (`PlayerSupport`, the only place a revive leaves from); whoever
  decides ASKS (`remaining/0` travels in the situation frame). Same ETS mould as `SkillClock`.
  """

  alias Pokex.Settings

  @table :pokex_revive_ledger

  @doc false
  def table, do: @table

  @doc "Garante a tabela. Idempotente."
  @spec ensure_table() :: :ok
  def ensure_table do
    if :ets.whereis(@table) == :undefined do
      :ets.new(@table, [:set, :public, :named_table, write_concurrency: true])
    end

    :ok
  rescue
    ArgumentError -> :ok
  end

  @doc "Anota UM revive despachado, contra o estoque em vigor agora."
  @spec note() :: :ok
  def note do
    ensure_table()
    stock = Settings.get(:revive_stock)
    {_stock, spent} = current(stock)
    :ets.insert(@table, {:ledger, stock, spent + 1})
    :ets.insert(@table, {:last_note_at, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc """
  Has a revive gone out in the last `window_ms`? This is `HandWatch`'s question: the bot's
  revive calls `SkillClock.reset/0`, which erases the stamp of its own F4, so an F4 sighting in
  a late drain would be OWNERLESS and be read as his hand, counting the same item twice and
  re-resetting a clock that already holds fresh stamps from the post-revive burst. The ledger
  knows the time of the last dispatch, from either hand, and answers for it.
  """
  @spec noted_within?(pos_integer, integer) :: boolean
  def noted_within?(window_ms, now \\ System.monotonic_time(:millisecond)) do
    ensure_table()

    case :ets.lookup(@table, :last_note_at) do
      [{:last_note_at, at}] -> now - at <= window_ms
      [] -> false
    end
  end

  @doc """
  Stamps that a combo's F4 LEFT THE KEYBOARD just now: the end of the rescue, not its dispatch.

  The difference is the settle: the combo is stun -> a 1.5-2s wait -> F4, and `note/0` (which
  serves the STOCK) happens at dispatch. The post-revive blind window (`rescue_blackout_ms`)
  counted from the dispatch is DISPLACED by the whole settle: it covers the settle, when the
  pokémon is on the field on purpose and able to hit, and uncovers the first and second second
  after the F4, which is the real window. One night measured the cost of that displacement: 441
  keys "ready" that the game ignored, 320 of them in the first second after the F4, a 46%
  failure rate in the fight's bursts, each one buying a retry.
  """
  @spec landed() :: :ok
  def landed do
    ensure_table()
    :ets.insert(@table, {:last_landed_at, System.monotonic_time(:millisecond)})
    :ok
  end

  @doc "Has a combo's F4 gone out in the last `window_ms`? The blind window's question."
  @spec landed_within?(pos_integer, integer) :: boolean
  def landed_within?(window_ms, now \\ System.monotonic_time(:millisecond)) do
    ensure_table()

    case :ets.lookup(@table, :last_landed_at) do
      [{:last_landed_at, at}] -> now - at <= window_ms
      [] -> false
    end
  end

  @doc "How many have gone out since the last time he typed the stock."
  @spec spent() :: non_neg_integer
  def spent do
    ensure_table()
    {_stock, spent} = current(Settings.get(:revive_stock))
    spent
  end

  @doc """
  How many are left, or `nil` with the budget off (`revive_stock` at zero, "not counted"). Never
  negative: the count is approximate, and a negative number would look like a measurement.
  """
  @spec remaining() :: non_neg_integer | nil
  def remaining do
    case Settings.get(:revive_stock) do
      stock when is_integer(stock) and stock > 0 -> max(stock - spent(), 0)
      _off -> nil
    end
  end

  @doc "Esquece a conta — usado por teste e pela troca de personagem."
  @spec reset() :: :ok
  # …and the LANDING too. A reset that forgets the stock but remembers "the F4 just landed"
  # leaves the blind window armed for whoever comes next: in the suite the next test was born
  # inside a 2s blackout (order-dependent failures); in the game a character switch would
  # inherit two seconds of mute.
  def reset do
    ensure_table()
    :ets.delete(@table, :ledger)
    :ets.delete(@table, :last_note_at)
    :ets.delete(@table, :last_landed_at)
    :ok
  end

  # The count is valid for ONE typed value: if the setting changed since the last note, he
  # recounted the pocket and the old count dies here, with no settings observer needed.
  defp current(stock) do
    case :ets.lookup(@table, :ledger) do
      [{:ledger, ^stock, spent}] -> {stock, spent}
      _outro_estoque_ou_vazio -> {stock, 0}
    end
  end
end
