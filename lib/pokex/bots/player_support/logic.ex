defmodule Pokex.Bots.PlayerSupport.Logic do
  @moduledoc """
  Pure decision core for the survival combo. No I/O, no time of its own — the caller supplies the
  HP reading and the monotonic `now`, so every rule here is a total function that is trivial to
  test.

  WHEN to revive the main Pokémon is `Engine.Logic`'s call, not this module's — see
  `PlayerSupport.Worker.revive_decision/0`. `combo/1` builds the atomic Body sequence the engine's
  `revive: :now` triggers: recalls the Pokémon, max-revives it on its portrait, and puts it back
  out.
  """

  @doc """
  True when the main Pokémon wants a potion — everything EXCEPT the combat gate: enabled, HP known
  and below the potion threshold, and the previous sip's heal channel (cooldown) has elapsed. The
  caller checks combat separately because that answer costs a screen capture — this predicate is
  what makes that capture worth taking. A potion drunk in combat is a wasted potion (the channel is
  interrupted the moment a fight starts), so the worker only fires when it CONFIRMED out-of-combat.

  Same two-consecutive-reads rule as `decide/1` (`prev_hp_pct` must agree): a single garbage
  frame must not chug a potion either.

  Expects `:hp_pct` and `:prev_hp_pct` (0..100 or nil), `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_potion_at` (monotonic ms or nil) and `:now` (monotonic ms).
  """
  @spec potion_wanted?(map) :: boolean
  def potion_wanted?(%{enabled?: false}), do: false
  def potion_wanted?(%{hp_pct: nil}), do: false
  def potion_wanted?(%{hp_pct: hp, threshold_pct: threshold}) when hp >= threshold, do: false

  def potion_wanted?(%{prev_hp_pct: prev, threshold_pct: threshold})
      when is_nil(prev) or prev >= threshold,
      do: false

  def potion_wanted?(%{last_potion_at: nil}), do: true

  def potion_wanted?(%{now: now, last_potion_at: last, cooldown_ms: cooldown}),
    do: now - last >= cooldown

  @doc """
  True when the main Pokémon should press its own HEALING SKILL — the one job on
  `/time` that nothing used to fire.

  This exists because of what `potion_wanted?/1` says right above: a potion is a
  CHANNEL and combat cancels it, so the sip only ever happens out of battle.
  Which leaves the case that actually kills a pokémon — HP falling WHILE it
  fights — with nothing at all between the last full bar and the revive. A skill
  is an instant press, not a channel: it is the only one of the three that works
  mid-fight, so this predicate deliberately has NO combat gate.

  Hence the ladder, cheapest and most available first:

      heal skill  — free, works in combat        (pokemon_hp_heal_pct, highest)
      potion      — costs money, out of combat   (pokemon_hp_potion_pct)
      revive      — costs a revive, last resort  (pokemon_hp_rescue_pct, lowest)

  Same two-consecutive-reads rule as the other two: one garbage frame must not
  spend a cooldown either. The cooldown here is only anti-spam — whether the
  skill is actually up is the SKILL BAR's answer, and the caller asks it.

  Expects `:hp_pct`, `:prev_hp_pct`, `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_heal_at` and `:now`.
  """
  @spec heal_wanted?(map) :: boolean
  def heal_wanted?(input), do: rung_wanted?(input, :last_heal_at)

  @doc """
  A AURA DE DEFESA, o degrau acima da cura.

  "Quando o pokémon chega abaixo de 85% da HP quer dizer que já tem gente
  batendo nele o suficiente e vale usar o buff de defesa" (Lucas, 02/09). A
  mesma escada da cura: duas leituras abaixo do limiar, e o cooldown aqui é só
  anti-spam — se a aura está pronta é a BARRA que diz, e quem aperta pergunta.

  Expects `:hp_pct`, `:prev_hp_pct`, `:threshold_pct`, `:enabled?`,
  `:cooldown_ms`, `:last_shield_at` and `:now`.
  """
  @spec shield_wanted?(map) :: boolean
  def shield_wanted?(input), do: rung_wanted?(input, :last_shield_at)

  defp rung_wanted?(%{enabled?: false}, _last), do: false
  defp rung_wanted?(%{hp_pct: nil}, _last), do: false

  defp rung_wanted?(%{hp_pct: hp, threshold_pct: threshold}, _last) when hp >= threshold,
    do: false

  defp rung_wanted?(%{prev_hp_pct: prev, threshold_pct: threshold}, _last)
       when is_nil(prev) or prev >= threshold,
       do: false

  defp rung_wanted?(%{now: now, cooldown_ms: cooldown} = input, last) do
    case Map.get(input, last) do
      nil -> true
      at -> now - at >= cooldown
    end
  end

  @doc """
  Everything he still has in hand when the stun did NOT go out — the last
  thing tried before the field is given up.

  "Stun não confirmado: se não tem mais outras skills pra usar, pra tentar dar
  aquele último dano, daí recolhe" (Lucas, 2026-08-14). Recalling with a full
  hand is the worst of both worlds: the pokémon leaves, the pile stays awake,
  and the character is the one standing there. So a refused stun escalates
  instead — another control key may put the pile down, and damage may simply
  end it.

  Order IS the priority: `crowd` first (it is what the stun was for), then
  `aoe` (a gathered pile is a crowd by definition), then `single`. Keys already
  pressed drop out — pressing again what just failed to fire buys nothing.
  `ready` filters against the skill bar, and `nil` (no reading) keeps
  everything: the same fail-open rule as `stun_prefix/2`, because in this
  moment a blind press beats no press at all.
  """
  @spec last_resort_keys(map | nil, [String.t()], [String.t()] | nil, boolean) :: [String.t()]
  def last_resort_keys(loadout, tried, ready, single_target? \\ false)

  def last_resort_keys(nil, _tried, _ready, _single?), do: []

  def last_resort_keys(loadout, tried, ready, single_target?) do
    # …E O ALVO ÚNICO SÓ SE ELE MACHUCAR. Esta escalação existe pra tapar o
    # buraco de um resgate sem controle, e ela apertava TUDO que sobrou — mas
    # "skills de alvo único não funcionam mais, de propósito" (29/08). Uma
    # tecla que o jogo ignora não protege recolhida nenhuma: gasta o tempo do
    # corpo e o cooldown dela, e deixa a pilha acordada do mesmo jeito.
    single = if single_target?, do: Map.get(loadout, :single, []), else: []

    (Map.get(loadout, :crowd, []) ++ Map.get(loadout, :aoe, []) ++ single)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in tried))
    |> then(fn keys -> if is_list(ready), do: Enum.filter(keys, &(&1 in ready)), else: keys end)
  end

  @doc """
  True when the pokémon on the field DIED — read from the bar's trajectory,
  because a dead pokémon has no bar left to read.

  When it falls, the game's pokémon window changes shape and the calibrated
  strip stops holding a bar at all (Lucas, 2026-08-14) — so the reading goes
  `:unrecognized`, which is exactly what a covered game or a minimized party
  window also produce. Identical in the pixels; what tells them apart is where
  the bar WAS the moment before. A bar at 12% that vanishes is a death; a bar
  at 100% that vanishes is a window someone moved.

  Hence: unreadable for two consecutive reads (the house rule against a single
  garbage frame) AND the last thing actually SEEN was below `faint_below_pct`.

  The caller clears `last_seen_hp` once this fires, so a death costs exactly
  one revive: firing again requires seeing the pokémon alive first. That is
  what stops a pokémon merely STORED in its ball from burning the stock.

  Expects `:enabled?`, `:unreadable_streak`, `:last_seen_hp`, `:faint_below_pct`,
  `:cooldown_ms`, `:last_faint_at` and `:now`.
  """
  @spec fainted?(map) :: boolean
  def fainted?(%{enabled?: false}), do: false
  def fainted?(%{unreadable_streak: streak}) when streak < 2, do: false
  def fainted?(%{last_seen_hp: nil}), do: false
  def fainted?(%{last_seen_hp: hp, faint_below_pct: below}) when hp > below, do: false
  def fainted?(%{last_faint_at: nil}), do: true

  def fainted?(%{now: now, last_faint_at: last, cooldown_ms: cooldown}),
    do: now - last >= cooldown

  @doc """
  The revive, as a Body action list: an optional STUN PREFIX (`stun_steps`,
  already-compiled `{:press, _}`/`{:wait, _}` actions — see `stun_prefix/2`),
  the lead wait its sleep still needs to LAND (`settle_ms`), and the key.

  One press is the whole revive in this client (Lucas, 2026-08-24: "é só
  apertar o botão F4" — it recalls, revives and puts the pokémon back on the
  field by itself). The client before it needed a choreography: recall, cursor
  onto the portrait, max-revive, release, cursor home — five steps nothing
  could interrupt, which is why they rode inside ONE `Body.perform`.

  The prefix still rides inside that same perform, for the reason it was born:
  nothing may wedge itself between the pile falling asleep and the pokémon
  leaving the field (2026-07-30, and 2026-08-14 when a rescue exposed the
  character himself). The exposure survived the client change — the pokémon is
  still away for a moment (Lucas, 2026-08-24) — so the prefix stays available,
  off by default, for the hunt that turns out to need it.
  """
  # E NASCE COM `:still` NA FRENTE: o Body solta as setas antes de qualquer
  # coisa desta lista sair. Reviver andando era o que ele proibiu em 02/09
  # ("pode ser mortal eu usar o revive enquanto ainda tem monstro na tela"), e
  # o cavebot só solta no tique dele — o revive não pode depender desse tique.
  @spec revive(map) :: [tuple | :still]
  def revive(%{rescue_key: rescue_key} = config) do
    stun = Map.get(config, :stun_steps, [])
    glue = if stun == [], do: [], else: [{:wait, Map.get(config, :step_ms, 40)}]

    [
      :still
      | stun ++ glue ++ settle_wait(Map.get(config, :settle_ms, 0)) ++ [{:press, rescue_key}]
    ]
  end

  defp settle_wait(ms) when is_integer(ms) and ms > 0, do: [{:wait, ms}]
  defp settle_wait(_none), do: []

  @doc """
  Compiles a combo's stun steps into Body actions against the skill-bar reading.

  `ready` is the list of ready keys — or `nil` when the reading is unavailable, in which case ALL
  go in blind (a cooling key is a no-op in game; holding the rescue waiting for a read costs HP).
  A skill on cooldown is SKIPPED and returned in `skipped` so the log can name it (decision: skip,
  never wait). Waits are always kept (ms cost, zero risk). A step that isn't a skill/wait is
  ignored — eligibility filters earlier, and a combo edited between selection and firing must
  NEVER take a rescue down.

  Returns `{actions, skipped}`.
  """
  @spec stun_prefix([tuple], [String.t()] | nil) :: {[tuple], [String.t()]}
  def stun_prefix(steps, ready) do
    {actions, skipped} =
      Enum.reduce(steps, {[], []}, fn
        {:skill, key}, {actions, skipped} ->
          if ready == nil or key in ready,
            do: {[{:press, key} | actions], skipped},
            else: {actions, [key | skipped]}

        {:wait, ms}, {actions, skipped} when is_integer(ms) ->
          {[{:wait, ms} | actions], skipped}

        _odd_step, acc ->
          acc
      end)

    {Enum.reverse(actions), Enum.reverse(skipped)}
  end
end
