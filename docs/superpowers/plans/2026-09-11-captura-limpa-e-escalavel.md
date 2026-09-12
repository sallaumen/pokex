# A captura limpa e escalável — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deixar o subsistema de auto-captura com UM caminho que funciona (vigia → brilho → rastro → âncora → bola → conferência), sem peso morto, com um só relato do que o Catcher está fazendo, uma bancada que repete episódios reais da caixa-preta, e uma costura pronta pra escolher a bola por alvo — sem mudar o que já captura hoje (19:43 de 11/09: "caiu em 1418,918" → "bola" → "capturado").

**Architecture:** Hoje `Catcher.Worker` (1.759 linhas) carrega cinco eras: a varredura comum por acervo de sprites (`SpotScan`/`CorpseLibrary`), a mira por COR do corpo (`ShinyAim`, sessões `:sighting`/`:cue`), o brilho + rastro + âncora (`ShinyGuard`/`Sparkle`/`Trail`), o "varrer" do modo Parado (`Sweep`) e portões de eras anteriores (feed `:corpses` aposentado, primitivo `capture_sequence` do Rig). O plano tira o que está morto ou demonstradamente inútil (a mira por cor achou 0 px em 100 % das rodadas de 11/09 — o corpo não tem a cor viva, #601), fixa o rastro no que a tela mostra, unifica o fato `:capture` num módulo só, divide o worker em `Hunt` (rastro/âncora) + `Narration` (frases) + o GenServer, e abre a escolha da bola por alvo. **A captura de corpos comuns (o acervo de sprites: `SpotScan`, `CorpseLibrary`, a lente `:corpse_scan` da `Logic`, `capture_enabled`) e o "varrer" (`Sweep`) FICAM INTEIROS:** virá um modo "captura tudo que mata" (há caçadas que não são só de shiny), e esse modo nasce em cima deles. Cada tarefa é um PR verde por si; a bancada (Task 0) e a captura das 19:43 são a rede.

**Tech Stack:** Elixir/OTP (GenServer, PubSub, `Pokex.WorldState`), ExUnit, `Pokex.Bots.Catcher.{Worker, Logic, Trail, Ball, Balls, SpotScan, CorpseLibrary}`, `Pokex.Bots.{ShinyGuard, CrowdScan, Engine}`, `Pokex.Vision.{Sparkle, CreatureMarks, CreatureFence}`, Phoenix LiveView (`cavebot_live`, `panel_live`, `config_live`).

## Global Constraints

- **Branch por PR a partir de `origin/main`**, no worktree (`git checkout -b <nome> origin/main`); nunca trabalhar em `~/projects/pokex`; nunca `mix run` nem subir servidor (o servidor vivo dele está na porta 4004 e `~/.pokex` é compartilhado com ele).
- **Identificadores, comentários e nomes de teste em inglês** (sem acento em nome de teste); **só texto de feed/diário/UI em pt-BR**. Frases de log que algum teste já afirma (`assert_log_eventually("…")`) ficam VERBATIM.
- **Gate por PR, nesta ordem:** `mix format` → só os arquivos de teste tocados durante o trabalho → `MIX_ENV=test mix precommit` completo em segundo plano (1–2 h na máquina dele com o jogo aberto; falha de teste por tempo em arquivo NÃO tocado: re-rodar SÓ aquele arquivo, e só então chamar de flake) → `mix credo` (nos tocados e completo) → `mix dialyzer` → commit → `git push -u origin <branch>` → `gh pr create --body-file` → `gh pr checks --watch --fail-fast` → `gh pr merge --squash --delete-branch` → `git push origin --delete <branch>` (se sobrou) → `git checkout --detach origin/main`.
- **Nunca remover uma chave de `Settings`.** Tirar uma chave faz o build se declarar mais velho que o `settings.json` dele e o Settings passa a LER sem ESCREVER (#506/#507). Chave aposentada: mantém o default em `lib/pokex/settings.ex`, tira todo leitor, e move o rótulo para o grupo `"Aposentadas"` em `lib/pokex/settings/locked.ex` (ver `ball_rules` como modelo, `locked.ex:222-224`). O conserto do crachá é dívida fora deste plano.
- **Repo público:** nenhum nome de jogador em fixture ou teste; os fixtures desta pasta (`test/fixtures/captura/`) carregam só pontos e contagens.
- **A captura de corpos comuns NÃO é apagada nem enfraquecida** (ordem dele, 11/09): `SpotScan`, `CorpseLibrary`, o acervo ensinado na Calibração, `scan_obs/1`, a lente `:corpse_scan` da `Logic`, `capture_enabled`, `corpse_*`, e o `Sweep` ("varrer") ficam como estão. Só o que é demonstradamente morto (Task 1) ou a mira por COR do corpo do SHINY (Task 2, D1) saem. Toda tarefa que tocar o worker mantém `scan_obs/1` → `advance/2` → bola comum funcionando (os testes "the ordinary…"/"pending_corpses rides the snapshot…" de `worker_test.exs` são a prova).
- **Grep no shell dele é função:** use `/usr/bin/grep`.
- **A rede de proteção:** `test/pokex/bots/catcher/trail_replay_test.exs` (Task 0) e os testes "the shiny's bar followed until it falls buys the ball at the cue, with no colour at all", "with the feet still, the ball flies at the fall without waiting for the cue" e "the anchor's ball survives a scan stamped in the same instant" em `test/pokex/bots/catcher/worker_test.exs` nunca são apagados nem afrouxados: são a captura das 19:43.
- **Commit por tarefa**, mensagem em pt-BR no estilo do repo (título = a frase da lição; corpo = o que o diário mostrou), `Co-Authored-By` do modelo executor.

## Duas decisões que são do Lucas (defaults abaixo valem se ele não disser nada)

- **D1 — aposentar a mira por COR do corpo (Task 2).** Evidência: em 11/09 toda sessão (`:sighting` de 90 s e `:cue` de 6 s) fechou com "maior mancha do tom 0 px"; o corpo do shiny não tem a cor do vivo (#601, memória `o-corpo-nao-tem-a-cor-viva`); a sessão de 70 s das 19:50 queimou o teto do "segurar pra bola" e deixou "shiny na tela / mirando" no azulejo com o bicho longe. A detecção do shiny VIVO pela cor (`ColorRules` no vigia, o tom ensinado) FICA — é outro assunto. **Default: aposentar.** Pra manter, pule a Task 2 e ajuste a Task 4 (o fato continua com `aiming?`).
- **D2 — o "varrer" FICA (decidido por ele em 11/09).** `sweep_enabled` é `false` por padrão e ele caça, mas o varrer é a forma crua de "capturar o chão", e virá um modo que captura tudo que mata. A Task 6 deste plano foi retirada; o varrer só é tocado pela Task 5 (muda de lugar dentro do worker, sem mudar de comportamento).

## O modo "captura tudo que mata" (fora deste plano; o plano o respeita)

Há caçadas que não são só de shiny: nelas, todo corpo que cai merece a bola. A direção, pra quem for desenhar depois (e pra ninguém apagar o que ele vai usar):

- **O rastro já segue TODAS as barras** (`Trail.observe/4` cria um track por bicho; só o caçado — `hunted?` — vira âncora ao cair). O modo nasce de uma regra a mais: com `capture_all_kills` (chave nova) ligado, todo track que cai com a lista vazia vira âncora, e `throw_at_anchors/1` joga nelas na hora da bola — sem acervo, sem cor. O `free?` (nunca em cima de bicho de pé) e o `corpse_max_balls` já limitam o gasto.
- **O acervo de sprites (`SpotScan`/`CorpseLibrary`) segue sendo a confirmação e a escolha da bola por espécie** (`Balls.key_for(name, :corpse)`): um corpo reconhecido pelo acervo diz o NOME, e o nome escolhe a bola (Task 7 deixa essa costura pronta).
- **O varrer (`Sweep`)** fica como a rede de segurança do modo Parado (pesca) até esse modo existir; se o modo o tornar redundante, aí se aposenta — noutro plano, com a evidência.

## Mapa de hoje (o que cada peça faz, pra quem nunca abriu o código)

```
ShinyGuard (0,7 s)  ── Sparkle.find (a estrela ao lado do nome) ──► {:shiny_on_screen, vistos}  ──► Worker.hunt/2 ──► Trail.hunt_at
CrowdWatch (4/s)    ── {:crowd, reading} ──► Worker.follow/2 ──► CrowdScan.mark_special + Trail.observe ──► say_falls ──► ball_the_fall
Engine (200 ms)     ── {:capture_now} na rodada fechada ──► Worker: scan_obs (acervo) + throw_at_anchors + aim_by_colour_at_cue (D1)
Worker.throw_at_anchors ──► Observation (source :shiny_aim, diag anchor) ──► Logic.step ──► {:capture_sequence} ──► Balls.key_for ──► Ball.sequence ──► Body.perform(:high)
Logic (puro)        ── fila, arremesso, conferência (`captured_at`, `walked?`, `other_lens?`), ignorados, bolas secas
Fato :capture       ── publish_capture: %{aiming?, pending, corpses, armed?} ──► Engine.capturing?/catcher_armed? (segura os pés)
Snapshot {:catcher} ── broadcast: pending_corpses, aim?, hold_reason, trail… ──► Cavebot.Worker, PlayerSupport.Worker, Central, Painel
```

Referências de linha abaixo são de `origin/main` em `2c580fe7` (#616); re-localize com `/usr/bin/grep -n` antes de editar.

---

### Task 0: A bancada da captura (ENTREGUE junto com o plano)

**Files:**
- Create: `test/support/trail_replay.ex` (`Pokex.TrailReplay`)
- Create: `test/fixtures/captura/2026-09-11-1943-queda-limpa.jsonl`, `test/fixtures/captura/2026-09-11-1950-gemeos.jsonl`
- Create: `test/pokex/bots/catcher/trail_replay_test.exs`

**Interfaces:**
- Produces: `Pokex.TrailReplay.run(path) :: %{anchors: [map], falls: [%{t: integer, screen: {integer, integer}, world: {float, float}}], hunted: map | nil, looks: non_neg_integer}` e `Pokex.TrailReplay.replay([look]) :: result` (um `look` é o mapa decodificado de uma linha do jsonl: `"t"`, `"me"`, `"pos"`, `"hostiles"` `[[x, y, hp]]`, `"pet"`, `"vistos"` `[[x, y, px]]`, `"listed"`, `"enemies"`, `"route"`).
- O replay alimenta `Trail.observe/4` com `%{read?: true, me:, hostiles:, pet:, shiny_on?: vistos != [], pile_dead?: listed <= 1}` depois de `CrowdScan.mark_special/3`, e `Trail.hunt_at/6` com cada visto meio tile abaixo — exatamente `Worker.follow/2` e `Worker.hunt/2`. `listed` é a lista crua COM a linha do pokémon dele: 1 = pilha morta.

- [x] **Step 1:** harness, fixtures e teste escritos e verdes: `MIX_ENV=test mix test test/pokex/bots/catcher/trail_replay_test.exs` → `2 tests, 0 failures`.
  - 1943: UMA queda em `{1418, 918}` entre 6 e 8 s; uma âncora "Shiny (brilho)".
  - 1950 (comportamento de HOJE, fixado): UMA queda em `{1720, 918}` — um tile à direita do corpo (as conchas em ~1569,990; o último brilho pôs o nome em x 1418 em t=20_192). A Task 3 muda esta expectativa.

**Como gerar um fixture novo** (quando ele mandar o horário de um shiny): copie `~/.pokex/captures/incidents/<carimbo>-shiny/manifest.jsonl` ANTES da rotação (só 6 episódios ficam), e converta com o mesmo mapeamento do harness: uma linha por entrada com `crowd.read? == true`, `t` = ms desde a primeira entrada, `me = crowd.me`, `pos = minimap.pos`, `hostiles = [[point.x, point.y, hp_pct]]`, `pet = crowd.pet.point`, `vistos = [[point.x, point.y, px]]` de `special.vistos`, `listed = crowd.listed`, `enemies = length(battle.enemies)`, `route = orders.route`. Nada de nomes.

---

### Task 1: Tirar o que está morto

**Files:**
- Modify: `lib/pokex/bots/catcher/trail.ex` (apagar `clear_anchors/1`, ~linhas 203–206 com o `@doc`/`@spec`)
- Modify: `lib/pokex/bots/catcher/corpse_library.ex:103` (apagar `best/1`); `test/pokex/bots/catcher/corpse_library_test.exs` (apagar o teste que chama `CorpseLibrary.best/1`, ~linha 86)
- Modify: `lib/pokex/bots/catcher/shiny_aim.ex:108-109` (apagar `judge/6`); `test/pokex/bots/catcher/shiny_aim_test.exs` (todo `ShinyAim.judge(` vira `ShinyAim.judge_told(` e pega `{candidates, _diag}`)
- Modify: `lib/pokex/bots/catcher/worker.ex:134` (apagar `Phoenix.PubSub.subscribe(Pokex.PubSub, Perception.topic())`) e `:279` (apagar `def handle_info({:world, _key, _obs}, state), do: {:noreply, state}`)
- Modify: `lib/pokex/rig.ex:27` (apagar `@callback capture_sequence(point)`), `lib/pokex/rig/mac.ex:184-191`, `lib/pokex/rig/fake.ex:97-98`, `lib/pokex/rig/sim.ex:57-58` (apagar as implementações), `lib/pokex/bots/body.ex:303,554,601,611,664` (apagar as cinco cláusulas `{:capture_sequence, _point}`), `lib/pokex/bots/fishing/worker.ex:403` (apagar o braço `describe_action({:capture_sequence, {x, y}})`), `lib/pokex_web/live/diagnostics_live.ex:405-411` (o botão passa a fazer o que `Ball.sequence/1` faz)
- Modify: `lib/pokex/settings.ex:513-514` (comentário "Independent switches, both only meaningful while parado" — está errado desde a captura em modo hunt, #590)
- Modify (docs): `docs/superpowers/plans/2026-07-10-corpse-capture.md`, `docs/superpowers/specs/2026-07-10-corpse-capture-design.md`, `docs/superpowers/plans/2026-07-10-space-loot.md`, `docs/refactor/fase-0-inventario.md` (linhas 36, 47, 57), `docs/superpowers/plans/2026-09-10-shiny-quatro-abertos.md`
- Test: `test/pokex/bots/catcher/trail_test.exs`, `test/pokex/bots/body_test.exs`, `test/pokex/rig/*_test.exs` (o que citar `capture_sequence`)

**Interfaces:** nada novo; só remoções. Depois desta tarefa `capture_sequence` só existe como a AÇÃO do `Catcher.Logic` (`{:capture_sequence, point, name}`, 3-tupla) — nunca mais como primitivo do Rig.

- [ ] **Step 1: enumerar os sítios do primitivo morto**

Run: `/usr/bin/grep -rn "capture_sequence" lib test | /usr/bin/grep -v "{:capture_sequence, _, _}\|{:capture_sequence, point, \|{:capture_sequence, throw.point\|capture_sequence, _point, _name"`
Expected: exatamente os sítios listados em **Files** (rig.ex, rig/mac.ex, rig/fake.ex, rig/sim.ex, body.ex ×5, fishing/worker.ex, diagnostics_live.ex) mais os testes que os exercitam.

- [ ] **Step 2: o botão do diagnóstico faz a mesma coisa pelo caminho vivo**

Em `lib/pokex_web/live/diagnostics_live.ex`, substitua o corpo de `handle_info({:delayed_seq, point}, socket)`:

```elixir
  def handle_info({:delayed_seq, point}, socket) do
    # the same two steps the retired Rig primitive did, with the configured key
    result =
      with :ok <- Rig.impl().move(point) do
        Rig.impl().press(Pokex.Bots.Catcher.Ball.key())
      end

    {:noreply, assign(socket, pending: nil, tools_msg: "bola (move + tecla) → #{inspect(result)}")}
  end
```

- [ ] **Step 3: apagar os sítios e as cláusulas** (rig.ex callback; mac/fake/sim impls; as cinco cláusulas do body.ex — `actuators/1`, `execute/1`, `guarded_input?/1`, `first_action/1`, `action_label/1`; o braço do fishing). Apague também os testes que só existiam pra elas (`/usr/bin/grep -rln "capture_sequence" test/pokex/rig test/pokex/bots/body_test.exs`).

- [ ] **Step 4: apagar `Trail.clear_anchors/1`, `CorpseLibrary.best/1` (+ seu teste), `ShinyAim.judge/6` (+ trocar chamadas nos testes), a assinatura de `Perception.topic()` e a cláusula `{:world, …}` no worker**

Run: `/usr/bin/grep -rn "clear_anchors\|CorpseLibrary.best(\|ShinyAim.judge(\|Perception.topic()" lib test`
Expected: nenhuma linha em `lib/pokex/bots/catcher/`; `Perception.topic()` só nos outros assinantes (LiveViews/feeds).

- [ ] **Step 5: o comentário de `settings.ex:513`**

Substitua o bloco "Independent switches, both only meaningful while parado:" por:

```elixir
    # A conferência da bola comum, em qualquer modo: desde #590 a captura roda
    # na caçada com a estrada segurada e a lista vazia, não só no modo Parado.
```

- [ ] **Step 6: docs** — no topo de cada um dos três documentos de 10/07 e da seção de captura do `fase-0-inventario.md`, uma linha: `> **Substituído.** O feed `:corpses` (baseline + diff) e `loot_enabled` não existem desde 30/07 (apagados em 09/09). A captura de hoje: `docs/superpowers/specs/2026-09-09-shiny-na-cacada-design.md` e `docs/superpowers/plans/2026-09-11-captura-limpa-e-escalavel.md`.` Em `2026-09-10-shiny-quatro-abertos.md`, marque as 33 caixas `- [x]` (as quatro entregas estão no código: `shiny_aim.ex:232-243`, `logic.ex:307`, `shiny_guard.ex:288-308`, `ColorRules.proof_fits?/2`).

- [ ] **Step 7: testes tocados** — `MIX_ENV=test mix test test/pokex/bots/catcher/trail_test.exs test/pokex/bots/catcher/corpse_library_test.exs test/pokex/bots/catcher/shiny_aim_test.exs test/pokex/bots/catcher/worker_test.exs test/pokex/bots/body_test.exs test/pokex/bots/fishing/worker_test.exs test/pokex_web/live/diagnostics_live_test.exs` → `0 failures`.

- [ ] **Step 8: gate completo + PR** (Global Constraints). Título sugerido: `o primitivo que a bola já não usa: capture_sequence sai do Rig, e o feed do chão sai do Catcher`.

---

### Task 2 (D1): A mira por cor do corpo se aposenta; o brilho + rastro é o único caminho do shiny

**Files:**
- Modify: `lib/pokex/bots/catcher/worker.ex` — apagar: `handle_info({:shiny_seen, _}, …)` ×2 (linhas 388–393; ver Step 3), `handle_info(:aim, …)` ×2 (395–422), `open_aim/2`, `aim_by_colour_at_cue/1` ×2, `aim_opened_msg/1`, `aim_expired_msg/1`, `new_tally/0`, `tally_look/3`, `tally/2`, `say_tally/1`, `seconds/1`, `tally_parts/1`, `tally_prefix/1`, `close_aim/1` ×2, `aim_done?/1`, `aim_ttl_ms/0`, `schedule_aim/1`, `aim_look/1`, `announce_corpses/2` (a de 2 argumentos), `shiny_reading?/2`, o ramo `state.aim != nil` de `hold_reason/1`, os campos `aim`, `aim_timer`, `aimer` do estado/`init`, `@cue_aim_ttl_ms`, `@cue_aim_looks`, a opção `aimer:` de `start_link/1`, a chamada `aim_by_colour_at_cue(state)` em `handle_info({:capture_now}, …)`
- Modify: `lib/pokex/bots/catcher/shiny_aim.ex` → **renomear para** `lib/pokex/bots/catcher/observation.ex` (`Pokex.Bots.Catcher.Observation`), mantendo só `screen_clear/2` e `obs/4` (renomeada `anchors/3`); apagar `scan/1`, `judge_told/6`, `steady/3`, `forbidden_boxes` e `bodies/1`, `crowd/1`
- Modify: `lib/pokex/bots/catcher/logic.ex:307,338` (`other_lens?`/`source_of`: a lente da âncora passa a chamar `:anchor`)
- Modify: `lib/pokex_web/live/cavebot_live.ex:1243-1260` (`capture_aiming?/1` e "mirando o corpo pela cor" → o estado do rastro), `lib/pokex_web/live/config_live.ex` (apagar a linha de `shiny_aim_max_candidates`), `lib/pokex/settings/locked.ex:314` (`shiny_aim_max_candidates` → grupo `"Aposentadas"`), `lib/pokex/bots/shiny_readiness.ex` (o que citar a mira por cor — `/usr/bin/grep -n "mira\|aim" lib/pokex/bots/shiny_readiness.ex`)
- Modify: `lib/pokex/bots/engine/worker.ex:394-406` (`capturing?/1`: `aiming?` sai; entra `anchors`)
- Test: apagar em `test/pokex/bots/catcher/worker_test.exs` os testes "the colour aim logs pixels, not a percentage", "at the capture cue, an armed colour rule looks for the shiny's corpse by colour", "at the capture cue with no colour rule armed, no colour session opens", "a colour session that finds nothing says what it saw when it closes", "in hunt mode a shiny sighting aims by colour and throws at :high", "the aim ignores the fight gate: a combat still engaged does not hold the shiny ball", "in hunt mode without a sighting nothing flies", "the aim session publishes the :capture fact and clears it on close", "the aim session ends when the shiny corpse is not found", "a held aim does not count as a blind scan", e os helpers `stage_aim/1`, `aim_obs/1`, `arm_colour_rule/1` se ficarem sem uso; em `test/pokex/bots/catcher/shiny_aim_test.exs` → renomear `observation_test.exs` e manter só o `describe "the screen has to be empty of the living"` e o teste "obs speaks the Logic's contract" (agora `Observation.anchors/3`); `test/pokex_web/live/cavebot_live_test.exs` (o que afirmar "mirando o corpo").

**Interfaces:**
- Consumes: `Trail.hunted/2`, `Trail.anchors/3` (Task 0/3).
- Produces: `Pokex.Bots.Catcher.Observation.anchors(candidates, at, diag) :: map` com `source: :anchor`; `Observation.screen_clear/2` (idêntica à antiga `ShinyAim.screen_clear/2`); o fato `:capture` passa a ser `%{pending: n, anchors: n, hunted?: boolean, armed?: boolean}`; o snapshot troca `aim?` por `hunted?: boolean` e `anchors: n`; `shiny_pending?` deixa de ser campo — vira `shiny_open?/1` derivado do rastro.

- [ ] **Step 1: o teste que descreve o novo fato**

Em `test/pokex/bots/catcher/worker_test.exs`, ao lado de "the shiny's bar followed until it falls buys the ball at the cue, with no colour at all":

```elixir
  # THE FACT SAYS WHAT THE TRAIL KNOWS. The colour aim used to say `aiming?`
  # for up to 90 s with nothing on the ground; now the brain holds the feet
  # for a body the trail has (an anchor) or a ball in flight (pending).
  @tag :tmp_dir
  test "the :capture fact carries the trail: hunted while the bar stands, anchors once it fell" do
    worker = start_hunt_worker(scanner: fn -> nil end)
    me = {500, 350}
    shiny = %{special?: true, special_name: "Shiny Golem", special_px: 394}
    seen = fn hostiles -> %{read?: true, me: me, hostiles: hostiles, pet: nil} end

    send(worker, {:crowd, seen.([Map.merge(%{point: {600, 250}}, shiny)])})
    :sys.get_state(worker)
    assert {:ok, %{hunted?: true, anchors: 0}} = WorldState.get(:capture, 5_000, now())

    for _ <- 1..3, do: send(worker, {:crowd, seen.([])})
    assert_log_eventually("Shiny Golem caiu em 600,250")
    assert {:ok, %{hunted?: false, anchors: 1}} = WorldState.get(:capture, 5_000, now())
    refute Map.has_key?(elem(WorldState.get(:capture, 5_000, now()), 1), :aiming?)
  end
```

(`now/0` já existe no arquivo de teste; se não, `defp now, do: System.monotonic_time(:millisecond)`.)

- [ ] **Step 2: rodar e ver falhar** — `MIX_ENV=test mix test test/pokex/bots/catcher/worker_test.exs --only line:<linha do teste>` → falha em `hunted?`/`anchors` (chaves ausentes).

- [ ] **Step 3: o licenciamento do shiny sem sessão**

`{:shiny_seen, _info}` deixa de abrir sessão; o que ele fazia de útil era a LICENÇA da bola com a captura desligada (`shiny_always_ball`). Ela passa a vir do rastro. No worker:

```elixir
  # A shiny on screen licenses the ball even with capture off: the trail knows
  # while the bar stands (hunted) and after it fell (an anchor) — no session.
  def handle_info({:shiny_seen, _info}, state), do: {:noreply, state}

  defp shiny_open?(state) do
    ref = trail_ref(%{})
    Trail.hunted(state.trail, ref) != nil or Trail.anchors(state.trail, ref, now()) != []
  end

  defp capture_allowed?(state),
    do: Settings.get(:capture_enabled) or (shiny_open?(state) and Settings.get(:shiny_always_ball))
```

`capture_allowed?/2` (a licença por observação `%{source: :anchor}`) fica como está, só trocando `:shiny_aim` por `:anchor`. Apague o campo `shiny_pending?` e todo uso (`note_throw/3` só carimba a estrela; `snapshot/1` publica `hunted?: Trail.hunted(...) != nil`).

- [ ] **Step 4: `publish_capture/1` e o snapshot**

```elixir
  defp publish_capture(state) do
    ref = trail_ref(%{})

    WorldState.put(
      :capture,
      %{
        pending: (state.logic && Logic.pending(state.logic)) || 0,
        anchors: length(Trail.anchors(state.trail, ref, now())),
        hunted?: Trail.hunted(state.trail, ref) != nil,
        armed?: armed?(state)
      },
      now()
    )
  end
```

E em `Engine.Worker.capturing?/1` (`lib/pokex/bots/engine/worker.ex`):

```elixir
  defp capturing?(now) do
    case WorldState.get(:capture, ShinyGuard.fact_max_age_ms(), now) do
      {:ok, %{pending: pending}} when is_integer(pending) and pending > 0 -> true
      {:ok, %{anchors: anchors}} when is_integer(anchors) and anchors > 0 -> true
      _stale_or_missing_or_done -> false
    end
  end
```

(Atualize o comentário acima dela: "corpo no chão (âncora) ou bola no ar (pending) seguram os pés".) `publish_capture/1` também precisa rodar depois de `follow/2` (a âncora nasce ali): em `handle_info({:crowd, …})` termine com `state = state |> remember_standing(hostiles) |> follow(reading); publish_capture(state); {:noreply, state}`.

- [ ] **Step 5: `Observation`** — `git mv lib/pokex/bots/catcher/shiny_aim.ex lib/pokex/bots/catcher/observation.ex`; módulo `Pokex.Bots.Catcher.Observation` com `@moduledoc` de dois parágrafos (a observação sintética da âncora e o portão da tela vazia), `screen_clear/2` igual, e:

```elixir
  @doc "The Logic's observation for the trail's anchors: not a photo, a claim."
  @spec anchors([map], integer, map) :: map
  def anchors(candidates, at, diag \\ %{}) do
    %{
      scanning?: true,
      source: :anchor,
      diag: diag,
      corpses: Enum.map(candidates, & &1.point),
      known: Map.new(candidates, &{&1.point, %{name: &1.name, px: &1.px}}),
      candidates: candidates,
      region: {0, 0, 0, 0},
      captured_at: at
    }
  end
```

No worker, `throw_at_anchors/1` chama `Observation.anchors(candidates, at, %{anchor: true})`; `refuse_shiny/2`, `anchor_without_ball/2`, `capture_allowed?/2`, `advance/2` (o `match?(%{source: :shiny_aim}, obs)`) e `note_throw/3` passam a casar `source: :anchor`. Em `logic.ex` nada muda além do comentário de `other_lens?/2` ("a varredura comum e a âncora são duas lentes").

- [ ] **Step 6: apagar a sessão** — tudo listado em **Files** para o worker. Depois: `/usr/bin/grep -n "aim\b\|aim_\|:aim\|tally\|shiny_pending" lib/pokex/bots/catcher/worker.ex` → só `aim_settle` (a config da bola) pode sobrar.

- [ ] **Step 7: a Central e o painel** — em `cavebot_live.ex`, `capture_aiming?/1` vira `capture_open?(catcher)` = `Map.get(catcher, :hunted?) == true or Map.get(catcher, :anchors, 0) > 0`; a frase `"mirando o corpo pela cor"` vira `"seguindo a barra do shiny"` (hunted) / `"corpo no chão — bola a caminho"` (anchors > 0). Atualize `cavebot_live_test.exs` na mesma frase.

- [ ] **Step 8: testes** — apague/renomeie os listados em **Files**; `MIX_ENV=test mix test test/pokex/bots/catcher test/pokex/bots/engine/worker_test.exs test/pokex/bots/black_box_test.exs test/pokex_web/live/cavebot_live_test.exs test/pokex_web/live/config_live_test.exs` → `0 failures`; a bancada (Task 0) e os três testes da rede continuam verdes.

- [ ] **Step 9: gate completo + PR.** Título: `a mira por cor do corpo se aposenta: o corpo é onde a barra caiu, e o fato diz o que o rastro sabe`. No corpo do PR, a evidência (0 px em todas as sessões de 11/09; #601).

---

### Task 3: O rastro em tela — a âncora é a última evidência, e o gêmeo não cai

**Files:**
- Modify: `lib/pokex/bots/catcher/trail.ex` (`track` ganha `pos`; `hit/3`, `birth/3`, `hunt_at/6`; `fall/2` copia `screen` e `pos`; `anchors/3`; `observe/4` — a regra do gêmeo)
- Test: `test/pokex/bots/catcher/trail_test.exs`, `test/pokex/bots/catcher/trail_replay_test.exs`

**Interfaces:**
- Produces: anchor `%{world, screen, pos, name, px, fallen_at}`; `Trail.anchors/3` devolve `screen:` = o ponto de tela da última barra vista quando `ref.pos == anchor.pos` (o personagem não andou desde então), senão a projeção do mundo como hoje. `Trail.standing/2` inalterada.

- [ ] **Step 1: os testes**

Em `trail_test.exs`:

```elixir
  # 19:50 of 11/09: the minimap stood at (309,1425) for fifteen seconds while
  # the screen scrolled two tiles each way. World coordinates lie when the
  # minimap does not move; the last SCREEN point of the bar does not, as long
  # as the character has not walked since (the same minimap reading).
  test "with the minimap unchanged since the last bar, the anchor is that bar's screen point" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}
    frozen = {309, 1425, 6}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, pos: frozen, sparkle: true)
      # the screen scrolled two tiles right (the minimap did not follow): the
      # same creature reads two tiles further on the screen
      |> look([at(2, -2)], 1_000, pos: frozen, sparkle: true)
      |> look([at(2, -2)], 1_250, pos: frozen, sparkle: true)
      |> look([], 1_500, pos: frozen, pile: :dead)
      |> look([], 1_750, pos: frozen, pile: :dead)
      |> look([], 2_000, pos: frozen, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref(frozen), 2_000)
    assert screen == at(2, -2).point
  end

  test "once the character walks, the anchor is projected from the world again" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, pos: {100, 100, 7})
      |> look([], 250, pos: {100, 100, 7}, pile: :dead)
      |> look([], 500, pos: {100, 100, 7}, pile: :dead)
      |> look([], 750, pos: {100, 100, 7}, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref({101, 100, 7}), 750)
    assert screen == at(-1, -2).point
  end

  # Live, the frozen minimap made the same shiny TWO hunted tracks two tiles
  # apart, and both fell — a ball on the sand each side of the body. A hunted
  # bar that falls while another hunted bar was seen more recently is the
  # stale twin: it is dropped, and the fresh one falls where the body is.
  test "of two hunted tracks the stale one is dropped, the fresh one is the corpse" do
    shiny = %{special?: true, special_name: "Shiny (brilho)", special_px: 51}

    trail =
      Trail.new()
      |> look([at(0, -2, shiny)], 0, sparkle: true)
      # the twin, two tiles away, hunted by the guard's blob one look later
      |> look([at(0, -2), at(2, -2)], 250, sparkle: true)
      |> Trail.hunt_at(at(2, -2).point, "Shiny (brilho)", 51, ref(), 300)
      # the old track's bar is gone; the twin is still seen
      |> look([at(2, -2)], 500, sparkle: true)
      |> look([at(2, -2)], 750, sparkle: true)
      |> look([], 1_000, pile: :dead)
      |> look([], 1_250, pile: :dead)
      |> look([], 1_500, pile: :dead)

    assert [%{screen: screen}] = Trail.anchors(trail, ref(), 1_500)
    assert screen == at(2, -2).point
  end
```

E em `trail_replay_test.exs`, a expectativa de 1950 passa a ser a propriedade:

```elixir
  test "1950: the anchor lands within a tile of the last sparkle point" do
    result = TrailReplay.run(fixture("2026-09-11-1950-gemeos.jsonl"))

    assert [%{screen: {x, y}}] = result.falls
    # the last sparkle put the name at (1418, 842); the body centre is half a tile under
    assert abs(x - 1418) <= 151 and abs(y - 917) <= 151, "anchor at #{x},#{y}"
    assert length(result.anchors) == 1
  end
```

- [ ] **Step 2: rodar e ver falhar** — `MIX_ENV=test mix test test/pokex/bots/catcher/trail_test.exs test/pokex/bots/catcher/trail_replay_test.exs` → os três novos e o de 1950 falham.

- [ ] **Step 3: o rastro guarda a tela e a posição**

Em `trail.ex`: `@type track` ganha `pos: {integer, integer, integer} | nil`; `@type anchor` ganha `screen: point, pos: {integer, integer, integer} | nil`.

```elixir
  defp hit(track, hostile, now, ref) do
    %{
      track
      | prev: track.world,
        world: hostile.world,
        screen: hostile.point,
        pos: ref.pos,
        seen_at: now,
        misses: 0,
        occluded: 0,
        hunted?: track.hunted? or Map.get(hostile, :special?, false),
        name: Map.get(hostile, :special_name) || track.name,
        px: Map.get(hostile, :special_px) || track.px
    }
  end

  defp birth(hostile, id, now, ref) do
    %{
      id: id,
      world: hostile.world,
      prev: nil,
      screen: hostile.point,
      pos: ref.pos,
      seen_at: now,
      misses: 0,
      occluded: 0,
      hunted?: Map.get(hostile, :special?, false),
      name: Map.get(hostile, :special_name),
      px: Map.get(hostile, :special_px)
    }
  end

  defp fall(track, now),
    do: %{
      world: track.world,
      screen: track.screen,
      pos: track.pos,
      name: track.name || "shiny",
      px: track.px,
      fallen_at: now
    }
```

`match/4` passa `ref` a `hit/4`; `observe/4` e `hunt_at/6` passam `ref` a `birth/4` (o `ref` já é o `frame(trail, ref)` — com `pos` preenchido). Em `anchors/3`:

```elixir
  def anchors(trail, ref, now) do
    ref = frame(trail, ref)

    for anchor <- trail.anchors, now - anchor.fallen_at <= @anchor_ttl_ms do
      Map.put(anchor, :screen, anchor_screen(anchor, ref))
    end
  end

  # THE LAST BAR'S OWN SCREEN POINT while the character has not walked since
  # (the same minimap reading): world coordinates lie when the minimap freezes
  # under a scrolling screen (19:50 of 11/09), the pixel does not.
  defp anchor_screen(%{pos: pos, screen: screen}, %{pos: pos}) when pos != nil, do: screen
  defp anchor_screen(%{world: world}, ref), do: to_screen(world, ref)
```

- [ ] **Step 4: o gêmeo velho não cai**

Em `observe/4`, depois de `{fallen, alive} = …` e antes de `corpses = …`:

```elixir
    # A HUNTED BAR THAT FALLS WHILE ANOTHER HUNTED BAR WAS SEEN MORE RECENTLY
    # is the stale twin of the same creature (a frozen minimap under a
    # scrolling screen, 19:50 of 11/09): no body there — the fresh one falls
    # where the body is.
    freshest_hunted =
      tracks |> Enum.filter(& &1.hunted?) |> Enum.map(& &1.seen_at) |> Enum.max(fn -> nil end)

    fallen = Enum.filter(fallen, &(&1.seen_at == freshest_hunted))
```

(`tracks` aqui é a lista já casada nesta olhada, com os que caem dentro.)

- [ ] **Step 5: rodar** — `MIX_ENV=test mix test test/pokex/bots/catcher/trail_test.exs test/pokex/bots/catcher/trail_replay_test.exs test/pokex/bots/catcher/worker_test.exs` → `0 failures`. Se 1950 ainda cair fora do tile: imprima `result.falls` e os `seen_at`/`screen` dos rastros caçados nas olhadas 20_191–21_770 (`IO.inspect` temporário) — a regra certa é "a âncora é a última barra vista do rastro mais fresco"; ajuste `hunt_at/6` para que o brilho em (1418, 917) sem barra a menos de 1,5 tile CRIE o rastro fresco (hoje ele cria — confira `nearest/2`).

- [ ] **Step 6: gate completo + PR.** Título: `o rastro em tela: a âncora é a última barra vista, e o gêmeo velho não vira corpo`.

---

### Task 4: Um só relato — `Catcher.Fact`, o prazo do fato é do Catcher, e uma só voz pra "a bola não saiu"

**Files:**
- Create: `lib/pokex/bots/catcher/fact.ex` (`Pokex.Bots.Catcher.Fact`)
- Modify: `lib/pokex/bots/catcher/worker.ex` (`publish_capture/1`, `snapshot/1`, `refuse_shiny/2` + `anchor_without_ball/2` → `explain_no_ball/3`, `@pulse_ms`)
- Modify: `lib/pokex/bots/engine/worker.ex:388-406` (`ShinyGuard.fact_max_age_ms()` → `Catcher.Fact.max_age_ms()`)
- Test: Create `test/pokex/bots/catcher/fact_test.exs`; Modify `test/pokex/bots/catcher/worker_test.exs` (as asserções "a bola da âncora NÃO saiu" continuam iguais)

**Interfaces:**
- Produces: `Catcher.Fact.build(trail, logic, armed?, now) :: %{pending: n, anchors: n, hunted?: b, armed?: b}`; `Catcher.Fact.max_age_ms() :: 3_000` (= `@pulse_ms 1_000 × 3`: o pulso do worker, não a cadência do vigia); `Catcher.Fact.snapshot_fields(fact) :: %{pending_corpses: n, anchors: n, hunted?: b}`.

- [ ] **Step 1: teste**

```elixir
defmodule Pokex.Bots.Catcher.FactTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.{Fact, Logic, Trail}

  @ref %{me: {1695, 686}, tile: 151, pos: {100, 100, 7}}

  test "an empty trail and an idle logic are a quiet fact" do
    assert Fact.build(Trail.new(), Logic.new(%{}), false, @ref, 0) ==
             %{pending: 0, anchors: 0, hunted?: false, armed?: false}
  end

  test "the fact's shelf life is three pulses of the worker, not the guard's cadence" do
    assert Fact.max_age_ms() == 3_000
  end

  test "the snapshot's fields are cut from the same fact" do
    fact = %{pending: 2, anchors: 1, hunted?: true, armed?: true}
    assert Fact.snapshot_fields(fact) == %{pending_corpses: 2, anchors: 1, hunted?: true}
  end
end
```

(Confira a assinatura de `Logic.new/1` em `logic.ex:28` e ajuste o argumento.)

- [ ] **Step 2: o módulo**

```elixir
defmodule Pokex.Bots.Catcher.Fact do
  @moduledoc """
  What the Catcher is doing, in one map — the ONLY source for both the
  `:capture` world fact (the brain holds the feet on it) and the `{:catcher,
  snapshot}` broadcast's capture fields (Cavebot, PlayerSupport, the Central).
  Two channels, one truth: three consumers used to compute three slightly
  different "is the catcher busy" answers off two wires.
  """

  alias Pokex.Bots.Catcher.{Logic, Trail}

  @pulse_ms 1_000

  @doc "The worker's heartbeat for `armed?`, in ms."
  def pulse_ms, do: @pulse_ms

  @doc "How old the fact may be and still count: three pulses."
  def max_age_ms, do: @pulse_ms * 3

  @spec build(Trail.t(), Logic.t() | nil, boolean, map, integer) :: map
  def build(trail, logic, armed?, ref, now) do
    %{
      pending: (logic && Logic.pending(logic)) || 0,
      anchors: length(Trail.anchors(trail, ref, now)),
      hunted?: Trail.hunted(trail, ref) != nil,
      armed?: armed?
    }
  end

  @doc "The broadcast's capture fields, cut from the fact."
  def snapshot_fields(%{pending: p, anchors: a, hunted?: h}),
    do: %{pending_corpses: p, anchors: a, hunted?: h}
end
```

No worker: `publish_capture(state)` → `WorldState.put(:capture, Fact.build(state.trail, state.logic, armed?(state), trail_ref(%{}), now()), now())`; `snapshot/1` faz `Map.merge(base, Fact.snapshot_fields(Fact.build(…)))` e apaga `pending_corpses:`/`hunted?:` calculados à parte; `@pulse_ms` do worker vira `Fact.pulse_ms()`. Em `engine/worker.ex`, as duas leituras de `:capture` usam `Pokex.Bots.Catcher.Fact.max_age_ms()` (e o `alias`).

- [ ] **Step 3: uma só voz** — substitua `refuse_shiny/2` e `anchor_without_ball/2` por:

```elixir
  # THE ANCHOR'S BALL NEVER DISAPPEARS IN SILENCE (17:26:00 and 19:51:19 of
  # 11/09). One reporter, one shape of line, whatever refused it.
  defp explain_no_ball(%{source: :anchor, diag: %{anchor: true}} = obs, state, why) do
    detail =
      case why do
        :logic ->
          logic = state.logic

          "a lógica recusou #{length(obs.corpses)} âncora(s): fila #{length(logic.queue)}, " <>
            "ignorados #{map_size(logic.ignored)}, esta observação #{obs.captured_at}, " <>
            "a última que ela viu #{inspect(logic.last_obs_at)}"

        text when is_binary(text) ->
          text
      end

    log(:macro, "🌟 a bola da âncora NÃO saiu — #{detail}")
  end

  defp explain_no_ball(_obs, _state, _why), do: :ok
```

Chamadas: `explain_no_ball(obs, state, "o mini-game está em curso")`, `… "captura desligada e shiny_always_ball desligado"`, `… "o jogo não está em foco, ou o pânico está armado"`, e depois de `run_step`: `if state.logic.throw == nil, do: explain_no_ball(obs, state, :logic)`.

- [ ] **Step 4: rodar** — `MIX_ENV=test mix test test/pokex/bots/catcher/fact_test.exs test/pokex/bots/catcher/worker_test.exs test/pokex/bots/engine/worker_test.exs test/pokex/bots/cavebot/worker_test.exs test/pokex/bots/player_support/worker_test.exs` → `0 failures`.

- [ ] **Step 5: gate completo + PR.** Título: `um só relato da captura: o fato e o snapshot saem da mesma conta, com o prazo do Catcher`.

---

### Task 5: O worker em três — `Hunt` (rastro e âncora), `Narration` (as frases), e o GenServer

**Files:**
- Create: `lib/pokex/bots/catcher/hunt.ex` (`Pokex.Bots.Catcher.Hunt`)
- Create: `lib/pokex/bots/catcher/narration.ex` (`Pokex.Bots.Catcher.Narration`)
- Modify: `lib/pokex/bots/catcher/worker.ex` (mover; o worker fica < 1.000 linhas)
- Test: Create `test/pokex/bots/catcher/narration_test.exs`; `test/pokex/bots/catcher/worker_test.exs` inalterado (é a rede)

**Interfaces:**
- `Hunt.follow(state, reading) :: {state, fell? :: boolean}` (o antigo `follow/2` sem o `ball_the_fall`), `Hunt.hunt(state, vistos) :: state`, `Hunt.anchor_targets(state) :: {[candidate], [anchor]}` (o filtro `on_screen?`/`free?` de `throw_at_anchors/1`, devolvendo os candidatos `%{name, px, point, in_frame}` e as âncoras a gastar), `Hunt.spend(state, anchors) :: state`, `Hunt.ref(reading) :: ref`, `Hunt.snapshot(state) :: map`, `Hunt.fresher_than(logic, now) :: integer`. `Hunt` NÃO loga nem chama `advance/2`: devolve fatos; quem joga é o worker.
- `Narration.scan(obs) :: obs` (o antigo `narrate/1`), `Narration.cue(obs) :: {:macro | :debug, String.t()} | nil`, `Narration.hold_reason(state) :: String.t() | nil`, `Narration.hunt_hold() :: String.t() | nil`, `Narration.library() :: String.t()`, `Narration.corpses_taught() :: String.t()`, `Narration.falls(before, after_look, ref, now) :: [String.t()]`. Puras: devolvem strings; o worker chama `log/2`.

- [ ] **Step 1: o teste da narração** (`narration_test.exs`): três casos de `hold_reason/1` — mini-game em jogo → `"mini-game em jogo"`; `player_mode "hunt"` com a estrada andando → a frase atual de `hunt_hold/0`; captura desligada → `"captura desligada"` (copie as strings exatas de `hold_reason/1`, `worker.ex:1692-1734`).

- [ ] **Step 2: mover por nome** — cada função listada em **Interfaces** sai do worker para o módulo novo com o MESMO corpo (só `defp` → `def`, e `log/2` trocado por devolver a string). No worker, `handle_info({:crowd, …})`:

```elixir
  def handle_info({:crowd, %{read?: true, hostiles: hostiles} = reading}, state) do
    state = remember_standing(state, hostiles)
    before = state.trail
    {state, fell?} = Hunt.follow(state, reading)
    for line <- Narration.falls(before, state.trail, Hunt.ref(reading), now()), do: log(:macro, line)
    state = if fell?, do: ball_the_fall(state), else: state
    publish_capture(state)
    {:noreply, state}
  end
```

e `throw_at_anchors/1` vira:

```elixir
  defp throw_at_anchors(state) do
    case Hunt.anchor_targets(state) do
      {[], _none} ->
        state

      {candidates, anchors} ->
        at = Hunt.fresher_than(state.logic, now())
        for %{name: name, point: {x, y}} = c <- candidates, do: log(:macro, "🌟 bola na âncora do #{name} em #{x},#{y} — caiu há #{div(at - c.fallen_at, 1000)}s")
        obs = Observation.anchors(candidates, at, %{anchor: true})
        throws_before = state.logic.counters.throws
        state = advance(state, obs)

        if state.logic.counters.throws > throws_before do
          Hunt.spend(state, anchors)
        else
          log(:macro, "🌟 a âncora ficou pra próxima hora da bola — nenhuma bola saiu agora")
          state
        end
    end
  end
```

(`candidate` passa a carregar `fallen_at`.) Os testes do worker afirmam as mesmas frases: nada muda para eles.

- [ ] **Step 3: rodar** — `MIX_ENV=test mix test test/pokex/bots/catcher` → `0 failures`; `wc -l lib/pokex/bots/catcher/worker.ex` → `< 1200` (o varrer fica dentro dele, ~170 linhas, agrupado sob `# --- sweep (o varrer do modo Parado) ---`).

- [ ] **Step 4: gate completo + PR.** Título: `o Catcher em três: o rastro decide, a narração fala, o worker joga`.

---

### Task 6: (retirada — o "varrer" fica, ver D2)

Nada a fazer. O `Sweep` e seus handlers no worker são movidos, sem mudar de comportamento, na Task 5 (ficam no GenServer, agrupados sob um comentário `# --- sweep (o varrer do modo Parado) ---`), e continuam cobertos por `test/pokex/bots/catcher/sweep_test.exs` e pelos testes de "sweep" em `worker_test.exs`.

---

### Task 7: A bola por alvo — o shiny escolhe a própria bola

**Files:**
- Modify: `lib/pokex/settings.ex` (nova chave `shiny_ball_key: nil` ao lado de `shiny_always_ball`, sem range), `lib/pokex/settings/locked.ex` (NÃO travada: é editável), `lib/pokex_web/live/config_live.ex` (uma linha no grupo "Shiny (visão)", um `<select>` com as opções de `ball_types` mais "a padrão", no padrão das linhas de `engine_capture_hold_ms`, `config_live.ex:352-359`)
- Modify: `lib/pokex/bots/catcher/balls.ex` (`key_for/2` por alvo), `lib/pokex/bots/catcher/worker.ex` (`throw_balls/2` passa o alvo)
- Test: `test/pokex/bots/catcher/balls_test.exs`, `test/pokex/bots/catcher/worker_test.exs`, `test/pokex_web/live/config_live_test.exs`

**Interfaces:**
- Produces: `Balls.key_for(name, :corpse | :anchor) :: String.t()`; `Balls.key_for(name, kind, chosen, shiny_choice, types)` (a metade testável). O alvo vem de `obs.source` (`:corpse_scan` → `:corpse`, `:anchor` → `:anchor`).

- [ ] **Step 1: testes** (`balls_test.exs`):

```elixir
  test "the anchor's ball is the shiny's choice when it is on the hotbar" do
    types = [%{"key" => "f1", "name" => "Poké Ball"}, %{"key" => "f3", "name" => "Ultra"}]
    assert Balls.key_for("Shiny (brilho)", :anchor, nil, "f3", types) == "f3"
  end

  test "a shiny choice off the hotbar, or none, falls back to the default" do
    types = [%{"key" => "f1", "name" => "Poké Ball"}]
    assert Balls.key_for("Shiny (brilho)", :anchor, nil, "f9", types) == Balls.default_key()
    assert Balls.key_for("Shiny (brilho)", :anchor, nil, nil, types) == Balls.default_key()
  end

  test "an ordinary corpse keeps the taught corpse's choice" do
    types = [%{"key" => "f1", "name" => "Poké Ball"}, %{"key" => "f2", "name" => "Água"}]
    assert Balls.key_for("Kingler", :corpse, "f2", nil, types) == "f2"
  end
```

E no `worker_test.exs`, junto de "with the feet still, the ball flies at the fall…": `SettingsStash.stash!(shiny_ball_key: "f3", ball_types: [%{"key" => "f1", "name" => "Poké Ball"}, %{"key" => "f3", "name" => "Ultra"}])` antes da queda, e `assert_receive {:performed, :high, actions}`, `assert {:press, "f3"} in actions`.

- [ ] **Step 2: `Balls`**

```elixir
  @spec key_for(String.t() | nil, :corpse | :anchor) :: String.t()
  def key_for(name, kind),
    do:
      key_for(
        name,
        kind,
        CorpseLibrary.ball_for(name),
        Settings.get(:shiny_ball_key),
        Settings.get(:ball_types)
      )

  @doc "Same, against explicit choices and hotbar — the testable half."
  def key_for(_name, :anchor, _chosen, shiny_choice, types) do
    if is_binary(shiny_choice) and on_hotbar?(shiny_choice, types),
      do: shiny_choice,
      else: default_key()
  end

  def key_for(name, :corpse, chosen, _shiny_choice, types) do
    if is_binary(name) and is_binary(chosen) and on_hotbar?(chosen, types),
      do: chosen,
      else: default_key()
  end
```

Mantenha `key_for/1` e `key_for/3` como atalhos de `:corpse` (o `ShinyReadiness` e a calibração os usam). No worker, `throw_balls/2` recebe `kind` de `source_of(obs)` e chama `Balls.key_for(name, kind)`.

- [ ] **Step 3: a chave e a linha do /config** — `settings.ex`: `# A BOLA DO SHINY: a tecla do hotbar que vai no corpo do shiny (nil = a padrão, ball_key).` + `shiny_ball_key: nil,`; `config_live.ex`: a linha com `<select>` das `ball_types` + "a padrão"; `config_live_test.exs`: a linha aparece e grava.

- [ ] **Step 4: rodar** — `MIX_ENV=test mix test test/pokex/bots/catcher/balls_test.exs test/pokex/bots/catcher/worker_test.exs test/pokex_web/live/config_live_test.exs test/pokex/settings_test.exs` → `0 failures`.

- [ ] **Step 5: gate completo + PR.** Título: `a bola do shiny: o corpo do brilho escolhe a própria tecla`.

---

### Task 8: O mapa da captura, escrito

**Files:**
- Create: `docs/captura/README.md`
- Modify: `docs/superpowers/specs/2026-09-11-reconhecimento-de-corpo-design.md` (uma linha no topo: "Depende de `2026-09-11-captura-limpa-e-escalavel.md`; é o passo seguinte — o corpo achado no chão depois da queda, para o bicho que anda no último segundo.")

- [ ] **Step 1: escrever `docs/captura/README.md`** (pt-BR, ~150 linhas) com as seções: (1) **O caminho** — o diagrama do "Mapa de hoje" atualizado pós-Tasks 2–7; (2) **Quem decide o quê** — `ShinyGuard`/`Sparkle` (o brilho), `CrowdWatch`/`CrowdScan` (as barras), `Trail` (identidade, queda, gêmeo, tela × mundo), `Hunt` (alvos), `Logic` (fila/arremesso/conferência/frescor), `Balls`/`Ball` (qual bola, como joga), `Fact` (o relato), `Engine.hold_for_capture` (segurar os pés, teto por rodada); (3) **As linhas do diário e o que provam** — `✨ shiny na tela — o brilho ao lado do nome (Npx)`, `🎯 <nome> caiu em x,y — a barra sumiu`, `🌟 a âncora caiu com a estrada andando`, `🌟 bola na âncora … caiu há Ns`, `🌟 bola em x,y`, `🌟 capturado em x,y`, `🌟 a bola da âncora NÃO saiu — …`; (4) **As configurações vivas** (as que sobraram na Task 3 da auditoria, com o efeito de cada uma) e **as aposentadas** (por quê ficam declaradas); (5) **Como investigar um shiny que passou** — copiar o episódio da caixa-preta antes da rotação, gerar o fixture (Task 0), rodar a bancada, olhar os quadros `queda`/`bola`; (6) **O que ainda não resolve** — o bicho que anda no último segundo (o corpo fica um tile ao lado: só olhando o CHÃO depois da queda), o nome escondido atrás do pet, o minimapa parado; (7) **O que vem depois** — o modo "captura tudo que mata" (a seção do plano com esse nome: todo track que cai vira âncora; o acervo confirma e escolhe a bola), e o corpo achado no chão depois da queda (`2026-09-11-reconhecimento-de-corpo-design.md`).
- [ ] **Step 2: gate (só docs → `mix format` não toca; CI verde) + PR.** Título: `o mapa da captura, escrito`.

---

## Self-Review

- **Cobertura:** refinar (Tasks 3, 4), limpar (1, 2), organizar (4, 5, 8), escalar (7, 0). A captura das 19:43 é protegida pelos três testes nomeados nas constraints e pela bancada. A captura de corpos comuns e o varrer ficam intactos (ordem dele) — o modo "captura tudo que mata" nasce em cima deles.
- **Sem placeholders:** cada passo tem o código ou o comando; onde o valor depende de rodar (1950 na Task 3) a asserção é uma propriedade fechada.
- **Nomes:** `Observation.anchors/3`, `source: :anchor`, `Fact.build/5`, `Fact.max_age_ms/0`, `Hunt.follow/2`, `Hunt.anchor_targets/1`, `Narration.falls/4`, `Balls.key_for/2` e `/5`, `shiny_ball_key` — usados com a mesma grafia em todas as tarefas.
- **Fora do plano (dívidas nomeadas):** o crachá `__keys__` que impede remover chaves (#506/#507); a detecção do shiny vivo por cor (`ColorRules`) — fica; o corpo achado no chão depois da queda (`2026-09-11-reconhecimento-de-corpo-design.md`).
