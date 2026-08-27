# Mãos paralelas — o teclado pode agir enquanto outra ação dorme?

Investigação de 2026-08-26, a partir da pergunta: *"enquanto algo tá em sleep,
outra ação poderia ocorrer em paralelo? Teria como sempre ter umas 3 threads em
paralelo para o teclado?"*

**Resposta curta: sim, dá — e não vale quase nada.** O teclado ocupa entre
**0,8% e 2%** do relógio de caçada no único ponto que é de fato serializado.
Paralelizar isso é otimizar 1%. Três outras coisas, medidas abaixo, custam
entre 26% do relógio e a validade de todo o instrumento de medição.

---

## 1. O que serializa hoje

Quatro serializadores empilhados, e **só um** é imposto pelo SO.

| # | Onde | Natureza | Custo |
|---|---|---|---|
| 1 | `Bots.Body` — flag `busy?` + 3 filas de prioridade | nossa | uma sequência por vez |
| 2 | `Rig.Mac.KeyEvents` — 1 GenServer, `read_line` bloqueante dentro do `handle_call` | nossa | ~12ms por tecla (`usleep(12_000)` em `priv/native/key_events.swift`), 80ms quando re-fronta |
| 3 | `priv/native/key_events.swift` — um `while let line = readLine()` | nossa | idem |
| 4 | `Rig.Mac.OsaBus` — `System.cmd` dentro do `handle_call` | **do SO** (System Events é fila única) | 30–100ms por spawn, **e ver §3** |

O contraintuitivo: **a premissa "uma ação por vez" já é falsa em três lugares,
de propósito.** O Combat vai direto no Rig (`combat/worker.ex`, justificado no
comentário do `dispatch/2`), o mini-game segura Space direto no Rig
(`mini_game/player.ex`), e `Body.hold` roda inline no loop. Já existem três
correntes de tecla independentes — o que falta não é paralelismo, é
**escalonamento**.

E "três teclas em voo" não tem sentido físico: existe um teclado, e CGEvents
postados no `.cghidEventTap` são entregues em ordem de postagem. O que dá para
paralelizar é a **espera**, nunca a postagem.

---

## 2. Quanto se perde — números do diário dele

Config viva (`~/.pokex/settings.json`): `combat_skill_gap_ms: 500`,
`combat_skill_jitter_ms: 100`, `combat_skill_burst_size: 2`. Semente:
35 / 20 / 3.

Janela real de `~/.pokex/events/2026-08-26.jsonl` — 122s em torno dos 5 kills:

- **35 rajadas / 108 teclas** julgadas por recibo
- Sono dentro de rajada: **44,8s = 37% do relógio**
- Trabalho real no helper (12ms × 108): **1,3s = 1,06%**
- Decisões de ~300ms cobertas por uma rajada em voo: **~149**

Uma rajada de abertura de 7 teclas leva **3,3 segundos** para sair da mão. É o
`Process.sleep(gap + jitter)` de `Rig.Mac.pause_between_keys/2`, não o helper.

E esse sono **segura a única vaga de despacho do combate** (`burst_pid` vivo ⇒
`try_dispatch` pula, contando em `Perf.count("combat.burst_skipped")`, que
ninguém lê). Pacing e exclusão mútua são o mesmo objeto.

---

## 3. Os quatro defeitos achados, em ordem de custo

### 3.1 O relógio do recibo era o da PRIMEIRA tecla — CORRIGIDO nesta PR

`tap_keys/4` carimbava `at = now()` **antes** de `press_many`, e
`Perception.ready_skills_after(at, _)` aceita qualquer quadro da barra
capturado depois de `at`. Com a barra publicada a cada `feed_skill_bar_ms: 400`
e uma rajada de 3,3s, o quadro aceito era rotineiramente **do meio da rajada** —
onde a cauda ainda não tinha sido apertada e portanto ainda estava pronta.
`SkillReceipt` chama isso de `missed` por construção.

Efeito no diário de 26/08: **fired 6 · missed 70 · unknown 41 → taxa de 7,9%**.
Cada `missed` dispara `{:skills_missed, keys}` ⇒ uma rajada de repressão em
cima. Uma fatia desconhecida — possivelmente a maioria — dos 70 é o instrumento
mentindo, não o jogo recusando.

