defmodule Pokex.Bots.Engine.Situation do
  @moduledoc """
  The shared tactical picture: what is TRUE right now, before anybody decides
  anything.

  Three processes have been answering "how many monsters are there?" separately
  — and the one that revives the pokémon never asked at all. `PlayerSupport`
  decides on a health bar and nothing else, which is why a revive fires at 60%
  in the middle of a live pile, with every cooldown still up, throwing away both
  halves of what a revive is worth (Lucas, 2026-08-17: "quem manda ser tomada
  uma poção ou reviver um pokémon não deveria ser só um observador da vida,
  puramente, porque não é puro assim").

  So the reading moves here, once, and everyone reads the same picture.

  Pure on purpose: it takes observations already pulled off the blackboard and a
  monotonic `now`, and returns a map. No ETS, no clock, no captures — the whole
  thing is a table test.

  ## `own_out?` has three answers, not two

  `true` is "the bar reads, so the pokemon is on the field". `false` is a
  PROVEN absence — the support saw a live bar fall below the faint line and then
  vanish for two straight reads. `:unknown` is everything else: a minimised
  party window, a stale fact, a frame the reader did not recognise.

  Two answers were enough while nobody acted on the absence. They stopped being
  enough the moment `Logic` gained a rule that refuses to fight without a body
  on the field: with `false` also meaning "I could not read it", one bad frame
  would have stopped the hunt.

  ## `nil` is a legal answer

  An empty screen and an unreadable screen are the same pixels to a counter and
  opposite facts to a decision. Zero means "nothing is there"; `nil` means "I
  cannot see". Whoever consumes this decides what to do with not knowing — that
  choice belongs to the consumer's fail-open rule, never to the picture.

  ## The own row

  `enemies` deliberately excludes his own pokémon, "lembrando de não contar o
  próprio" (2026-08-17). It is excluded BY NAME, not by position: the panel's
  order is the game's business, and a rule that trusts "row 0 is mine" breaks
  the day it isn't.

  The name comes from `enemies_detail`, which needs the located layout he does
  not run with. So there are two more ways to find his row, in order of how much
  they know:

    * **By health.** His health is read twice by two readers that know nothing
      of each other — the Pokebar and the row's own track — and when exactly one
      unreadable row matches, that agreement names the row without a glyph.
    * **By position.** The first unreadable row, which his own measurement of
      2026-08-18 puts at row 0 in 134 of 140 readings.

  `own_row_seen?` says WHICH of the four answered, because a discount made on a
  guess must never look like one made on a name.

  ## The measurement is closed, and he was right

  Whether his pokémon takes a row was an open question — `interpret.ex:44` had a
  reading saying it does not appear; he said it is always the first row. His
  hunt of 2026-08-18 settled it: row 0 was his pokémon in **134 of 140**
  readings, and `own_row_seen?` came back `false` in **all 134** filed
  decisions. It appears, and the by-name discount never fired.

  The reason is the trap: his Vespiquen's name reads as `nil` (the glyphs for it
  were never taught), and a name that cannot be read can never match. So every
  count that night was inflated by exactly one — which opened the area on 12
  piles of two, and walked away from 6 monsters that were still alive.

  So the name is no longer the only way to find his row. When his pokémon is on
  the field and NO row matched by name, the first unreadable row is his. That is
  narrower than subtracting one in the dark: it keeps the named list and the
  count consistent, it does nothing when every row is legible, and it does
  nothing when his pokémon is not out. `own_row_seen?` answers `:unnamed` there,
  so the screen can say which of the two ways found it — a discount made on a
  guess must never look like one made on a name.
  """

  @type t :: %{
          rows: non_neg_integer | nil,
          enemies: non_neg_integer | nil,
          named: [map],
          own_row_seen?: boolean | :unnamed | :by_hp | nil,
          worth_fighting?: boolean,
          heavy?: boolean,
          grit: non_neg_integer,
          heavy_latch?: boolean,
          boss_tiles: non_neg_integer | nil,
          boss_asleep_left_ms: non_neg_integer | nil,
          growing?: boolean,
          stable_since: integer,
          stable_for_ms: non_neg_integer,
          pos: {integer, integer, integer} | nil,
          walked_total: non_neg_integer,
          pile_walk_at: non_neg_integer,
          walked: non_neg_integer,
          own_hp: 0..100 | nil,
          # A VIDA DELE, e quanto ela caiu desde a foto anterior (0 sem queda).
          player_hp: 0..100 | nil,
          player_drop: non_neg_integer,
          own_out?: boolean | :unknown,
          ready_keys: [String.t()] | nil,
          combo_left_ms: non_neg_integer | nil,
          bar_seen?: boolean,
          spent?: boolean | nil,
          prepared?: boolean | nil,
          control_back_in_ms: non_neg_integer | nil,
          revive_left: non_neg_integer | nil,
          blind?: boolean,
          at: integer
        }

  @doc """
  Builds the picture from what was read this tick.

  `inputs` carries `:battle` (the fact's observation, or `nil` when missing or
  stale), `:own_hp`, `:own_out?` (`true | false | :unknown`), `:own_name`,
  `:ready_keys` (or `nil` when the bar could not be read), `:damage_keys` (this
  pokémon's area + single keys), `:pos` (where he is standing, for the distance
  half of the ruler) and `:prev` — the previous picture, which is what makes
  "is the pile still growing?" and "how far have I walked for it?" answerable.

  `config` carries `:engage_from`.
  """
  @spec build(map, map, integer) :: t
  def build(inputs, config, now) do
    battle = read_battle(Map.get(inputs, :battle), inputs)

    prev = Map.get(inputs, :prev)
    {growing?, stable_since} = settle(battle.enemies, prev, now)
    {walked_total, pile_at} = pace(battle.enemies, Map.get(inputs, :pos), prev)

    grit =
      grit(battle.enemies, Map.get(inputs, :ready_keys), Map.get(inputs, :damage_keys, []), prev)

    latch? = latch?(battle.enemies, grit, prev, config)

    %{
      rows: battle.rows,
      enemies: battle.enemies,
      named: battle.named,
      own_row_seen?: battle.own_row_seen?,
      # O CHEFE, por NOME: alguma linha inimiga da janela bate com a lista
      # `boss_names` do /config. É o gatilho da postura de chefe do cérebro —
      # e passa por cima da régua, porque um chefe sozinho vale a luta que
      # cinco bichos comuns valem.
      heavy?: heavy?(battle.named, config) or latch? or especial?(inputs),
      # O CHEFE, pelo TEMPO DE MATAR: skills de dano ENTREGUES (saíram da barra)
      # sem NENHUM corpo cair da pilha. Nome nenhum — "ele tem o mesmo nome que
      # os outros pokémons" (31/08). Medido na noite fraca de 31/08 (3h42): o
      # máximo que uma pilha comum engole é 4 entregas (p99 = 3); um chefe 10×
      # engole o dobro em dois giros da barra. `heavy_latch?` é a memória: uma
      # vez declarado, o chefe segue chefe até a pilha ZERAR — matar um bicho
      # comum do lado dele zera o grit, não a declaração.
      grit: grit,
      heavy_latch?: latch?,
      # A QUE DISTÂNCIA O CHEFE ESTÁ, em tiles — nil quando ninguém mede. O
      # stun tem raio: apertá-lo com o chefe a 6 tiles é dormir o vento
      # (medido na bancada: o primeiro stun saía a 6 e o chefe chegava
      # acordado). No simulador o mundo responde; no jogo, o CrowdScan é quem
      # sabe — e enquanto não estiver ligado aqui, nil deixa o stun sair na
      # hora, que é o comportamento de antes.
      boss_tiles: Map.get(inputs, :boss_tiles),
      # QUANTO FALTA DO SONO DO CHEFE (ms) — 0 acordado, nil sem testemunha.
      # O carimbo do cérebro diz o que ele MANDOU; isto diz o que o CHEFE
      # sentiu — e a diferença é um stun que pegou o vento (pokémon na bola,
      # alvo fora do raio, lag). Com o canal, a postura de chefe mede o ciclo
      # pelo sono real e reaperta de graça um stun que não pegou.
      boss_asleep_left_ms: Map.get(inputs, :boss_asleep_left_ms),
      worth_fighting?:
        worth_fighting?(battle.enemies, config) or heavy?(battle.named, config) or latch? or
          especial?(inputs),
      growing?: growing?,
      stable_since: stable_since,
      stable_for_ms: now - stable_since,
      pos: Map.get(inputs, :pos),
      walked_total: walked_total,
      pile_walk_at: pile_at,
      walked: walked_total - pile_at,
      own_hp: Map.get(inputs, :own_hp),
      player_hp: Map.get(inputs, :player_hp),
      player_drop: player_drop(Map.get(inputs, :player_hp), prev),
      own_out?: Map.get(inputs, :own_out?, :unknown),
      ready_keys: Map.get(inputs, :ready_keys),
      # QUANTO FALTA PRO CONTROLE VOLTAR, em ms — nil quando ninguém sabe. É o
      # que transforma "precisa de controle" numa espera com prazo em vez de uma
      # trava sem saída, e sai do relógio das teclas (`Pokex.Bots.SkillClock`).
      control_back_in_ms: Map.get(inputs, :control_back_in_ms),
      # O CADERNINHO DO ESTOQUE (`Pokex.Bots.ReviveLedger`): quantos revives
      # restam pela conta dele, ou nil com o orçamento desligado. É o que separa
      # "revive é de graça" (o simulador devolve tudo por 500ms) de "revive é um
      # item que acabou às 23:43" (a noite de 27→28/08).
      revive_left: Map.get(inputs, :revive_left),
      # QUANTO FALTA DA CORRENTE DO JOGO (`Combat.Combo`), em ms — nil quando esta
      # caçada não tem combo. É a testemunha que impede um revive de recolher o
      # pokémon com metade das skills por sair: a corrente é indivisível, e
      # cortá-la joga fora o dano que ela ainda ia entregar.
      combo_left_ms: Map.get(inputs, :combo_left_ms),
      # A BARRA FOI LIDA NA TELA? `ready_keys` cruza a foto com o relógio, e
      # depois de um revive o relógio está zerado — então "tudo pronto" pode
      # ser a foto ou pode ser ninguém. O reset é cobrado POR IMAGEM (regra
      # dele, 01/09): sem foto, a promessa fica em aberto.
      bar_seen?: Map.get(inputs, :bar_seen?, false),
      spent?:
        spent?(
          Map.get(inputs, :damage_keys, []),
          Map.get(inputs, :ready_keys),
          Map.get(config, :spent_keys_left, 0)
        ),
      # A OUTRA PONTA DO `spent?`: a barra está INTEIRA? É a pergunta que a
      # regra de chegar preparado no próximo grupo faz, e ela não é a negação de
      # `spent?` — entre "gastou tudo" e "está inteira" cabe a barra pela
      # metade, que é onde ele vive.
      prepared?: prepared?(Map.get(inputs, :damage_keys, []), Map.get(inputs, :ready_keys)),
      blind?: Map.get(inputs, :battle) == nil,
      at: now
    }
  end

  # No reading at all: everything about the screen is unknown. Not zero.
  defp read_battle(nil, _inputs),
    do: %{rows: nil, enemies: nil, named: [], own_row_seen?: nil}

  defp read_battle(battle, inputs) do
    rows = length(Map.get(battle, :enemies, []))
    detail = Map.get(battle, :enemies_detail, [])

    cond do
      rows == 0 ->
        %{rows: 0, enemies: 0, named: [], own_row_seen?: false}

      detail == [] ->
        # No description of the rows at all, so the own row cannot be told from
        # an enemy. Raw count, unknown stated.
        %{rows: rows, enemies: rows, named: [], own_row_seen?: nil}

      true ->
        {mine, theirs} = Enum.split_with(detail, &mine?(&1, Map.get(inputs, :own_name)))
        by_name_or_by_absence(rows, mine, theirs, inputs)
    end
  end

  # Found by name: the precise way, and the only one that works when his pokémon
  # is not the first row.
  defp by_name_or_by_absence(rows, mine, theirs, _inputs) when mine != [],
    do: %{rows: rows, enemies: length(theirs), named: theirs, own_row_seen?: true}

  # Nothing matched by name, but his pokémon IS on the field — so one of these
  # rows is his and the reader could not spell it. If every row is legible
  # nothing is taken away: a legible list that does not contain him means he
  # really is not in it.
  defp by_name_or_by_absence(rows, _none, theirs, %{own_out?: true} = inputs) do
    case Enum.split_with(theirs, &(&1.name == nil)) do
      {[], _all_legible} ->
        %{rows: rows, enemies: rows, named: theirs, own_row_seen?: false}

      {unreadable, legible} ->
        {how, others} = own_among(unreadable, Map.get(inputs, :own_hp))

        %{
          rows: rows,
          enemies: length(legible ++ others),
          named: legible ++ others,
          own_row_seen?: how
        }
    end
  end

  # He is not on the field, so no row is his — an unreadable row here is a
  # monster whose name the glyphs do not know yet, and taking it off the count
  # would be walking away from something real.
  defp by_name_or_by_absence(rows, _none, theirs, _not_out),
    do: %{rows: rows, enemies: rows, named: theirs, own_row_seen?: false}

  # WHICH unreadable row is his, when no name can say it.
  #
  # His health is read twice, from two places that do not know about each other:
  # the Pokebar (`own_hp`) and the row's own track. They agree — measured on his
  # capture of 2026-08-27, the single remaining row read 67% while the Pokebar
  # read 69 — and that agreement names the row without a single glyph. It is
  # used only to CHOOSE among rows already known to be unreadable, and only when
  # exactly one of them matches: two rows at the same health is a coin toss, and
  # the fallback (the first, his own measurement of 2026-08-18: row 0 in 134 of
  # 140 readings) is what a coin toss should defer to.
  #
  # The slack is wide because the two readings are two different CAPTURES: the
  # battle feed and the party bar are read on their own clocks, and a pokémon
  # losing health fast is a different number in each. It only has to be narrow
  # enough to tell one row from another, and it never decides the COUNT — his
  # pokémon takes a row whether or not this says which one.
  @hp_slack 8

  defp own_among([first | rest], own_hp) when is_integer(own_hp) do
    case Enum.filter([first | rest], &hp_near?(&1, own_hp)) do
      [only] -> {:by_hp, Enum.reject([first | rest], &(&1 == only))}
      _none_or_many -> {:unnamed, rest}
    end
  end

  defp own_among([_first | rest], _no_hp), do: {:unnamed, rest}

  defp hp_near?(%{hp_pct: pct}, own_hp) when is_number(pct),
    do: abs(round(pct * 100) - own_hp) <= @hp_slack

  defp hp_near?(_row_without_bar, _own_hp), do: false

  defp mine?(_row, nil), do: false

  defp mine?(%{name: name}, own_name) when is_binary(name) and is_binary(own_name),
    do: bare(name) == bare(own_name)

  defp mine?(_row, _own_name), do: false

  # `team.json` says "Shiny Vileplume"; the panel reads "Vileplume" (his capture
  # of 2026-08-11). The prefix is a property of the creature, not of the row, and
  # it must never make the bot count itself among its enemies.
  defp bare(name) do
    name
    |> String.trim()
    |> String.downcase()
    |> String.replace_prefix("shiny ", "")
  end

  # "Pararam de chegar" is the signal a gathering ends on, so only GROWTH
  # restarts the clock. A pile that is dying shrinks the list, and that is the
  # opposite of one still walking in.
  defp settle(nil, _prev, now), do: {false, now}

  defp settle(enemies, %{enemies: was, stable_since: since}, now)
       when is_integer(was) and is_integer(since) do
    if enemies > was, do: {true, now}, else: {false, since}
  end

  defp settle(_enemies, _no_history, now), do: {false, now}

  # HIS RULER HAS TWO AXES, and this is the second one: "andei dois passos e
  # achei três inimigos, só que eu só andei dois passos. Que que custa eu andar
  # mais 5 passos, juntar mais monstros e aí matar todo mundo já ao redor"
  # (2026-08-25). A count alone cannot tell a pile that is worth growing from
  # one that has already been walked for.
  #
  # `walked_total` is a monotonic tile counter and `pile_walk_at` is where it
  # stood when THIS pile started — so `walked` answers "how far have I walked
  # since the first monster of this one showed up", which is the number his
  # sentence is about. A pile ending (or the screen going unreadable) rearms it.
  #
  # Chebyshev, because the game's diagonal is one step.
  defp pace(enemies, pos, prev) do
    total = Map.get(prev || %{}, :walked_total, 0) + steps(Map.get(prev || %{}, :pos), pos)
    was = Map.get(prev || %{}, :enemies)

    if pile_started?(was, enemies),
      do: {total, total},
      else: {total, Map.get(prev || %{}, :pile_walk_at) || total}
  end

  defp pile_started?(was, enemies),
    do: is_integer(enemies) and enemies > 0 and (is_nil(was) or was == 0)

  defp steps({x1, y1, z}, {x2, y2, z}), do: max(abs(x2 - x1), abs(y2 - y1))
  defp steps(_no_reading, _or_another_floor), do: 0

  # R1, his ruler: "se tem 1 ou 2 monstros, eu às vezes até ignoro aquele mob e
  # sigo a minha vida (…) eu realmente mato quando tem uns três". Not knowing is
  # not worth fighting either — that call belongs to the consumer.
  # Quanto a vida DELE caiu entre duas fotos — só cai, nunca sobe: uma leitura
  # ruim para cima não vira "sangrando" na volta.
  defp player_drop(hp, %{player_hp: before}) when is_integer(hp) and is_integer(before),
    do: max(before - hp, 0)

  defp player_drop(_hp, _sem_anterior), do: 0

  defp worth_fighting?(enemies, config) when is_integer(enemies),
    do: enemies >= Map.fetch!(config, :engage_from)

  defp worth_fighting?(_unknown, _config), do: false

  # Sem nome legível não há chefe: a comparação é caso-insensível, e a lista
  # aceita a forma do /config ("Chefe, Boss X") e a de um cenário (["chefe"]).
  defp heavy?(named, config) do
    case boss_names(Map.get(config, :boss_names)) do
      [] -> false
      names -> Enum.any?(named, &(String.downcase(Map.get(&1, :name) || "") in names))
    end
  end

  # QUANTAS SKILLS DE DANO A PILHA JÁ ENGOLIU sem um corpo cair. Uma entrega é
  # uma tecla de dano que estava pronta no tique anterior e saiu da barra neste
  # (cooldown andou = recibo de que o jogo aceitou — tecla engolida continua
  # pronta e não conta). Só teclas de DANO: o ciclo stun+revive do próprio
  # chefe não pode inflar o medidor que o declara.
  #
  # Zera quando um corpo cai (a pilha encolheu) ou a tela limpa; barra ilegível
  # não conta nem zera. Kite, espera de cooldown e cegueira não somam nada —
  # foi exatamente isso que separou o chefe da pilha comum na medição: "spent +
  # pilha parada" dava 28 falsos chefes/hora, entregas sem queda deram ZERO.
  # Um corpo caindo DESCONTA o preço típico de um kill em vez de zerar: numa
  # pilha mista (chefe + comuns) cada comum que morre zerava o medidor e o
  # chefe comia de graça durante a recontagem — a bancada mediu o tanque em
  # 5-41% pagando essa latência. Com o desconto, o excedente que o chefe
  # engoliu sobrevive aos kills dos comuns. O preço (4) é o máximo que a noite
  # fraca de 31/08 entregou por corpo (p99 = 3) — e com ele o medidor da noite
  # inteira nunca passou de 4, zero falsos chefes.
  @kill_cost 4

  defp grit(enemies, ready, damage_keys, prev) do
    was = Map.get(prev || %{}, :enemies)
    before = Map.get(prev || %{}, :grit, 0)
    fired = fired_count(ready, Map.get(prev || %{}, :ready_keys), damage_keys)

    cond do
      not is_integer(enemies) -> before
      enemies == 0 -> 0
      is_integer(was) and enemies < was -> max(before - @kill_cost * (was - enemies), 0)
      true -> before + fired
    end
  end

  defp fired_count(ready, was_ready, damage_keys)
       when is_list(ready) and is_list(was_ready) do
    was_ready
    |> Enum.filter(&(&1 in damage_keys))
    |> Enum.count(&(&1 not in ready))
  end

  defp fired_count(_unreadable, _or_no_history, _damage_keys), do: 0

  # A declaração LATCHA: o gatilho é o grit cruzar o knob, e a memória segura a
  # postura até a pilha zerar — sem ela, o primeiro corpo comum caindo do lado
  # do chefe (ou o F4 devolvendo a barra) despia a postura no meio da luta.
  # `boss_grit` 0 = desligado, só o nome declara.
  defp latch?(enemies, grit, prev, config) do
    knob = Map.get(config, :boss_grit, 0)
    alive? = is_integer(enemies) and enemies > 0

    cond do
      not alive? -> false
      Map.get(prev || %{}, :heavy_latch?, false) -> true
      is_integer(knob) and knob > 0 and grit >= knob -> true
      true -> false
    end
  end

  # O ESPECIAL PELA COR — o terceiro caminho, e o único que enxerga ANTES de
  # apanhar. O nome não separa nada no Poké Alliance ("ele tem o mesmo nome
  # que os outros pokémons") e o grit precisa da luta já aberta: contra o
  # especial solitário abaixo da régua, e contra o que a mobada arrasta junto,
  # os dois chegam tarde. A cor chega na hora — é a regra que ele ensinou e
  # PROVOU na calibração, vista pelo `ShinyGuard`.
  #
  # E ela liga a postura INTEIRA porque o bicho é um só: "o shiny É o chefe"
  # (01/09). Vale a luta fora da régua, não se kita (a R7 já se cala com
  # `heavy?`), e o combo skills → stun → revive é exatamente o que ele descreve
  # pra esse monstro. A bola garantida vem do Catcher, pelo mesmo avistamento.
  defp especial?(inputs), do: Map.get(inputs, :especial?) == true

  defp boss_names(nil), do: []
  defp boss_names(names) when is_list(names), do: Enum.map(names, &String.downcase/1)

  defp boss_names(names) when is_binary(names) do
    names
    |> String.split(",", trim: true)
    |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    |> Enum.reject(&(&1 == ""))
  end

  # O REVIVE VALE MAIS QUANDO OS COOLDOWNS JÁ FORAM (R3), então a foto precisa
  # saber dizer que foram. Sem leitura da barra, ou sem tecla classificada, a
  # resposta é DESCONHECIDO e não "não".
  #
  # `spent_keys_left` é quantas teclas de dano ainda prontas ele aceita chamar
  # de "acabou". Era METADE, cravado — com sete teclas de dano o revive saía com
  # três na mão, e ele viu isso na caçada: "ele usa muito ressurect à toa (…) a
  # gente tem que usar todas as skills, para depois usar um ressurect, porque
  # ele tem um certo custo que não é de graça" (27/08). Zero é a regra dele; o
  # knob existe porque a folga de uma tecla pode valer a pena quando a que
  # sobrou é a mais fraca da barra, e isso é medição, não opinião.
  # Sem tecla classificada, ou sem leitura da barra, é DESCONHECIDO — e quem lê
  # trata desconhecido como "não mexe", que é o lado barato de errar aqui: um
  # revive a menos custa alguns segundos de cooldown, um revive a mais no meio
  # de uma pilha acordada custa o pokémon.
  defp prepared?([], _ready), do: nil
  defp prepared?(_damage, nil), do: nil
  defp prepared?(damage, ready), do: Enum.all?(damage, &(&1 in ready))

  defp spent?([], _ready, _left), do: nil
  defp spent?(_damage, nil, _left), do: nil

  defp spent?(damage, ready, left) do
    Enum.count(damage, &(&1 in ready)) <= left
  end
end
