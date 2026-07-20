defmodule Pokex.Bots.Catcher.Logic do
  @moduledoc """
  Pure decision core for corpse capture (spec 2026-07-10-corpse-capture-design.md): admit
  detected corpses into a queue, keep exactly ONE ball in flight, confirm each throw against
  observations captured after the ball's flight window (a hit consumes the corpse instantly —
  game rule), retry once, and ignore persistent non-corpses (a parked pet) for a TTL. No I/O,
  no clock: the driver supplies observations and monotonic `now`.
  """

  defstruct state: :idle,
            config: nil,
            queue: [],
            throw: nil,
            ignored: %{},
            last_obs_at: nil,
            error: nil,
            counters: %{captures: 0, throws: 0, ignored: 0}

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
    logic = admit(logic, obs.corpses)
    {logic, throw_actions} = maybe_throw(logic, now)

    {logic, confirm_actions ++ throw_actions}
  end

  @doc "Poll cadence while work is pending; nil when there is nothing to watch."
  def next_wake(%__MODULE__{state: :idle}, _now), do: nil
  def next_wake(%__MODULE__{throw: nil, queue: []}, _now), do: nil
  def next_wake(%__MODULE__{config: config}, _now), do: max(config.feed_corpses_ms, 1)

  @doc """
  Corpses still being worked (queued + the one ball in flight) — the post-fight
  policy signal: suporte can wait for this to hit zero before healing/moving.
  """
  def pending(%__MODULE__{state: :idle}), do: 0

  def pending(%__MODULE__{queue: queue, throw: throw}),
    do: length(queue) + if(throw, do: 1, else: 0)

  # -- confirmation -------------------------------------------------------------

  defp confirm(%{throw: nil} = logic, _obs, _now), do: {logic, []}

  defp confirm(%{throw: throw, config: config} = logic, obs, now) do
    cond do
      # the ball is still flying — this frame proves nothing
      obs.captured_at < throw.at + config.corpse_confirm_after_ms ->
        {logic, []}

      # past the flight window, still there (moved-or-not is irrelevant) → retry
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) and
          throw.balls < config.corpse_max_balls ->
        logic = update_in(logic.counters.throws, &(&1 + 1))

        {%{logic | throw: %{throw | balls: throw.balls + 1, at: now}},
         [
           {:capture_sequence, throw.point},
           {:log, "bola #{throw.balls + 1} em #{point_str(throw.point)}"}
         ]}

      # past the window, still there, and out of balls → not a corpse; ignore for the TTL
      present?(obs.corpses, throw.point, config.corpse_match_tolerance_px) ->
        logic = update_in(logic.counters.ignored, &(&1 + 1))
        ignored = Map.put(logic.ignored, throw.point, now + config.corpse_ignore_ttl_ms)

        {%{logic | throw: nil, ignored: ignored},
         [{:log, "não é corpo (#{point_str(throw.point)}); ignorando"}]}

      # past the window, gone → captured
      true ->
        logic = update_in(logic.counters.captures, &(&1 + 1))
        {%{logic | throw: nil}, [{:log, "capturado em #{point_str(throw.point)}"}]}
    end
  end

  # -- admission ---------------------------------------------------------------

  defp admit(logic, corpses) do
    tolerance = logic.config.corpse_match_tolerance_px

    known =
      logic.queue ++
        Map.keys(logic.ignored) ++ if logic.throw, do: [logic.throw.point], else: []

    fresh = Enum.reject(corpses, fn c -> Enum.any?(known, &near?(&1, c, tolerance)) end)
    %{logic | queue: logic.queue ++ fresh}
  end

  defp maybe_throw(%{throw: nil, queue: [point | rest]} = logic, now) do
    logic = update_in(logic.counters.throws, &(&1 + 1))

    {%{logic | throw: %{point: point, balls: 1, at: now}, queue: rest},
     [{:capture_sequence, point}, {:log, "bola em #{point_str(point)}"}]}
  end

  defp maybe_throw(logic, _now), do: {logic, []}

  defp prune_ignored(logic, now) do
    %{logic | ignored: Map.filter(logic.ignored, fn {_point, expiry} -> expiry > now end)}
  end

  defp present?(corpses, point, tolerance),
    do: Enum.any?(corpses, &near?(&1, point, tolerance))

  defp near?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp point_str({x, y}), do: "#{x},#{y}"
end
