defmodule Pokex.Bots.Fisher.Skills do
  @moduledoc """
  Picks the next combat skill to press, VERIFIED against the skill-bar image.

  PokeXGames drops inputs — you press a skill and nothing comes out. A human spams the
  key and watches the bar: only when the icon darkens (goes on cooldown) did the press
  actually land, and only then do they move to the next skill. So we don't pace to a
  clock and assume the press stuck; the driver re-reads the skill bar EVERY tick and we
  press the highest-priority READY key. A skill that fired leaves the ready set (it's on
  cooldown now), so the next tick naturally advances to the next skill; a swallowed one
  stays ready and gets pressed again. The bar IS the confirmation — the clock never was.

  Pure and stateless: `pick/2` is a function of the priority order and the ready keys.
  """

  @doc """
  The hotbar key to press THIS tick, given the priority-ordered `order` (strongest first)
  and the READY keys read from the skill bar. Returns the highest-priority ready key; `nil`
  when nothing in the rotation is ready (auto-attack keeps hitting and we retry next tick,
  firing the instant one comes up). A `ready` of `nil` means "no skill-bar reading available"
  → press the strongest key blindly (best effort, unverified).
  """
  @spec pick([String.t()], [String.t()] | nil) :: String.t() | nil
  def pick(order, ready) when is_list(ready), do: Enum.find(order, &(&1 in ready))
  def pick(order, nil), do: List.first(order)
end
