defmodule Pokex.Bots.CrowdScan do
  @moduledoc """
  Where every creature around the character stands, in tiles from HIM and
  from his pokemon.

  ## Measured from the character, always

  The calibrated character point never disappears and is never mistaken for
  a monster. His pokemon is one more mark — the one with the number box under
  its bar, nearest to him — and it is optional: without it `from_pet` is
  `nil`, and a consumer knows it only has distances from the character.

  The first eye anchored on "the green name", which in this client is any
  creature at full health: on 2026-09-03 it measured from a Feraligatr, and
  from a palm tree.

  ## Marks in, tiles out

  `Pokex.Vision.CreatureMarks` turns pixels into bar marks; `place/3` turns
  marks into tiles and is pure, so the simulator can feed it the marks its
  own world would draw. `look/1` is the only function here that touches the
  screen.

  ## It shows its work

  With `evidence: true` the reading carries the captured box with the marks
  drawn on it: bars boxed (blue hostile, green pet), skulls tagged, a magenta
  cross where the character is. A number cannot say whether the detector, the
  anchor or the ruler was wrong; a picture can.

  ## Cost

  Measured on the live server log (2026-09-05): ~9 ms for the capture of a
  1812×1440 box and ~18 ms for the read. A per-tick cost, not a per-decision
  one.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{CreatureMarks, Evidence, Frame}

  @hostile_box {0, 220, 255}
  @pet_box {0, 255, 120}
  @skull_box {255, 255, 255}
  @me_cross {255, 0, 255}

  # A mark whose body stands within this many tiles of the character IS the
  # character (his own bar floats over his head).
  @me_tiles 0.6
  # One column of the 25-column bar.
  @pet_hp_tolerance 4
  # How far over his head his own bar can float, in screen points: 36 on the
  # notebook, ~100 on the ultrawide, never a tile and a half of the big screen.
  @me_head_px 200

  @type hostile :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          from_me: non_neg_integer,
          from_pet: non_neg_integer | nil,
          hp_pct: 0..100,
          skull?: boolean
        }
  @type pet :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          tiles: non_neg_integer,
          hp_pct: 0..100
        }
  @type placed :: %{
          read?: true,
          me: {integer, integer},
          pet: pet | nil,
          hostiles: [hostile],
          passive: non_neg_integer,
          passive_points: [{integer, integer}]
        }
  @type reading ::
          %{
            read?: true,
            at: integer,
            took_ms: non_neg_integer,
            me: {integer, integer},
            box: {integer, integer, integer, integer},
            pet: pet | nil,
            hostiles: [hostile],
            listed: non_neg_integer | nil,
            evidence: String.t() | nil
          }
          | %{read?: false, reason: atom}

  @doc """
  Captures the box around the character and places every creature in it.

  Options:

    * `:radius_tiles` — how far out to look (default `crowd_scan_radius_tiles`)
    * `:listed` — the battle-list count to carry alongside, when the caller has one
    * `:pet_hp` — his pokemon's health as the Pokebar reads it, to find it by
    * `:me_hp` — his own health, to tell his own bar from a monster's
    * `:evidence` — also return the picture it read, with the marks drawn on
    * `:capture` — injected for tests
  """
  @spec look(keyword) :: reading
  def look(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    radius = Keyword.get(opts, :radius_tiles, Pokex.Settings.get(:crowd_scan_radius_tiles))
    capture = Keyword.get(opts, :capture, &Capture.frame/2)

    with {:ok, calib} <- calibration(),
         {px, py} when is_integer(px) <- Calibration.player_point(calib),
         box = box_around({px, py}, radius, calib),
         {:ok, frame} <- capture.(box, "crowd_scan.raw") do
      scale = frame_scale(frame)
      tile = Calibration.tile_px(calib)
      found = CreatureMarks.find(frame)
      marks = Enum.map(found, &to_screen(&1, box, scale))
      taught = sprite_pet(frame, found, tile, scale, opts)

      marks
      |> place(
        {px, py},
        tile,
        Keyword.take(opts, [:pet_hp, :me_hp]) ++ [sprite: sprite_verdict(taught, box, scale)]
      )
      |> Map.merge(%{
        at: started,
        took_ms: System.monotonic_time(:millisecond) - started,
        box: box,
        listed: Keyword.get(opts, :listed),
        evidence: evidence(opts, frame, found, box, {px, py}, scale)
      })
    else
      {:error, reason} -> %{read?: false, reason: reason}
      :not_calibrated -> %{read?: false, reason: :not_calibrated}
      _no_anchor -> %{read?: false, reason: :no_player_point}
    end
  end

  @doc """
  Marks (bar centres, in screen points) placed in tiles from `me` and from
  his pokemon. Pure: the simulator calls it with the marks its world draws.

  His pokemon is, first, the mark `:sprite` names — `%{point:, score:}`, the
  body the taught sprites recognised and how sure they were (`look/1`, his
  three or four Torterra angles). Failing that, the mark with the number box
  nearest to him. Without a box (his notebook draws none) it is the mark whose
  health matches `:pet_hp`, what the Pokebar reads, within one column of the
  bar — nearest to him when two match. No match, no pet: `from_pet` stays
  `nil`. And whichever path names him, the Pokebar has the last word: a sprite
  or a box whose bar disagrees with it loses to the bar that agrees
  (`believe_the_pokebar/4`).

  The SCORE travels with the point because the two are one verdict: passing
  only the point left `pet.score` nil on every live reading, and the card that
  says how sure the eye is fell through to "não se sabe por qual caminho"
  exactly when the taught sprite was what decided.
  """
  @spec place([CreatureMarks.mark()], {integer, integer}, pos_integer, keyword) :: placed
  def place(marks, {px, py} = me, tile, opts \\ []) do
    me_hp = Keyword.get(opts, :me_hp)

    seen =
      marks
      |> Enum.reject(&over_his_head?(&1, me, tile, me_hp))
      |> Enum.map(fn %{point: {x, y}} = mark -> %{mark | point: {x, y + tile}} end)
      |> Enum.reject(&(chebyshev(&1.point, me) <= @me_tiles * tile))

    # THE RESPAWNED ARE NOT THE FIGHT (09/09). Magenta means the creature will
    # not come at him, and the battle list does not carry it either — so
    # counting it here was the reason the screen and the list could never
    # agree. They are counted, not thrown away: monsters he already killed
    # standing up again around him is the measure he asked for of a hunt that
    # is running too slow.
    {passive, bodies} = Enum.split_with(seen, &Map.get(&1, :passive?, false))

    # …e QUAL DOS TRÊS CAMINHOS achou o pokémon. Eram três tentativas em
    # cascata e nada dizia qual venceu; quando ele "troca qual é o pokémon que
    # ele acha que é o meu", saber se foi a sprite, a caixa de número ou a vida
    # é a diferença entre achar o defeito e adivinhar.
    pet_hp = Keyword.get(opts, :pet_hp)

    pet =
      with nil <- taught_pet(bodies, Keyword.get(opts, :sprite), tile) |> by(:sprite),
           nil <- boxed_pet(bodies, me) |> by(:box) do
        pet_by_health(bodies, me, pet_hp) |> by(:hp)
      end
      |> believe_the_pokebar(bodies, me, pet_hp)

    # PELO PONTO, não pelo mapa: o pokémon ganha as chaves de COMO foi achado
    # (`found_by`, `sprite_score`) e deixaria de ser igual a si mesmo na lista.
    hostiles =
      bodies
      |> Enum.reject(&(pet != nil and &1.point == pet.point))
      |> Enum.map(&hostile(&1, me, pet, tile))
      |> Enum.sort_by(&{&1.from_me, &1.dx, &1.dy})

    %{
      read?: true,
      me: {px, py},
      pet: pet && pet_of(pet, me, tile),
      hostiles: hostiles,
      passive: length(passive),
      # …E ONDE ELES ESTÃO. A contagem responde "a caçada está lenta"; a cerca da
      # mira por cor faz outra pergunta — "tem algo VIVO neste tile?" — e pra
      # essa a contagem não serve. O renascido não vem na lista de batalha e não
      # está em `hostiles`: sem o ponto ele é invisível pras duas cercas, e a
      # bola voa num pokémon vivo.
      passive_points: Enum.map(passive, & &1.point)
    }
  end

  @doc """
  Marks which of the creatures the SPECIAL COLOUR is sitting on.

  The guard finds a shiny by colour and the eye finds bodies by their health bar; until now
  nothing joined the two, so the screen could say "there is a shiny" and "there are four
  creatures" without ever saying WHICH of the four. `vistos` are the guard's blobs
  (`%{name, px, point}` in SCREEN points, the same frame the bodies use), and a blob within
  `tile` of a body is that body's.

  `px` rides along beside the rule's own trigger, because that ratio IS the confidence: a blob
  at four times the proven trigger is a different claim from one that scraped past it.
  """
  @spec mark_special(placed | reading, [map], pos_integer) :: placed | reading
  def mark_special(%{read?: true, hostiles: hostiles} = reading, vistos, tile)
      when is_list(vistos) do
    %{reading | hostiles: Enum.map(hostiles, &joined(&1, vistos, tile))}
  end

  def mark_special(reading, _vistos, _tile), do: reading

  # OS DOIS PONTOS NÃO SÃO O MESMO ÂNCORA. O quadrado do bicho é a barra dele
  # mais UM tile (`place/4`); a mancha de cor é o centro de massa da arte, que
  # fica meio tile abaixo da barra. Um corpo dista meio tile da própria mancha,
  # e o VIZINHO dista um tile — então "até um tile" pintava o vizinho de shiny
  # junto, com a mesma confiança escrita em cima, e o bicho comum ao lado perdia
  # o número da vida.
  defp joined(hostile, vistos, tile) do
    meio = div(tile, 2)

    case Enum.find(vistos, &(chebyshev(square_of(&1, tile), hostile.point) <= meio)) do
      nil ->
        hostile

      visto ->
        Map.merge(hostile, %{special?: true, special_name: visto.name, special_px: visto.px})
    end
  end

  defp square_of(%{point: {x, y}}, tile), do: {x, y + div(tile, 2)}
  defp square_of(_no_point, _tile), do: {-1_000_000, -1_000_000}

  # --- himself ----------------------------------------------------------------

  # His own bar floats straight over his head, and carries HIS health. That
  # second half holds even when the tile ruler is wrong for the screen — the
  # notebook ran a whole afternoon with 151 for a 36-point tile, and his own
  # bar read as a hostile one tile away.
  defp over_his_head?(%{point: {x, y}, hp_pct: hp}, {px, py}, tile, me_hp)
       when is_integer(me_hp) do
    abs(x - px) <= @me_tiles * tile and y < py and py - y <= @me_head_px and
      abs(hp - me_hp) <= @pet_hp_tolerance
  end

  defp over_his_head?(_mark, _me, _tile, _unknown), do: false

  # --- his pokemon -----------------------------------------------------------

  # THE TAUGHT SPRITE WINS (09/09): "ele muitas vezes troca qual é o pokémon que
  # ele acha que é o meu — é importante usar a calibração do meu pokémon, três
  # ou quatro imagens do Torterra de vários ângulos". Every mark's body is
  # scored against the taught library; the body that is his pokémon by name,
  # above the tracker's own threshold and clear of the next mark, is the pet —
  # whatever box or health the others show. Nothing taught, or nothing close
  # enough: the box and the health decide, as before.
  #
  # HALF A TILE, NOT A WHOLE ONE. The creature's SQUARE is a full tile under
  # its bar (that is what `place/4` walks the point down by), but its ART is
  # drawn overlapping upward, so the middle of the picture sits halfway. Aiming
  # a whole tile down reads the ground under its feet, and the feature was
  # inert in the field: MEASURED over 34 of his own frames (09/09, ultrawide,
  # 81 marks), a whole tile scored 0.69 at best and cleared the floor 5 times;
  # half a tile scores his Torterra at 0.79-0.94 with every other mark under
  # 0.40, and clears the floor 23 times.
  #
  # And the winner has to be CLEAR of the runner-up. In the one frame of the 34
  # where the pokémon was not in the picture, two monsters tied at 0.554 and
  # 0.552 — a coin toss for "which one is mine", which is the very flipping he
  # is complaining about. A tie is no answer: the box and the health decide.
  @clear_by 0.15

  defp sprite_pet(frame, marks, tile, scale, opts) do
    name = Keyword.get_lazy(opts, :pet_name, &Pokex.Pokedex.Team.active/0)
    lib = Keyword.get_lazy(opts, :sprites, &Pokex.Bots.PokemonSprites.library/0)

    if is_binary(name) and marks != [] and not Pokex.Vision.SpriteLibrary.empty?(lib) do
      aimed = Pokex.Vision.SpriteLibrary.aimed(lib)
      box = Pokex.Settings.get(:pokemon_sprite_box_px)
      floor = Pokex.Settings.get(:pokemon_track_min_similarity)
      body_below = round(tile * scale / 2)

      marks
      |> Enum.map(fn %{point: {x, y}} = mark ->
        window = {x - div(box, 2), y + body_below - div(box, 2), box, box}
        {mark, Pokex.Vision.SpriteLibrary.best_in(aimed, frame, window)}
      end)
      |> Enum.filter(fn {_mark, hit} -> hit != nil and same_name?(hit.name, name) end)
      |> Enum.sort_by(fn {_mark, hit} -> -hit.score end)
      |> clearly_best(floor)
    else
      nil
    end
  end

  defp clearly_best([{mark, best} | rest], floor) do
    runner_up =
      case rest do
        [{_mark, second} | _others] -> second.score
        [] -> 0.0
      end

    # A NOTA VIAJA JUNTO. Ela decidia e era jogada fora, e o card do cerco não
    # tinha como dizer QUANTO ele acredita que aquele quadrado é o pokémon
    # dele — que é a pergunta que ele faz olhando a tela ("qual a taxa de
    # confiabilidade que ele acha").
    if best.score >= floor and best.score - runner_up >= @clear_by,
      do: Map.put(mark, :sprite_score, best.score)
  end

  defp clearly_best([], _floor), do: nil

  defp same_name?(taught, active), do: String.downcase(taught) == String.downcase(active)

  # The sprite's verdict, as it leaves `look/1`: where the winning body's bar
  # is, in screen points, and how sure the library was. `nil` when nothing was
  # taught, nothing matched, or the winner was not clear of the runner-up.
  defp sprite_verdict(nil, _box, _scale), do: nil

  defp sprite_verdict(mark, box, scale),
    do: %{point: to_screen(mark, box, scale).point, score: Map.get(mark, :sprite_score)}

  # …and the score is put BACK on the body the reading returns. `place/4` works
  # on its own list of marks, so re-finding the winner by point and stopping
  # there dropped the number on the floor: `pet.score` was nil on every live
  # reading and the card said "não se sabe por qual caminho" about the one
  # path that actually knew.
  defp taught_pet(bodies, %{point: {x, y}, score: score}, tile) do
    case Enum.find(bodies, fn %{point: {bx, by}} -> {bx, by - tile} == {x, y} end) do
      nil -> nil
      mark -> Map.put(mark, :sprite_score, score)
    end
  end

  defp taught_pet(_bodies, _no_sprite, _tile), do: nil

  defp boxed_pet(bodies, me) do
    bodies
    |> Enum.filter(& &1.pet?)
    |> Enum.min_by(&chebyshev(&1.point, me), fn -> nil end)
  end

  # THE POKEBAR IS THE FACT (11/09, 14:48-15:00, his six black-box episodes):
  # in 9 frames the box or the sprite (at 0.55, the coin-toss score) named a
  # Golem asleep under the chain — tinted purple like his Shiny Venusaur — as
  # his pokémon, at 8-44 % of health while the Pokebar read 100 %, and his own
  # Venusaur went into the reading as a hostile standing at 100 %. The aim then
  # held the ball for 6 s ("segurada por bicho de pé") and a hunted creature's
  # fall would have read as "covered by the pet". Every frame where the health
  # path decided agreed with the Pokebar within 2 points; every swap disagreed
  # by 56-92. So a box or a sprite only names the pet when its bar agrees with
  # the Pokebar; when it does not and some bar does agree, that bar is the pet.
  # With no bar agreeing the candidate stands (a frozen Pokebar must not turn
  # the pet into nobody).
  defp believe_the_pokebar(%{found_by: how, hp_pct: hp} = candidate, bodies, me, pet_hp)
       when how in [:sprite, :box] and is_integer(pet_hp) and
              abs(hp - pet_hp) > @pet_hp_tolerance do
    case pet_by_health(bodies, me, pet_hp) do
      nil -> candidate
      agreed -> by(agreed, :hp)
    end
  end

  defp believe_the_pokebar(candidate, _bodies, _me, _pet_hp), do: candidate

  # One column of the bar is 4%: the Pokebar's 39% draws as 36% or 40%.
  defp pet_by_health(bodies, me, pet_hp) when is_integer(pet_hp) do
    bodies
    |> Enum.filter(&(abs(&1.hp_pct - pet_hp) <= @pet_hp_tolerance))
    |> Enum.min_by(&chebyshev(&1.point, me), fn -> nil end)
  end

  defp pet_by_health(_bodies, _me, _unknown), do: nil

  # --- geometry ------------------------------------------------------------

  defp hostile(%{point: point, hp_pct: hp, skull?: skull?}, me, pet, tile) do
    {dx, dy} = offset(point, me, tile)

    %{
      point: point,
      dx: dx,
      dy: dy,
      from_me: max(abs(dx), abs(dy)),
      from_pet: pet && tiles_between(point, pet.point, tile),
      hp_pct: hp,
      skull?: skull?
    }
  end

  defp pet_of(%{point: point, hp_pct: hp} = mark, me, tile) do
    {dx, dy} = offset(point, me, tile)

    %{
      point: point,
      dx: dx,
      dy: dy,
      tiles: max(abs(dx), abs(dy)),
      hp_pct: hp,
      by: Map.get(mark, :found_by),
      score: Map.get(mark, :sprite_score)
    }
  end

  defp by(nil, _how), do: nil
  defp by(mark, how), do: Map.put(mark, :found_by, how)

  defp offset({x, y}, {px, py}, tile), do: {round((x - px) / tile), round((y - py) / tile)}

  defp tiles_between(a, b, tile) do
    {dx, dy} = offset(a, b, tile)
    max(abs(dx), abs(dy))
  end

  defp chebyshev({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  defp to_screen(%{point: point} = mark, region, scale),
    do: %{mark | point: Calibration.frame_to_screen(scale, region, point)}

  defp evidence(opts, frame, marks, {rx, ry, _w, _h}, {px, py}, scale) do
    if Keyword.get(opts, :evidence, false) do
      geo = CreatureMarks.geometry(scale)

      Evidence.data_url(frame,
        shrink: Pokex.Settings.get(:crowd_scan_evidence_shrink),
        boxes: Enum.flat_map(marks, &mark_boxes(&1, geo)),
        marks: [{round((px - rx) * scale), round((py - ry) * scale), @me_cross}]
      )
    end
  end

  # The bar boxed in its kind's colour, and the skull boxed above it when
  # there is one.
  defp mark_boxes(%{point: {x, y}} = mark, %{bar_w: bw, bar_h: bh}) do
    bar = %{
      x: x - div(bw, 2),
      y: y - div(bh, 2),
      w: bw,
      h: bh,
      colour: if(mark.pet?, do: @pet_box, else: @hostile_box)
    }

    skull = %{x: x - 8, y: y - 34, w: 16, h: 17, colour: @skull_box}

    if mark.skull?, do: [bar, skull], else: [bar]
  end

  defp frame_scale(%Frame{scale: scale}) when is_number(scale) and scale > 0, do: scale
  defp frame_scale(_frame), do: 1.0

  defp box_around({px, py}, radius_tiles, %Calibration{screen_w: sw, screen_h: sh} = calib) do
    radius = radius_tiles * Calibration.tile_px(calib)
    x = max(px - radius, 0)
    y = max(py - radius, 0)
    w = min(2 * radius, max(sw, 1) - x)
    h = min(2 * radius, max(sh, 1) - y)

    {x, y, max(w, 1), max(h, 1)}
  end

  defp calibration do
    case Calibration.load() do
      {:ok, %Calibration{screen_w: w, screen_h: h} = calib}
      when is_integer(w) and is_integer(h) ->
        {:ok, calib}

      _no_calibration ->
        :not_calibrated
    end
  end
end
