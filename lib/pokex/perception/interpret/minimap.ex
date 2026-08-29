defmodule Pokex.Perception.Interpret.Minimap do
  @moduledoc """
  Where we are — read, not inferred.

  PokeTibia prints the player's position as text at the top of the minimap
  ("(337, 46107, 4)"), which is why this bot will never need to understand the
  map picture to walk it.

  Two sanity gates keep a garbled frame from teleporting the world model: the
  floor must be plausible, and a jump larger than `@max_jump` tiles against the
  last good read is rejected. The rejection is not sticky — a genuine teleport
  (stairs, boat) re-baselines as soon as the same reading comes back.

  The observation also carries `coord_gap`: the digits the atlas has never been
  taught at the height this band is drawn at. A digit that is not in the atlas
  does not read as "unknown", it reads as the nearest digit that IS — so a hole
  in the alphabet is a WRONG coordinate, not a missing one, and only the
  alphabet can show it.
  """

  alias Pokex.{Calibration, Layout, Settings}
  alias Pokex.Calibration.CoordBandSearch
  alias Pokex.Vision.Glyphs

  @max_floor 15
  # A character walks; it does not teleport. 8 tiles per second is generous
  # (haste, diagonals) and still an order of magnitude below the jumps a
  # MISREAD produces: Lucas's hunt (2026-08-10) read an x that flipped ~24
  # tiles between consecutive frames, and the hunt believed every one of them —
  # counting waypoints as "reached" one second apart while the character stood
  # against a wall.
  @tiles_per_second 8
  # The ceiling on that allowance, however long the feed was blind. A misread
  # digit in the tens place moves the character 10 to 90 tiles; walking moves
  # it 4 between ticks. Anything at or past this has to come back a second time
  # before the world believes it — which costs a real teleport one tick and
  # costs a misread everything.
  @max_jump 10
  # The floor under the allowance: at the feed's cadence a real step must
  # always fit, and a clock that reports no elapsed time must not freeze the
  # reader.
  @min_jump 3
  # A failed read is usually just "label not on screen" (standing still, no
  # hover) — scanning the whole crop on every 500ms tick would burn CPU for
  # nothing. First miss hunts immediately (a walking bot must not stay blind),
  # then every 6th.
  @search_every 6
  @fresh_state %{
    last: nil,
    pending: nil,
    pending_at: nil,
    pending_seen: 0,
    band: nil,
    ink: nil,
    misses: 0,
    at: nil,
    gap: nil,
    chute: nil
  }

  def interpret(frame, calib, settings, state \\ nil) do
    state = Map.merge(@fresh_state, state || %{})
    {read, state} = read_position(frame, calib, settings, state)
    state = %{state | gap: gap(read) || state.gap, chute: chute(read) || state[:chute]}
    {obs, state} = accept(read, state)

    {obs |> Map.put(:coord_gap, state.gap) |> Map.put(:coord_guessed, state[:chute]), state}
  end

  # QUANTO DESTA COORDENADA É CHUTE — o aviso que faltava, e a razão de ele ter
  # olhado a tela de glifos e lido "nenhum problema" enquanto o bot andava pra
  # um lugar inventado.
  #
  # `coord_gap` responde "falta algum dígito no alfabeto desta altura?", e no
  # render dele a resposta é não: os dez estão lá, a 8px. O que não estava lá
  # era o dígito DELE — o atlas casava por semelhança, sete glifos de onze, e
  # semelhança repete o mesmo erro em todo frame.
  #
  # Sticky pelo mesmo motivo que `gap`: um aviso que pisca com o feed é um
  # aviso que ele aprende a ignorar.
  defp chute(%{guessed: guessed, glyphs: total})
       when is_integer(guessed) and is_integer(total) and total > 0 and guessed > 0,
       do: %{guessed: guessed, glyphs: total, pct: round(guessed * 100 / total)}

  defp chute(_leitura_exata_ou_ausente), do: nil

  # Sticky: the answer changes when he TEACHES, not when a tick fails to read.
  # A banner that blinks with the feed is a banner he learns to ignore.
  defp gap(%{px: px}) when is_integer(px) do
    case Map.get(Glyphs.missing_digits(), px) do
      nil -> nil
      faltam -> %{px: px, faltam: faltam}
    end
  end

  defp gap(_no_read), do: nil

  # The frame is the crop of minimap_capture_region — the SAME union the feed
  # captures — so every band is relative to that origin. The label MOVES with
  # the widget's visual state (measured 2026-08-10): walking draws it at the
  # widget's top-left, a hovering mouse slides the control bar in and pushes it
  # ~40pt down. A band marked in one state misses in the other, so a miss on
  # the last-good and saved bands HUNTS for the band on the crop itself
  # (throttled), and a find sticks in the state for the next read.
  defp read_position(frame, %Calibration{} = calib, settings, state) do
    case Calibration.minimap_capture_region(calib) do
      {ox, oy, _w, _h} ->
        opts = coord_opts(calib, settings)
        saved = relative_band(Calibration.minimap_coord_region(calib), ox, oy)

        # the ink floor the hunt settled on wins: over bright terrain the
        # taught floor welds the map to the strokes and reads nothing
        read_opts = Keyword.put(opts, :ink, state.ink || opts[:ink])

        case try_bands(frame, [state.band, saved], read_opts) do
          {:ok, band, pos} -> {pos, %{state | band: band, misses: 0}}
          :miss -> hunt_band(frame, calib, {ox, oy}, opts, state)
        end

      nil ->
        {nil, state}
    end
  end

  defp read_position(_frame, _no_calib, _settings, state), do: {nil, state}

  defp relative_band({x, y, w, h}, ox, oy), do: {x - ox, y - oy, w, h}
  defp relative_band(nil, _ox, _oy), do: nil

  defp try_bands(frame, bands, opts) do
    bands
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.find_value(:miss, fn band ->
      case Glyphs.read_coord_detail(frame, band, opts) do
        %{} = read -> {:ok, band, read}
        nil -> nil
      end
    end)
  end

  defp hunt_band(frame, calib, {ox, oy}, opts, state) do
    misses = state.misses + 1

    with true <- rem(misses - 1, @search_every) == 0,
         {mx, my, mw, mh} <- Calibration.minimap_region(calib),
         {:ok, band, pos, ink, _text, _glyphs} <-
           CoordBandSearch.search(frame, {mx - ox, my - oy, mw, mh}, frame_scale(frame), opts) do
      {%{pos: pos, guessed: 0, px: nil}, %{state | band: band, ink: ink, misses: 0}}
    else
      _not_found -> {nil, %{state | misses: misses}}
    end
  end

  defp frame_scale(frame), do: Map.get(frame, :scale) || 1.0

  @doc """
  The options this reader segments the coordinate band with.

  Public because a page that TEACHES the band has to segment it exactly as the
  reader does: a glyph cut at another ink floor is a different bitmap, so the
  atlas would learn a shape the reader never produces and the teaching would
  appear to do nothing.

  The strip's ink floor is TUNABLE (minimap_coord_ink): the global default
  (120) let the map's lit ground compete with the digits. The layout region's
  declared opts still apply underneath — merge, never replace.
  """
  def coord_opts(calib, settings) do
    layout_opts = if calib.layout, do: Layout.region_opts(calib.layout, :minimap_coord), else: []
    Keyword.merge(layout_opts, ink: Settings.value(settings, :minimap_coord_ink))
  end

  @doc """
  The sanity gates, as a pure step: a read plus the last-good state gives the
  position to publish and the next state. Public because this is the part with
  real logic — the pixels around it are just `Glyphs.read_coord/2`.
  """
  def accept(read, state, now \\ nil)

  def accept(nil, state, _now), do: {%{pos: nil}, forget(state)}

  def accept(read, state, now), do: judge(position(read), read, state, stamp(now))

  defp position({_x, _y, _z} = pos), do: pos
  defp position(%{pos: pos}), do: pos

  defp guessed(%{guessed: n}) when is_integer(n), do: n
  defp guessed(_bare), do: 0

  defp judge({_x, _y, z} = pos, _read, state, _now) when z < 0 or z > @max_floor,
    do: {%{pos: nil}, Map.merge(state, %{pending: pos, pending_at: nil, pending_seen: 0})}

  defp judge(pos, _read, %{last: nil} = state, now),
    do: {%{pos: pos}, accepted(state, pos, now)}

  defp judge(pos, read, %{last: last} = state, now) do
    cond do
      near?(pos, last, reach(state[:at], now)) ->
        {%{pos: pos}, accepted(state, pos, now)}

      # Um salto vindo de uma leitura que é quase toda chute não é um salto, é
      # o atlas errando o mesmo glifo duas vezes. Ver `resemblance?/1`.
      resemblance?(read) ->
        {%{pos: last}, hold(state, pos, now)}

      confirmed?(pos, guessed(read), state, now) ->
        {%{pos: pos}, accepted(state, pos, now)}

      true ->
        {%{pos: last}, hold(state, pos, now)}
    end
  end

  # SEMELHANÇA NÃO TELEPORTA NINGUÉM.
  #
  # Confirmar uma leitura repetindo-a só prova alguma coisa quando o erro é
  # ALEATÓRIO. O erro do atlas não é: um glifo que ele não conhece casa com o
  # mesmo vizinho errado em todo frame, então duas leituras idênticas de um
  # render que ele nunca viu se confirmam com a mesma confiança de duas
  # leituras certas — e o mundo re-baseia num lugar onde ele não está.
  #
  # MEDIDO nas duas capturas dele de 29/08, mesma faixa e mesmo tamanho: a das
  # 07:08 leu `1099, 1373, 5` com SETE dos onze glifos adivinhados, e a das
  # 07:14 leu `1056, 1373, 5` com seis. Quarenta e três tiles de diferença em
  # x, com y e andar idênticos — o "teleporte" que fez a rota ir e voltar. O
  # atlas tem os dez dígitos na altura dele (8px), então `missing_digits/0`
  # não tinha o que acusar: o buraco não é um dígito AUSENTE, é um dígito
  # PARECIDO.
  #
  # A regra, então, separa as duas coisas que uma leitura pode afirmar: onde
  # ele ESTÁ (um passo, e aí adivinhar é barato — o próximo frame corrige) e
  # que ele SE MOVEU muito (um salto, e aí adivinhar custa a caçada inteira).
  # Uma leitura em que a maior parte dos glifos é chute pode fazer a primeira e
  # nunca a segunda.
  #
  # O preço de errar pra este lado é conhecido e pequeno: quem tem um render
  # que o atlas nunca viu fica com a posição velha depois de uma escada até
  # ensinar os glifos — e a tela DIZ isso agora (`coord_guessed`), em vez de
  # andar pra um lugar inventado em silêncio.
  @mostly_guessed 0.5

  defp resemblance?(%{guessed: guessed, glyphs: total})
       when is_integer(guessed) and is_integer(total) and total > 0,
       do: guessed / total > @mostly_guessed

  defp resemblance?(_leitura_sem_detalhe), do: false

  # A jump re-baselines only when the SAME reading comes back — and "the same"
  # is measured against the PENDING read's clock, not the last accepted one.
  # With the old code both used the allowance since the last good position, so
  # after a few blind seconds two readings up to forty tiles apart confirmed
  # each other: a coordinate flickering between two wrong values (Lucas's 1088
  # read as 1066 and as 1099) re-baselined the world onto a misread.
  #
  # And a reading built from GUESSED glyphs has to come back twice. The atlas
  # hit is knowledge; `nearest/1` is resemblance, and resemblance flickers with
  # the anti-aliasing. Costs a real teleport one extra tick on a render the
  # atlas has never seen, and nothing at all on one it knows.
  defp confirmed?(pos, guessed, state, now) do
    pending = state[:pending]

    pending != nil and near?(pos, pending, reach(state[:pending_at], now)) and
      (state[:pending_seen] || 0) + 1 >= needed(guessed)
  end

  defp needed(0), do: 1
  defp needed(_guessed), do: 2

  defp hold(state, pos, now) do
    streak =
      if state[:pending] && near?(pos, state[:pending], reach(state[:pending_at], now)),
        do: (state[:pending_seen] || 0) + 1,
        else: 0

    Map.merge(state, %{pending: pos, pending_at: now, pending_seen: streak})
  end

  defp forget(state), do: Map.merge(state, %{pending: nil, pending_at: nil, pending_seen: 0})

  # Map.merge, not the update syntax: a state shaped before the clock existed
  # (a feed mid-upgrade, a caller's own map) must not raise on a missing key.
  defp accepted(state, pos, now),
    do: Map.merge(state, %{last: pos, pending: nil, pending_at: nil, pending_seen: 0, at: now})

  # How far the character COULD have walked since `at` — capped, because a long
  # blind stretch is not evidence of a long walk.
  defp reach(nil, _now), do: @min_jump

  defp reach(at, now) do
    elapsed = max(now - at, 0)

    elapsed
    |> Kernel.*(@tiles_per_second)
    |> div(1000)
    |> max(@min_jump)
    |> min(@max_jump)
  end

  defp stamp(nil), do: System.monotonic_time(:millisecond)
  defp stamp(now), do: now

  defp near?({x1, y1, z1}, {x2, y2, z2}, reach),
    do: z1 == z2 and abs(x1 - x2) <= reach and abs(y1 - y2) <= reach
end
