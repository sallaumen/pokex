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
      stun reached when it went out. "Stood where" is a GAME tile, not a place
      on the screen: the eye measures from the character and the character
      walks, so the cover carries the tile he was on and the comparison shifts
      by however far he has gone since (`covered?/3`). No coordinate at either
      end, or a floor change in between, and nobody is covered;
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

  @type cover :: %{
          at: integer,
          pet: {integer, integer} | nil,
          pos: {integer, integer, integer} | nil,
          points: [{integer, integer}]
        }

  @type t :: %{
          read?: boolean,
          age_ms: non_neg_integer | nil,
          pet_seen?: boolean,
          pet: {integer, integer} | nil,
          pos: {integer, integer, integer} | nil,
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
  heavy for this fight, and `pos:` the minimap tile he is standing on — the
  frame the stun's cover is compared in (see `covered?/3`).
  """
  @spec build(map | nil, non_neg_integer | nil, cover | nil, map, integer, keyword) :: t
  def build(crowd, listed, cover, config, now, opts \\ [])

  def build(%{read?: true} = crowd, listed, cover, config, now, opts) do
    fresh? = fresh?(cover, config, now)
    pin = config.pin_tiles
    pos = Keyword.get(opts, :pos)
    shift = shift(cover, pos)

    hostiles =
      crowd.hostiles
      |> Enum.map(&Map.put(&1, :asleep?, fresh? and covered?(&1, cover, shift)))
      |> Enum.sort_by(& &1.from_me)

    heavy? = Keyword.get(opts, :heavy?, false) or most_wear_skulls?(hostiles)
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
      pos: pos,
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

  def build(crowd, _listed, _cover, config, now, opts) do
    %{
      read?: false,
      age_ms: age(crowd, now),
      pet_seen?: false,
      pet: nil,
      pos: Keyword.get(opts, :pos),
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

  The points are written down in tiles from the CHARACTER, and the tile he
  stood on goes with them: he walks, and `covered?/3` needs both ends to put
  the two readings in the same frame.
  """
  @spec cover(t, map, integer) :: cover
  def cover(%{read?: true, pet_seen?: true} = siege, config, now) do
    reach = config.stun_reach_tiles

    points =
      for %{dx: dx, dy: dy, from_pet: from_pet} <- siege.hostiles,
          is_integer(from_pet) and from_pet <= reach,
          do: {dx, dy}

    %{at: now, pet: siege.pet, pos: siege.pos, points: points}
  end

  def cover(_unread_or_no_pet, _config, now),
    do: %{at: now, pet: nil, pos: nil, points: []}

  @doc """
  WHERE TO PARK THE POKÉMON when the hunt stops for a pile: `gap` tiles from
  HIM toward the pile the eye sees, so one empty tile stays between the two —
  "perto demais eu ocupo uma das oito bocas e ele luta com 7". The direction
  is the pile's centre, snapped to one of the eight; nil without an eye,
  without hostiles, or with the pile already centred on him.
  """
  @spec park_spot(t, pos_integer) :: {integer, integer} | nil
  def park_spot(%{read?: true, hostiles: [_ | _] = hostiles}, gap) do
    count = length(hostiles)
    cx = Enum.sum(Enum.map(hostiles, & &1.dx)) / count
    cy = Enum.sum(Enum.map(hostiles, & &1.dy)) / count
    reach = max(abs(cx), abs(cy))

    if reach < 0.5, do: nil, else: {gap * round(cx / reach), gap * round(cy / reach)}
  end

  def park_spot(_no_eye_or_nobody, _gap), do: nil

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

  # HIS OWN RULE JUDGES THE SKULL (09/09): "nunca há mistura: ou todos ou
  # nenhum". So ONE skull among bare heads is a misread, not an area — and
  # taking any single mark's word for it cost him the exit. MEASURED over 34 of
  # his frames that morning, 107 marks in an area with no skulls at all: one
  # mark came back wearing one (1%), and with several marks per reading that is
  # a bad call every few fights — one of them (08:49:30) refused a pile of four
  # already biting, with nobody loose. Against the fixtures the share is not
  # close: a real skull area reads 75% and 100%, a skull-less one 0% and 0%,
  # and the false call 17%. A lone creature wearing one still counts, which
  # fails toward caution.
  defp most_wear_skulls?(hostiles),
    do: Enum.count(hostiles, & &1.skull?) * 2 > length(hostiles)

  defp pinned?(%{from_pet: from_pet}, pin), do: is_integer(from_pet) and from_pet <= pin

  defp fresh?(%{at: at}, config, now) when is_integer(at),
    do: now - at <= config.stun_hold_ms

  defp fresh?(_no_cover, _config, _now), do: false

  # Asleep: a covered point within one tile of where the creature stands now —
  # AND both readings put in the same frame first.
  #
  # The eye measures in tiles from the CHARACTER, and he walks: `stun_hold_ms`
  # is seven seconds and the brain orders `route: :go` in half its phases, so a
  # cover taken before a couple of steps describes a screen that has moved
  # under it. A creature asleep on the floor has not moved at all, so its GAME
  # tile is the thing that did not change — which is what `shift/2` restores by
  # the tiles he walked. Read literally, an awake monster that walked into the
  # offset the sleeping one used to occupy came back "dormindo", `loose` fell
  # to zero, and `pile_closed?` opened the area on a pile that had not closed.
  defp covered?(%{dx: dx, dy: dy}, %{points: points}, {sx, sy}),
    do: Enum.any?(points, fn {px, py} -> max(abs(px - dx - sx), abs(py - dy - sy)) <= 1 end)

  defp covered?(_hostile, _no_cover, _unprovable_frame), do: false

  # How far he has walked since the cover was taken, in tiles — `nil` when the
  # two frames cannot be proven to be the same one (no coordinate at either
  # end, or a floor change in between). An unprovable frame puts NOBODY to
  # sleep: this number is the licence a revive is given on, and guessing it is
  # the one mistake that costs the character.
  defp shift(%{pos: {x1, y1, z}}, {x2, y2, z}), do: {x2 - x1, y2 - y1}
  defp shift(_no_cover_or_no_coordinate, _now), do: nil

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
