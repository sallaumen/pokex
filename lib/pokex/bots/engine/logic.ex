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
    * **R4 — the stun is a clock nothing contradicts, and it is what makes the
      revive free.** The price of a revive is the empty field: for
      `revive_settle_ms` there is nothing of his out there and every bite lands
      on HIM. A pile asleep does not charge that price, which is why
      `PlayerSupport`'s rescue fires the reserved control key first, waits for
      the sleep to land, and only then recalls.

      His claim, 2026-08-25: *"teoricamente mesmo no caos nunca deveríamos
      morrer, que com o revive e stun em área antes de usar o revive tudo se
      resolve"*. Measured once the simulator finally modelled the sleep: with
      the prefix on and his own floor between two rescues, **forty-eight runs of
      five minutes across both circuits, four thousand six hundred monsters, and
      the pokémon did not fall once** — at any band setting. Without it, the
      dense circuit loses it forty-five times an hour and kills the character.

      Nothing in THIS module changed for that. The rule was always here; what
      was missing was a world that modelled it. A partial stun is the
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
            since: %{},
            # R3b desarmada porque um reset foi COBRADO e não veio: ver
            # `judge_reset/2`
            # QUANDO o reset foi desarmado (nil = armado). Era um bool sem
            # volta — prisão perpétua por um julgamento de um tique — e a
            # corrida de 28/08 mostrou o custo: desarme falso no minuto 1,
            # 39 minutos de recuo com pilhas de 9 na tela. Agora o desarme
            # tem prazo (`reset_rearm_ms`) e voz (os whys dizem "desarmado").
            reset_broken_at: nil,
            # QUANTAS promessas seguidas quebraram. A leitura dele (29/08):
            # "se usou revive e não recuperou cooldown/vida, quer dizer que
            # NÃO SAIU de verdade — pode só usar de novo". O jogo engole um F4
            # de vez em quando (28 de 319 revives, ~9%, sem padrão), e fugir
            # da pilha por causa disso é o perigo real — "numa hunt difícil
            # correr chama mais bicho ainda". Então a quebra não desarma: ela
            # conta, e a regra fica ARMADA pra apertar de novo no tique
            # seguinte ao veredito (o piso `reset_revive_cooldown_ms` dá o
            # ritmo). Só a TERCEIRA seguida desarma pelo prazo longo — três
            # F4 sem efeito nenhum é a cara da noite em que o estoque acabou,
            # e aí sim andar é a resposta certa (o freio do chão, #415). Uma
            # promessa CUMPRIDA zera a conta.
            reset_strikes: 0,
            # quantos tiles já tinham sido andados quando a fuga da R7 começou —
            # é como se sabe se ela está andando de verdade
            kite_from: nil

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
  # right sequence. Splitting it again to buy a lower complexity score would
  # undo exactly that, so the check is off for this head and this head only.
  defp decide(t) do
    t = %{t | logic: audit_reset(t)}

    t |> choose() |> hold_until_reset_seen(t)
  end

  # O RESET É UMA PROMESSA COBRADA POR IMAGEM. "Temos que ter certeza de que
  # os cooldowns foram resetados antes de continuar a rota — se não tiver
  # recuperado, não podemos continuar" (01/09). Enquanto `:reset_pending`
  # estiver aberto, a decisão da caçada vira ESPERA: a rota segura e a mão fica
  # quieta. Seguir andando com a barra gasta é chegar no próximo grupo sem
  # nada; apertar o combo em cima de um reset que ainda não aconteceu é o que
  # ele viu às 23:04 — o relógio zerado dizia "barra cheia" 3s depois do F4.
  #
  # Uma SOBREPOSIÇÃO, não um ramo da fila: as regras continuam decidindo, e só
  # o que sai muda. O chefe fica de fora — o ciclo dele (stun a cada emenda,
  # F4 a cada 5s) tem física medida em oito PRs e é mais curto que o prazo da
  # promessa; segurá-lo era acordar o chefe com o controle na mão. E as fases
  # de emergência ficam de fora porque já seguram a rota por conta própria.
  @held_by_reset [:travelling, :gathering, :sizing, :bunching, :engaged, :skipping]

  # O tique que PEDE o revive passa inteiro — a ordem diz por que reviveu, e
  # o suporte a lê no tique seguinte. A espera começa daí.
  defp hold_until_reset_seen({logic, orders}, t) do
    pending? = Map.has_key?(logic.since, :reset_pending)

    if pending? and orders.revive == :hold and orders.phase in @held_by_reset and
         not heavy?(t) do
      {logic, %{orders | phase: :resetting, route: :hold, fire: :hold, why: awaiting_why(t)}}
    else
      {logic, orders}
    end
  end

  defp awaiting_why(t) do
    segundos = div(t.now - Map.get(t.logic.since, :reset_pending, t.now), 1_000)

    tela =
      if bar_seen?(t),
        do: "a barra ainda não voltou na tela",
        else: "a barra está ilegível"

    "revive pedido há #{segundos}s — #{tela}; a rota só segue com os cooldowns de volta"
  end

  defp bar_seen?(t), do: Map.get(t.s, :bar_seen?) == true

  # credo:disable-for-next-line Credo.Check.Refactor.CyclomaticComplexity
  defp choose(t) do
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
      # O ESPECIAL ACORDADO NÃO ESPERA BANDA NENHUMA.
      #
      # Medido na bancada (01/09, shinies empilhando): das 29,3s às 34,9s o
      # cérebro ficou em amarelo — "gastando os cooldowns" — com um shiny 5×
      # COLADO e ACORDADO, o controle PRONTO na mão e o revive liberado, e caiu
      # de 58% a 26% sem apertar o controle uma vez. A banda revive pra CURAR,
      # e curar debaixo da mordida é encher um balde furado: o que para o dano
      # é o stun. "1 segundo sem stun no campo quer dizer que eu morri."
      #
      # Só a perna do CONTROLE fura a fila, nunca a postura inteira: a banda
      # continua dona do revive: gastar um tique de 200ms no stun e reviver no
      # seguinte é exatamente o "controle primeiro, revive na sequência" dele.
      boss_stun_due?(t) -> boss_stun(t)
      t.logic.state == :recovering -> recovering(t)
      # R5: a band whose only move is a revive the game will refuse for another
      # forty seconds is not a reason to stand still.
      t.band in [:yellow, :red] and not revive_plausible?(t) -> unaided(t)
      # Health rules the rest: the revive needs no attack key, and a pokémon
      # about to fall must not be abandoned because nobody classified its bar.
      t.band == :red -> emergency(t)
      # O CICLO DO AUTO COMBO, nos passos que ele numerou — e ABAIXO do vermelho
      # de propósito: o chão de segurança nunca espera a corrente.
      #
      # Passo 3-4: enquanto a corrente sai, o cérebro INTEIRO para. "Ele não pode
      # sair andando" — andar durante a janela é chamar bicho novo pra cima de
      # um revive que vem em segundos, e "pode ser mortal usar o revive enquanto
      # ainda tem monstro na tela". Na noite de 02/09 o "pilha limpa — seguindo
      # a rota" saía DENTRO da janela, e o F4 caía já andando.
      mid_combo?(t) -> combo_running(t)
      # Passo 6: a corrente acabou e a barra está gasta, então revive — com
      # bicho ou sem, porque os que sobraram ainda estão no sono que a própria
      # corrente deixou. Três noites essa regra não saiu por ter sido deixada
      # cair das antigas (seis na tela, tela limpa, fase da caçada); agora é
      # regra, e vem antes da régua.
      combo_reset_due?(t) -> combo_reset(t)
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

    cond do
      # O BOLSO VAZIO NÃO PRECISA DE PROVA. O caderninho conta cada revive
      # despachado, e quando ele diz zero não há o que descobrir esperando: a
      # tecla não tem item atrás dela e nenhum minuto de insistência vai criar
      # um.
      #
      # MEDIDO na noite simulada de 5h com o estoque dele (28/08): o bolso
      # esvaziou em 2h19 e o PERSONAGEM MORREU 2,1 SEGUNDOS DEPOIS — enquanto o
      # freio abaixo, que espera cinco minutos de fracasso, só ia disparar cinco
      # minutos MAIS TARDE. Ele chegava pra parar uma caçada que já tinha
      # acabado num cemitério.
      #
      # O freio empírico continua embaixo, e continua sendo necessário: o
      # orçamento pode estar desligado (`nil`), a conta pode divergir do bolso
      # real, e o revive pode falhar por outro motivo que nenhum caderninho
      # sabe. Este atalho só cobre o caso em que a resposta já está escrita.
      Map.get(t.s, :revive_left) == 0 ->
        {%{t.logic | state: :stranded},
         Orders.standing(
           :stranded,
           t.band,
           "acabaram os revives pela conta — parando a caçada antes de perder o personagem"
         )}

      # O FIM DA INSISTÊNCIA. Medido na noite de 27→28/08: o estoque de revives
      # acabou às 23:43 e o bot passou 4,9 HORAS apertando uma tecla vazia — 605
      # despachos, a rota andando com o pokémon no chão, a estagnação alarmando
      # 73 vezes sem frear nada. Um punhado de pedidos que não mudaram nada é um
      # revive que não está vindo; horas deles é uma noite inteira jogada fora.
      # Daqui a ordem é PARAR: a rota segura, o pedido cala, e a caçada (que lê
      # esta fase) bloqueia a frota de vez — repor o estoque é trabalho de gente.
      t.config.downed_give_up_ms > 0 and down_for(t) >= t.config.downed_give_up_ms ->
        {%{t.logic | state: :stranded},
         Orders.standing(
           :stranded,
           t.band,
           "#{div(down_for(t), 60_000)}min de revive sem devolver ninguém — " <>
             "sem estoque não há noite: parando a caçada"
         )}

      elapsed?(t, :downed_asked, asking_every(t)) ->
        {mark(t.logic, :downed_asked, t.now),
         Orders.walking(:downed, t.band, downed_why(t), revive: :now)}

      true ->
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

  # UMA CHAVE TENTADA E REMOVIDA: separar o revive do amarelo (o luxo — fechar a
  # rodada e voltar cheio) do revive do vermelho (o resgate). Medida em 25/08 no
  # formigueiro, 60 minutos, com o stun na frente: desligar o luxo economiza 11
  # revives por hora e custa 7% dos monstros, nos três pisos. Uma chave cuja
  # posição desligada nunca é a certa não é uma escolha, é entulho.
  defp revive_now?(t) do
    not mid_combo?(t) and
      (t.s.enemies == 0 or not within?(t, :closing, t.config.closing_timeout_ms))
  end

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
      # DE VOLTA COM BICHO NA TELA: a luta continua, e continua AGORA.
      #
      # "Quando ele acaba de usar o combo e não mata, ele anda um pouco antes de
      # reusar o combo depois que ele revive — não faz muito sentido quando a
      # gente está usando um revive como reset de cooldown: a gente está no meio
      # de uma luta agressiva, então continua na luta" (27/08).
      #
      # `reset/1` zera os relógios e a régua recomeçava do zero: juntar de novo,
      # andar os cinco passos, esperar os seis segundos. No meio de uma luta
      # aberta isso é o combo chegando tarde — e o revive foi gasto justamente
      # pra ele chegar cedo.
      is_integer(hp(t)) and hp(t) >= t.config.resume_pct and some?(t.s) ->
        {%{reset(t.logic) | state: :engaged},
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "de volta com a barra cheia e #{count(t.s)} na frente — a luta continua"
         )}

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
  #
  # …and where it does NOT stop, once the brain itself decided to walk a pile
  # together (R6): the hunt reports `:walking` the moment the route moves, and
  # letting that end the gathering would cancel the decision on its own first
  # step.
  defp normal(%{logic: %{state: :gathering}} = t), do: ruler(t)

  # …E A LUTA EM ANDAMENTO TAMBÉM SOBREVIVE AO TRECHO DE MOB. O ramo do
  # luring (logo abaixo) re-setava o estado pra :gathering a CADA tique,
  # pisando no :bunching que a régua tinha acabado de abrir: o carimbo
  # `bunch_from` renascia toda volta, "mais 2 passos pra puxar" recomeçava do
  # zero eternamente, e o fogo NUNCA liberava enquanto o trecho durasse.
  # Filmado na morte de 30/08 13:21 — 43 passos de mobada com 6-9 bichos
  # mastigando, "estourando a área" decidido dezenas de vezes e nenhuma
  # rajada solta: o cabo de guerra era o cérebro contra ele mesmo.
  defp normal(%{logic: %{state: state}} = t) when state in [:bunching, :engaged, :skipping],
    do: ruler(t)

  defp normal(%{hunt: %{state: :fighting}} = t), do: ruler(t)

  # O TRECHO MARCADO À MÃO, que ele quer parar de marcar — e que continua aqui
  # por um motivo medido, não por apego.
  #
  # A R6 junta pilha sozinha, mas só depois de ver o PRIMEIRO bicho: é dele que
  # a contagem de passos começa. A marca sabe de algo que a foto não tem como
  # saber — "tem bicho adiante, comece a recolher agora" — e numa rota esparsa
  # essa dianteira vale 6% dos monstros (8,52 → 7,98 mortos/min, medido em
  # 26/08 tirando este ramo). No circuito denso não muda nada: lá sempre há um
  # primeiro bicho por perto.
  #
  # Ou seja: parar de marcar é uma escolha legítima e custa isso. Marcar não é
  # mais NECESSÁRIO pra caçada mobar — é uma dianteira opcional.
  defp normal(%{hunt: %{state: :walking, luring?: true}} = t) do
    cond do
      # Chefe na tela derruba a mobada na hora: puxar pilha com um ataque 10x
      # atrás é colecionar mordida que ninguém paga.
      Map.get(t.s, :heavy?, false) ->
        engaged(%{t | logic: enter(t.logic, :engaged, t.now)})

      t.config.gather_piles and pile_payable?(t) ->
        {reset_fight(t.logic, :gathering),
         Orders.walking(:gathering, t.band, "mobando: puxando a pilha, sem atacar")}

      # "Não deveria estar andando por aí se eu não tenho nenhum cooldown
      # disponível" (28/08, depois de morrer). Juntar seis bichos que não há
      # barra pra matar nem revive pra comprá-la é escolher uma luta sem saída:
      # a rota segue (R2 — andando eles perdem o interesse) e o fogo fica
      # livre pra primeira tecla que voltar.
      t.config.gather_piles ->
        {reset_fight(t.logic, :travelling),
         Orders.walking_and_firing(
           :travelling,
           t.band,
           opening(t),
           "sem barra e sem revive pra comprá-la — não abro pilha: seguindo a rota"
         )}

      # SEM JUNTAR, O TRECHO DE MOBADA É RÉGUA COMO QUALQUER OUTRO. Isto era
      # "batendo enquanto ando" — a rota seguia andando com a pilha atrás, que
      # é exatamente o que ele proibiu em 02/09 ("não dar mais nenhum passo,
      # deixar os bichos virem até mim"). A régua para: conta quem chega, abre
      # quando vale, e o teto bounds a espera.
      true ->
        ruler(t)
    end
  end

  defp normal(%{s: %{heavy?: true}} = t),
    do: engaged(%{t | logic: enter(t.logic, :engaged, t.now)})

  defp normal(t) do
    if prepare?(t, t.config.prepare_max_enemies) do
      {reset_fight(t.logic, :travelling)
       |> mark(:reset_revive, t.now)
       |> mark(:reset_pending, t.now),
       Orders.walking(
         :travelling,
         t.band,
         "andando com a barra pela metade — revive agora pra chegar inteiro",
         revive: :prepare
       )}
    else
      {reset_fight(t.logic, :travelling),
       Orders.walking(:travelling, t.band, travelling_why(t.hunt))}
    end
  end

  # R11 — CHEGAR PREPARADO NO PRÓXIMO GRUPO.
  #
  # "É raro quando uso todas minhas skills realmente esperar cooldown, eu sempre
  # uso um revive antes de matar o próximo grupo de monstros (…) mesmo que nem
  # tenha acabado todos os cooldowns, pra já deixar preparado pro próximo grupo
  # que logo vai aparecer na tela conforme andarmos" (27/08).
  #
  # As outras regras de revive perguntam "a barra ACABOU?". Esta pergunta o
  # contrário: "a barra está INTEIRA?" — e entre as duas cabe a barra pela
  # metade, que é onde a caçada dele vive.
  #
  # SEM PREFIXO DE CONTROLE, e isso não fura a regra dos 5s: o controle existe
  # pra proteger um revive dado no meio de uma pilha ACORDADA, e aqui a tela
  # está limpa. Sem ninguém em campo, o pokémon na bola não custa dano nenhum.
  #
  # E "sem prefixo" agora é dito na ORDEM (`revive: :prepare`), não só desejado
  # aqui: até 28/08 o executor prefixava o stun em TODO revive, então o preparo
  # gastava o controle numa tela limpa — e quando o revive perigoso chegava, o
  # controle estava gelado e o F4 saía sem proteção nenhuma na cara da pilha
  # acordada. Foi a cadeia da morte do personagem.
  #
  # Ela se limita sozinha: o revive devolve a barra inteira, então na volta
  # `prepared?` é true e a regra cala até o próximo grupo gastar alguma tecla.
  # No máximo um revive por grupo, e só se o grupo custou alguma coisa.
  # `Map.get` e não `t.s.prepared?`: uma foto montada por um chamador (um teste,
  # um worker no meio de uma atualização) não pode derrubar o cérebro por uma
  # chave nova — e ausente é DESCONHECIDO, que aqui não mexe.
  # `ceiling` é quantos restos na tela ainda contam como "entre grupos". No
  # `engaged` ele é ZERO — os bichos dali estão EM CIMA do pokémon, e recolher
  # ele na frente deles é o oposto de chegar preparado. Na estrada (`normal`) o
  # teto é `prepare_max_enemies`: a análise da noite de 27→28/08 mostrou que a
  # tela dessa rota NUNCA limpa (trem de 6-9 o tempo todo, `travelling` com 0
  # inimigos quase não existe), então a regra dele — "eu sempre uso um revive
  # antes de matar o próximo grupo, mesmo que nem tenha acabado os cooldowns" —
  # não disparava NUNCA: 18 revives preparados contra 171 no meio do bolo. Um
  # ou dois restos perseguindo de longe são a tela limpa que essa rota tem.
  defp prepare?(t, ceiling) do
    t.config.prepare_revive and not mid_combo?(t) and
      Map.get(t.s, :prepared?) == false and t.s.own_out? == true and
      quiet?(t, ceiling) and elapsed?(t, :reset_revive, t.config.reset_revive_cooldown_ms) and
      t.logic.reset_broken_at == nil and affordable?(t)
  end

  defp quiet?(%{s: %{enemies: enemies}}, ceiling) when is_integer(enemies),
    do: enemies <= ceiling

  defp quiet?(_unknown, _ceiling), do: false

  defp travelling_why(%{state: :walking}), do: "andando a rota"
  defp travelling_why(%{state: :post_fight}), do: "limpando o que ficou no chão"
  defp travelling_why(%{state: state}), do: "a caçada está em #{state}"

  # --- THE RULER (R1) --------------------------------------------------------
  #
  # Standing at the kill spot, the question is not "is there something to hit"
  # but "is this worth the area damage". Three states answer it and they used to
  # share one function name, so `sizing(%{state: :engaged})` was a thing you had
  # to read twice.

  # O CHEFE FURA TODA FILA. Juntar, medir, esperar bolo — tudo isso é economia
  # de área, e um chefe com ataque 10x não dá o tempo que a economia custa:
  # "1 segundo sem stun no campo quer dizer que eu morri" (29/08). Na tela,
  # briga-se JÁ, com a postura de chefe do `engaged/1`.
  defp ruler(%{s: %{heavy?: true}} = t),
    do: engaged(%{t | logic: enter(t.logic, :engaged, t.now)})

  defp ruler(%{logic: %{state: :bunching}} = t), do: bunching(t)
  defp ruler(%{logic: %{state: :engaged}} = t), do: engaged(t)
  # A PILHA DEIXADA PRA TRÁS CONTINUA SENDO OLHADA. Este ramo era `skipping(t)`
  # seco: uma vez decidido "não vale", o cérebro andava de mãos baixas SEM
  # reler a lista — o estado só saía por chefe ou emergência. Diário de 02/09,
  # 20:33: "só 2 inimigos em 8s: não vale a área", cinco waypoints andados sem
  # uma contagem sequer, e dez bichos em cima dele quando ele puxou o pânico.
  # "Ele checou que tinha dois, saiu correndo e do nada tinha uns 10."
  #
  # R1 continua valendo — um ou dois a gente ignora — mas a pergunta é feita a
  # cada tique: encheu enquanto eu andava, é régua de novo (e com a juntada
  # desligada a régua abre parada); esvaziou, a rota segue LIMPA, sem carregar
  # o "não vale" pra próxima pilha.
  defp ruler(%{logic: %{state: :skipping}} = t) do
    cond do
      t.s.enemies == 0 ->
        {reset_fight(t.logic, :travelling),
         Orders.walking(:travelling, t.band, "a pilha ficou pra trás — seguindo a rota")}

      t.s.worth_fighting? ->
        sizing(%{t | logic: enter(t.logic, :sizing, t.now)})

      true ->
        skipping(t)
    end
  end

  defp ruler(t), do: sizing(%{t | logic: enter_sizing(t.logic, t.now)})

  # Walking a pile together is still SIZING — it is the same question, asked
  # while moving — so the clock started at the first sighting keeps running and
  # the ceiling still bounds the whole thing.
  defp enter_sizing(%{state: state} = logic, now) when state in [:sizing, :gathering],
    do: %{logic | state: :sizing, since: Map.put_new(logic.since, :sizing, now)}

  defp enter_sizing(logic, now), do: enter(logic, :sizing, now)

  # THE ROUND IS OVER when the list is empty — 0, not `nil`. "Finishing what you
  # started" is the rule for a list that is shrinking, not for a screen with
  # nobody on it: holding the route there narrates a fight against nothing and
  # keeps the hunt standing at a spot it has already cleared.
  defp engaged(%{s: %{enemies: 0}} = t) do
    if prepare?(t, 0) do
      {reset_fight(t.logic, :travelling)
       |> mark(:reset_revive, t.now)
       |> mark(:reset_pending, t.now),
       Orders.walking(
         :travelling,
         t.band,
         "pilha limpa — revive agora pra chegar inteiro no próximo grupo",
         revive: :prepare
       )}
    else
      {reset_fight(t.logic, :travelling),
       Orders.walking(:travelling, t.band, "pilha limpa — seguindo a rota")}
    end
  end

  # R7 — A BARRA VAZIA NÃO SEGURA A ROTA.
  #
  # Medido no formigueiro (2026-08-25): a salva de área abre em cinco e mata
  # três, e os dois que sobram comem 64% da vida nos oito segundos seguintes,
  # com todas as teclas em cooldown. Parado, a luta é uma troca em que só um
  # lado bate. Andando, eles seguem sem morder — e o fogo continua livre, então
  # a primeira tecla que volta sai na hora.
  #
  # É o que uma mão humana faz sem pensar, e é o oposto do que "terminar o que
  # começou" diz quando lido como "não sair do lugar".
  #
  # Vem DEPOIS da R3b de propósito: as duas respondem à mesma barra vazia na
  # frente da mesma pilha, e a R3b é a cara — ela compra a barra de volta com um
  # revive. Andar é de graça, então é a resposta quando a cara está desligada ou
  # não cabe.
  # A POSTURA DE CHEFE vem antes de tudo, nas duas metades do combo dele
  # (29/08): "usar todas as skills, finalizar com stun e depois usar o revive
  # pra repetir esse combo, deixando o boss sempre stunado". O relógio é o
  # SONO, não a barra — e sem chefe na tela ela devolve nil e a luta comum
  # decide como sempre decidiu.
  defp engaged(t), do: boss_orders(t) || engaged_regular(t)

  defp boss_orders(t) do
    cond do
      not heavy?(t) ->
        nil

      # A perna de emergência: chefe ACORDADO e controle no chão — dois chefes
      # sobrepostos fazem isso. Esperar 40s de cooldown é a morte que ele
      # descreveu; o F4 compra o controle de volta AGORA.
      boss_rearm_due?(t) ->
        {t.logic |> mark(:reset_revive, t.now) |> mark(:reset_pending, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "chefe acordado e controle no chão — F4 compra o controle de volta",
           revive: :now
         )}

      # O controle sai de novo com 1s de folga antes do sono acabar — a folga
      # é a frase dele: "1 segundo sem stun no campo quer dizer que eu morri".
      boss_stun_due?(t) ->
        boss_stun(t)

      # …e o revive vem logo atrás de cada stun SEM esperar a barra esvaziar:
      # é o revive que devolve o controle pro próximo ciclo.
      boss_revive_due?(t) ->
        {t.logic |> mark(:reset_revive, t.now) |> mark(:reset_pending, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "chefe dormindo — revive agora, o controle do próximo ciclo sai dele",
           revive: :now
         )}

      # O REVIVE COBERTO: a barra gastou, o piso do item venceu, e o sono
      # ainda cobre a recolhida inteira (pegada + volta + folga) — o F4 sai
      # SEM stun novo, porque dormir um chefe já dormindo é pagar duas vezes.
      # É o "usar o revive sempre que fizer sentido, maximizando dano/s": a
      # barra volta cheia no meio da cobertura, e o stun fica no relógio dele.
      boss_covered_revive_due?(t) ->
        {t.logic |> mark(:reset_revive, t.now) |> mark(:reset_pending, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "chefe coberto e barra gasta — F4 recheia a barra dentro do sono",
           revive: :now
         )}

      true ->
        nil
    end
  end

  # O CONTROLE, sozinho — a única ordem que PARA o dano do especial. Vive fora
  # do `boss_orders` porque ela também é cobrada acima das bandas de vida (ver
  # `decide/1`): reviver sem stunar é curar debaixo da mordida.
  defp boss_stun(t) do
    # `enter/3` é idempotente com o estado atual, então chamar daqui não mexe
    # no relógio de uma luta que já estava em curso — e chamando de FORA do
    # `engaged` (a fila das bandas) é ele que garante que a luta é uma luta,
    # não um `:idle` narrando fogo.
    {t.logic |> enter(:engaged, t.now) |> mark(:stunned, t.now),
     Orders.standing_and_firing(
       :engaged,
       t.band,
       crowd(t) ++ opening(t),
       "especial na tela — controle antes do sono acabar"
     )}
  end

  defp engaged_regular(t) do
    cond do
      # R10, primeira metade: a pilha é grande e o controle está pronto. Ele sai
      # AGORA, junto com o dano — guardá-lo pro resgate é guardá-lo pra um
      # resgate que, numa hunt séria, chega tarde demais.
      stun_now?(t) ->
        {mark(t.logic, :stunned, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           crowd(t) ++ opening(t),
           "#{count(t.s)} em cima — controle e dano juntos"
         )}

      # …e a segunda metade, que é o que torna o controle barato: com a pilha
      # dormindo, o campo vazio não custa nada, e o revive devolve o controle
      # junto com o resto da barra. A janela é dele: "SEMPRE usar o revive
      # dentro da range de 5 segundos no máximo depois da skill de controle".
      stun_window?(t) ->
        {mark(t.logic, :reset_revive, t.now) |> mark(:reset_pending, t.now) |> forget_stun(),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "controle no chão — revive dentro da janela, pra voltar com a barra cheia",
           revive: :now
         )}

      # A R3b PASSA A OBEDECER A JANELA DELE. A regra é dele e não tem exceção —
      # "SEMPRE usar o revive dentro da range de 5 segundos no máximo depois de
      # usar a skill de controle" — e a R3b era a única porta que a furava: ela
      # gasta um revive com a pilha ACORDADA e deixa o campo vazio na frente
      # dela por todo o settle.
      #
      # MEDIDO em 26/08, com `stunned_at` carimbado: só 39% dos revives do anel
      # e 29% do formigueiro saíam dentro dos cinco segundos, e esta era a
      # razão. Com o controle pronto ele sai PRIMEIRO, e o revive cai no
      # `stun_window?` do tique seguinte — que é exatamente a sequência que ele
      # descreveu: controle, algum dano, revive.
      stun_before_reset?(t) ->
        {mark(t.logic, :stunned, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           crowd(t) ++ opening(t),
           "sem cooldown com #{count(t.s)} na frente — controle primeiro, revive na sequência"
         )}

      reset_revive?(t) ->
        # R3b SEM CONTROLE PRONTO — e sem ESPERA nenhuma. A aposta com prazo
        # (`stun_wait_ms`) segurava o revive por um controle que "volta logo",
        # e o que ele viu foi o preço dela: "não perde tempo fugindo tanto
        # assim (…) usar o que tem e usa o revive, e não recuar" (28/08). A
        # proteção que a espera comprava mudou de endereço em #429: o executor
        # escala com o que sobrou, com settle, e nunca recolhe nu.
        {t.logic |> mark(:reset_revive, t.now) |> mark(:reset_pending, t.now),
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "sem cooldown com #{count(t.s)} na frente — revive pra voltar com a barra cheia",
           revive: :now
         )}

      # Com o especial na tela não se recua: a barra volta em 40s, o shiny não
      # volta nunca. Não precisa de guarda própria — `heavy?` já é ele.
      kiting?(t) and not Map.get(t.s, :heavy?, false) ->
        # PELO CHÃO LIMPO, não pela rota: andar pra frente aqui atravessa spawn
        # novo e o trem cresce mais rápido que a barra volta (medido na noite de
        # 27→28/08, 9+ na tela por minutos a fio). Recuar mantém a pilha colada
        # e não acorda ninguém — a caçada sabe andar a rota ao contrário.
        {arm_kite(t),
         Orders.retreating_and_firing(
           :engaged,
           t.band,
           opening(t),
           "sem cooldown com #{count(t.s)} em cima — recuando#{kite_reason(t)}"
         )}

      true ->
        # A fight already opened does not re-measure itself as it kills:
        # finishing what you started is right even as the list shrinks past
        # three. Com a barra vazia e o reset desarmado, a linha DIZ o desarme —
        # 39 minutos de silêncio em 28/08 pareciam covardia e eram uma trava.
        {t.logic,
         Orders.standing_and_firing(
           :engaged,
           t.band,
           opening(t),
           "matando o que já abriu#{disarmed_note(t)}"
         )}
    end
  end

  # UMA FUGA QUE NÃO ANDA NÃO É FUGA. Cercado, o pé não sai do lugar: a caçada
  # nem escapa nem luta, e no jogo dele ela ainda tropeçou em `:stuck` no meio
  # disso, quinze segundos depois de começar (26/08). O banco não via porque o
  # personagem atravessava a pilha — atravessa não mais.
  #
  # Então a fuga se prova: passada a janela, se `walked_total` não andou um
  # tile, ela é abandonada e a luta volta a ser parada. `walked_total` é
  # monotônico, então "andou" é uma subtração — nada de histórico de posição.
  # Só com a pilha grande, só com a tecla PRONTA (a barra responde isso), e só
  # com um pokémon em campo pra apertá-la.
  # …E NÃO COM A BARRA GASTA. Com `crowd_from: 1` o controle saía em qualquer
  # bolo, quase toda vez que voltava — e o cooldown dele (40s no time dele) é da
  # ordem do da barra inteira. Resultado, visto por ele em 27/08: "eu precisava
  # da minha skill de stun ali e ele já tinha usado". Com a barra gasta o
  # trabalho do controle é ser o prefixo do revive (R10), e gastá-lo antes disso
  # é trocar o reset da barra inteira por um stun solto.
  #
  # Não se perde o uso ofensivo: com a barra gasta e a pilha grande, o controle
  # sai do mesmo jeito — por `stun_before_reset?`, com o revive atrás.
  defp stun_now?(t) do
    control_ready?(t) and controle_livre?(t) and is_integer(t.s.enemies) and
      t.s.enemies >= t.config.crowd_from and elapsed?(t, :stunned, t.config.stun_window_ms)
  end

  # `stun_hold_ms` é quanto o controle DELE segura um bicho no chão — medido
  # por ele: 3s. A versão do simulador (`stun_ms`) tem que bater com esta
  # crença, senão a bancada prova um combo que o jogo não dá.
  #
  # O F4 NÃO TEM COOLDOWN NO JOGO — "aquele era um cooldown de segurança" —
  # então nenhuma foto valida revive: o único piso é o de segurança
  # (`rescue_floor_ms`), contado do nosso último pedido.
  defp boss_rearm_due?(t) do
    heavy?(t) and not mid_combo?(t) and t.s.own_out? == true and not control_ready?(t) and
      boss_awake?(t) and
      elapsed?(t, :reset_revive, t.config.rescue_floor_ms) and
      affordable?(t)
  end

  # O chefe está acordado? Com a testemunha, é o sono zerado; sem ela, é um
  # carimbo de stun mais velho que a duração do sono.
  defp boss_awake?(t) do
    case Map.get(t.s, :boss_asleep_left_ms) do
      nil -> not within?(t, :stunned, t.config.stun_hold_ms)
      left -> left == 0
    end
  end

  # O STUN É O PREFIXO DO REVIVE, e o ciclo tem DOIS gatilhos:
  #
  #   * a BARRA GASTA — "usar todas as skills, finalizar com stun e depois
  #     usar o revive" (30/08);
  #   * a EMENDA — a física que ele mediu na segunda passada: o sono dura 5s
  #     e só pega 2s depois do aperto. O próximo stun tem que sair enquanto o
  #     sono velho ainda cobre a pegada do novo — cobertura restante ≤ pegada
  #     — senão cada ciclo abre 2s de chefe acordado que nenhuma rajada paga.
  #     Com o piso de segurança de 5s entre F4s, a conta fecha exata:
  #     aperto a cada ~5s, pegada de 2s, sono de 5s — emenda contínua.
  #
  # O piso de 1,5s entre ordens é só o tempo de o aperto anterior chegar ao
  # jogo antes de acusá-lo de vento (um stun que não pegou é reapertado, de
  # graça).
  # …e o stun NÃO espera o piso do F4 (o piso protege o ITEM; o sono protege
  # o pokémon — esperar relógio de segurança com o chefe mordendo custou 2,2s
  # por ciclo na bancada), NEM sai com a barra gasta no meio da cobertura:
  # stun em cima de sono pago desperdiça o sono e desalinha a emenda. O stun
  # tem UM relógio — a emenda.
  defp boss_stun_due?(t) do
    heavy?(t) and control_ready?(t) and close_enough_to_stun?(t) and
      emenda_due?(t) and elapsed?(t, :stunned, 1_500)
  end

  # A cobertura restante chegou na pegada? Com testemunha, é aritmética; sem
  # (o jogo real, por enquanto), o carimbo da ordem aproxima: cobertura do
  # aperto = `stun_hold_ms`, então a emenda vence em `hold - pegada`.
  #
  # A FOLGA DE 600ms é o preço da margem zero: piso de 5s + pegada de 2s =
  # cobertura de 7s EXATA, então qualquer deriva de fase (rajada, tique,
  # blackout) viraria chefe acordado. Emendar 600ms antes sobrepõe 600ms de
  # sono — que o mundo só estica, nunca encurta — e compra a folga que a
  # aritmética não dá.
  @emenda_folga_ms 600

  defp emenda_due?(t) do
    pegada = t.config.stun_onset_ms + @emenda_folga_ms

    case Map.get(t.s, :boss_asleep_left_ms) do
      nil -> elapsed?(t, :stunned, max(t.config.stun_hold_ms - pegada, 0))
      left -> left <= pegada
    end
  end

  # O STUN TEM RAIO. O primeiro rascunho apertava o controle no primeiro
  # avistamento — com o chefe a 6 tiles, raio 4: sono no vento, e o chefe
  # chegava acordado com o controle já gasto ("se disperdiçar stun à toa (…) é
  # morte na certa"). Sem medida de distância (nil), sai na hora — pior
  # segurar um stun que talvez pegasse do que garantir um que não pega.
  defp close_enough_to_stun?(t) do
    case Map.get(t.s, :boss_tiles) do
      nil -> true
      tiles -> tiles <= t.config.stun_reach_tiles
    end
  end

  # O revive do ciclo exige um stun VISTO (o carimbo `:stunned` existe e está
  # dentro da janela do R10) — sem essa exigência, um `within?` de carimbo
  # ausente devolve true e o F4 sairia sem sono nenhum na frente do chefe. O
  # desarme da R3b NÃO entra aqui de propósito: com o estoque de verdade
  # zerado o F4 é um aperto vazio de graça, e correr do chefe é a morte que
  # ele descreveu — não há plano B a proteger.
  defp boss_revive_due?(t) do
    heavy?(t) and not mid_combo?(t) and t.s.own_out? == true and
      is_integer(Map.get(t.logic.since, :stunned)) and
      within?(t, :stunned, t.config.stun_window_ms) and
      stun_seen_for_revive?(t) and
      one_revive_per_stun?(t) and
      elapsed?(t, :reset_revive, t.config.rescue_floor_ms) and
      affordable?(t)
  end

  # "Se disperdiçar stun à toa e não usar o ressurect no tempo do stun dele, é
  # morte na certa" — o F4 do ciclo só sai com o chefe DORMINDO DE VERDADE:
  # com o canal presente, sono restante > 0. Sem canal, vale o carimbo, como
  # sempre valeu.
  defp stun_seen_for_revive?(t) do
    case Map.get(t.s, :boss_asleep_left_ms) do
      nil -> true
      left -> left > 0
    end
  end

  # UM revive por stun. Sem isto o piso de 3s comprava um SEGUNDO F4 dentro da
  # mesma janela de sono — e "disperdiçar revive à toa" é o outro lado da
  # moeda do stun desperdiçado.
  defp one_revive_per_stun?(t) do
    case Map.get(t.logic.since, :reset_revive) do
      nil -> true
      revived_at -> revived_at < Map.get(t.logic.since, :stunned)
    end
  end

  # Sono de sobra = pegada (2s) + recolhida e volta (~1s): abaixo disso o
  # pokémon voltaria com o chefe acordando na cara. Só com testemunha — sem o
  # canal (o jogo, por enquanto) este atalho não existe e o par clássico
  # responde sozinho.
  defp boss_covered_revive_due?(t) do
    left = Map.get(t.s, :boss_asleep_left_ms)

    heavy?(t) and not mid_combo?(t) and t.s.own_out? == true and t.s.spent? == true and
      is_integer(left) and left >= t.config.stun_onset_ms + 1_000 and
      elapsed?(t, :reset_revive, t.config.rescue_floor_ms) and
      affordable?(t)
  end

  defp heavy?(t), do: Map.get(t.s, :heavy?, false)

  # A CORRENTE DO JOGO SAINDO SEGURA TODO REVIVE DE ECONOMIA.
  #
  # No Auto Combo uma prensa encadeia as skills ofensivas do pokémon, e o revive
  # RECOLHE o pokémon: pedido no meio da corrente, ele joga fora metade do dano
  # que ela ainda ia entregar — e a corrente termina em controle, que é
  # justamente o sono que faz o revive valer a pena. Por isso o revive do ciclo
  # é "o mais cedo possível DEPOIS do combo" (Lucas, 01/09), não durante.
  #
  # Não segura a EMERGÊNCIA nem o CAÍDO: com o pokémon prestes a cair, terminar
  # a corrente é o luxo. `nil` é "esta caçada não tem combo" e não segura nada.
  defp mid_combo?(t) do
    case Map.get(t.s, :combo_left_ms) do
      left when is_integer(left) -> left > 0
      _sem_combo -> false
    end
  end

  # O controle está livre pro uso ofensivo? Com a R3b desligada, sempre — não há
  # revive nenhum esperando por ele, e a regra dele de 26/08 vale inteira ("tento
  # ir usando o 1 pra quando tem muito monstro, pra eu não morrer").
  #
  # Com ela ligada, NUNCA. A guarda anterior ("só com a barra fresca") não
  # bastava: com `crowd_from: 1` o controle saía na ABERTURA de quase todo bolo
  # — 147 "controle e dano juntos" na corrida de 3h de 29/08 — e o cooldown
  # dele (40-50s) é da ordem do da barra inteira, então quando a barra
  # esvaziava 15s depois o revive achava o controle no chão: 60 "controle em
  # cooldown na hora do revive" na mesma corrida, o resgate escalando exposto.
  # A ordem dele: "temos é que ser mais rígidos para não ter fluxo onde a
  # skill de controle tá sendo usada sem querer (…) o caminho não é fazer meu
  # personagem correr 40s pra esperar a skill de stun que ele usou errado".
  # Com a R3b ligada o trabalho do controle é UM: prefixo do revive
  # (`stun_before_reset?`, e o do resgate como reserva).
  defp controle_livre?(t), do: not t.config.reset_revive

  # O PREFIXO DO REVIVE, não uma segunda R10: a pilha não precisa ser grande pra
  # justificar o controle aqui, porque quem está sendo comprado é a barra, não a
  # pilha. `crowd_from` continua sendo o dono do controle OFENSIVO.
  defp stun_before_reset?(t) do
    reset_revive?(t) and control_ready?(t) and
      elapsed?(t, :stunned, t.config.stun_window_ms)
  end

  defp control_ready?(t) do
    crowd(t) != [] and t.s.own_out? == true and Enum.any?(crowd(t), &ready?(t, &1))
  end

  # A janela só existe depois de um controle que ESTE módulo mandou sair, e só
  # enquanto ela dura: fora dela o revive volta a ser a regra de sempre.
  #
  # E ELA EXIGE A BARRA GASTA. Não exigia, e por isso o controle OFENSIVO virava
  # gatilho de revive: com `crowd_from: 1` qualquer bolo faz o controle sair, a
  # janela abre, e o revive saía com a barra INTEIRA na mão. Medido em 27/08,
  # nas 6 sementes: 19 dos 137 revives do anel saíram com cinco teclas prontas.
  #
  # "A gente tem que usar todas as skills, para depois usar um ressurect, porque
  # ele tem um certo custo que não é de graça" (27/08). A janela dele é sobre a
  # ORDEM — quando reviver, revive logo depois do controle —, não uma licença
  # pra reviver toda vez que o controle sai.
  defp stun_window?(t) do
    reset_revive?(t) and Map.has_key?(t.logic.since, :stunned) and
      within?(t, :stunned, t.config.stun_window_ms)
  end

  # Sem leitura da barra a tecla conta como pronta: uma leitura que falta não
  # pode ser o motivo de a caçada nunca usar o controle.
  defp ready?(t, key) do
    case Map.get(t.s, :ready_keys) do
      nil -> true
      keys -> key in keys
    end
  end

  defp crowd(%{hands: %{crowd: keys}}), do: keys
  defp crowd(_no_hands), do: []

  defp forget_stun(logic), do: %{logic | since: Map.delete(logic.since, :stunned)}

  # O recuo diz POR QUE está recuando em vez de resetar: o desarme era mudo, e
  # 39 minutos de kite pareciam covardia quando eram uma trava latchada.
  defp disarmed_note(%{s: %{spent?: true}, logic: %{reset_broken_at: at}} = t)
       when is_integer(at),
       do: kite_reason(t)

  defp disarmed_note(_armed_or_not_spent), do: ""

  defp kite_reason(%{logic: %{reset_broken_at: at}} = t) when is_integer(at) do
    left = div(max(t.config.reset_rearm_ms - (t.now - at), 0), 1_000)

    " — o reset está DESARMADO (3 revives seguidos sem efeito nenhum — " <>
      "confere o ESTOQUE no jogo; tento de novo em #{left}s)"
  end

  defp kite_reason(t) do
    if reset_no_piso?(t),
      do: " — reset já pedido, segurando #{div(t.config.reset_revive_cooldown_ms, 1_000)}s",
      else: " pelo chão limpo até a barra voltar"
  end

  defp reset_no_piso?(t),
    do:
      t.config.reset_revive and
        not elapsed?(t, :reset_revive, t.config.reset_revive_cooldown_ms)

  defp kiting?(t) do
    t.config.kite_when_spent and t.s.spent? == true and some?(t.s) and escaping?(t) and
      kite_budget_left?(t)
  end

  # O TETO DA RETIRADA — e ele existe porque a retirada não termina sozinha.
  #
  # A R7 recua com a barra vazia pra ganhar tempo enquanto os cooldowns voltam,
  # e o fogo continua LIVRE durante o recuo. Aí está o laço: cada tecla que
  # volta é gasta na mesma hora na pilha que vem atrás, `spent?` nunca chega a
  # ser falso, e a condição que faria o recuo parar nunca acontece. Com o reset
  # desarmado — sem revive pra comprar a barra de volta — recuar vira o estado
  # permanente da caçada.
  #
  # MEDIDO na noite dele de 29/08, 9,8 horas: 2.836 tiques de "recuando", 13
  # episódios de desarme espaçados de 10 em 10 minutos (o prazo de rearme), e
  # 771 waypoints andados PARA TRÁS — um deles uma volta inteira de 40 cantos
  # em 92 segundos, o circuito refeito de costas. Foi isso que ele viu: "ficou
  # em loop indo pra frente e pra trás".
  #
  # O teto é a pergunta honesta: recuar compra tempo para a barra, então um
  # recuo que dura mais que um ciclo de cooldown já provou que não está
  # comprando nada — e o preço é o chão limpo sendo refeito de costas enquanto
  # o trem cresce. Passado o teto a caçada PARA e bate ("continuar em frente
  # batalhando", ele em 28/08): a pilha fica colada do mesmo jeito, e a
  # primeira tecla que voltar abre nela inteira.
  #
  # Zero desliga o teto e devolve o recuo sem fim de antes.
  defp kite_budget_left?(%{config: %{kite_max_ms: 0}}), do: true
  defp kite_budget_left?(t), do: within?(t, :kiting, t.config.kite_max_ms)

  # Ainda dentro da janela, a fuga tem o benefício da dúvida; passada ela, só
  # segue quem realmente andou.
  defp escaping?(%{logic: %{kite_from: nil}}), do: true

  defp escaping?(t) do
    within?(t, :kiting, kite_confirm_ms(t)) or Map.get(t.s, :walked_total, 0) > t.logic.kite_from
  end

  # Generosa em relação ao tique (200ms) e ao passo (~320ms/tile): cobrar cedo
  # demais chamaria de parada uma fuga que só não tinha completado um tile.
  defp kite_confirm_ms(t), do: max(t.config.revive_confirm_ms, 1_500)

  # UMA REGRA TENTADA E REFUTADA, escrita pra não voltar: "não se abre uma pilha
  # com a barra vazia — espera os cooldowns andando, que o tempo passa de graça
  # e a pilha só cresce". Soa certa e não muda nada: `sizing` só é alcançado
  # quando a luta anterior já acabou, e a barra a essa altura quase sempre
  # voltou. Medida em 25/08 nos dois circuitos, 5 min × 12 sementes: 31,2 →
  # 30,95 e 8,92 → 8,75 mortos/min, tudo dentro do ruído.
  #
  # R1 says to IGNORE one or two and walk on ("eu às vezes até ignoro aquele mob
  # e sigo a minha vida"), hands down. Bater em quem vem junto foi medido
  # (#489) e não mudava nada; a régua saiu em 02/09.
  defp skipping(t),
    do:
      {t.logic, Orders.walking(:skipping, t.band, "deixei essa pilha pra trás — seguindo a rota")}

  defp sizing(t) do
    cond do
      # Nobody there. Not `nil` — that is the blind case, and it never reaches
      # here. Walking a pile that no longer exists is walking.
      t.s.enemies == 0 ->
        {reset_fight(t.logic, :travelling),
         Orders.walking(:travelling, t.band, "nada aqui — seguindo a rota")}

      rushing_in?(t) ->
        open(t, "#{count(t.s)}: caindo em cima, sem esperar juntar")

      # R6. The pile is worth fighting AND it has been walked for: the steps
      # bought whatever was going to join, and dragging further only spends the
      # rope R2 charges for.
      # AS FRASES NOMEIAM A REGRA. "10 passos e não veio mais ninguém" foi a
      # pergunta dele de 02/09 — ele quis subir os 10 e não tinha a palavra pra
      # procurar. Cada saída da régua diz qual knob a fechou.
      gathered_enough?(t) ->
        open(
          t,
          "#{count(t.s)} depois de #{walked(t)} passos juntando (bolo cheio): estourando a área"
        )

      stopped_arriving?(t) ->
        open(t, "#{count(t.s)} e pararam de chegar: estourando a área")

      # "Ou quando a gente já andou demais e não achou mais ninguém": past the
      # patience, what is there is worth more than what might still come.
      patience_out?(t) ->
        open(
          t,
          "paciência: #{walked(t)} passos e não veio mais ninguém — matando #{count(t.s)}"
        )

      # O TETO NUMA PILHA QUE VALE ABRE, NÃO PULA. A semente sempre prometeu
      # "decide com o que apareceu", e o código pulava a pilha inteira com a
      # frase "não vale a área" — mentindo, porque ela valia. Era o que fazia
      # subir a paciência ser perigoso: passos a mais que estourassem o teto
      # viravam pilha deixada pra trás. Medido na bancada (02/09): o teto pula
      # pilha boa zero vezes nos defaults, então isto só muda o que acontece
      # quando ele SOBE a paciência — que é a hora em que precisa estar certo.
      ceiling_out?(t) and t.s.worth_fighting? ->
        open(t, "#{count(t.s)} e o teto da juntada venceu: abrindo com o que veio")

      true ->
        still_sizing(t)
    end
  end

  defp still_sizing(t) do
    cond do
      # Nothing worth having, and the clock says stop looking here. Só chega
      # aqui pilha que NÃO vale — a que vale abriu na régua, no teto.
      ceiling_out?(t) ->
        {%{t.logic | state: :skipping},
         Orders.walking(
           :skipping,
           t.band,
           "só #{count(t.s)} em #{div(t.config.size_ceiling_ms, 1_000)}s (teto da juntada): " <>
             "não vale a área — seguindo a rota"
         )}

      # AND OTHERWISE: KEEP WALKING. This branch used to stand still counting,
      # which is the one thing his own hands never do — "que que custa eu andar
      # mais 5 passos, fechar mais um, andar mais um pouquinho, juntar mais
      # monstros". The pile follows, and the walking is what makes it a pile.
      t.config.gather_piles and pile_payable?(t) ->
        {reset_fight(%{t.logic | state: :gathering}, :gathering),
         Orders.walking(:gathering, t.band, gathering_why(t))}

      # Barra vazia e sem revive que a compre: esta pilha não tem pagamento.
      # Mesma saída do teto de tempo — seguir a rota — e pelo mesmo motivo:
      # parado aqui, só um lado bate.
      t.config.gather_piles ->
        {%{t.logic | state: :skipping},
         Orders.walking(
           :skipping,
           t.band,
           "sem barra e sem revive pra comprá-la — deixando essa pilha: seguindo a rota"
         )}

      # …e sem juntada, uma pilha que NÃO vale não segura a rota: "um ou dois
      # eu ignoro e sigo a vida" (R1). Isto contava PARADO até o teto (8s) —
      # "ele vê 1 inimigo, fica parado uns segundos, diz que desistiu e volta
      # a andar; segundo sem ação, só parado, é ruim" (02/09). A contagem
      # continua a cada tique, andando: encheu, a régua para e abre.
      true ->
        {t.logic,
         Orders.walking(
           :sizing,
           t.band,
           "só #{count(t.s)} à vista — seguindo a rota, contando quem vem"
         )}
    end
  end

  # R12 — A JANELA FECHOU; AGORA DEIXA ELES CHEGAREM.
  #
  # "Fecho essa janela de mob (…) só que, quando fecho, eu tenho que aguardar,
  # por exemplo, cinco segundos, pros bichos se aproximarem do meu pokémon"
  # (27/08). A régua sabia QUANDO parar de juntar e disparava no mesmo tique —
  # e três bichos que acabaram de aparecer na lista estão longe do pokémon, não
  # em cima dele. Uma área estourada ali pega um e gasta o cooldown dos três.
  #
  # O pé PARA (a rota segura) e o fogo espera: parar é o que faz eles virem, e é
  # o que a mão dele faz. Passado o relógio, abre com tudo.
  defp open(t, why) do
    if t.config.bunch_ms > 0 do
      # O MESMO TIQUE já entra na espera e decide: parado, contando.
      logic = enter(t.logic, :bunching, t.now)

      %{t | logic: logic} |> bunching() |> narrate_open(why)
    else
      fire_all(t, why)
    end
  end

  # A razão de FECHAR a janela viaja junto com a razão de estar esperando: a
  # primeira só é dita uma vez, e é ela que explica por que a caçada parou de
  # juntar.
  defp narrate_open({logic, orders}, why), do: {logic, %{orders | why: "#{why} · #{orders.why}"}}

  # De onde contar os passos da primeira metade da espera. Vai no mesmo mapa dos
  # relógios porque tem a mesma vida: nasce com a fase e morre com ela.

  # A RAJADA DO TAMANHO DA PILHA. A abertura inteira (escudo, aura, todas as
  # áreas) é da pilha que vale a área; a que a régua já chamou de "não vale"
  # (abaixo de `engage_from`) só está sendo limpa porque a paciência acabou —
  # e limpá-la com a barra inteira foi como a barra chegou vazia na pilha de
  # verdade: "gastei minhas skills num bicho bobo" (28/08). Uma tecla de dano
  # resolve; desconhecido abre inteiro, como sempre (fail-open pra caçada).
  defp fire_all(t, why),
    do:
      {%{t.logic | state: :engaged},
       Orders.standing_and_firing(:engaged, t.band, hand_for(t), why)}

  defp hand_for(t) do
    case {Map.get(t.s, :worth_fighting?), small(t)} do
      {false, [_key | _] = small} -> small
      _worth_or_unknown_or_empty -> opening(t)
    end
  end

  defp small(%{hands: %{small: keys}}), do: keys
  defp small(_no_hands), do: []

  # `combo_left_ms == 0` só existe no Auto Combo (fora dele é `nil`): a
  # corrente acabou ou nunca saiu — e com a barra gasta as duas pedem o mesmo.
  # O chefe tem o ciclo dele; o desarme e o orçamento continuam valendo.
  defp combo_reset_due?(t) do
    Map.get(t.s, :combo_left_ms) == 0 and t.s.spent? == true and t.s.own_out? == true and
      not heavy?(t) and t.logic.reset_broken_at == nil and
      elapsed?(t, :reset_revive, t.config.reset_revive_cooldown_ms) and affordable?(t)
  end

  # PARADO ENQUANTO A CORRENTE SAI. A rota segura; o fogo fica livre de
  # propósito — a cerca do combate já recusa qualquer tecla na janela, e
  # segurar o fogo trocaria a postura pra defesa no meio da corrente. A luta
  # vira `:engaged` aqui (idempotente), pra que depois do reset, se sobrou
  # bicho, a régua continue em "matando o que já abriu" e a corrente saia de
  # novo — "quantas vezes precisarmos até matar o shiny".
  defp combo_running(t) do
    left = Map.get(t.s, :combo_left_ms, 0)

    {enter(t.logic, :engaged, t.now),
     Orders.standing_and_firing(
       :engaged,
       t.band,
       opening(t),
       "corrente saindo (#{left}ms) — parado até ela acabar, sem chamar mais ninguém"
     )}
  end

  # Rota e fogo seguros desde o pedido: o tique seguinte já é a espera pela
  # barra (`hold_until_reset_seen/2`), e a corrente volta na borda do fogo.
  defp combo_reset(t) do
    {t.logic |> mark(:reset_revive, t.now) |> mark(:reset_pending, t.now),
     Orders.standing(
       :resetting,
       t.band,
       "combo acabou com a barra gasta — revive agora, #{count(t.s)} ainda no sono",
       revive: :now
     )}
  end

  # A ESPERA, parada. Até 02/09 ela tinha uma primeira metade que andava
  # ("mais uns 5 passos" pra arrastar o bolo, 27/08); com "não dar mais nenhum
  # passo, deixar os bichos virem até mim" (02/09) o arrasto saiu. Fogo
  # segurado enquanto ela dura, e as saídas de sempre: o relógio, e a pilha
  # sumindo.
  defp bunching(t) do
    cond do
      t.s.enemies == 0 ->
        {reset_fight(t.logic, :travelling),
         Orders.walking(:travelling, t.band, "sumiram enquanto eu esperava — seguindo a rota")}

      within?(t, :bunching, t.config.bunch_ms) ->
        {t.logic,
         Orders.standing(
           :bunching,
           t.band,
           "#{count(t.s)} vindo — esperando eles fecharem em cima do pokémon"
         )}

      true ->
        fire_all(t, "#{count(t.s)} em cima e perto: estourando a área")
    end
  end

  defp gathering_why(t) do
    "juntando: #{count(t.s)} até agora, #{walked(t)} passos"
  end

  defp ceiling_out?(t), do: not within?(t, :sizing, t.config.size_ceiling_ms)

  defp walked(t), do: Map.get(t.s, :walked, 0)

  defp rushing_in?(t), do: t.s.worth_fighting? and not t.config.gather_piles

  # O ALVO DO BOLO, e não só os passos: "quando encontra dois monstros, pode
  # andar bastante até ter seis monstros; se tiver cinco monstros na tela, pode
  # andar um pouquinho e depois parar" (27/08). Com dois na tela e o passo
  # cumprido, a régua fechava a janela e abria fogo num bolo de dois — que é o
  # "usando as skills cedo demais" que ele viu.
  #
  # A paciência (`patience_tiles`) continua sendo o teto: um bolo que nunca
  # chega no alvo não pode segurar a caçada pra sempre.
  defp gathered_enough?(t), do: bolo_cheio?(t)

  defp stopped_arriving?(t), do: bolo_cheio?(t) and settled?(t)

  defp bolo_cheio?(t) do
    t.s.worth_fighting? and is_integer(t.s.enemies) and t.s.enemies >= t.config.gather_target
  end

  defp patience_out?(t), do: some?(t.s) and out_of_patience?(t)

  defp out_of_patience?(t), do: walked(t) >= t.config.patience_tiles

  defp some?(%{enemies: n}) when is_integer(n) and n > 0, do: true
  defp some?(_none_or_unknown), do: false

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
  # A TRAVA QUE ELE PEDIU. "Usei revive e diz que recuperou 5 cooldowns, mas não
  # recuperou um" — uma R3b que gasta um revive e não recebe a barra de volta é
  # uma R3b que vai gastar o próximo, e o próximo. Então ela se DESARMA na
  # primeira vez que a promessa não é cumprida.
  #
  # A cobrança é feita depois que o corpo já teve tempo de voltar: a prensa
  # tira o pokémon de campo, e enquanto ele está na bola a barra não é dele pra
  # ler. Passada essa janela, com o pokémon em campo e a barra AINDA vazia, o
  # reset não aconteceu — seja porque o jogo não zera nada, seja porque a
  # leitura mente. As duas conclusões pedem a mesma coisa: parar de pagar.
  defp audit_reset(%{logic: %{reset_broken_at: at}} = t) when is_integer(at) do
    if t.now - at >= t.config.reset_rearm_ms,
      do: %{t.logic | reset_broken_at: nil},
      else: t.logic
  end

  defp audit_reset(t) do
    case Map.get(t.logic.since, :reset_pending) do
      nil -> t.logic
      at -> judge_reset(t, at)
    end
  end

  # Três respostas, e a terceira é definitiva. O caso fica ABERTO enquanto o
  # corpo pode não ter voltado ainda ou a barra não pode ser lida; fecha
  # CUMPRIDO na primeira leitura de uma barra que voltou; e fecha QUEBRADO
  # quando, com o pokémon em campo e a janela vencida, ela ainda está vazia.
  #
  # `:reset_pending` é uma marca própria de propósito: o piso entre duas prensas
  # (`:reset_revive`) não pode ser zerado por um veredito, senão fechar o caso
  # liberaria a prensa seguinte na hora.
  # A PROMESSA VISTA fecha o caso NA HORA, dentro ou fora da janela. O juiz
  # antigo só olhava a barra DEPOIS da janela de ~6s — e numa pilha grande a
  # barra volta cheia e é despejada de novo em dois ou três segundos, que é o
  # reset FUNCIONANDO. O julgamento tardio via `spent?` de novo e condenava:
  # quanto melhor o reset trabalhava, mais certo ele quebrava. Foi o minuto 1
  # da corrida de 28/08 — cinco resets perfeitos, um veredito errado, e 39
  # minutos de "recuando pelo chão limpo" com o estoque a 700.
  # …E A PROMESSA VISTA É VISTA NA TELA. Depois do revive o relógio está
  # zerado, então `spent? == false` com a barra ilegível é o relógio falando
  # sozinho — "tudo pronto" de quem não viu nada. Cumprida só com a FOTO
  # (regra dele: "vamos validar os cooldowns por imagem"). Sem foto até o
  # prazo, o caso fecha como inverificável: nem cumprida (não zera as
  # quebras), nem quebrada (não conta strike por uma barra que ninguém leu).
  defp judge_reset(t, at) do
    cond do
      t.s.own_out? == true and t.s.spent? == false and bar_seen?(t) ->
        %{close_reset(t.logic) | reset_strikes: 0}

      t.now - at < t.config.revive_confirm_ms + reset_grace_ms(t) ->
        t.logic

      t.s.own_out? != true ->
        t.logic

      not bar_seen?(t) ->
        close_reset(t.logic)

      true ->
        judge_broken(t)
    end
  end

  # A quebra REAPERTA em vez de correr: com menos de três seguidas o caso
  # fecha, a regra continua armada, e `reset_revive?` dispara de novo já no
  # tique seguinte (o piso de 3s venceu durante o próprio julgamento). Na
  # terceira, desarma — e o porquê aparece no `disarmed_note`.
  defp judge_broken(t) do
    strikes = t.logic.reset_strikes + 1
    broken_at = if strikes >= 3, do: t.now, else: nil

    %{close_reset(t.logic) | reset_broken_at: broken_at, reset_strikes: strikes}
  end

  defp close_reset(logic), do: %{logic | since: Map.delete(logic.since, :reset_pending)}
  defp arm_kite(%{logic: %{kite_from: from} = logic}) when is_integer(from), do: logic

  defp arm_kite(t),
    do: %{mark(t.logic, :kiting, t.now) | kite_from: Map.get(t.s, :walked_total, 0)}

  # A fuga pertence a UMA luta: sair de `:engaged` a esquece, senão a próxima
  # herdaria o veredito da anterior.
  defp forget_kite(logic), do: %{logic | kite_from: nil, since: Map.delete(logic.since, :kiting)}

  # O corpo volta em `revive_settle_ms`, que é do MUNDO e não deste módulo — a
  # janela aqui é generosa de propósito: cobrar cedo demais desarmaria a regra
  # por causa de um tique, e desarmar é definitivo.
  defp reset_grace_ms(t), do: max(t.config.rescue_cooldown_ms, 5_000)

  defp reset_revive?(%{logic: %{reset_broken_at: at}}) when is_integer(at), do: false

  defp reset_revive?(t) do
    t.config.reset_revive and not mid_combo?(t) and t.s.spent? == true and
      t.s.own_out? == true and
      is_integer(t.s.enemies) and t.s.enemies >= t.config.engage_from and
      healthy_enough?(t) and elapsed?(t, :reset_revive, t.config.reset_revive_cooldown_ms) and
      affordable?(t)
  end

  # O ORÇAMENTO: as regras que COMPRAM conveniência com revive (chegar
  # preparado, resetar a barra) só gastam enquanto sobra mais que a reserva.
  # A emergência, a faixa amarela e o caído NUNCA passam por aqui — os últimos
  # revives do bolso são deles, que é o que uma reserva é. `nil` é orçamento
  # desligado (ele não contou o estoque) e não muda nada.
  defp affordable?(t) do
    case Map.get(t.s, :revive_left) do
      nil -> true
      left -> left > t.config.revive_reserve
    end
  end

  # A pile is PAYABLE while there is a bar to spend on it — or a revive that
  # buys the bar back (R3b). With neither, gathering is aggro with no answer:
  # the rule the 25/08 sweep refuted ("não se abre pilha com a barra vazia")
  # was about the bar ALONE, measured before the real 40-50s cooldowns and
  # before the reserve existed; this one only closes the door when the revive
  # is ALSO gone, which is the night the stock ran out.
  defp pile_payable?(t) do
    t.s.spent? != true or reset_possible?(t)
  end

  defp reset_possible?(t) do
    t.config.reset_revive and t.logic.reset_broken_at == nil and affordable?(t)
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
    do: %{forget_kite(logic) | state: state, since: Map.drop(logic.since, [:sizing, :closing])}
end
