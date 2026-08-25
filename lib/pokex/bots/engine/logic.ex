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

      And measured AGAIN once the bench stopped inventing the floor between two
      revives (it used 2s; `rescue_cooldown_ms` is 60s): the rule does not BUY
      revives, it REALLOCATES them. The floor decides how many a night can hold;
      R3b decides whether they are spent as rescues or forward as resets. Over
      16 seeds × 5 minutes it bought 5–9% more monsters and cost the character
      health every time, which is why it is still off by default — and why it
      now refuses to fire on a bar that is not full.
    * **R5 — a revive you cannot press is not a plan.** The floor between two
      presses is `rescue_cooldown_ms`, and it is a MINUTE. Waiting for one that
      cannot come does not heal anything: measured 2026-08-25, a bench hunt
      spent **47.5% of itself in `:recovering`**, standing still in thirty-second
      blocks while the health bar kept falling, and `:engaged` got 0.1%.

      That measurement was taken at the SEEDED floor of sixty seconds; his own
      `rescue_cooldown_ms` is two, so the freeze is not what his nights look
      like today. It is what they look like the moment a revive is refused for
      any other reason — an empty stock, a key that did not leave the hand, a
      closed gate — which is the failure already sitting in his journal. So the
      wait now ends the moment the revive is seen NOT to have landed, and while
      it cannot come the band stops holding the route — the order stays out, so
      the press lands the instant the floor passes, and the hunt walks instead
      of freezing.
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

  # The grace before the engine asks for a second revive. Long enough that a
  # revive already in flight has landed; short enough that a night is not lost
  # to one key that did not leave the hand.
  @downed_retry_ms 4_000

  # How long a revive has to prove it landed before it is called a refusal. Its
  # only job is to be longer than the game takes to put the body back and much
  # shorter than `recover_timeout_ms`.
  @revive_confirm_ms 3_000

  # The floor the ACTUATOR keeps between two rescues, mirrored here so the brain
  # stops planning around a press that cannot happen. Authority is Settings.
  @rescue_cooldown_ms 60_000

  defstruct state: :idle,
            # when each phase started, so a wait can have a ceiling
            since: %{},
            # the health the last revive was ORDERED at, which is how a revive
            # that landed is told from one the game refused
            revive_hp: nil,
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

  # NOTHING IS ON THE FIELD, and it was PROVEN — `own_out?` answers `:unknown`
  # when the bar merely could not be read. Every order below this line spends a
  # bar that belongs to a body in the ball, so none of them may be given: the
  # keys hit nothing, the health bar is gone (and `nil` is not a band), and the
  # hunt narrates "estourando a área" at a pile it cannot touch. That is not a
  # hypothetical — it was 93% of a bench run, measured 2026-08-25.
  defp decide(logic, %{situation: %{own_out?: false}} = world, config, now),
    do: downed(logic, world, config, now)

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
      # Health still rules first: the revive needs no attack key, and a pokémon
      # about to fall must not be abandoned because nobody classified its bar.
      # …unless the answer to the band is not available at all (R5): a band whose
      # only move is a revive the game will refuse for another forty seconds is
      # not a reason to stand still.
      band in [:yellow, :red] and not revive_plausible?(logic, config, now) ->
        unaided(logic, world, config, now, band)

      band == :red ->
        emergency(logic, world, config, now)

      band == :yellow ->
        closing(logic, world, config, now)

      world.situation.blind? ->
        blind(logic)

      # NO HANDS. `fire: :free` with an empty `opening` is an order that looks
      # like an action and does nothing — the shape of "lutando como sem pokémon
      # escolhido" in his own journal, and of a simulator that ran a whole fight
      # without a single key leaving the bar (2026-08-25). A fight with no keys
      # is not a fight; say so instead of narrating one.
      opening(world) == [] ->
        handless(logic, world, config)

      true ->
        normal(logic, world, config, now)
    end
  end

  # The route keeps walking, for the same reason it does with no keys: standing
  # still in a pile with nothing to defend him is the worse of the two. What it
  # will NOT do is fight, and what it WILL do is keep asking for the body back —
  # the fallen rescue fires exactly once and then disarms itself until a live
  # bar is seen again (`PlayerSupport.Logic.fainted?/1`), so a revive that does
  # not land has, until now, ended the night with nobody ever asking twice.
  #
  # The first ask waits `downed_retry_ms` on purpose: the ordinary reason to be
  # off the field is a revive already in flight, and a second press on top of it
  # buys nothing and costs a revive.
  defp downed(logic, world, config, now) do
    logic = enter_downed(logic, now)
    band = band(world.situation, config)

    if ask_revive?(logic, config, now) do
      {%{logic | since: Map.put(logic.since, :downed_asked, now)},
       orders(:downed, band,
         route: :go,
         fire: :hold,
         revive: :now,
         why: downed_why(logic, config, now)
       )}
    else
      {logic,
       orders(:downed, band,
         route: :go,
         fire: :hold,
         why: "sem pokémon em campo — nada a atacar até ele voltar"
       )}
    end
  end

  # After the same ceiling that already governs "a revive that never lands must
  # not end the night standing still", the asking SLOWS DOWN instead of stopping:
  # seven presses that changed nothing are enough to say the revive is not
  # working, and one press a minute keeps the door open for the night to fix
  # itself when he refills the stock.
  defp asking_every(logic, config, now) do
    ceiling = Map.get(config, :recover_timeout_ms, 30_000)
    retry = Map.get(config, :downed_retry_ms, @downed_retry_ms)

    if down_for(logic, now) >= ceiling, do: max(ceiling, retry), else: retry
  end

  defp ask_revive?(logic, config, now) do
    since = Map.get(logic.since, :downed_asked) || Map.get(logic.since, :downed, now)

    now - since >= asking_every(logic, config, now)
  end

  defp down_for(logic, now), do: now - Map.get(logic.since, :downed, now)

  defp downed_why(logic, config, now) do
    if down_for(logic, now) >= Map.get(config, :recover_timeout_ms, 30_000) do
      "o revive não está saindo há #{div(down_for(logic, now), 1_000)}s — insistindo devagar"
    else
      "o pokémon não voltou pro campo — pedindo o revive de novo"
    end
  end

  # A NEW fall starts both clocks over. Carrying `:downed_asked` across would
  # make the first tick of the next fall ask immediately — on top of the revive
  # that had just put the pokemon in the ball.
  defp enter_downed(%{state: :downed} = logic, _now), do: logic

  defp enter_downed(logic, now) do
    since = logic.since |> Map.put(:downed, now) |> Map.delete(:downed_asked)
    %{logic | state: :downed, since: since}
  end

  # The route keeps walking: standing still would turn a missing configuration
  # into a stopped night. What it will NOT do is pretend to fight.
  defp handless(logic, world, config) do
    {%{logic | state: :handless},
     orders(:handless, band(world.situation, config),
       route: :go,
       fire: :hold,
       why: "sem teclas de ataque: nenhum pokémon configurado pra lutar"
     )}
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

    {to_recovering(logic, now, hp),
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
        {to_recovering(logic, now, hp),
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

      # R5. The press was made and NOTHING moved — the bar did not rise and the
      # body never left the field. That is a refusal, not a slow revive, and
      # waiting out the whole recovery ceiling on it is the thirty-second freeze
      # this rule exists to end.
      not landed?(logic, hp) and not within?(logic, :recovering, confirm_ms(config), now) ->
        denied(logic, world, config, now)

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

  # A revive that LANDED always shows itself: the bar comes back higher than it
  # was when the key was pressed. (The body leaving the field is the other sign,
  # and `:downed` catches that one before this function is ever reached.)
  defp landed?(%{revive_hp: was}, hp) when is_integer(was) and is_integer(hp), do: hp > was
  defp landed?(_no_mark, _hp), do: false

  defp confirm_ms(config), do: Map.get(config, :revive_confirm_ms, @revive_confirm_ms)

  # The refusal, remembered. Nothing here presses anything: it walks, and it
  # writes down WHEN, so the bands stop holding the route until the floor the
  # actuator keeps (`rescue_cooldown_ms`) has actually passed.
  defp denied(logic, world, config, now) do
    logic = %{reset(logic) | state: :travelling, since: %{revive_denied: now}, revive_hp: nil}

    {logic,
     orders(:travelling, band(world.situation, config),
       route: :go,
       fire: :free,
       opening: opening(world),
       why: "o revive não saiu — seguindo a rota, o próximo só daqui a #{floor_s(config)}s"
     )}
  end

  defp floor_s(config), do: div(revive_floor_ms(config), 1_000)

  defp revive_floor_ms(config), do: Map.get(config, :rescue_cooldown_ms, @rescue_cooldown_ms)

  defp revive_plausible?(logic, config, now) do
    case Map.get(logic.since, :revive_denied) do
      nil -> true
      at -> now - at >= revive_floor_ms(config)
    end
  end

  # The band is right and the only answer to it is out of reach. Neither of the
  # two obvious moves is the one: standing still does not raise a health bar
  # (that was the 47.5% freeze), and hunting on at 45% with no revive behind it
  # just spends the pokemon (measured — it doubled the falls).
  #
  # So: WALK IT OFF. The route goes, because progress is the only thing still
  # available; the keys stay free, because what is already biting has to be
  # answered; and no pile is opened, because opening one is choosing a fight
  # with no way out of it. It is what he does himself when he is low — keep
  # moving and let them lose interest (R2, used on purpose instead of suffered).
  defp unaided(logic, world, config, now, band) do
    hp = world.situation.own_hp
    left = div(max(revive_floor_ms(config) - denied_for(logic, now), 0), 1_000)

    {reset_fight(%{logic | state: :unaided}, :unaided, now),
     orders(:unaided, band,
       route: :go,
       fire: :free,
       opening: opening(world),
       why: "#{hp}% e o revive só volta em #{left}s — andando sem abrir pilha"
     )}
  end

  defp denied_for(logic, now), do: now - Map.get(logic.since, :revive_denied, now)

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
       fire: skip_fire(config),
       opening: skip_keys(world, config),
       why: skip_why(config)
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

  # R1 says to IGNORE one or two and walk on ("eu às vezes até ignoro aquele mob
  # e sigo a minha vida"), and that is what this does by default. The knob is
  # here because the bench found the opposite worth measuring: the phase that
  # walks while firing (`:unaided`) kills more per minute than this one, which
  # walks with the hands down — and what follows a hunt out of a skipped pile
  # bites it the whole way. Single-target only when it is on: the area is what
  # the ruler is saving, not the cheap keys.
  defp skip_fire(config), do: if(Map.get(config, :skip_fire, false), do: :free, else: :hold)

  defp skip_keys(world, config) do
    if Map.get(config, :skip_fire, false), do: singles(world), else: []
  end

  defp skip_why(config) do
    if Map.get(config, :skip_fire, false),
      do: "deixei essa pilha pra trás — seguindo a rota, batendo em quem vier junto",
      else: "deixei essa pilha pra trás — seguindo a rota"
  end

  defp singles(%{hands: %{single: keys}}) when keys != [], do: keys
  defp singles(world), do: opening(world)

  # A RULE THAT WAS TRIED AND REFUTED, written down so it is not tried again:
  # "a pile under the ruler that has stopped arriving has nothing left to wait
  # for — skip it now instead of standing still while it bites". It reads well
  # and it is wrong, because "stopped arriving" is measured over
  # `pile_settle_ms` and a pile that DRIPS is idle for longer than that between
  # arrivals. Measured 2026-08-25 on `pilha-que-pinga`: five monsters, five
  # abandoned, none killed — his own complaint made worse.
  #
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
      healthy_enough?(s, config) and reset_revive_ready?(logic, config, now)
  end

  # …and only on a pokemon that is not already half spent. The floor between two
  # revives is a MINUTE (`rescue_cooldown_ms`), so a proactive press made at 60%
  # health is not "a bar bought cheaply" — it is the rescue this fight will need
  # in forty seconds, spent early. Measured 2026-08-25: with the real floor in
  # the bench, R3b without this guard traded rescues one-for-one for resets and
  # bought no monsters at all.
  defp healthy_enough?(%{own_hp: hp}, config) when is_integer(hp),
    do: hp >= Map.get(config, :reset_revive_min_hp, 100)

  defp healthy_enough?(_unknown_bar, _config), do: false

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

  defp to_recovering(logic, now, hp),
    do: %{
      logic
      | state: :recovering,
        since: Map.put(logic.since, :recovering, now),
        revive_hp: hp
    }

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
