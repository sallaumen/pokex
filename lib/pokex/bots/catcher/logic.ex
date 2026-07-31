defmodule Pokex.Bots.Catcher.Logic do
  @moduledoc """
  Pure decision core for corpse capture (spec 2026-07-10-corpse-capture-design.md): admit
  detected corpses into a queue, keep exactly ONE ball in flight, confirm each throw against
  observations captured after the ball's flight window (a hit consumes the corpse instantly —
  game rule), retry once, and ignore persistent non-corpses (a parked pet) for a TTL. No I/O,
  no clock: the driver supplies observations and monotonic `now`.
  """

  # Hard confirmation ceiling: past this not even absence counts as proof — the
  # world already changed (a full ignore-TTL elapsed). Not a knob: 60s is
  # operational physics (4x the fight_timeout that holds scans).
  @confirmation_cap_ms 60_000

  defstruct state: :idle,
            config: nil,
            queue: [],
            throw: nil,
            ignored: %{},
            last_obs_at: nil,
            # Consecutive balls RESOLVED without a confirmed capture ("not a
            # corpse" + inconclusive): at config.dry_balls_alarm, alarm and
            # reset — the mirror of fishing's dry-cast alarm.
            dry_balls: 0,
            error: nil,
            counters: %{captures: 0, tardias: 0, throws: 0, ignored: 0}

  def new(config), do: %__MODULE__{config: config}

  def start(%__MODULE__{} = logic, _now) do
    {%{logic | state: :armed, queue: [], throw: nil, ignored: %{}, last_obs_at: nil, error: nil},
     []}
  end

  def stop(logic), do: {%{logic | state: :idle, queue: [], throw: nil}, []}

  @doc "Observation step. obs = %{corpses: [{x,y}], captured_at: ms} | nil (nothing fresh)."
  def step(%__MODULE__{state: :idle} = logic, _obs, _now), do: {logic, []}
  def step(logic, nil, _now), do: {logic, []}

  # A warmup frame (`scanning?: false`) proves nothing about the ground — its `corpses` list
  # is always empty by construction, so letting it fall through would falsely CONFIRM any
  # pending throw as captured (and, worse, admit nothing while wiping the queue's chance to
  # re-admit). Must be checked before the freshness dedup below: a warmup frame is fresh
  # (captured_at keeps advancing) and would otherwise reach the general clause.
  def step(logic, %{scanning?: false}, _now), do: {logic, []}

  def step(%{last_obs_at: last} = logic, %{captured_at: at}, _now)
      when is_integer(last) and at <= last,
      do: {logic, []}

  def step(logic, obs, now) do
    logic = %{prune_ignored(logic, now) | last_obs_at: obs.captured_at}

    {logic, confirm_actions} = confirm(logic, obs, now)
    logic = admit(logic, obs)
    {logic, throw_actions} = maybe_throw(logic, obs, now)

    {logic, confirm_actions ++ throw_actions}
  end

  @doc """
  Poll cadence while work is pending; nil when there is nothing to watch.

  With a ball in flight the wake targets the REAL confirmation deadline
  (`throw.at + corpse_confirm_after_ms`): waking earlier yields a scan the
  confirmation discards ("still flying") — a whole scan wasted per ball.
  """
  def next_wake(%__MODULE__{state: :idle}, _now), do: nil
  def next_wake(%__MODULE__{throw: nil, queue: []}, _now), do: nil

  # Expired deadline != wake in a loop: when the scan is HELD (engaged fight,
  # gate), the deadline passes and a 1ms wake became a machine gun — measured
  # 2026-07-30: ~15,000 wakes in a 15s fight. Past the deadline, retry at the
  # feed cadence.
  def next_wake(%__MODULE__{throw: %{at: at}, config: config}, now) do
    restante = at + config.corpse_confirm_after_ms - now
    if restante > 0, do: restante, else: max(config.feed_corpses_ms, 1)
  end

  def next_wake(%__MODULE__{config: config}, _now), do: max(config.feed_corpses_ms, 1)

  @doc """
  The instant the ball REALLY left: the driver calls this after Body.perform
  (the move+wait+key sequence takes ~200ms), so the confirmation window counts
  from actuation, not decision — otherwise the deadline absorbs the Body's queue
  time and the first read judges too early.
  """
  def ball_flown(%__MODULE__{throw: %{} = throw} = logic, at),
    do: %{logic | throw: %{throw | at: at}}

  def ball_flown(logic, _at), do: logic

  @doc """
  Corpses still being worked (queued + the one ball in flight) — the post-fight
  policy signal: support can wait for this to hit zero before healing/moving.
  """
  def pending(%__MODULE__{state: :idle}), do: 0

  def pending(%__MODULE__{queue: queue, throw: throw}),
    do: length(queue) + if(throw, do: 1, else: 0)

  defp confirm(%{throw: nil} = logic, _obs, _now), do: {logic, []}

  defp confirm(%{throw: throw, config: config} = logic, obs, now) do
    cond do
      # the ball is still flying — this frame proves nothing
      obs.captured_at < throw.at + config.corpse_confirm_after_ms ->
        {logic, []}

      # Only past the HARD CEILING is an observation truly garbage — the field
      # proved it (2026-07-30: 27 of 80 balls resolved AFTER 6x the window,
      # because the 15s fight_timeout holds scans; the day's 7 "inconclusive"
      # were REAL captures thrown away). Within the ceiling, evidence judges:
      # absent = captured (late); present SAME species = retry; present OTHER
      # species = the original was captured and a new corpse fell there (this
      # same step's admit queues it).
      obs.captured_at > throw.at + @confirmation_cap_ms ->
        dry(%{logic | throw: nil}, [
          {:log, "confirmação inconclusiva (observação tardia) em #{point_str(throw.point)}"}
        ])

      # OTHER species present at the point: the original corpse is GONE — captured.
      # (Missing a name on either side falls to the presence branches below: conservative.)
      outra_especie?(obs, throw, config.corpse_match_tolerance_px) ->
        captured(logic, obs, now)

      # past the flight window, still there (moved-or-not is irrelevant) → retry
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) and
          throw.balls < config.corpse_max_balls ->
        logic = update_in(logic.counters.throws, &(&1 + 1))

        {%{logic | throw: %{throw | balls: throw.balls + 1, at: now}},
         [
           {:capture_sequence, throw.point},
           {:log, "bola #{throw.balls + 1} em #{point_str(throw.point)}"}
         ]}

      # past the window, still there, and out of balls → not a corpse; ignore
      # for the TTL — storing the IDENTITY: a NEW corpse of another species
      # landing on the same tile must not inherit this veto.
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) ->
        logic = update_in(logic.counters.ignored, &(&1 + 1))

        entrada = %{
          ate: now + config.corpse_ignore_ttl_ms,
          name: name_in(obs, throw.point, config.corpse_match_tolerance_px)
        }

        dry(
          %{logic | throw: nil, ignored: Map.put(logic.ignored, throw.point, entrada)},
          [{:log, "não é corpo (#{point_str(throw.point)}); ignorando"}]
        )

      # past the window, gone → captured
      true ->
        captured(logic, obs, now)
    end
  end

  defp captured(%{throw: throw, config: config} = logic, obs, _now) do
    logic = update_in(logic.counters.captures, &(&1 + 1))
    tardio? = obs.captured_at > throw.at + config.corpse_confirm_after_ms * 6

    logic =
      if tardio?,
        do: update_in(logic.counters.tardias, &(&1 + 1)),
        else: logic

    selo = if tardio?, do: " (tardio)", else: ""

    {%{logic | throw: nil, dry_balls: 0},
     [{:log, "capturado#{selo} em #{point_str(throw.point)}"}]}
  end

  # A corpse of ANOTHER species exactly where the ball flew: proof the original
  # target was consumed and the ground recycled. Requires a name on BOTH sides.
  defp outra_especie?(obs, %{name: ball_name, point: ponto}, tol)
       when is_binary(ball_name) do
    case name_in(obs, ponto, tol) do
      nil -> false
      current_name -> current_name != ball_name
    end
  end

  defp outra_especie?(_obs, _throw_without_name, _tol), do: false

  # Mirror of fishing's dry cast: N consecutive balls resolved WITHOUT a
  # confirmed capture = the hotkey isn't reaching the game, the aim is wrong, or
  # a library false-positive is eating the queue. Alarm and reset; 0 = off.
  defp dry(logic, actions) do
    dry = logic.dry_balls + 1
    cap = Map.get(logic.config, :dry_balls_alarm, 0)

    if cap > 0 and dry >= cap do
      {%{logic | dry_balls: 0},
       actions ++
         [
           {:alarm,
            "🥎 #{dry} bolas seguidas sem captura confirmada — o atalho chega no jogo? " <>
              "a mira está no corpo? tem falso-positivo na fila?"}
         ]}
    else
      {%{logic | dry_balls: dry}, actions}
    end
  end

  # The identity the scan already knows at the point — so the ignore veto never
  # contaminates a future corpse of ANOTHER species on the same tile.
  defp name_in(obs, ponto, tolerancia) do
    obs
    |> Map.get(:known, %{})
    |> Enum.find_value(fn {p, %{name: name}} -> if near?(p, ponto, tolerancia), do: name end)
  end

  defp admit(logic, obs) do
    tolerance = logic.config.corpse_match_tolerance_px
    busy = logic.queue ++ if logic.throw, do: [logic.throw.point], else: []

    fresh =
      Enum.reject(obs.corpses, fn c ->
        Enum.any?(busy, &near?(&1, c, tolerance)) or vetoed?(logic, obs, c, tolerance)
      end)

    %{logic | queue: logic.queue ++ fresh}
  end

  # The ignore veto is by IDENTITY when possible: a point vetoed as "Pet" must
  # not hold a Kingler freshly fallen on the same tile. Without names on both
  # sides (old library, read without known) the point veto still applies —
  # fails conservative.
  defp vetoed?(logic, obs, candidato, tolerance) do
    Enum.any?(logic.ignored, fn {ponto, entrada} ->
      near?(ponto, candidato, tolerance) and same_identity?(entrada, obs, candidato, tolerance)
    end)
  end

  defp same_identity?(%{name: nil}, _obs, _candidato, _tol), do: true

  defp same_identity?(%{name: vetoed_name}, obs, candidato, tol) do
    case name_in(obs, candidato, tol) do
      nil -> true
      new_name -> new_name == vetoed_name
    end
  end

  defp same_identity?(_entrada_antiga, _obs, _candidato, _tol), do: true

  defp maybe_throw(%{throw: nil, queue: [point | rest]} = logic, obs, now) do
    logic = update_in(logic.counters.throws, &(&1 + 1))

    # The name the scan saw at the point travels with the ball: it enables
    # identity-based judging at confirmation (other species there = captured).
    throw = %{
      point: point,
      balls: 1,
      at: now,
      name: name_in(obs, point, logic.config.corpse_match_tolerance_px)
    }

    {%{logic | throw: throw, queue: rest},
     [{:capture_sequence, point}, {:log, "bola em #{point_str(point)}"}]}
  end

  defp maybe_throw(logic, _obs, _now), do: {logic, []}

  defp prune_ignored(logic, now) do
    %{logic | ignored: Map.filter(logic.ignored, fn {_point, entrada} -> ate(entrada) > now end)}
  end

  defp ate(%{ate: expiry}), do: expiry
  defp ate(expiry) when is_integer(expiry), do: expiry

  defp present?(corpses, point, tolerance),
    do: Enum.any?(corpses, &near?(&1, point, tolerance))

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp point_str({x, y}), do: "#{x},#{y}"
end