Isto invalida qualquer varredura de `gap_ms` feita contra `Tally.keys/1` antes
desta correção, pelo mesmo motivo de sempre: **a bancada media um bot
parecido.**

### 3.2 Uma rajada com modificador parava o barramento de teclas inteiro — CORRIGIDO

`Commands.press_many/2` emite as linhas `delay <gap+jitter>` **dentro do
script osascript**, e esse script roda via `System.cmd` **dentro de
`OsaBus.handle_call`**. Qualquer rajada contendo um `+` cai inteira nesse
caminho (`Rig.Mac.native_pressable?/1`), e as teclas de postura `shift+1` /
`shift+3` são prependadas às rajadas por `Combat.Logic.wear/2`.

Consequência: uma rajada de 3 teclas com `shift+1` na frente segura o
barramento global de teclas por ~1,1s — resgate, poção, revive e setas do
cavebot no caminho de fallback ficam todos atrás dela. **Este é o maior lock de
teclado do sistema hoje**, e ele não aparece em nenhuma métrica.

Corrigido: `Commands.press_many/2` deu lugar a `Commands.burst/2`, que devolve
a rajada como **passos** (`{:press, combo}` / `{:pause, ms}`). O `Rig.Mac` paga
a pausa no processo do próprio chamador, entre comandos curtos, e cada tecla
toma a rota que lhe cabe — CGEvent nativo quando é mapeada e sem modificador,
um osascript curto quando não. Nenhum script do barramento carrega mais de uma
tecla, então não há entre-teclas para esperar dentro dele.

### 3.3 A vaga de despacho é o processo que dorme — MEDIDO, e a cauda NÃO é o problema

`burst_pid` vivo = "uma rajada está em voo" = "um processo está dormindo". Uma
abertura de 1,8s (7 teclas a 300ms) deixa o combate surdo por 1,8s (~6 decisões
descartadas) e **irrevisável**: o mundo pode mudar completamente e a cauda da
rajada sai mesmo assim.

A hipótese era que a cauda acerta um corpo. **A bancada diz que não.** Antes de
medir foi preciso consertar o modelo: desde #367 ela cobrava o TEMPO da rajada
mas entregava o DANO todo no instante zero — a última tecla de sete saindo 1,8s
depois da primeira acertava o mundo de 1,8s atrás. Com cada tecla saindo na sua
vez (12 sementes × 180s):

| cenário | intervalo | modelo antigo | modelo novo | delta |
|---|---|---|---|---|
| lotavanon | 300ms | 59,28 | **62,22** | +5,0% |
| lotavanon | 500ms | 55,92 | 55,92 | 0 |
| formigueiro | 300ms | 13,14 | **13,89** | +5,7% |
| formigueiro | 500ms | 13,00 | 13,19 | +1,5% |

O sinal é **positivo**, e o motivo é o oposto da hipótese: enquanto a cauda
espera, as teclas dela **saem do cooldown**. O modelo antigo apertava as sete de
uma vez e desperdiçava as que ainda não estavam prontas.

E uma regra de cancelamento ingênua — abandonar a cauda quando o campo esvazia —
deu **exatamente os mesmos números** nos quatro casos: no cenário desses testes
o campo praticamente nunca esvazia dentro da janela de uma rajada.

**Conclusão: não construir o plano cancelável com a justificativa de dano.** A
justificativa que sobra é a surdez (6 decisões descartadas por abertura), e essa
ainda não tem preço medido — precisa de um predicado melhor que "campo vazio",
provavelmente "o alvo travado morreu".

### 3.4 O Body tem uma pista só para dois atuadores

`busy?` cobre a sequência inteira, inclusive os ~65ms de
`with_mouse_restore/2`. Uma sequência só-de-tecla espera atrás de uma
só-de-mouse sem nenhuma razão física. `:critical` **não preempta** — `dequeue/1`
só é alcançado no `{:done, ...}`.

Pior caso hoje: `flee_actions/1` = click + `{:wait, 5000}` + seta +
`{:wait, 300}` + seta = **5,3s** segurando a vaga `:critical`.

Armadilhas para quem for dividir em duas pistas:
- `click(:middle, _)` **não é mouse** para efeito de contenção: é o único
  clique que roda na porta do `KeyEvents` (`Rig.Mac.click/2`). Classificar por
  **atuador**, não por formato da tupla.
