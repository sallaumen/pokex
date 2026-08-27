defmodule Pokex.Bots.Engine.Orders do
  @moduledoc """
  What the engine ANSWERS: one shape, built in one place.

  The orders travel as a fact and three workers read them, so the shape is a
  contract and not a convenience. It was being assembled twenty times by hand
  from a keyword list, each site restating `route`, `fire` and `opening` — and a
  site that forgot one silently got the default rather than the intent.

  ## The four postures, which is all there ever was

  Every order the engine has ever given is one of four, plus what it asks the
  support for:

    * `walking/3` — the route goes, the hands are down.
    * `walking_and_firing/4` — the route goes and what is already biting gets
      answered. This is how a hunt leaves a pile behind without taking the
      whole walk in the teeth.
    * `standing/3` — the route holds and the hands are down: counting who is
      arriving, and nothing else.
    * `standing_and_firing/4` — the fight.

  `revive: :now` rides on any of them, because a revive needs no attack key and
  no particular posture — it is a separate hand.

  ## `opening: []` is not "do not fight"

  It means "fight, I have no keys to name". `Combat.Worker.opening_or/2` falls
  back to the combo he recorded at that kill spot, which is the right answer
  when the engine has no loadout to speak from. The order that means "do not
  fight" is `fire: :hold`, and it is given by name (`:handless`) so the feed can
  say why instead of going quiet.
  """

  @type phase ::
          :idle
          | :guarding
          | :travelling
          | :gathering
          | :sizing
          | :bunching
          | :engaged
          | :skipping
          | :closing
          | :emergency
          | :recovering
          | :unaided
          | :downed
          | :handless
          | :blind

  @type t :: %{
          phase: phase,
          band: :green | :yellow | :red,
          route: :go | :hold,
          fire: :hold | :free,
          opening: [String.t()],
          revive: :hold | :now,
          potion: :hold | :now,
          why: String.t()
        }

  @doc "The route goes and the hands stay down."
  @spec walking(phase, atom, String.t(), keyword) :: t
  def walking(phase, band, why, opts \\ []),
    do: new(phase, band, why, [route: :go, fire: :hold] ++ opts)

  @doc "The route goes and `keys` answer whatever is already on the pokémon."
  @spec walking_and_firing(phase, atom, [String.t()], String.t(), keyword) :: t
  def walking_and_firing(phase, band, keys, why, opts \\ []),
    do: new(phase, band, why, [route: :go, fire: :free, opening: keys] ++ opts)

  @doc "The route holds and the hands stay down."
  @spec standing(phase, atom, String.t(), keyword) :: t
  def standing(phase, band, why, opts \\ []),
    do: new(phase, band, why, [route: :hold, fire: :hold] ++ opts)

  @doc "The fight: the route holds and `keys` are spent."
  @spec standing_and_firing(phase, atom, [String.t()], String.t(), keyword) :: t
  def standing_and_firing(phase, band, keys, why, opts \\ []),
    do: new(phase, band, why, [route: :hold, fire: :free, opening: keys] ++ opts)

  # The posture goes FIRST and `Keyword` reads the first match, so what the named
  # builder chose is what stands: a caller's `opts` may add `revive:` but cannot
  # quietly turn a walk into a stand.
  defp new(phase, band, why, opts) do
    %{
      phase: phase,
      band: band,
      route: Keyword.fetch!(opts, :route),
      fire: Keyword.fetch!(opts, :fire),
      opening: Keyword.get(opts, :opening, []),
      revive: Keyword.get(opts, :revive, :hold),
      potion: Keyword.get(opts, :potion, :hold),
      why: why
    }
  end
end
