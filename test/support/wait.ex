defmodule Pokex.TestWait do
  @moduledoc """
  Two waits, and telling them apart is what nine hand-rolled copies got wrong.

  `eventually/2` is a DEADLINE: "this must become true, and here is how long I
  am willing to wait". A slower machine deserves more rope — the answer does not
  change, only how long it takes to arrive.

  `never/2` is a QUIET WINDOW: "for this long, this must NOT happen". The number
  is the assertion itself, not patience. Stretching it on a slow machine changes
  what is being claimed — a key pressed at 600 ms passes a 250 ms window and
  fails a 1.250 ms one — so this one never scales.

  A suite that spells both as `eventually` (17 of them written `refute
  eventually(…)`) cannot scale one without silently rewriting the other.

  ## The CI slack

  `test/test_helper.exs` already grants CI 5x the ExUnit timeout, measured:
  the vision tests chew the capture fixtures 3-6x slower on the 2-core runner.
  Deadlines here follow the same ruler and the same reason.
  """

  # Fine enough that a deadline rarely overshoots, coarse enough that 153 waits
  # do not become a busy loop.
  @poll_ms 10
  @ci_slack 5

  @doc "Polls until `fun` returns truthy. True if it did before the deadline."
  @spec eventually((-> as_boolean(term)), pos_integer) :: boolean
  def eventually(fun, timeout \\ 1_000),
    do: wait(fun, System.monotonic_time(:millisecond) + slack(timeout))

  @doc """
  True if `fun` stayed falsy for the whole window.

  Takes no default: a quiet window is always a deliberate number.
  """
  @spec never((-> as_boolean(term)), pos_integer) :: boolean
  def never(fun, window),
    do: not wait(fun, System.monotonic_time(:millisecond) + window)

  @doc "A deadline's budget on this machine — 5x on CI, as the ExUnit timeout is."
  @spec slack(pos_integer) :: pos_integer
  def slack(ms), do: if(System.get_env("CI"), do: ms * @ci_slack, else: ms)

  defp wait(fun, deadline) do
    cond do
      fun.() ->
        true

      System.monotonic_time(:millisecond) > deadline ->
        false

      true ->
        Process.sleep(@poll_ms)
        wait(fun, deadline)
    end
  end
end