- `tap/1` e `focus_click/1` são **UNGATED** de propósito (exceções de
  calibração). Duas pistas dobram a taxa com que atuação ungated passa por um
  latch.
- `Body.cursor/1` desvia da fila de propósito — é o caminho do pânico. Não
  serializar leitura atrás de atuação.
- `flee_to_escape` é um `handle_call` que trava o GenServer do PlayerSupport
  inteiro; poção e revive rodam no mesmo loop. Duas pistas no Body não
  resolvem um bloqueio que está **acima** do Body.
- A garantia escrita em `guardian.ex` ("o pânico é limitado pela ação do Body
  em voo") vira o **máximo** das duas pistas. Precisa de um `Body.abort/0`
  entre ações — e de `{:wait, ms}` fatiado, senão a fuga de 5s continua sendo
  o teto.

---

## 4. O que NÃO paralelizar

1. **Dano dentro da janela `stun → settle → recall`** do resgate. O Combat não
   passa pelo Body e pode disparar ali hoje; uma tecla de dano acorda a pilha.
   A janela ainda atravessa **dois** `Body.perform` com um vão desprotegido no
   meio.
2. **`press(K)` enquanto outro dono segura `K`.** Um `press("right")` manda
   `down → 12ms → up` e **solta** a seta que o cavebot segura; o diff do tick
   seguinte dá `[]`, nada é reapertado, e o painel continua dizendo "segurando
   right".
3. **Quebrar `move → wait → press`.** A vara e a bola disparam no cursor.
4. **Paralelizar para dentro do osascript.** Se o `KeyEvents` não está
   `:ready`, N em voo reproduz literalmente "o mouse move, a tecla nunca
   chega" (incidente de 2026-07-11). E o `OsaBus` **falha aberto**: com o
   barramento morto os chamadores rodam `System.cmd` direto e concorrente.
5. **Duas `screencapture` ao mesmo tempo** (medido: 0,28s isolada, 2–4s
   concorrentes).

---

## 5. Ordem de entrega

| Fase | O quê | Prova |
|---|---|---|
| **0** | Varrer `combat_skill_gap_ms` em 500 / 200 / 60 e ler `Tally.keys/1` | **Zero código** — o `gap_ms` já viaja em cada recibo e o `/sim` já renderiza a tabela. Só é honesto **depois** da 3.1 |
| **1** | §3.1 — o relógio do recibo ✅ | teste do worker: um quadro do meio da rajada não vira "não saiu" |
| **2** | §3.2 — o gap sai de dentro do script osascript ✅ | teste do `Commands`: um comando de rajada carrega no máximo uma tecla |
| **3** | §3.3 — cada tecla sai na sua vez no simulador ✅ · o plano cancelável fica **em aberto** (a bancada não paga por ele) | teste: a segunda tecla sai quando chega a vez dela, sem ordem nova |
| **4** | §3.4 — duas pistas no Body + `Body.abort/0` | teste com `SlowRig`: um `:critical` de tecla responde durante uma sequência de mouse em voo |

Constantes órfãs a medir junto (nenhuma tem medição, comentário, teste ou
commit que a justifique): `usleep(12_000)` entre down e up, `usleep(80_000)`
depois do `ensureFrontmost`, os 50ms gêmeos do osascript, e
`@native_hold_latency_ms 15` (consumido como horizonte de predição pelo piloto
do mini-game).

---

## 6. Incógnitas

1. **Que intervalo entre teclas o jogo aceita.** Ninguém mediu. O `35` da
   semente foi recomendação sem base (#349). A Fase 0 responde.
2. **Por que as teclas não gastam cooldown**, no que sobrar dos 70 `missed`
   depois da 3.1. Três explicações incompatíveis: a tecla não sai da máquina;
   sai e o jogo recusa (sem alvo, fora de alcance, sem mana); ou o OCR da
   barra erra. `Rig.key_watch` já carimba cada DOWN a 8ms e **ninguém lê esses
   timestamps** — cruzar recibo × probe separa os três. Ressalva: o poller
   amostra a 8ms, então ele não pode julgar um `press` mais curto que isso.
3. **Custo real de um round trip nativo.** `KeyEvents` não tem **um** único
   `Perf.record`.
4. **Se `using {shift down}` do System Events vaza modificador** sobre um
   CGEvent concorrente. Os dois barramentos não são ordenados entre si — isso
   o código prova; o comportamento do SO, não.
