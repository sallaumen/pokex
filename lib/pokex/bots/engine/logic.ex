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
    * **R4 — the stun is a clock nothing contradicts.** A partial stun is the
      common case, not the exception, and the window it opens is the best one
      available: "essa é a melhor janela antes de eu não ter mais opções e
      deixar meu pokémon morrer."

  And the three bands he drew over them: green above `band_yellow_pct` hunts
  normally; yellow CLOSES THE ROUND (stop gathering, let the pile arrive, stun,
  spend everything, then revive even above the red line, so the next leg starts
  full); red revives immediately, mid-fight.

  ## What it deliberately does not decide

  Not seeing is not a decision. When the picture says it cannot read the screen,
  the orders say hold — and every consumer's rule for a missing order is what it
  does today. An engine that guesses is worse than one that is quiet.
  """

  defstruct state: :idle,
            # when each phase started, so a wait can have a ceiling
            since: %{},
            # within the CURRENT round: a stun is one press, not a rotation, and
            # a revive is a resource, not a reflex
            stun_sent?: false,
            why: nil

  @type t :: %__MODULE__{}

  @type orders :: %{
          phase: atom,
          band: :green | :yellow | :red,
          route: :go | :hold,
          fire: :hold | :free,
          opening: [String.t()],
          stun: :hold | :now,
          revive: :hold | :now,
          potion: :hold | :now,
          why: String.t()
        }

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  One tick of the decision.

  `world` carries `:situation` (the shared picture), `:hunt` (where the route
  is, or `nil` when no hunt is running) and `:hands` (`%{opening: keys, crowd:
  keys}` for the pokémon on the field).
  """
  @spec step(t, map, map, integer) :: {t, orders}
  def step(logic, world, config, now) do
    {logic, orders} = decide(logic, world, config, now)
    {%{logic | why: orders.why}, orders}
  end

  # Nothing to decide about: no hunt is running. The route order still reads
  # `:go` because a stopped engine must never be the reason a hunt stands still.
  defp decide(logic, %{hunt: nil}, _config, _now) do
    {%{logic | state: :idle}, orders(:idle, :green, why: "sem caçada rodando")}
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

  # YELLOW — "fecha a rodada". The one sequence that crosses all three workers,
  # and the reason a central engine exists at all.
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

      # The stun buys the window the revive needs. One press, never a rotation.
      not logic.stun_sent? and world.hands.crowd != [] ->
        {%{logic | stun_sent?: true},
         orders(:closing, :yellow,
           route: :hold,
           fire: :hold,
           stun: :now,
           why: "amarelo (#{hp}%): stun antes de gastar tudo"
         )}

      # R4: the window closes. Spending it late is spending it never — and the
      # alternative is the revive combo with no pokémon on the field.
      revive_now?(logic, s, config, now) ->
        {to_recovering(logic, now),
         orders(:closing, :yellow,
           route: :hold,
           fire: :free,
           opening: opening(world),
           revive: :now,
           why: revive_why(s, hp, config, now)
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

  # R3 in one predicate: the revive is spent when the round is actually over —
  # the pile is down, or the sleep that made this safe is about to end, or the
  # whole closing has run past its ceiling and waiting longer buys nothing.
  defp revive_now?(logic, s, config, now) do
    s.enemies == 0 or window_closing?(s, config, now) or
      not within?(logic, :closing, config.closing_timeout_ms, now)
  end

  defp window_closing?(%{asleep?: true, asleep_until: until}, config, now)
       when is_integer(until),
       do: until - now <= config.revive_lead_ms

  defp window_closing?(_awake, _config, _now), do: false

  defp revive_why(%{enemies: 0}, hp, _config, _now),
    do:
      "amarelo (#{hp}%): pilha limpa e cooldowns gastos — revive agora, o próximo mob começa cheio"

  defp revive_why(_still_up, hp, _config, _now),
    do: "amarelo (#{hp}%): o stun está acabando — revive agora, é a melhor janela que vai ter"

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
    {reset_fight(logic, :gathering, now),
     orders(:gathering, band(world.situation, config),
       route: :go,
       why: "mobando: puxando a pilha, sem atacar"
     )}
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
  defp sizing(%{state: :engaged} = logic, world, config, _now) do
    # A fight already opened does not re-measure itself as it kills: finishing
    # what you started is right even as the list shrinks past three.
    {logic,
     orders(:engaged, band(world.situation, config),
       route: :hold,
       fire: :free,
       opening: opening(world),
       why: "matando o que já abriu"
     )}
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

  # "Pararam de chegar", with a floor on how long they have to have stopped.
  defp settled?(%{growing?: true}, _config), do: false
  defp settled?(%{stable_for_ms: ms}, config), do: ms >= config.pile_settle_ms

  defp count(%{enemies: nil}), do: "não sei quantos"
  defp count(%{enemies: 1}), do: "1 inimigo"
  defp count(%{enemies: n}), do: "#{n} inimigos"

  defp opening(%{hands: %{opening: keys}}), do: keys
  defp opening(_no_hands), do: []

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

  # A new round starts with a full hand: the stun is available again, and the
  # clocks of the round that ended must not bound the one starting.
  defp reset(logic), do: %{logic | since: %{}, stun_sent?: false}

  defp reset_fight(%{state: state} = logic, state, _now), do: logic

  defp reset_fight(logic, state, _now),
    do: %{
      logic
      | state: state,
        since: Map.drop(logic.since, [:sizing, :closing]),
        stun_sent?: false
    }

  defp orders(phase, band, opts) do
    %{
      phase: phase,
      band: band,
      route: Keyword.get(opts, :route, :go),
      fire: Keyword.get(opts, :fire, :hold),
      opening: Keyword.get(opts, :opening, []),
      stun: Keyword.get(opts, :stun, :hold),
      revive: Keyword.get(opts, :revive, :hold),
      potion: Keyword.get(opts, :potion, :hold),
      why: Keyword.fetch!(opts, :why)
    }
  end
end
