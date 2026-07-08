defmodule Pokex.Bots.Loot.Logic do
  @moduledoc """
  Pure state machine for the loot sub-cycle: walk to a corpse, space-loot the adjacent
  body, throw the pokéball, and retrace the EXACT path back to the fishing spot. No side
  effects — the driver hands it the corpse's floating-name screen point + `now` and executes
  the returned actions.

  Runs independently of combat: attacking depends only on the fixed side battle panel, so
  walking the character never disturbs it. The walk is planned ONCE at the start (the world
  scrolls as we move, so a mid-walk re-derivation from a stale point would drift), and the
  return leg is the exact reverse of the executed outbound steps — so loot always lands back
  on the origin tile. Contains ZERO combat logic.
  """

  defstruct state: :idle,
            config: nil,
            entered_at: 0,
            waiting_until: nil,
            walk_plan: [],
            walk_taken: [],
            loot_offset: nil,
            loot_presses_left: 0,
            failures: 0,
            error: nil,
            counters: %{loots: 0, captures: 0, failures: 0}

  def new(config), do: %__MODULE__{config: config}

  @doc """
  Begin looting the corpse whose floating-name screen point is `corpse` (nil = position
  unknown → loot in place). Plans the walk once and enters `:walking_to_loot`; an empty plan
  (unknown / too-far corpse) skips straight to `:looting`.
  """
  def start(%__MODULE__{} = logic, corpse, now) do
    {plan, offset} = plan_walk(corpse, logic.config)

    logic = %{
      logic
      | walk_plan: plan,
        walk_taken: [],
        loot_offset: offset,
        loot_presses_left: logic.config.loot_presses,
        failures: 0,
        error: nil
    }

    state = if plan == [], do: :looting, else: :walking_to_loot
    {advance(logic, state, now), []}
  end

  def busy?(%__MODULE__{state: :idle}), do: false
  def busy?(%__MODULE__{}), do: true

  def stop(logic), do: {%{logic | state: :idle, waiting_until: nil}, []}

  def io_failed(logic, reason, now), do: fail(logic, now, reason)

  # Loot walks by dead-reckoning — it never senses the battle. The Guardian owns the panic
  # corner (its on_panic halts this worker), so loot needs no cursor read of its own.
  def needs(%__MODULE__{}, _now), do: []

  def tick_interval(%__MODULE__{config: c}), do: c.tick_ms_default

  def waiting?(%__MODULE__{waiting_until: nil}, _now), do: false
  def waiting?(%__MODULE__{waiting_until: until}, now), do: now < until

  # -- stepping ---------------------------------------------------------------

  def step(%__MODULE__{state: state} = logic, _obs, _now) when state in [:idle, :error],
    do: {logic, []}

  def step(logic, obs, now) do
    if logic.waiting_until != nil and now < logic.waiting_until do
      {logic, []}
    else
      do_step(%{logic | waiting_until: nil}, obs, now)
    end
  end

  # One arrow press per tick, each SPACED by walk_step_ms — rapid back-to-back movement inputs
  # bug the pokemon out and it doesn't move at all. Every executed step is prepended to
  # walk_taken so the walk-back is an exact retrace.
  defp do_step(%{state: :walking_to_loot, walk_plan: [dir | rest]} = logic, _obs, now) do
    {advance(
       %{logic | walk_plan: rest, walk_taken: [dir | logic.walk_taken]},
       :walking_to_loot,
       now,
       wait: logic.config.walk_step_ms
     ), [{:press, dir}]}
  end

  defp do_step(%{state: :walking_to_loot, walk_plan: []} = logic, _obs, now) do
    {advance(logic, :looting, now), []}
  end

  # SPACE loots any ADJACENT corpse — no aiming needed. A couple of spaced presses covers a
  # slow corpse-drop animation.
  defp do_step(%{state: :looting, loot_presses_left: n} = logic, _obs, now) when n > 0 do
    {advance(%{logic | loot_presses_left: n - 1}, :looting, now, wait: logic.config.wait_loot_ms),
     [{:press, "space"}]}
  end

  defp do_step(%{state: :looting} = logic, _obs, now) do
    logic = update_in(logic.counters.loots, &(&1 + 1))
    {advance(logic, :capturing, now), []}
  end

  defp do_step(%{state: :capturing} = logic, _obs, now) do
    # We stopped adjacent to the corpse: click one tile toward it (or one tile below the
    # player when the corpse position was unknown).
    {ox, oy} = logic.loot_offset || {0, 1}
    {px, py} = logic.config.player_point
    target = {px + ox * logic.config.tile_px, py + oy * logic.config.tile_px}
    logic = %{logic | failures: 0}

    {logic, actions} =
      if logic.config.auto_capture do
        {update_in(logic.counters.captures, &(&1 + 1)), [{:capture_sequence, target}]}
      else
        {logic, [{:log, "auto-captura desligada — sem pokébola"}]}
      end

    # walk_taken is most-recent-first, so mapping to opposites IS the exact retrace back to
    # the fishing spot (arrow presses are 1 tile regardless of a slightly-wrong tile_px, so
    # the return can never drift).
    {advance(
       %{
         logic
         | walk_plan: Enum.map(logic.walk_taken, &opposite/1),
           walk_taken: [],
           loot_offset: nil
       },
       :walking_back,
       now,
       wait: logic.config.wait_after_capture_ms
     ), actions}
  end

  defp do_step(%{state: :walking_back, walk_plan: [dir | rest]} = logic, _obs, now) do
    {advance(%{logic | walk_plan: rest}, :walking_back, now, wait: logic.config.walk_step_ms),
     [{:press, dir}]}
  end

  defp do_step(%{state: :walking_back, walk_plan: []} = logic, _obs, now) do
    # back at the fishing spot → idle, waiting for the next kill.
    {advance(%{logic | loot_offset: nil}, :idle, now), []}
  end

  # -- walk planning ----------------------------------------------------------

  # Turn the corpse's floating-name screen point into an arrow-key plan, computed ONCE. The
  # body lies one tile BELOW the name. Stops ADJACENT to the corpse (one step short per axis)
  # — SPACE loots from there. nil / too-far → loot in place (empty plan).
  defp plan_walk(nil, _config), do: {[], nil}

  defp plan_walk({cx, cy}, config) do
    bx = cx
    by = cy + config.tile_px
    {px, py} = config.player_point
    dx = round((bx - px) / config.tile_px)
    dy = round((by - py) / config.tile_px)

    if abs(dx) > config.max_walk_tiles or abs(dy) > config.max_walk_tiles do
      {[], nil}
    else
      plan =
        List.duplicate(if(dx > 0, do: "right", else: "left"), max(abs(dx) - 1, 0)) ++
          List.duplicate(if(dy > 0, do: "down", else: "up"), max(abs(dy) - 1, 0))

      {plan, {clamp_unit(dx), clamp_unit(dy)}}
    end
  end

  defp clamp_unit(d), do: d |> max(-1) |> min(1)

  defp opposite("up"), do: "down"
  defp opposite("down"), do: "up"
  defp opposite("left"), do: "right"
  defp opposite("right"), do: "left"

  # -- shared helpers ---------------------------------------------------------

  defp fail(%__MODULE__{} = logic, now, reason) do
    failures = logic.failures + 1
    logic = update_in(logic.counters.failures, &(&1 + 1))
    reason = to_string(reason)

    if failures >= logic.config.max_consecutive_failures do
      {%{
         logic
         | state: :error,
           failures: failures,
           waiting_until: nil,
           error: "#{reason} (#{failures}x)"
       }, [{:log, reason}]}
    else
      # abandon this corpse and go idle; the next kill event starts fresh.
      {advance(%{logic | failures: failures}, :idle, now), [{:log, reason}]}
    end
  end

  defp advance(logic, state, now, opts \\ []) do
    wait = Keyword.get(opts, :wait)
    %{logic | state: state, entered_at: now, waiting_until: wait && now + wait}
  end
end
