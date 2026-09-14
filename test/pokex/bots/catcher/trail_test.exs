defmodule Pokex.Bots.Catcher.TrailTest do
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.Trail

  # his ultrawide: the character mid-screen, a tile of 151 px
  @me {1695, 686}
  @tile 151

  defp ref(pos \\ {100, 100, 7}), do: %{me: @me, tile: @tile, pos: pos}

  # a creature standing `dx, dy` tiles from the character, as the eye reports it
  defp at(dx, dy, extra \\ %{}) do
    {mx, my} = @me
    Map.merge(%{point: {mx + round(dx * @tile), my + round(dy * @tile)}}, extra)
  end

  defp reading(hostiles, pet), do: %{read?: true, hostiles: hostiles, pet: pet}

  defp look(trail, hostiles, now, opts \\ []) do
    reading =
      reading(hostiles, opts[:pet])
      |> Map.put(:shiny_on?, Keyword.get(opts, :sparkle, false))
      |> Map.put(:pile_dead?, Keyword.get(opts, :pile, :alive) == :dead)

    Trail.observe(trail, reading, ref(opts[:pos] || {100, 100, 7}), now)
  end

  test "the hunted creature is followed while it walks, and its fall is the anchor" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

    trail =
      Trail.new()
      |> look([at(-2, -3, shiny)], 0)
      |> look([at(-1.5, -2.5)], 250)
      |> look([at(-1, -2)], 500)
      |> look([at(-0.5, -1.5)], 750)
      |> look([at(0, -1)], 1_000)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(0, -1).point

    # the bar is gone: one look is nothing, three is a death — the corpse lies
    # where the creature last stood
    trail = trail |> look([], 1_250) |> look([], 1_500)
    assert Trail.anchors(trail, ref(), 1_500) == []
    assert Trail.hunted(trail, ref())

    trail = look(trail, [], 1_750)

    assert [%{name: "Shiny Golem", px: 394, screen: anchor, fallen_at: 1_750}] =
             Trail.anchors(trail, ref(), 1_750)

    assert anchor == at(0, -1).point
    refute Trail.hunted(trail, ref())
  end

  test "two creatures crossing keep their identities" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      # A (hunted) walks right along y=-2; B walks left along the same row
      |> look([at(-3, -2, shiny), at(3, -2)], 0)
      |> look([at(-2, -2), at(2, -2)], 250)
      |> look([at(-1, -2), at(1, -2)], 500)
      |> look([at(0, -2), at(0, -2)], 750)
      |> look([at(1, -2), at(-1, -2)], 1_000)
      |> look([at(2, -2), at(-2, -2)], 1_250)

    assert %{screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(2, -2).point, "the hunted track swapped to the other creature"
  end

  test "his own pokemon standing on the hunted creature covers it, it does not kill it" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}
    pet_on_top = %{point: at(0, -2).point}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0)
      |> look([], 250, pet: pet_on_top)
      |> look([], 500, pet: pet_on_top)
      |> look([], 750, pet: pet_on_top)
      |> look([], 1_000, pet: pet_on_top)

    assert Trail.anchors(trail, ref(), 1_000) == []
    assert %{name: "Shiny Golem"} = Trail.hunted(trail, ref())

    # …and when the pet steps aside the bar is the same creature
    trail = look(trail, [at(0.5, -2)], 1_250)
    assert %{screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(0.5, -2).point
  end

  test "the character walking does not move the creatures: tracks live in world tiles" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(2, 0, shiny)], 0, pos: {100, 100, 7})
      # the character stepped two tiles right: the same creature is now on him
      |> look([at(0, 0)], 1_000, pos: {102, 100, 7})
      |> look([at(-1, 0)], 2_000, pos: {103, 100, 7})

    assert [_one_track] = Map.values(trail.tracks)
    assert %{world: {102.0, 100.0}} = Trail.hunted(trail, ref({103, 100, 7}))

    # it falls; three looks later the anchor is asked from yet another place
    trail =
      trail
      |> look([], 3_000, pos: {103, 100, 7})
      |> look([], 3_250, pos: {103, 100, 7})
      |> look([], 3_500, pos: {103, 100, 7})

    assert [%{screen: screen}] = Trail.anchors(trail, ref({105, 100, 7}), 3_500)
    assert screen == at(-3, 0).point
  end

  test "a minimap that went blind keeps the last position" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(2, 0, shiny)], 0, pos: {100, 100, 7})
      |> look([at(2, 0)], 250, pos: nil)

    assert %{world: {102.0, 100.0}} = Trail.hunted(trail, %{me: @me, tile: @tile, pos: nil})
  end

  test "the guard's blob names the track under it, or is born as one" do
    trail =
      Trail.new()
      |> look([at(1, 1), at(-2, 0)], 0)
      |> Trail.hunt_at(at(1, 1).point, "Shiny Golem", 200, ref(), 100)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(1, 1).point

    born = Trail.hunt_at(Trail.new(), at(3, 3).point, "Shiny Golem", 200, ref(), 0)
    assert %{name: "Shiny Golem"} = Trail.hunted(born, ref())
  end

  test "an anchor is spent by the ball and dies of old age" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 300}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0)
      |> look([], 250)
      |> look([], 500)
      |> look([], 750)

    assert [%{world: world}] = Trail.anchors(trail, ref(), 750)
    assert Trail.anchors(trail, ref(), 750 + 121_000) == []
    assert Trail.anchors(Trail.spend(trail, world), ref(), 750) == []
  end

  # 12:39 of 11/09: eight bars in the pile, and the hunted Shiny Golem was gone
  # from the trail two seconds after the sighting — a miss on ANY other track
  # threw away every track matched before it.
  test "another creature missing a look does not lose the hunted one" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 228}

    trail =
      Trail.new()
      |> look([at(3, 2, shiny), at(-1, 0), at(1, 1), at(0, -2)], 0)
      # the far one blinks out of the reading for a few looks; the shiny stays
      |> look([at(3, 2), at(-1, 0), at(1, 1)], 250)
      |> look([at(2, 2), at(-1, 0), at(1, 1)], 500)
      |> look([at(2, 1), at(-1, 0), at(1, 1), at(0, -2)], 750)

    assert %{name: "Shiny Golem", screen: screen} = Trail.hunted(trail, ref())
    assert screen == at(2, 1).point
    assert map_size(trail.tracks) == 4
  end

  # 18:34 of 11/09: the Shiny Feraligatr stood in the green-haze pile with its
  # sparkle and skull, ALIVE, while the eye lost its bar for looks on end. The
  # trail called that a death, minted a corpse anchor, and balled the empty
  # ground as the character walked on. A shiny is alive while its sparkle shows;
  # the game confirmed it falls and becomes a body, and the sparkle leaves only
  # then.
  test "a shiny whose bar blinks out of the pile does not fall while its sparkle shows" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      # the bar is lost in the haze, but the sparkle is still on screen: alive
      |> look([], 250, sparkle: true)
      |> look([], 500, sparkle: true)
      |> look([], 750, sparkle: true)
      |> look([at(0, -2, shiny)], 1_000, sparkle: true)
      |> look([], 1_250, sparkle: true)
      |> look([], 2_000, sparkle: true)

    assert Trail.anchors(trail, ref(), 2_000) == [], "no corpse while the sparkle shows"
    assert Trail.hunted(trail, ref())

    # the sparkle leaves and the battle list is EMPTY — it fell. Now the bar
    # being gone IS a death, and the corpse lies where it last stood.
    trail =
      trail
      |> look([], 2_250, sparkle: false, pile: :dead)
      |> look([], 2_500, sparkle: false, pile: :dead)
      |> look([], 2_750, sparkle: false, pile: :dead)

    assert [%{name: "Shiny (brilho)", screen: anchor}] = Trail.anchors(trail, ref(), 2_750)
    assert anchor == at(0, -2).point
  end

  # 19:15:51-53 of 11/09: the chain's green haze hid the star AND the bar for
  # three scans with the shiny alive and the list at one enemy. Mid-fight the
  # body waits a long grace after the sparkle's last sighting.
  test "mid-fight, a sparkle lost under the haze is not a death until the grace runs out" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      |> look([], 250, sparkle: false)
      |> look([], 500, sparkle: false)
      |> look([], 2_000, sparkle: false)
      |> look([], 3_000, sparkle: false)

    assert Trail.anchors(trail, ref(), 3_000) == [], "the list still has enemies: no corpse yet"
    assert Trail.hunted(trail, ref())

    trail = look(trail, [], 3_600, sparkle: false)
    assert [%{screen: anchor}] = Trail.anchors(trail, ref(), 3_600)
    assert anchor == at(0, -2).point
  end

  test "a hunted bar lost long before the sparkle leaves is no corpse: no phantom ball" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      # the bar is never seen again; the sparkle lingers seconds (the shiny
      # wandered, or the guard blinked) then leaves with the list empty. Its
      # last bar spot is stale: no body there.
      |> look([], 250, sparkle: true)
      |> look([], 6_000, sparkle: true)
      |> look([], 6_250, sparkle: false, pile: :dead)
      |> look([], 6_500, sparkle: false, pile: :dead)
      |> look([], 7_000, sparkle: false, pile: :dead)

    assert Trail.anchors(trail, ref(), 7_000) == []
    refute Trail.hunted(trail, ref())
  end

  # 19:50 of 11/09: the eye lost the shiny's bar at 1720,918 and never read it
  # again, while the guard kept seeing its STAR — last at 1418,842, two tiles
  # left. The trail anchored on the stale bar and the ball fell on the sand a
  # tile right of the body. Seeing the star IS seeing the creature: where it
  # shines, the shiny is, now.
  test "the sparkle moves the hunted track and refreshes it: the body is where it last shone" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      # the bar is gone from the eye's read, but the star keeps showing — two
      # tiles left of where the bar was last seen
      |> look([], 250, sparkle: true)
      |> Trail.hunt_at(at(-2, -2).point, "Shiny (brilho)", 51, ref(), 250)
      |> look([], 500, sparkle: true)
      |> Trail.hunt_at(at(-2, -2).point, "Shiny (brilho)", 51, ref(), 500)
      # the star leaves and the list empties: it fell
      |> look([], 750, pile: :dead)
      |> look([], 1_000, pile: :dead)
      |> look([], 1_250, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref(), 1_250)
    assert screen == at(-2, -2).point, "the body is at the last star, not at the last bar"
  end

  test "the sparkle on a track does not resurrect it forever: it still falls" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      |> Trail.hunt_at(at(0, -2).point, "Shiny (brilho)", 51, ref(), 0)
      |> look([], 250, pile: :dead)
      |> look([], 500, pile: :dead)
      |> look([], 750, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref(), 750)
    assert screen == at(0, -2).point
  end

  test "once the character walks, the anchor is projected from the world again" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, pos: {100, 100, 7})
      |> look([], 250, pos: {100, 100, 7}, pile: :dead)
      |> look([], 500, pos: {100, 100, 7}, pile: :dead)
      |> look([], 750, pos: {100, 100, 7}, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref({101, 100, 7}), 750)
    assert screen == at(-1, -2).point
  end

  # Live, the frozen minimap made the same shiny TWO hunted tracks two tiles
  # apart, and both fell — a ball on the sand each side of the body. A hunted
  # bar that falls while another hunted bar was seen more recently is the
  # stale twin: it is dropped, and the fresh one falls where the body is.
  test "of two hunted tracks the stale one is dropped, the fresh one is the corpse" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      # the twin, two tiles away, hunted by the guard's blob one look later
      |> look([at(0, -2), at(2, -2)], 250, sparkle: true)
      |> Trail.hunt_at(at(2, -2).point, "Shiny (brilho)", 51, ref(), 300)
      # the old track's bar is gone; the twin is still seen
      |> look([at(2, -2)], 500, sparkle: true)
      |> look([at(2, -2)], 750, sparkle: true)
      |> look([], 1_000, pile: :dead)
      |> look([], 1_250, pile: :dead)
      |> look([], 1_500, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref(), 1_500)
    assert screen == at(2, -2).point
  end

  test "an ordinary creature that vanishes is simply forgotten" do
    trail =
      Trail.new()
      |> look([at(1, 1)], 0)
      |> look([], 250)
      |> look([], 500)
      |> look([], 750)
      |> look([], 1_000)

    assert trail.tracks == %{}
    assert trail.anchors == []
  end

  # A QUEDA DESCARTADA POR VELHICE DEIXA RASTRO.
  #
  # "Às vezes eu preciso usar uns 5, 6 revives pra matar um shiny, e nesses
  # casos ele não joga pokébola" (14/09). O descarte por `@corpse_fresh_ms` era
  # MUDO: um terço das brigas com brilho na tela não produz a linha `caiu em` e
  # não havia como saber se era este motivo ou outro.
  test "a fall whose bar is older than the corpse window is reported, not swallowed" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    bicho = at(-2, -3, shiny)

    trail =
      Trail.new()
      |> look([bicho], 0, sparkle: true)
      |> look([bicho], 250, sparkle: true)
      # o pet cobre a barra por um bom tempo, e só então a pilha zera
      |> look([], 20_000, pile: :dead)
      |> look([], 20_250, pile: :dead)
      |> look([], 20_500, pile: :dead)

    assert trail.anchors == []
    assert [%{hunted?: true, name: "Shiny Golem", age: idade}] = trail.dropped
    assert idade > Pokex.Settings.get(:corpse_fresh_ms)
  end

  # …e uma olhada limpa depois disso não arrasta a queixa da anterior
  test "the dropped list belongs to the LAST look only" do
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    bicho = at(-2, -3, shiny)

    trail =
      Trail.new()
      |> look([bicho], 0, sparkle: true)
      |> look([bicho], 250, sparkle: true)
      |> look([], 20_000, pile: :dead)
      |> look([], 20_250, pile: :dead)
      |> look([], 20_500, pile: :dead)

    assert trail.dropped != []
    assert look(trail, [], 20_750, pile: :dead).dropped == []
  end

  # DOIS SHINIES SÃO DOIS CORPOS. O gêmeo é o que está no MESMO LUGAR.
  #
  # "Quando tem dois shinies na minha tela, normalmente ele joga pokébola só em
  # um" (14/09). A peneira do gêmeo guardava só a trilha caçada MAIS NOVA, e
  # isso confundia "o mesmo bicho contado duas vezes" (o fantasma do minimapa
  # congelado, a dois tiles) com "dois bichos".
  describe "two shinies are two bodies" do
    test "two hunted tracks far apart both become anchors" do
      shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
      a = at(-3, -3, shiny)
      b = at(3, 3, shiny)

      # o de cima fica um instante oculto, então os dois caem com `seen_at`
      # DIFERENTES — que era tudo o que a peneira velha olhava
      trail =
        Trail.new()
        |> look([a, b], 0, sparkle: true)
        |> look([a, b], 250, sparkle: true)
        |> look([b], 500, sparkle: true)
        |> look([], 750, pile: :dead)
        |> look([], 1_000, pile: :dead)
        |> look([], 1_250, pile: :dead)

      assert length(trail.anchors) == 2
    end

    # …e o fantasma continua fora: a dois tiles é o MESMO shiny, e a segunda
    # bola cai na areia.
    test "a hunted track a couple of tiles from a fresher one is the ghost, not a body" do
      shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

      # o fantasma nasce com o minimapa congelado e PARA de ser visto; o de
      # verdade segue sendo lido a dois tiles dali
      trail =
        Trail.new()
        |> look([at(-3, -3, shiny), at(-3, -1, shiny)], 0, sparkle: true)
        |> look([at(-3, -1, shiny)], 250, sparkle: true)
        |> look([at(-3, -1, shiny)], 500, sparkle: true)
        |> look([], 750, pile: :dead)
        |> look([], 1_000, pile: :dead)
        |> look([], 1_250, pile: :dead)

      assert length(trail.anchors) == 1
    end
  end

  # O RASTRO INTEIRO VIRA ALVO ENQUANTO A CENA É DE SHINY.
  #
  # "Bora fazer ele tentar jogar a bola no rastro inteiro, pra garantir, mesmo
  # que pegue outros pokemons no caminho tb (…) o importante é não deixar shiny
  # para trás" (13/09). Sem isto só a trilha que a COR apontou vira corpo, e um
  # shiny que a cor não marcou naquele instante não deixa âncora nenhuma.
  describe "the whole trail is a target while the scene is a shiny's" do
    setup do
      Pokex.SettingsStash.stash_keys!([:capture_whole_trail])
      :ok
    end

    test "a common that fell beside the shiny gets an anchor of its own" do
      shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

      trail =
        Trail.new()
        |> look([at(0, -1, shiny), at(2, 2)], 0, sparkle: true)
        |> look([at(0, -1, shiny), at(2, 2)], 250, sparkle: true)
        |> look([], 500, pile: :dead)
        |> look([], 750, pile: :dead)
        |> look([], 1_000, pile: :dead)

      nomes = trail.anchors |> Enum.map(& &1.name) |> Enum.sort()
      assert nomes == ["Shiny Golem", "vizinho"]
    end

    # O corpo do vizinho é do VIZINHO: chamá-lo de shiny faria o diário mentir
    # em cada bola.
    test "…and the shiny's own anchor is still one, in its own name" do
      shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

      trail =
        Trail.new()
        |> look([at(0, -1, shiny), at(2, 2), at(-3, 1)], 0, sparkle: true)
        |> look([], 500, pile: :dead)
        |> look([], 750, pile: :dead)
        |> look([], 1_000, pile: :dead)

      assert Enum.count(trail.anchors, &(&1.name == "Shiny Golem")) == 1
      assert Enum.count(trail.anchors, &(&1.name == "vizinho")) == 2
    end

    # A TRAVA. Sem brilho nenhum na cena a caçada é comum, e bola em todo comum
    # que cai seria a noite inteira gastando bola.
    test "with no sparkle in the scene, only the coloured track becomes a body" do
      trail =
        Trail.new()
        |> look([at(2, 2), at(-3, 1)], 0)
        |> look([], 250)
        |> look([], 500)
        |> look([], 750)
        |> look([], 1_000)

      assert trail.anchors == []
    end

    test "the switch turns it off and the old rule comes back" do
      Pokex.Settings.put(:capture_whole_trail, false)
      shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}

      trail =
        Trail.new()
        |> look([at(0, -1, shiny), at(2, 2)], 0, sparkle: true)
        |> look([], 500, pile: :dead)
        |> look([], 750, pile: :dead)
        |> look([], 1_000, pile: :dead)

      assert Enum.map(trail.anchors, & &1.name) == ["Shiny Golem"]
    end
  end
end
