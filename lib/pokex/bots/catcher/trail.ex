defmodule Pokex.Bots.Catcher.Trail do
  @moduledoc """
  The shiny's identity, travelling with its health bar until it falls.

  "Cor nenhuma resolve isso" (11/09): the guard sees the shiny ALIVE by its
  colour, but the corpse is different art — the Shiny Golem's live shell is a
  purplish dark (47,43,46), the dead one a neutral grey — and the cave's light
  changes both again. Measured on his frames of 09:13: the corpse was on
  screen with ZERO pixels of the taught tone. So the corpse cannot be found by
  what the live creature looked like. It CAN be found by where the live
  creature was when its bar disappeared.

  The eye (`CrowdWatch`) already reads every creature's bar a few times a
  second, as SCREEN points. This module keeps those readings as TRACKS in
  WORLD tiles — the minimap's position plus the screen offset over the tile —
  so a track survives the character walking, and follows each creature from
  look to look by nearest neighbour with a small velocity guess. The guard's
  blob (`CrowdScan.mark_special/3`) names ONE of those tracks the hunted one;
  when the hunted bar is gone for a couple of looks, its last place is the
  ANCHOR: the tile the corpse is lying on, colour or no colour, item light or
  not. His own pokémon standing on the hunted creature (it covered the Golem
  one look after the sighting, 09:12:55) is an occlusion, not a death: the
  track coasts while the pet is on it.

  Pure: the worker feeds it readings and asks for the anchor in today's screen.
  """

  # A creature walks about a tile a second and the eye looks 4× a second in a
  # fight, 1× walking: a tile and a half also absorbs the minimap's whole-tile
  # jitter between two readings taken from the same place.
  @gate_tiles 1.5
  # looks without a bar before an ordinary track is forgotten
  @lost_after 4
  # …and before a HUNTED bar gone is a corpse: two looks (half a second in a
  # fight) is a bar hidden by an animation frame, not a death — three is a death
  alias Pokex.Settings

  @fall_after 3
  # the pet on top of the hunted track: it is covered, not dead — but not forever
  @occluded_max 12
  # how long a corpse is worth a ball (the item light lasts ~34 s; a corpse minutes)
  @anchor_ttl_ms 120_000
  # A SHINY IS ALIVE WHILE ITS SPARKLE SHOWS. The game (11/09): the shiny falls
  # and becomes a body, and the star beside its name leaves only then. So a
  # hunted bar missing from the eye's read is a DEATH only once the guard's
  # sparkle is gone. Under the chain's green haze the guard loses the star for
  # seconds with the shiny alive (19:15:51-53 of 11/09: three scans without it,
  # then back at the same spot), so mid-fight the corpse waits a long grace
  # after the sparkle's last sighting — and when the battle list is EMPTY
  # (`pile_dead?`, the brain's count) the wait is over: nothing alive is left
  # to be hidden, the bar gone is the body.
  @shiny_grace_ms 3_500
  # …and the body lies where the bar was JUST before the sparkle left. A hunted
  # bar lost far longer than this wandered off (or the guard hallucinated a
  # sparkle elsewhere): there is no body at that stale spot — drop it, no ball.
  # O número mora no `Settings` (`corpse_fresh_ms`): ele nasceu 6 s, era curto
  # pra briga longa, e o ótimo é do dono da caçada.
  # …E QUANTO TEMPO UMA CENA CONTINUA SENDO "A CENA DO SHINY". Passado isto sem
  # nenhum brilho, a caçada é uma caçada comum de novo e o rastro volta a só
  # marcar corpo do bicho que a cor apontou. É a trava do modo largo: sem ela
  # cada comum morto viraria bola, a noite inteira.
  @shiny_scene_ms 30_000

  # AS QUEDAS QUE ESTA OLHADA JOGOU FORA por velhice, pro worker poder DIZER.
  #
  # "Às vezes eu preciso usar uns 5, 6 revives pra matar um shiny, e nesses
  # casos ele não joga pokébola" (Lucas, 14/09). Medido no diário: um terço das
  # brigas com brilho na tela nunca produz a linha `caiu em` — e o descarte por
  # `@corpse_fresh_ms` era MUDO, então não havia como saber se era este ou
  # outro. Vale só pra olhada mais recente.
  defstruct tracks: %{}, next_id: 1, anchors: [], pos: nil, sparkle_at: nil, dropped: []

  @type point :: {integer, integer}
  @type world :: {float, float}
  @type ref :: %{me: point, tile: pos_integer, pos: {integer, integer, integer} | nil}
  @type track :: %{
          id: pos_integer,
          world: world,
          prev: world | nil,
          screen: point,
          seen_at: integer,
          misses: non_neg_integer,
          occluded: non_neg_integer,
          hunted?: boolean,
          name: String.t() | nil,
          px: non_neg_integer | nil
        }
  @type anchor :: %{world: world, name: String.t(), px: non_neg_integer | nil, fallen_at: integer}
  @type t :: %__MODULE__{
          tracks: %{pos_integer => track},
          next_id: pos_integer,
          anchors: [anchor],
          pos: {integer, integer, integer} | nil,
          sparkle_at: integer | nil
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  One look of the eye. Hostiles carrying `special?: true` (the guard's blob on
  their body, `CrowdScan.mark_special/3`) become — or stay — the hunted track.
  `shiny_on?` says the guard still sees a sparkle (the shiny is alive);
  `pile_dead?` says the battle list is empty (a hunted bar gone is a body now).
  An unread look changes nothing: blindness is not absence.
  """
  @spec observe(t, map, ref, integer) :: t
  def observe(trail, %{read?: true, hostiles: hostiles} = reading, ref, now) do
    ref = frame(trail, ref)
    trail = %{trail | pos: ref.pos}
    seen = Enum.map(hostiles, &Map.put(&1, :world, to_world(&1.point, ref)))
    pet = pet_world(reading, ref)

    # the shiny is alive while its sparkle is on screen (the guard's fresh
    # sparkle points, `shiny_on?`); a body appears only after it has left —
    # right away with the battle list empty, after the grace otherwise.
    sparkle_on? = Map.get(reading, :shiny_on?, false)
    sparkle_at = if sparkle_on?, do: now, else: trail.sparkle_at
    sparkle_gone_long? = sparkle_at == nil or now - sparkle_at >= @shiny_grace_ms
    may_fall? = not sparkle_on? and (Map.get(reading, :pile_dead?, false) or sparkle_gone_long?)

    {tracks, left} = match(Map.values(trail.tracks), seen, pet, now)

    born =
      left
      |> Enum.with_index(trail.next_id)
      |> Enum.map(fn {hostile, id} -> birth(hostile, id, now) end)

    # O RASTRO INTEIRO VIRA ALVO ENQUANTO A CENA É DE SHINY.
    #
    # "Bora fazer ele tentar jogar a bola no rastro inteiro, pra garantir, mesmo
    # que pegue outros pokemons no caminho tb (…) o importante é não deixar
    # shiny para trás" (Lucas, 13/09).
    #
    # Fora do modo largo só vira corpo a trilha que a COR apontou (`hunted?`) —
    # e um shiny que a cor não marcou naquele instante não deixa âncora, não
    # ganha bola, e fica pra trás. No modo largo, com o brilho tendo aparecido
    # nesta cena, toda trilha que sumiu vira alvo: é ele trocando bola por
    # certeza, de olhos abertos.
    wide? = wide?(trail, now)

    {fallen, alive} =
      if may_fall?, do: Enum.split_with(tracks, &fallen?(&1, wide?)), else: {[], tracks}

    # UM SÓ CORPO POR SHINY. Com o minimapa congelado embaixo de uma tela que
    # rola, o MESMO shiny virou dois rastros caçados a dois tiles um do outro e
    # os dois caíram — uma bola na areia de cada lado do corpo (19:50 de
    # 11/09). Quem caiu com outra barra caçada vista MAIS TARDE é o gêmeo
    # velho: não há corpo ali.
    #
    # …E ELA FICA DE PÉ NO MODO LARGO. O gêmeo velho não é um alvo a mais: é o
    # MESMO shiny contado duas vezes, e a segunda bola cai na areia. O que o
    # modo largo abre é trilha de OUTRO bicho; fantasma continua fora.
    fallen = drop_twins(fallen, tracks)

    # only a bar seen just before the sparkle left is a body; a hunted bar lost
    # far longer wandered off — no corpse there, and no ball at the stale spot.
    {corpses, velhos} = Enum.split_with(fallen, &(now - &1.seen_at <= corpse_fresh_ms()))
    kept = Enum.reject(alive, &lost?/1)

    %{
      trail
      | tracks: Map.new(kept ++ born, &{&1.id, &1}),
        next_id: trail.next_id + length(born),
        anchors: Enum.map(corpses, &fall(&1, now)) ++ trail.anchors,
        dropped: Enum.map(velhos, &%{name: &1.name, hunted?: &1.hunted?, age: now - &1.seen_at}),
        sparkle_at: sparkle_at
    }
  end

  def observe(trail, _unread, _ref, _now), do: %{trail | dropped: []}

  @doc """
  The guard's blob when the eye's reading did not carry the mark: the track
  whose body the blob sits on becomes the hunted one; with no body there yet, a
  hunted track is born on the blob (the bar can come one look later).
  """
  @spec hunt_at(t, point, String.t(), non_neg_integer | nil, ref, integer) :: t
  def hunt_at(trail, {_, _} = point, name, px, ref, now) do
    ref = frame(trail, ref)
    world = to_world(point, ref)

    case nearest(Map.values(trail.tracks), world) do
      {track, _rest} ->
        # O BRILHO É UM AVISTAMENTO, não uma etiqueta. Ele dizia só "este é o
        # caçado" e deixava a posição e a hora da BARRA — então um rastro que o
        # olho tinha perdido oito segundos antes seguia sendo a evidência mais
        # nova do shiny, e o corpo era cravado onde ele NÃO estava (19:50 de
        # 11/09: a barra vista pela última vez em 1720,918, o brilho já em
        # 1418,842, a bola na areia um tile ao lado do corpo). Ver a estrela é
        # ver o bicho: onde ela está, ele está, agora.
        put_track(trail, %{
          track
          | hunted?: true,
            name: name,
            px: px,
            prev: track.world,
            world: world,
            screen: point,
            seen_at: now,
            misses: 0,
            occluded: 0
        })

      nil ->
        track = birth(%{point: point, world: world}, trail.next_id, now)

        put_track(%{trail | next_id: trail.next_id + 1}, %{
          track
          | hunted?: true,
            name: name,
            px: px
        })
    end
  end

  @doc "The hunted creature still standing, with today's screen point — or nil."
  @spec hunted(t, ref) :: %{screen: point, world: world, name: String.t() | nil} | nil
  def hunted(trail, ref) do
    case Enum.find(Map.values(trail.tracks), & &1.hunted?) do
      nil ->
        nil

      track ->
        %{screen: to_screen(track.world, frame(trail, ref)), world: track.world, name: track.name}
    end
  end

  @doc """
  Where the hunted creature fell, in today's screen — the corpse's tile. Fresh
  ones first; `nil` past the TTL or when nothing hunted ever fell.
  """
  @spec anchors(t, ref, integer) :: [
          %{
            screen: point,
            world: world,
            name: String.t(),
            px: non_neg_integer | nil,
            fallen_at: integer
          }
        ]
  def anchors(trail, ref, now) do
    ref = frame(trail, ref)

    for anchor <- trail.anchors, now - anchor.fallen_at <= @anchor_ttl_ms do
      Map.put(anchor, :screen, to_screen(anchor.world, ref))
    end
  end

  @doc "Every creature still standing, in today's screen — a ball never flies onto one."
  @spec standing(t, ref) :: [point]
  def standing(trail, ref) do
    ref = frame(trail, ref)
    for track <- Map.values(trail.tracks), track.misses == 0, do: to_screen(track.world, ref)
  end

  @doc "The ball flew at this anchor: it is spent."
  @spec spend(t, world) :: t
  def spend(trail, world),
    do: %{trail | anchors: Enum.reject(trail.anchors, &(&1.world == world))}

  # --- the frame ---------------------------------------------------------------

  # The minimap may be unreadable for a look; the last position it gave is the
  # best guess (the character rarely moves between two looks a quarter second
  # apart), and with none ever read the world is the screen over the tile.
  defp frame(trail, %{pos: nil} = ref), do: %{ref | pos: trail.pos || {0, 0, 0}}
  defp frame(_trail, ref), do: ref

  defp to_world({sx, sy}, %{me: {mx, my}, tile: tile, pos: {px, py, _z}}),
    do: {px + (sx - mx) / tile, py + (sy - my) / tile}

  defp to_screen({wx, wy}, %{me: {mx, my}, tile: tile, pos: {px, py, _z}}),
    do: {mx + round((wx - px) * tile), my + round((wy - py) * tile)}

  defp pet_world(%{pet: %{point: point}}, ref), do: to_world(point, ref)
  defp pet_world(_no_pet, _ref), do: nil

  # --- following ------------------------------------------------------------------

  # Where the creature should be now if it kept walking as it did: the guess
  # that keeps two creatures crossing paths from swapping identities.
  defp predict(%{world: {x, y}, prev: {px, py}, misses: 0}),
    do: {x + (x - px) / 2, y + (y - py) / 2}

  defp predict(%{world: world}), do: world

  # CLOSEST PAIRS FIRST, over every track at once. Hunted-first greedy let a
  # neighbour standing ONE tile away steal the hunted track the moment the
  # shiny fell (its own bar gone, the neighbour's bar inside the gate), so the
  # track walked onto the neighbour and never fell — no anchor, no ball. With
  # the pairs sorted by distance the neighbour's own track claims it at
  # distance zero first, and the hunted track is left with nothing: a miss,
  # and three misses are the fall. Ties go to the hunted track.
  defp match(tracks, hostiles, pet, now) do
    # by INDEX, never by value: two creatures crossing stand on the same point
    # for a look and are two equal maps
    indexed = Enum.with_index(hostiles)

    pairs =
      for track <- tracks,
          {hostile, i} <- indexed,
          d = distance(hostile.world, predict(track)),
          d <= @gate_tiles,
          do: {d, not track.hunted?, track, hostile, i}

    {hits, used_tracks, used_hostiles} =
      pairs
      |> Enum.sort_by(fn {d, common?, track, _h, _i} -> {d, common?, -track.seen_at} end)
      |> Enum.reduce({[], MapSet.new(), MapSet.new()}, fn {_d, _c, track, hostile, i},
                                                          {hits, ts, hs} ->
        if MapSet.member?(ts, track.id) or MapSet.member?(hs, i),
          do: {hits, ts, hs},
          else: {[hit(track, hostile, now) | hits], MapSet.put(ts, track.id), MapSet.put(hs, i)}
      end)

    misses =
      for track <- tracks, not MapSet.member?(used_tracks, track.id), do: miss(track, pet)

    left = for {hostile, i} <- indexed, not MapSet.member?(used_hostiles, i), do: hostile
    {hits ++ misses, left}
  end

  # O GÊMEO É O QUE ESTÁ NO MESMO LUGAR, não o que é mais velho.
  #
  # Com o minimapa congelado embaixo de uma tela que rola, o MESMO shiny virou
  # dois rastros caçados a DOIS TILES um do outro e os dois caíram — uma bola na
  # areia de cada lado do corpo (19:50 de 11/09). A peneira que nasceu dali
  # guardava só a trilha caçada MAIS NOVA, e isso confundia duas coisas
  # diferentes: "o mesmo bicho contado duas vezes" e "dois bichos".
  #
  # "Quando tem dois shinies na minha tela, normalmente ele joga pokébola só em
  # um" (Lucas, 14/09). Era isto: dois shinies de verdade, em cantos diferentes,
  # e o mais velho descartado como fantasma.
  #
  # Fantasma é quem tem outra trilha caçada MAIS NOVA em cima dele. Longe, é
  # outro bicho.
  @twin_tiles 2.5

  defp drop_twins(fallen, tracks) do
    Enum.reject(fallen, fn track ->
      track.hunted? and Enum.any?(tracks, &twin_of?(&1, track))
    end)
  end

  defp twin_of?(other, track) do
    other.hunted? and other.id != track.id and other.seen_at > track.seen_at and
      tiles_apart(other.world, track.world) <= @twin_tiles
  end

  defp tiles_apart({ax, ay}, {bx, by}), do: :math.sqrt((ax - bx) ** 2 + (ay - by) ** 2)

  defp corpse_fresh_ms, do: Settings.get(:corpse_fresh_ms)

  defp nearest(hostiles, {gx, gy}) do
    hostiles
    |> Enum.map(&{distance(&1.world, {gx, gy}), &1})
    |> Enum.filter(fn {d, _h} -> d <= @gate_tiles end)
    |> Enum.min_by(fn {d, _h} -> d end, fn -> nil end)
    |> case do
      nil -> nil
      {_d, hostile} -> {hostile, List.delete(hostiles, hostile)}
    end
  end

  defp distance({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  defp hit(track, hostile, now) do
    %{
      track
      | prev: track.world,
        world: hostile.world,
        screen: hostile.point,
        seen_at: now,
        misses: 0,
        occluded: 0,
        hunted?: track.hunted? or Map.get(hostile, :special?, false),
        name: Map.get(hostile, :special_name) || track.name,
        px: Map.get(hostile, :special_px) || track.px
    }
  end

  # The pet standing on a hunted creature hides its bar: covered, not gone.
  defp miss(%{hunted?: true} = track, pet) when pet != nil do
    if distance(track.world, pet) <= 1.0 and track.occluded < @occluded_max,
      do: %{track | occluded: track.occluded + 1},
      else: %{track | misses: track.misses + 1}
  end

  defp miss(track, _pet), do: %{track | misses: track.misses + 1}

  defp birth(hostile, id, now) do
    %{
      id: id,
      world: hostile.world,
      prev: nil,
      screen: hostile.point,
      seen_at: now,
      misses: 0,
      occluded: 0,
      hunted?: Map.get(hostile, :special?, false),
      name: Map.get(hostile, :special_name),
      px: Map.get(hostile, :special_px)
    }
  end

  defp fallen?(%{hunted?: true, misses: misses}, _wide?), do: misses >= @fall_after
  defp fallen?(%{misses: misses}, true), do: misses >= @fall_after
  defp fallen?(_track, false), do: false

  # A CENA AINDA É DE SHINY? O modo largo só vale enquanto o brilho desta cena
  # for recente: sem esta pergunta, uma caçada sem shiny nenhum jogaria bola em
  # cada comum que cai, a noite inteira. `sparkle_at` nil é "nunca vi brilho",
  # que aqui é NÃO — o contrário do que ele significa no `may_fall?`, onde a
  # ausência de brilho é o que libera o corpo.
  defp wide?(%{sparkle_at: at}, now) when is_integer(at),
    do: now - at <= @shiny_scene_ms and Settings.get(:capture_whole_trail) == true

  defp wide?(_nunca_viu_brilho, _now), do: false

  defp lost?(%{hunted?: true}), do: false
  defp lost?(%{misses: misses}), do: misses >= @lost_after

  # O NOME DIZ DE QUEM É O CORPO. A âncora do modo largo é de um bicho que a cor
  # NÃO apontou — chamá-la de "shiny" faria o diário mentir em cada bola.
  defp fall(%{hunted?: true} = track, now),
    do: %{
      world: track.world,
      name: track.name || "shiny",
      px: track.px,
      fallen_at: now,
      hunted?: true
    }

  defp fall(track, now),
    do: %{world: track.world, name: "vizinho", px: track.px, fallen_at: now, hunted?: false}

  defp put_track(trail, track), do: %{trail | tracks: Map.put(trail.tracks, track.id, track)}
end
