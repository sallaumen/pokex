defmodule Pokex.Bots.Engine.Logic do
  @moduledoc """
  The decision, in one place and as one pure function.

  Until now the tactical decisions lived in three processes that never spoke:
  the hunt held the fire on a clock, the fight opened on an edge, and the
  support revived on a health bar alone. Each was defensible on its own and the
  combination was not — a revive fired at 60% into a live pile with every
  cooldown up, throwing away both halves of what a revive is worth.

  So `step/4` takes the shared picture, where the hunt is, and what this
  pokémon's keys do, and answers with ORDERS. It presses nothing: the orders
  travel as a fact, and whoever obeys them owns their own hands.

  ## The rules are his, and they are the contract

    * **R1 — the ruler is a count, not a clock.** Under three monsters it is not
      worth attacking at all: keep walking, let them lose interest. "Eu
      realmente mato quando tem uns três."
    * **R2 — greed has a ceiling.** Dragging a pile far from where it spawned
      makes it vanish, so "wait until they stop arriving" is always bounded.
    * **R3 — the revive is economics, not first aid.** It resets every cooldown
      AND heals, so it is spent at the END of a round, once the cooldowns are
      already gone. "Reviver no meio do nada, só porque a vida do pokémon ficou
      baixa, também é uma lógica muito burra."
    * **R3b — a bar with nothing left IS the end of a round.** Standing in front
      of a pile still worth fighting with every damage key on cooldown is a
      round that has already ended, whatever the health bar says: waiting out
      eight seconds of cooldown buys nothing the reset would not buy in one.
      The press is `rescue_key` — F4, which in Poké Alliance is the whole
      choreography in one key: it recalls, uses the revive and puts the pokemon
      back on the field (his own account, 2026-08-25). The reset is the
      send-out; whether it really clears the cooldowns is measured in `/sim`.
      "Quando estávamos com 0 cooldowns livres, muitos inimigos ainda na tela,
      vale a pena usar o revive no F4 rapidinho pra luta seguir firme e forte"
      (Lucas, 2026-08-25). Measured in the bench before it was written: the
      hunt spends **12% to 23% of every run** in exactly that state.
    * **R4 — the stun is a clock nothing contradicts.** A partial stun is the
      common case, not the exception, and the window it opens is the best one
      available: "essa é a melhor janela antes de eu não ter mais opções e
      deixar meu pokémon morrer." Untouched here on purpose — see the note
      below on `revive`.

  And the three bands he drew over them: green above `band_yellow_pct` hunts
  normally; yellow CLOSES THE ROUND (stop gathering, let the pile arrive, spend
  everything on it, then revive even above the red line, so the next leg starts
  full); red revives immediately, mid-fight.

  ## `revive` is the whole sequence, not half of one

  `PlayerSupport`'s rescue combo already presses this pokémon's reserved
  control key, CONFIRMS it against the skill bar, waits out what is left of the
  sleep, and only then recalls — atomically, as one `Body.perform`
  (`PlayerSupport.Logic.combo/1`). That is R4, already field-tested (PRs #285,
  #289) and already fails toward saving when the stun does not land. `revive:
  :now` triggers exactly that, unchanged — this module decides WHEN, not how.

  An earlier draft had this module ALSO order a stun mid-round, ahead of the
  fight that spends the cooldowns, so the revive at the end would recall into a
  pile already asleep. Dropped: `Strategy.reserved/1` keeps the control key out
  of every ordinary rotation for the ONE moment `PlayerSupport` needs it, and a
  second presser racing it — on a key with one copy — is a bug waiting for a
  timing coincidence, not a feature. `fire: :free` here means "spend what is
  NOT reserved"; the reserved key stays for the combo that already knows how to
  use it.

  ## What it deliberately does not decide

  Not seeing is not a decision. When the picture says it cannot read the screen,
  the orders say hold — and every consumer's rule for a missing order is what it
  does today. An engine that guesses is worse than one that is quiet.

  ## No hunt does not mean no pokémon

  `hunt: nil` used to mean "answer green and say nothing else" — right while
  Cavebot is simply between routes, wrong while Lucas is fishing: this worker
  still ticks in that mode (`engine_active` is not mode-gated), so it still
  PUBLISHES a fresh `:orders` fact every tick. `PlayerSupport`'s own HP ladder
  (`Logic.decide/1`) is only ever consulted when the engine's fact is missing
  or stale — a fresh fact saying `revive: :hold` is not "the engine has
  nothing to say", it is "the engine says hold", and it would silently
  outrank a ladder that has protected fishing for as long as the bot has
  existed. So `hunt: nil` still bands on HP (the one reading that means the
  same thing whether or not a hunt is running) and answers `revive: :now`
  on yellow or red — no pile to close, no cooldowns worth spending first, so
  there is nothing to wait for that closing/emergency's split still buys.
  """

  defstruct state: :idle,
            # when each phase started, so a wait can have a ceiling
            since: %{},
            why: nil

  @type t :: %__MODULE__{}

  @type orders :: %{
          phase: atom,
          band: :green | :yellow | :red,
          route: :go | :hold,
          fire: :hold | :free,
          opening: [String.t()],
          revive: :hold | :now,
          potion: :hold | :now,
          why: String.t()
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  One tick of the decision.

  `world` carries `:situation` (the shared picture), `:hunt` (where the route
  is, or `nil` when no hunt is running) and `:hands` (`%{opening: keys}` — the
  non-reserved keys this pokémon fights with; the reserved control key never
  appears here, see the moduledoc).
  """
  @spec step(t, map, map, integer) :: {t, orders}
  def step(logic, world, config, now) do
    {logic, orders} = decide(logic, world, config, now)
    {%{logic | why: orders.why}, orders}
  end

  # No hunt to run — but HP still means what it always means. See the
  # moduledoc's "No hunt does not mean no pokémon".
  defp decide(logic, %{hunt: nil} = world, config, _now) do
    band = band(world.situation, config)

    case band do
      :green ->
        {%{logic | state: :idle}, orders(:idle, :green, why: "sem caçada rodando")}

      _yellow_or_red ->
        hp = world.situation.own_hp

        {%{logic | state: :guarding},
         orders(:guarding, band,
           revive: :now,
           why: "sem caçada, só protegendo: #{hp}% de vida — revive agora"
         )}
    end
  end

  defp decide(%{state: :recovering} = logic, world, config, now),
    do: recovering(logic, world, config, now)

  defp decide(logic, world, config, now) do
    band = band(world.situation, config)

    cond do
      band == :red -> emergency(logic, world, config, now)
      band == :yellow -> closing(logic, world, config, now)
      world.situation.blind? -> blind(logic)
      true -> normal(logic, world, config, now)
    end
  end

  # An unknown health bar is not a band. The guard only ever fires on a number
  # it actually read — the same two-reads discipline the support has used since
  # a single garbage frame nearly burned a revive.
  defp band(%{own_hp: hp}, config) when is_integer(hp) do
    cond do
      hp < config.band_red_pct -> :red
      hp < config.band_yellow_pct -> :yellow
      true -> :green
    end
  end

  defp band(_unknown, _config), do: :green

  defp blind(logic) do
    {%{logic | state: :blind},
     orders(:blind, :green, why: "não estou vendo a lista de batalha — não mando nada")}
  end

  # RED. No waiting, no stun, no pile to finish: the pokémon is about to fall
  # and the revive is the only thing that answers that.
  defp emergency(logic, world, _config, now) do
    hp = world.situation.own_hp

    {to_recovering(logic, now),
     orders(:emergency, :red,
       route: :hold,
       fire: :free,
       opening: opening(world),
       revive: :now,
       why: "vermelho: #{hp}% de vida — revive agora, no meio da luta"
     )}
  end

  # YELLOW — "fecha a rodada". The one sequence that crosses two workers, and
  # the reason a central engine exists at all: the road holds (R2) while the
  # fight spends what it has (R3) on whatever the pile still owes, and the
  # revive — the ALREADY atomic stun+recall combo, see the moduledoc — fires
  # once that stops being worth waiting for.
  defp closing(logic, world, config, now) do
    logic = enter(logic, :closing, now)
    s = world.situation
    hp = s.own_hp

    cond do
      # R2: stop extending the gathering FIRST, then let what is already coming
      # arrive. The ceiling is what makes this a decision instead of a hang.
      not settled?(s, config) and within?(logic, :closing, config.closing_timeout_ms, now) ->
        {logic,
         orders(:closing, :yellow,
           route: :hold,
           fire: :hold,
           why: "amarelo (#{hp}%): parei de mobar, esperando a pilha fechar"
         )}

      # The pile is down, or the round has simply run long enough — waiting
      # longer buys nothing either way, and the alternative is the revive
      # combo firing with no pokémon left on the field.
      revive_now?(logic, s, config, now) ->
        {to_recovering(logic, now),
         orders(:closing, :yellow,
           route: :hold,
           fire: :free,
           opening: opening(world),
           revive: :now,
           why: revive_why(s, hp)
         )}

      true ->
        {logic,
         orders(:closing, :yellow,
           route: :hold,
           fire: :free,
           opening: opening(world),
           why: "amarelo (#{hp}%): gastando os cooldowns em #{count(s)}"
         )}
    end
  end

  defp revive_now?(logic, s, config, now),
    do: s.enemies == 0 or not within?(logic, :closing, config.closing_timeout_ms, now)

  defp revive_why(%{enemies: 0}, hp),
    do:
      "amarelo (#{hp}%): pilha limpa e cooldowns gastos — revive agora, o próximo mob começa cheio"

  defp revive_why(_still_up, hp),
    do: "amarelo (#{hp}%): a rodada já durou o que podia durar — revive agora"

  defp recovering(logic, world, config, now) do
    hp = world.situation.own_hp

    cond do
      is_integer(hp) and hp >= config.resume_pct ->
        logic |> reset() |> normal(world, config, now)

      not within?(logic, :recovering, config.recover_timeout_ms, now) ->
        {reset(%{logic | state: :travelling}),
         orders(:travelling, band(world.situation, config),
           route: :go,
           why: "desisti de esperar o revive — voltando pra rota"
         )}

      true ->
        {logic,
         orders(:recovering, band(world.situation, config),
           route: :hold,
           fire: :free,
           opening: opening(world),
           why: "me recuperando: a rota só volta com a vida acima de #{config.resume_pct}%"
         )}
    end
  end

  # GREEN: what the route says, with the ruler applied where it stops.
  defp normal(logic, %{hunt: %{state: :fighting}} = world, config, now),
    do: sizing(logic, world, config, now)

  defp normal(logic, %{hunt: %{state: :walking, luring?: true}} = world, config, now) do
    if gathering?(config) do
      {reset_fight(logic, :gathering, now),
       orders(:gathering, band(world.situation, config),
         route: :go,
         why: "mobando: puxando a pilha, sem atacar"
       )}
    else
      {reset_fight(logic, :travelling, now),
       orders(:travelling, band(world.situation, config),
         route: :go,
         fire: :free,
         opening: opening(world),
         why: "trecho de mobada, mas sem juntar pilha: batendo enquanto ando"
       )}
    end
  end

  defp normal(logic, world, config, now) do
    {reset_fight(logic, :travelling, now),
     orders(:travelling, band(world.situation, config),
       route: :go,
       why: travelling_why(world.hunt)
     )}
  end

  defp travelling_why(%{state: :walking}), do: "andando a rota"
  defp travelling_why(%{state: :post_fight}), do: "limpando o que ficou no chão"
  defp travelling_why(%{state: state}), do: "a caçada está em #{state}"

  # THE RULER (R1). Standing at the kill spot, the question is not "is there
  # something to hit" but "is this worth the area damage".
  defp sizing(%{state: :engaged} = logic, world, config, now) do
    s = world.situation

    if reset_revive?(logic, s, config, now) do
      # R3b. Stays ENGAGED — this is not a rescue and there is nothing to
      # recover from: the body comes back full, with a full bar, into the same
      # fight it left.
      {%{logic | since: Map.put(logic.since, :reset_revive, now)},
       orders(:engaged, band(s, config),
         route: :hold,
         fire: :free,
         opening: opening(world),
         revive: :now,
         why: "sem cooldown com #{count(s)} na frente — revive pra voltar com a barra cheia"
       )}
    else
      # A fight already opened does not re-measure itself as it kills: finishing
      # what you started is right even as the list shrinks past three.
      {logic,
       orders(:engaged, band(s, config),
         route: :hold,
         fire: :free,
         opening: opening(world),
         why: "matando o que já abriu"
       )}
    end
  end

  defp sizing(%{state: :skipping} = logic, world, config, _now) do
    {logic,
     orders(:skipping, band(world.situation, config),
       route: :go,
       why: "deixei essa pilha pra trás — seguindo a rota"
     )}
  end

  defp sizing(logic, world, config, now) do
    logic = enter(logic, :sizing, now)
    s = world.situation
    band = band(s, config)

    cond do
      s.worth_fighting? and not gathering?(config) ->
        {%{logic | state: :engaged},
         orders(:engaged, band,
           route: :hold,
           fire: :free,
           opening: opening(world),
           why: "#{count(s)}: caindo em cima, sem esperar juntar"
         )}

      s.worth_fighting? and settled?(s, config) ->
        {%{logic | state: :engaged},
         orders(:engaged, band,
           route: :hold,
           fire: :free,
           opening: opening(world),
           why: "#{count(s)} e pararam de chegar: estourando a área"
         )}

      not within?(logic, :sizing, config.size_ceiling_ms, now) ->
        {%{logic | state: :skipping},
         orders(:skipping, band,
           route: :go,
           why: "só #{count(s)}: não vale a área — seguindo a rota"
         )}

      true ->
        {logic,
         orders(:sizing, band,
           route: :hold,
           fire: :hold,
           why: "contando quem chega: #{count(s)} até agora, ainda chegando"
         )}
    end
  end

  # Gathering is what makes waiting worth it. Hunting creatures that arrive ONE
  # BY ONE — and that a pile never forms around — the wait is pure loss: the
  # pile never stops growing, `size_ceiling_ms` runs out, and a fight that was
  # always worth taking is skipped ("só 3 inimigos: não vale a área", measured
  # on his hunt 2026-08-24, right after two clean kills).
  defp gathering?(config), do: Map.get(config, :gather_piles, true)

  # "Pararam de chegar", with a floor on how long they have to have stopped.
  defp settled?(%{growing?: true}, _config), do: false
  defp settled?(%{stable_for_ms: ms}, config), do: ms >= config.pile_settle_ms

  defp count(%{enemies: nil}), do: "não sei quantos"
  defp count(%{enemies: 1}), do: "1 inimigo"
  defp count(%{enemies: n}), do: "#{n} inimigos"

  defp opening(%{hands: %{opening: keys}}), do: keys
  defp opening(_no_hands), do: []

  # R3b, with every guard it needs to not become "press F4 always":
  #
  #   * OFF by default (`reset_revive`), because whether recalling a HEALTHY
  #     pokemon really resets its cooldowns is a fact about the game that has
  #     to be watched once with his own eyes, not a fact about this code.
  #   * only with the bar actually spent — `spent?` is every DAMAGE key on
  #     cooldown, which is his "0 cooldowns livres".
  #   * only in front of a pile the ruler would still open on, so the reset is
  #     bought for a fight worth having.
  #   * only with a pokemon ON the field: ordering a second one while the first
  #     is still in the ball spends the press against a closed door.
  #   * and never twice inside `reset_revive_cooldown_ms`, so a fight whose bar
  #     stays empty does not turn into a key held down.
  defp reset_revive?(logic, s, config, now) do
    Map.get(config, :reset_revive, false) and s.spent? == true and s.own_out? == true and
      is_integer(s.enemies) and s.enemies >= config.engage_from and
      reset_revive_ready?(logic, config, now)
  end

  # NOT `within?/4`: that one answers true for a clock never started, which is
  # the right default for a ceiling and exactly the wrong one for a floor — the
  # rule would refuse the very first press it exists to make.
  defp reset_revive_ready?(logic, config, now) do
    case Map.get(logic.since, :reset_revive) do
      nil -> true
      at -> now - at >= Map.get(config, :reset_revive_cooldown_ms, 6_000)
    end
  end

  defp enter(%{state: state} = logic, state, _now), do: logic

  defp enter(logic, state, now),
    do: %{logic | state: state, since: Map.put(logic.since, state, now)}

  defp within?(logic, key, limit_ms, now) do
    case Map.get(logic.since, key) do
      nil -> true
      at -> now - at < limit_ms
    end
  end

  defp to_recovering(logic, now),
    do: %{logic | state: :recovering, since: Map.put(logic.since, :recovering, now)}

  # A new round's clocks must not be bound by the one that just ended.
  defp reset(logic), do: %{logic | since: %{}}

  defp reset_fight(%{state: state} = logic, state, _now), do: logic

  defp reset_fight(logic, state, _now),
    do: %{logic | state: state, since: Map.drop(logic.since, [:sizing, :closing])}

  defp orders(phase, band, opts) do
    %{
      phase: phase,
      band: band,
      route: Keyword.get(opts, :route, :go),
      fire: Keyword.get(opts, :fire, :hold),
      opening: Keyword.get(opts, :opening, []),
      revive: Keyword.get(opts, :revive, :hold),
      potion: Keyword.get(opts, :potion, :hold),
      why: Keyword.fetch!(opts, :why)
    }
  end
end
