defmodule Pokex.Bots.Engine.Siege do
  @moduledoc """
  THE SIEGE, JUDGED: what the eye's reading means for the one decision that
  kills him — recalling the pokémon with something awake close enough to bite
  HIM before it is back.

  Pure. `build/6` runs inside `Logic.tick/4` on the `:crowd` reading
  (`Pokex.Bots.CrowdScan`), the battle list's count, and the brain's own
  memory of the last stun (`stun_cover`); the simulator's bench calls the very
  same function on the reading its world produces.

  ## The four piles

    * `pinned` — biting the pokémon (`from_pet ≤ pin_tiles`);
    * `covered` — asleep: the stun is fresh and this creature stood where the
      stun reached when it went out;
    * `loose` — awake and away from the pile;
    * `unseen` — on the list but not in the picture. With a fresh stun they
      are the pile stacked on itself (bars hide bars); without one they are
      awake somewhere unknown, and the gap does not close.

  ## Skulls are the area's, not the creature's

  "Nunca existe bicho com caveira e sem caveira misturados: ou são todos com
  caveira ou nenhum." One `heavy?` per fight, latched by the brain
  (`logic.heavy_area?`) because an effect over the pile hides skulls without
  changing the area.

  ## The recall gap

  `recall_gap_ok?` is true when nobody is awake (loose, pinned or unseen), or
  when the nearest awake creature is at least the area's guard from HIM:
  `@guard_heavy` (4 tiles) with skulls, `@guard_light` (2) without ("sem
  caveira é brincadeira"). Both become keys when the brain obeys (PR 3).

  This module DECIDES nothing yet: in this PR the brain writes what the eye
  would say next to every revive it gives or holds ("o olho diria: …"), and a
  night of that shows where they disagree before the eye is given the key.
  """

  @guard_heavy 4
  @guard_light 2

  @type hostile :: %{
          dx: integer,
          dy: integer,
          from_me: non_neg_integer,
          from_pet: non_neg_integer | nil,
          hp_pct: 0..100,
          skull?: boolean,
          asleep?: boolean
        }

  @type cover :: %{at: integer, pet: {integer, integer} | nil, points: [{integer, integer}]}

  @type t :: %{
          read?: boolean,
          age_ms: non_neg_integer | nil,
          pet_seen?: boolean,
          pet: {integer, integer} | nil,
          pin: pos_integer,
          heavy?: boolean,
          hostiles: [hostile],
          pinned: non_neg_integer,
          covered: non_neg_integer,
          loose: non_neg_integer,
          unseen: non_neg_integer,
          nearest_awake_from_me: non_neg_integer | nil,
          recall_gap_ok?: boolean
        }

  @doc """
  The siege from a `:crowd` reading (or `nil` when there is no eye), the
  list's count, the last stun's cover, the engine config and the clock.

  Options: `heavy?: true` when the brain's latch already declared the area
  heavy for this fight.
  """
  @spec build(map | nil, non_neg_integer | nil, cover | nil, map, integer, keyword) :: t
  def build(crowd, listed, cover, config, now, opts \\ [])

  def build(%{read?: true} = crowd, listed, cover, config, now, opts) do
    fresh? = fresh?(cover, config, now)
    pin = config.pin_tiles

    hostiles =
      crowd.hostiles
      |> Enum.map(&Map.put(&1, :asleep?, fresh? and covered?(&1, cover)))
      |> Enum.sort_by(& &1.from_me)

    heavy? = Keyword.get(opts, :heavy?, false) or Enum.any?(hostiles, & &1.skull?)
    pinned = Enum.count(hostiles, &pinned?(&1, pin))
    covered = Enum.count(hostiles, & &1.asleep?)
    awake = Enum.reject(hostiles, & &1.asleep?)
    loose = Enum.count(awake, &(not pinned?(&1, pin)))
    unseen = max((listed || 0) - length(hostiles), 0)
    unseen_awake = if fresh?, do: 0, else: unseen
    nearest = awake |> Enum.map(& &1.from_me) |> Enum.min(fn -> nil end)
    guard = if heavy?, do: @guard_heavy, else: @guard_light

    %{
      read?: true,
      age_ms: age(crowd, now),
      pet_seen?: crowd.pet != nil,
      pet: pet_offset(crowd.pet),
      pin: pin,
      heavy?: heavy?,
      hostiles: hostiles,
      pinned: pinned,
      covered: covered,
      loose: loose,
      unseen: unseen,
      nearest_awake_from_me: nearest,
      recall_gap_ok?: unseen_awake == 0 and (nearest == nil or nearest >= guard)
    }
  end

  def build(crowd, _listed, _cover, config, now, _opts) do
    %{
      read?: false,
      age_ms: age(crowd, now),
      pet_seen?: false,
      pet: nil,
      pin: config.pin_tiles,
      heavy?: false,
      hostiles: [],
      pinned: 0,
      covered: 0,
      loose: 0,
      unseen: 0,
      nearest_awake_from_me: nil,
      recall_gap_ok?: false
    }
  end

  @doc """
  The stun's cover, taken the moment the control goes out (or the chain ends
  in one): where the pokémon was and which creatures stood within the stun's
  reach. Whoever arrives later matches no point and stays awake.

  Without a pokémon in the picture there is no reach to measure from, and
  nobody is covered — the safe side of not knowing.
  """
  @spec cover(t, map, integer) :: cover
  def cover(%{read?: true, pet_seen?: true} = siege, config, now) do
    reach = config.stun_reach_tiles

    points =
      for %{dx: dx, dy: dy, from_pet: from_pet} <- siege.hostiles,
          is_integer(from_pet) and from_pet <= reach,
          do: {dx, dy}

    %{at: now, pet: siege.pet, points: points}
  end

  def cover(_unread_or_no_pet, _config, now), do: %{at: now, pet: nil, points: []}

  @doc "One short sentence for the feed: what the eye would say about a recall now."
  @spec summary(t) :: String.t()
  def summary(%{read?: false, age_ms: age}) when is_integer(age),
    do: "sem olho (foto de #{age} ms) → só o sono fresco vale"

  def summary(%{read?: false}), do: "sem olho → só o sono fresco vale"

  def summary(siege) do
    verdict = if siege.recall_gap_ok?, do: "revive seguro", else: "segurando"
    area = if siege.heavy?, do: "olho (caveira)", else: "olho"

    "#{area}: #{pinned_words(siege)} · #{loose_words(siege)} · #{siege.unseen} sem ver → #{verdict}"
  end

  @doc "The siege as the decision record files it: numbers, no sentences."
  @spec record(t) :: map
  def record(siege) do
    %{
      read: siege.read?,
      heavy: siege.heavy?,
      pinned: siege.pinned,
      covered: siege.covered,
      loose: siege.loose,
      unseen: siege.unseen,
      gap: siege.recall_gap_ok?
    }
  end

  # -- the piles ------------------------------------------------------------------

  defp pinned?(%{from_pet: from_pet}, pin), do: is_integer(from_pet) and from_pet <= pin

  defp fresh?(%{at: at}, config, now) when is_integer(at),
    do: now - at <= config.stun_hold_ms

  defp fresh?(_no_cover, _config, _now), do: false

  # Asleep: a covered point within one tile of where the creature stands now.
  defp covered?(%{dx: dx, dy: dy}, %{points: points}),
    do: Enum.any?(points, fn {px, py} -> max(abs(px - dx), abs(py - dy)) <= 1 end)

  defp covered?(_hostile, _no_cover), do: false

  defp pet_offset(%{dx: dx, dy: dy}), do: {dx, dy}
  defp pet_offset(_no_pet), do: nil

  defp age(%{at: at}, now) when is_integer(at), do: max(now - at, 0)
  defp age(_no_reading, _now), do: nil

  # -- words ---------------------------------------------------------------------------

  defp pinned_words(%{pinned: 0}), do: "ninguém colado"

  defp pinned_words(%{hostiles: hostiles, pinned: pinned, pin: pin}) do
    asleep = Enum.count(hostiles, &(pinned?(&1, pin) and &1.asleep?))

    cond do
      asleep == pinned -> "#{pinned(pinned)} dormindo"
      asleep == 0 -> "#{pinned(pinned)} #{awake(pinned)}"
      true -> "#{pinned(asleep)} dormindo, #{pinned - asleep} #{awake(pinned - asleep)}"
    end
  end

  defp pinned(1), do: "1 colado"
  defp pinned(n), do: "#{n} colados"

  defp awake(1), do: "acordado"
  defp awake(_n), do: "acordados"

  defp loose_words(%{loose: 0}), do: "ninguém solto"

  defp loose_words(%{hostiles: hostiles, loose: loose, pin: pin}) do
    nearest =
      hostiles
      |> Enum.reject(&(&1.asleep? or pinned?(&1, pin)))
      |> Enum.map(& &1.from_me)
      |> Enum.min()

    "#{loose} #{if loose == 1, do: "solto", else: "soltos"} a #{nearest} #{tiles(nearest)}"
  end

  defp tiles(1), do: "tile"
  defp tiles(_n), do: "tiles"
end
