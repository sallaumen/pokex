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

  ## The tick is a noun

  Every rule needs the same six things: the picture, where the hunt is, the
  keys, the config, `now`, and the band. They used to be re-derived per branch —
  `band(world.situation, config)` appeared twelve times — so a branch that
  derived one of them differently would have been invisible. `tick/4` builds
  them once and every rule reads the same six.

  ## Two clocks, and they are not the same question

  A CEILING asks "am I still inside the window I gave myself" and a FLOOR asks
  "has enough time passed to do this again". Both answer true for a clock that
  was never started, and for opposite reasons — one because the wait has not
  begun, the other because nothing has been spent yet. They are `within?/3` and
  `elapsed?/3`, written once, because the version of this file that inlined
  them got the floor wrong once already (`reset_revive` would have refused the
  very first press it exists to make).
  """

  alias Pokex.Bots.Engine.Orders

  # ONLY what the next tick needs to answer differently. `why` used to live here
  # too, written every tick and read by nobody: the sentence travels on the
  # orders, which is where a consumer finds it. State a struct carries and
  # nothing reads is state that can go stale without anyone noticing.
  defstruct state: :idle,
            # when each phase started or each press was made, read as a ceiling
            # (`within?/3`) or as a floor (`elapsed?/3`) — never both
            since: %{}

  @type t :: %__MODULE__{}
  @type orders :: Orders.t()

  @spec new() :: t
  def new, do: %__MODULE__{}

  @doc """
  One tick of the decision.

  `world` carries `:situation` (the shared picture), `:hunt` (where the route
  is, or `nil` when no hunt is running) and `:hands` (`%{opening: keys, single:
  keys}` — the non-reserved keys this pokémon fights with; the reserved control
  key never appears here, see the moduledoc).

  `config` must be COMPLETE — build it with `Pokex.Bots.Engine.Config`. A knob
  missing from it raises naming the knob, which is cheaper than a fallback
  written beside the read.
  """
  @spec step(t, map, map, integer) :: {t, orders}
  def step(logic, world, config, now), do: decide(tick(logic, world, config, now))

  defp tick(logic, world, config, now) do
    situation = world.situation

    %{
      logic: logic,
      s: situation,
      hunt: Map.get(world, :hunt),
      hands: Map.get(world, :hands) || %{},
      config: config,
      now: now,
      band: band(situation, config)
    }
  end

  # THE PRIORITY, as one list. It used to be split across three function heads
  # and a six-branch cond, so reading the order meant reading four places in the
  # right sequence.
  defp decide(t) do
    cond do
      # NOTHING IS ON THE FIELD, and it was PROVEN — `own_out?` answers
      # `:unknown` when the bar merely could not be read. Every rule below this
      # line spends a bar that belongs to a body in the ball: the keys hit
      # nothing, the health bar is gone (and `nil` is not a band), and the hunt
      # narrates "estourando a área" at a pile it cannot touch. That was 93% of
      # a bench run, measured 2026-08-25.
      t.s.own_out? == false -> downed(t)
      # No hunt to run — but HP still means what it always means, and the floor
      # below is deliberately NOT consulted here. See the moduledoc's "No hunt
      # does not mean no pokémon": while fishing, a fresh `revive: :hold` would
      # silently outrank the support's own ladder.
      is_nil(t.hunt) -> guarding(t)
      t.logic.state == :recovering -> recovering(t)
      # R5: a band whose only move is a revive the game will refuse for another
      # forty seconds is not a reason to stand still.
      t.band in [:yellow, :red] and not revive_plausible?(t) -> unaided(t)
      # Health rules the rest: the revive needs no attack key, and a pokémon
      # about to fall must not be abandoned because nobody classified its bar.
      t.band == :red -> emergency(t)
      t.band == :yellow -> closing(t)
      t.s.blind? -> blind(t)
      # NO HANDS. `fire: :free` with an empty `opening` means "fight, I have no
      # keys to name" and `Combat.Worker` answers it with the combo he recorded
      # at that kill spot — which is right when a pokémon simply has no keys
      # classified, and wrong when there is no pokémon configured at all. This
      # branch is the second case, said out loud instead of narrated as a fight.
      opening(t) == [] -> handless(t)
      true -> normal(t)
    end
  end

  # --- the rules -------------------------------------------------------------

  defp guarding(%{band: :green} = t),
    do: {%{t.logic | state: :idle}, Orders.walking(:idle, :green, "sem caçada rodando")}

  defp guarding(t) do
    {%{t.logic | state: :guarding},
     Orders.walking(
       :guarding,
       t.band,
       "sem caçada, só protegendo: #{hp(t)}% de vida — revive agora",
       revive: :now
     )}
  end

  defp blind(t) do
    {%{t.logic | state: :blind},
     Orders.walking(:blind, :green, "não estou vendo a lista de batalha — não mando nada")}
  end

  # The route keeps walking: standing still would turn a missing configuration
  # into a stopped night. What it will NOT do is pretend to fight.
  defp handless(t) do
    {%{t.logic | state: :handless},
     Orders.walking(
       :handless,
       t.band,
       "sem teclas de ataque: nenhum pokémon configurado pra lutar"
     )}
  end

  # The pokémon is down, proven. The route keeps walking, for the same reason it
  # does with no keys: standing still in a pile with nothing to defend him is
  # the worse of the two. And it keeps ASKING for the body back — the fallen
  # rescue fires exactly once and then disarms itself until a live bar is seen
  # again (`PlayerSupport.Logic.fainted?/1`), so a revive that does not land
  # had, until 2026-08-25, ended the night with nobody ever asking twice.
  #
  # NEITHER number here is the engine's own, and that is the point. The grace
  # before the first ask is `revive_confirm_ms` — the ordinary reason to be off
  # the field is a revive already in flight, and how long one takes to show
  # itself is a number this file already has. The cadence after that is
  # `fainted_revive_cooldown_ms`, the floor the hands actually keep between two
  # fallen revives: asking four times faster than they can answer is noise in
  # the feed and nothing in the game.
  defp downed(t) do
    t = %{
      t
      | logic:
          enter_downed(
            t.logic,
            t.now,
            t.config.revive_confirm_ms,
            t.config.fainted_revive_cooldown_ms
          )
    }

    if elapsed?(t, :downed_asked, asking_every(t)) do
      {mark(t.logic, :downed_asked, t.now),
       Orders.walking(:downed, t.band, downed_why(t), revive: :now)}
    else
      {t.logic,
       Orders.walking(:downed, t.band, "sem pokémon em campo — nada a atacar até ele voltar")}
    end
  end

  # After `recover_timeout_ms` on the floor the asking SLOWS DOWN instead of
  # stopping: a handful of presses that changed nothing are enough to say the
  # revive is not working, and one a minute keeps the door open for the night to
  # fix itself when he refills the stock.
  defp asking_every(t) do
    floor = t.config.fainted_revive_cooldown_ms

    if down_for(t) >= t.config.recover_timeout_ms,
      do: max(t.config.recover_timeout_ms, floor),
      else: floor
  end

  defp downed_why(t) do
    if down_for(t) >= t.config.recover_timeout_ms,
      do: "o revive não está saindo há #{div(down_for(t), 1_000)}s — insistindo devagar",
      else: "o pokémon não voltou pro campo — pedindo o revive de novo"
  end

  defp down_for(t), do: t.now - Map.get(t.logic.since, :downed, t.now)

  # A NEW fall starts both clocks over. Carrying `:downed_asked` across would
  # make the first tick of the next fall ask immediately — on top of the revive
  # that had just put the pokémon in the ball.
  defp enter_downed(%{state: :downed} = logic, _now, _grace_ms, _cadence_ms), do: logic

  # BOTH clocks start at the fall, and the ask clock starts BACKDATED: the grace
  # before the first ask is `revive_confirm_ms`, not the whole cadence, because
  # the only thing being waited on is a revive already in flight showing itself.
  defp enter_downed(logic, now, grace_ms, cadence_ms) do
    asked_at = now - max(cadence_ms - grace_ms, 0)

    since = logic.since |> Map.put(:downed, now) |> Map.put(:downed_asked, asked_at)
    %{logic | state: :downed, since: since}
  end

  # RED. No waiting, no stun, no pile to finish: the pokémon is about to fall
  # and the revive is the only thing that answers that.
  defp emergency(t) do
    {to_recovering(t),
     Orders.standing_and_firing(
       :emergency,
       :red,
       opening(t),
       "vermelho: #{hp(t)}% de vida — revive agora, no meio da luta",
       revive: :now
     )}
  end

  # YELLOW — "fecha a rodada". The one sequence that crosses two workers, and
  # the reason a central engine exists at all: the road holds (R2) while the
  # fight spends what it has (R3) on whatever the pile still owes, and the
  # revive — the ALREADY atomic stun+recall combo, see the moduledoc — fires
  # once that stops being worth waiting for.
  defp closing(t) do
    t = %{t | logic: enter(t.logic, :closing, t.now)}

    cond do
      # R2: stop extending the gathering FIRST, then let what is already coming
      # arrive. The ceiling is what makes this a decision instead of a hang.
      not settled?(t) and within?(t, :closing, t.config.closing_timeout_ms) ->
        {t.logic,
         Orders.standing(
           :closing,
           :yellow,
           "amarelo (#{hp(t)}%): parei de mobar, esperando a pilha fechar"
         )}

      # The pile is down, or the round has simply run long enough — waiting
      # longer buys nothing either way, and the alternative is the revive combo
      # firing with no pokémon left on the field.
      revive_now?(t) ->
        {to_recovering(t),
         Orders.standing_and_firing(:closing, :yellow, opening(t), revive_why(t), revive: :now)}

      true ->
        {t.logic,
         Orders.standing_and_firing(
           :closing,
           :yellow,
           opening(t),
           "amarelo (#{hp(t)}%): gastando os cooldowns em #{count(t.s)}"
         )}
    end
  end

  defp revive_now?(t),
    do: t.s.enemies == 0 or not within?(t, :closing, t.config.closing_timeout_ms)

  defp revive_why(%{s: %{enemies: 0}} = t),
    do:
      "amarelo (#{hp(t)}%): pilha limpa e cooldowns gastos — revive agora, o próximo mob começa cheio"

  defp revive_why(t),
    do: "amarelo (#{hp(t)}%): a rodada já durou o que podia durar — revive agora"

  # WAITING FOR A REVIVE, and only for as long as one takes to show itself.
  #
  # There is no third answer here any more. A revive that LANDED puts the body
  # in the ball for its settle — which `:downed` catches before this rule is
  # ever reached — and brings it back at full health, so "the bar came back" is
  # the only proof this rule needs. Anything else, after `revive_confirm_ms`, is
  # a refusal wearing a delay, and waiting out `recover_timeout_ms` on it was
  # the thirty-second freeze R5 exists to end.
  defp recovering(t) do
    cond do
      is_integer(hp(t)) and hp(t) >= t.config.resume_pct ->
        normal(%{t | logic: reset(t.logic)})

      not within?(t, :recovering, t.config.revive_confirm_ms) ->
        denied(t)

      true ->
        {t.logic,
         Orders.standing_and_firing(
           :recovering,
           t.band,
           opening(t),
           "me recuperando: a rota só volta com a vida acima de #{t.config.resume_pct}%"
         )}
    end
  end

  # The refusal, remembered. Nothing here presses anything: it walks, and it
  # writes down WHEN, so the bands stop holding the route until the floor the
  # actuator keeps (`rescue_cooldown_ms`) has actually passed.
  #
  # It keeps the OTHER clocks. An earlier version replaced the whole map, which
  # silently forgave `reset_revive`'s own floor — a bug of exactly the kind a
  # bag of unnamed clocks invites.
  defp denied(t) do
    logic = %{
      t.logic
      | state: :travelling,
        since:
          t.logic.since
          |> Map.drop([:sizing, :closing, :recovering])
          |> Map.put(:revive_denied, t.now)
    }

    {logic,
     Orders.walking_and_firing(
       :travelling,
       t.band,
       opening(t),
       "o revive não saiu — seguindo a rota, o próximo só daqui a #{div(t.config.rescue_cooldown_ms, 1_000)}s"
     )}
  end

  defp revive_plausible?(t), do: elapsed?(t, :revive_denied, t.config.rescue_cooldown_ms)

  # The band is right and the only answer to it is out of reach. Neither of the
  # two obvious moves is the one: standing still does not raise a health bar
  # (that was the 47.5% freeze), and hunting on at 45% with no revive behind it
  # just spends the pokémon (measured — it doubled the falls).
  #
  # So: WALK IT OFF. The route goes, because progress is the only thing still
  # available; the keys stay free, because what is already biting has to be
  # answered; and no pile is opened, because opening one is choosing a fight
  # with no way out of it. It is what he does himself when he is low — keep
  # moving and let them lose interest (R2, used on purpose instead of suffered).
  defp unaided(t) do
    left = div(max(t.config.rescue_cooldown_ms - denied_for(t), 0), 1_000)

    {reset_fight(%{t.logic | state: :unaided}, :unaided),
     Orders.walking_and_firing(
       :unaided,
       t.band,
       opening(t),
       "#{hp(t)}% e o revive só volta em #{left}s — andando sem abrir pilha"
     )}
  end

  defp denied_for(t), do: t.now - Map.get(t.logic.since, :revive_denied, t.now)

  # GREEN: what the route says, with the ruler applied where it stops.
  defp normal(%{hunt: %{state: :fighting}} = t), do: ruler(t)

  defp normal(%{hunt: %{state: :walking, luring?: true}} = t) do
    if t.config.gather_piles do
      {reset_fight(t.logic, :gathering),
       Orders.walking(:gathering, t.band, "mobando: puxando a pilha, sem atacar")}
    else
      {reset_fight(t.logic, :travelling),
       Orders.walking_and_firing(
         :travelling,
         t.band,
         opening(t),
         "trecho de mobada, mas sem juntar pilha: batendo enquanto ando"
       )}
    end
  end

  defp normal(t),
    do:
      {reset_fight(t.logic, :travelling),
       Orders.walking(:travelling, t.band, travelling_why(t.hunt))}

  defp travelling_why(%{state: :walking}), do: "andando a rota"
  defp travelling_why(%{state: :post_fight}), do: "limpando o que ficou no chão"
  defp travelling_why(%{state: state}), do: "a caçada está em #{state}"

  # --- THE RULER (R1) --------------------------------------------------------
  #
  # Standing at the kill spot, the question is not "is there something to hit"
  # but "is this worth the area damage". Three states answer it and they used to
  # share one function name, so `sizing(%{state: :engaged})` was a thing you had
  # to read twice.

  defp ruler(%{logic: %{state: :engaged}} = t), do: engaged(t)
  defp ruler(%{logic: %{state: :skipping}} = t), do: skipping(t)
  defp ruler(t), do: sizing(%{t | logic: enter(t.logic, :sizing, t.now)})

  # THE ROUND IS OVER when the list is empty — 0, not `nil`. "Finishing what you
  # started" is the rule for a list that is shrinking, not for a screen with
  # nobody on it: holding the route there narrates a fight against nothing and
  # keeps the hunt standing at a spot it has already cleared.
  defp engaged(%{s: %{enemies: 0}} = t) do
    {reset_fight(t.logic, :travelling),
     Orders.walking(:travelling, t.band, "pilha limpa — seguindo a rota")}
  end

  defp engaged(t) do
    if reset_revive?(t) do
      # R3b. Stays ENGAGED — this is not a rescue and there is nothing to
      # recover from: the body comes back full, with a full bar, into the same
      # fight it left.
      {mark(t.logic, :reset_revive, t.now),
       Orders.standing_and_firing(
         :engaged,
         t.band,
         opening(t),
         "sem cooldown com #{count(t.s)} na frente — revive pra voltar com a barra cheia",
         revive: :now
       )}
    else
      # A fight already opened does not re-measure itself as it kills: finishing
      # what you started is right even as the list shrinks past three.
      {t.logic,
       Orders.standing_and_firing(:engaged, t.band, opening(t), "matando o que já abriu")}
    end
  end

  # R1 says to IGNORE one or two and walk on ("eu às vezes até ignoro aquele mob
  # e sigo a minha vida"), and that is what this does by default. The knob is
  # here because the bench found the opposite worth measuring: the phase that
  # walks while firing (`:unaided`) kills more per minute than this one, which
  # walks with the hands down — and what follows a hunt out of a skipped pile
  # bites it the whole way. Single-target only when it is on: the area is what
  # the ruler is saving, not the cheap keys.
  defp skipping(%{config: %{skip_fire: true}} = t) do
    {t.logic,
     Orders.walking_and_firing(
       :skipping,
       t.band,
       singles(t),
       "deixei essa pilha pra trás — seguindo a rota, batendo em quem vier junto"
     )}
  end

  defp skipping(t),
    do:
      {t.logic, Orders.walking(:skipping, t.band, "deixei essa pilha pra trás — seguindo a rota")}

  defp sizing(t) do
    cond do
      t.s.worth_fighting? and not t.config.gather_piles ->
        {%{t.logic | state: :engaged},
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "#{count(t.s)}: caindo em cima, sem esperar juntar"
         )}

      t.s.worth_fighting? and settled?(t) ->
        {%{t.logic | state: :engaged},
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "#{count(t.s)} e pararam de chegar: estourando a área"
         )}

      not within?(t, :sizing, t.config.size_ceiling_ms) ->
        {%{t.logic | state: :skipping},
         Orders.walking(
           :skipping,
           t.band,
           "só #{count(t.s)}: não vale a área — seguindo a rota"
         )}

      true ->
        {t.logic,
         Orders.standing(
           :sizing,
           t.band,
           "contando quem chega: #{count(t.s)} até agora, ainda chegando"
         )}
    end
  end

  # R3b, with every guard it needs to not become "press F4 always":
  #
  #   * OFF by default (`reset_revive`), because whether recalling a HEALTHY
  #     pokémon really resets its cooldowns is a fact about the game that has to
  #     be watched once with his own eyes, not a fact about this code.
  #   * only with the bar actually spent — `spent?` is every DAMAGE key on
  #     cooldown, which is his "0 cooldowns livres".
  #   * only in front of a pile the ruler would still open on, so the reset is
  #     bought for a fight worth having.
  #   * only with a pokémon ON the field: ordering a second one while the first
  #     is still in the ball spends the press against a closed door.
  #   * only on a bar that is not already half spent — the floor between two
  #     revives is a MINUTE, so a proactive press at 60% health is the rescue
  #     this fight needs in forty seconds, spent early.
  #   * and never twice inside `reset_revive_cooldown_ms`, so a fight whose bar
  #     stays empty does not turn into a key held down.
  defp reset_revive?(t) do
    t.config.reset_revive and t.s.spent? == true and t.s.own_out? == true and
      is_integer(t.s.enemies) and t.s.enemies >= t.config.engage_from and
      healthy_enough?(t) and elapsed?(t, :reset_revive, t.config.reset_revive_cooldown_ms)
  end

  defp healthy_enough?(t),
    do: is_integer(hp(t)) and hp(t) >= t.config.reset_revive_min_hp

  # --- reading the tick ------------------------------------------------------

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

  defp hp(t), do: t.s.own_hp

  defp opening(%{hands: %{opening: keys}}), do: keys
  defp opening(_no_hands), do: []

  defp singles(%{hands: %{single: keys}}) when keys != [], do: keys
  defp singles(t), do: opening(t)

  # A RULE THAT WAS TRIED AND REFUTED, written down so it is not tried again:
  # "a pile under the ruler that has stopped arriving has nothing left to wait
  # for — skip it now instead of standing still while it bites". It reads well
  # and it is wrong, because "stopped arriving" is measured over
  # `pile_settle_ms` and a pile that DRIPS is idle for longer than that between
  # arrivals. Measured 2026-08-25 on `pilha-que-pinga`: five monsters, five
  # abandoned, none killed — his own complaint made worse.
  #
  # "Pararam de chegar", with a floor on how long they have to have stopped.
  defp settled?(%{s: %{growing?: true}}), do: false
  defp settled?(t), do: t.s.stable_for_ms >= t.config.pile_settle_ms

  defp count(%{enemies: nil}), do: "não sei quantos"
  defp count(%{enemies: 1}), do: "1 inimigo"
  defp count(%{enemies: n}), do: "#{n} inimigos"

  # --- the two clocks --------------------------------------------------------

  # A CEILING: still inside the window I gave myself. True for a clock never
  # started, because the wait has not begun.
  defp within?(t, key, limit_ms) do
    case Map.get(t.logic.since, key) do
      nil -> true
      at -> t.now - at < limit_ms
    end
  end

  # A FLOOR: enough time has passed to do it again. Also true for a clock never
  # started, and for the opposite reason — nothing has been spent yet. Writing
  # this as `not within?` is the bug that would refuse the very first press.
  defp elapsed?(t, key, floor_ms) do
    case Map.get(t.logic.since, key) do
      nil -> true
      at -> t.now - at >= floor_ms
    end
  end

  defp mark(logic, key, now), do: %{logic | since: Map.put(logic.since, key, now)}

  defp enter(%{state: state} = logic, state, _now), do: logic
  defp enter(logic, state, now), do: %{mark(logic, state, now) | state: state}

  defp to_recovering(t), do: %{mark(t.logic, :recovering, t.now) | state: :recovering}

  # A new round's clocks must not be bound by the one that just ended.
  defp reset(logic), do: %{logic | since: %{}}

  defp reset_fight(%{state: state} = logic, state), do: logic

  defp reset_fight(logic, state),
    do: %{logic | state: state, since: Map.drop(logic.since, [:sizing, :closing])}
end
