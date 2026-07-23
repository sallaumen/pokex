# Logout automático — design

**Data:** 2026-07-23
**Branch:** `logout/auto`

## O problema, em uma frase

Uma madrugada inteira de estamina da conta principal do Lucas foi queimada porque o
minigame travou: o bot continuou "vivo" (fisgando sem parar) e produziu zero peixe,
e nada no sistema tinha autoridade para encerrar a sessão.

## O que já existe (e por que não bastou)

O `Guardian` já é o vigia de sessão. Ele já tem:

* **metas de sessão** — `stop_after_minutes` / `stop_after_kills`, que travam o latch e
  param a frota ([`guardian.ex:162`](../../../lib/pokex/bots/guardian.ex));
* **a regra anti-estagnação** — sessão ativa sem kill e sem fisgada por
  `stagnation_minutes`, com ação `"alarme"` ou `"parar"`
  ([`guardian.ex:192`](../../../lib/pokex/bots/guardian.ex)).

Faltavam três coisas, e as três importam:

1. **A regra estava desligada.** `stagnation_minutes` nasce `0`.
2. **A regra mede o sinal errado.** "Fisgada" é o puxão da vara, não o peixe. Com o
   minigame travado o contador `hooked` sobe a noite inteira, o relógio zera a cada
   fisgada, e a regra dorme feliz. O contador que representa peixe de verdade é o
   `clears` do minigame ([`mini_game/worker.ex:30`](../../../lib/pokex/bots/mini_game/worker.ex)).
3. **Parar não economiza estamina.** Estamina queima enquanto o personagem está
   online. Só deslogar resolve.

## Decisões tomadas com o Lucas

| pergunta | decisão |
|---|---|
| O canto do pânico desloga? | **Não.** O canto é "assumi o controle" — deslogar tiraria ele do jogo no exato momento em que ele quer agir. O canto para tudo e mantém a sessão. |
| Um relógio ou vários? | **Um só.** Qualquer sinal de vida zera. Pescando não há kill, caçando não há peixe — um relógio combinado não dispara falso em nenhum dos modos. |
| O que é sinal de vida? | **Kill + minigame vencido**, com a fisgada voltando a valer quando o vigia do minigame está desligado. |
| Como confirma que deslogou? | **Confere a tela.** Ver a seção "A confirmação". |
| Qual a tecla? | **Ctrl+Q**, e o Enter alguns milissegundos depois. |
| Que outros gatilhos deslogam? | Metas de sessão (tempo/kills) e um **botão manual** no painel. |

Fora de escopo por decisão explícita: deslogar depois da fuga de emergência, e parar
os feeds de percepção depois do logout (eles não atuam — só gastam CPU).

## Arquitetura

### `Pokex.Bots.Logout` — GenServer próprio, irmão do `Guardian`

Filho direto da aplicação, entre `BotSupervisor` e `ShinyGuard`.

**Por que um processo próprio e não uma função no `BotSupervisor`** (como a fuga de
emergência): o ciclo *apertar → esperar → conferir → tentar de novo* leva segundos.
Quem dispara é o `Guardian`, que precisa continuar checando o canto do pânico a cada
100ms. Bloquear o `Guardian` por cinco segundos deixa o canto do pânico surdo por
cinco segundos — inaceitável.

**API pública:**

```elixir
@spec request(String.t()) :: :ok
def request(reason, server \\ __MODULE__)

@spec status(GenServer.server()) :: map()
def status(server \\ __MODULE__)
```

`request/1` é um `cast`: retorna `:ok` imediatamente e nunca bloqueia quem chamou.
É **idempotente** — um pedido enquanto um logout está em voo é ignorado (e contado
em `duplicates`). Isso importa porque o `Guardian` reavalia a condição a cada 100ms.

`status/0` devolve o snapshot que o painel desenha, e é o mesmo mapa que vai no
broadcast `{:logout, snapshot}` do tópico `"logout"`:

```elixir
%{
  state: :idle | :pressing | :verifying | :out | :failed,
  reason: String.t() | nil,          # por que foi pedido ("manual", "estagnação: ...")
  attempt: non_neg_integer(),        # tentativa atual
  attempts: pos_integer(),           # o limite configurado, para o painel dizer "2/3"
  error: term() | nil,               # o motivo da falha, quando :failed
  finished_at: integer() | nil,      # monotonic ms do desfecho (nil enquanto em voo)
  duplicates: non_neg_integer()      # pedidos ignorados por já haver um em voo
}
```

O broadcast sai a cada **mudança de estado**, não a cada leitura: um logout inteiro
produz um punhado de mensagens, não uma por captura.

**Opções de `start_link/1`** (todas injetáveis para teste):

* `:name` — nome registrado, `nil` para instâncias de teste;
* `:body` — o módulo cujo `perform/3` ele chama (padrão `Pokex.Bots.Body`);
* `:stop_fun` — `fn -> :ok end` que para a frota (padrão `&BotSupervisor.stop_all/0`);
* `:front_fun` — `fn -> :ok | {:error, term} end` (padrão `&Focus.ensure_front/0`);
* `:read_fun` — `fn -> :gone | :present | :unreadable end` (padrão: lê o fato `:hud`);
* `:active` — `false` desliga a instância global no ambiente de teste, pelo flag
  `:logout_active`, seguindo o mesmo padrão de `:shiny_guard_active` e
  `:player_support_auto_monitor`.

### `Pokex.Bots.Logout.Logic` — a decisão, pura

Sem processo, sem relógio, sem tela. Recebe `config` e leituras; devolve a próxima ação.

```elixir
defstruct state: :idle,     # :idle | :pressing | :verifying | :out | :failed
          reason: nil,      # texto humano de por que o logout foi pedido
          attempt: 0,       # tentativa atual (1..logout_attempts)
          reads: 0,         # leituras feitas DENTRO da tentativa atual
          confirms: 0,      # leituras :gone consecutivas
          config: %{},
          error: nil
```

Ações: `:press | :verify | {:finish, :out} | {:finish, {:failed, reason}}`.

```elixir
@type reading :: :gone | :present | :unreadable
@type action :: :press | :verify | {:finish, :out} | {:finish, {:failed, term()}}

@spec start(String.t(), map()) :: {t(), action()}
@spec after_press(t(), :ok | {:error, term()}) :: {t(), action()}
@spec after_read(t(), reading()) :: {t(), action()}
```

Regras, exatamente:

* `start(reason, config)` → estado `:pressing`, `attempt: 1`, ação `:press`.
* `after_press(logic, :ok)` → estado `:verifying`, `reads: 0`, `confirms: 0`, ação `:verify`.
* `after_press(logic, {:error, r})` → `retry(logic, r)`. **Uma falha de `front_fun`
  entra por aqui também**: do ponto de vista da Logic, "não trouxe o jogo para a
  frente" e "a tecla não saiu" são o mesmo fato — a tecla não aconteceu.
* `after_read(logic, :gone)` → `reads + 1`, `confirms + 1`.
  Se `confirms >= 2` → `{:finish, :out}`.
  Senão se `reads >= @reads_per_attempt` → `retry(logic, :nao_confirmou)`.
  Senão → `:verify`.
* `after_read(logic, :present)` e `after_read(logic, :unreadable)` → `reads + 1`,
  `confirms: 0`.
  Se `reads >= @reads_per_attempt` → `retry(logic, :ainda_logado)` / `retry(logic, :ilegivel)`.
  Senão → `:verify`.
* `retry(logic, motivo)`: se `attempt < config.attempts` → `attempt + 1`, `reads: 0`,
  `confirms: 0`, ação `:press`. Senão → `{:finish, {:failed, motivo}}`.

`@reads_per_attempt` é `4` — atributo de módulo, **não** um ajuste. É um limite interno
para o laço terminar, não uma escolha que o Lucas queira fazer. Sete ajustes novos já
é bastante.

O cadenciamento das leituras fica no worker, não na Logic: a primeira leitura sai
`logout_verify_delay_ms` depois do Enter (tempo da tela trocar) e as seguintes a cada
`@read_gap_ms` (400). Pior caso: 3 tentativas × (0,3 + 1,5 + 3 × 0,4) = ~9 segundos.

### O protocolo, na ordem exata

```
1. InputGate.set_panic_latch(true)     ← primeiro, sempre
2. stop_fun.()                          ← para a frota inteira
3. front_fun.()                         ← traz o jogo pra frente
4. Body.perform([{:press, logout_key},
                 {:wait, logout_confirm_delay_ms},
                 {:press, logout_confirm_key}], :critical)
5. espera logout_verify_delay_ms
6. lê a barra de baixo (até 4×, a cada 400ms)
7. duas leituras :gone seguidas → deslogado; senão volta ao passo 3
```

O latch vem **antes** de tudo pelo mesmo motivo que no pânico: ele proíbe todo caminho
de auto-retomada (a retomada do `Focus` ao reganhar foco). Ele **permanece travado**
depois de um logout bem-sucedido — só o "Iniciar bot" limpa.

O passo 4 é **uma sequência atômica** no `Body`: em `:critical` ela entra na frente de
tudo e nada se intercala entre o Ctrl+Q e o Enter.

Se o mouse do Lucas estiver no canto do pânico quando um logout automático dispara,
`ensure_front/0` devolve `{:error, :panic_corner}`, o passo 4 nunca acontece, e depois
das tentativas o logout **falha ruidosamente**. Está correto: ele está na máquina, com
a mão no mouse, e vai ver o alarme.

## A confirmação

### Por que conferir a tela não é luxo

Quando o `InputGate` está fechado, `Rig.Mac.gated/1` **engole a tecla e devolve `:ok`**
— de propósito, para nenhum worker confundir "segurei por segurança" com "falhou".
Foi exatamente assim que o cavebot morreu achando que tinha andado (PR #86).

Um logout que confia no `:ok` do `Body.perform` tem o mesmo destino: reporta
"deslogado", o Lucas vai dormir, e a estamina queima a noite toda. **A tela é a única
testemunha honesta.**

### O que ele lê

O fato `:hud` do `WorldState` — o mesmo que os alertas de estoque já mantêm vivo
(o feed `:hud` tem consumidor permanente, então há demanda sempre). O worker também
faz seu próprio `Perception.attach(:hud)` enquanto está em voo, para não depender
desse detalhe.

```elixir
defp read_hud(now) do
  case WorldState.get(:hud, @hud_max_age_ms, now) do
    {:ok, %{level: nil, food: nil, fishing: nil}} -> :gone
    {:ok, _algum_numero} -> :present
    _sem_fato_fresco -> :unreadable
  end
end
```

`@hud_max_age_ms` é `2_000` — o feed publica a cada 250-500ms, então dois segundos
já significa "parou de chegar".

### Por que essa é a leitura certa

* **Os três campos juntos.** Deslogado = nível, comida *e* pesca param de dar número.
  Um glifo lido errado sozinho não consegue forjar um logout.
* **`read_int`, não `blank?`.** A tela de seleção de personagem *tem* pixels naquela
  região. Mas pixels aleatórios não viram número com confiança 1.0, que é o que
  `Vision.Glyphs.read_int` exige.
* **Fato velho ≠ tela vazia.** Sem fato fresco a resposta é `:unreadable`, nunca
  `:gone`. Ler `World.snapshot()` seria errado aqui: ele devolve `nil` nos três campos
  tanto para "tela vazia" quanto para "feed parou", e essa confusão inventaria um
  logout que não aconteceu.

### O viés é deliberado

Toda ambiguidade resolve para **"não deslogou"**. Sem calibração de layout, feed
parado, leitura duvidosa — tudo vira falha, e falha grita. Um "deslogado" falso é
precisamente o prejuízo silencioso que essa feature existe para matar; um "falhou"
falso só acorda o Lucas à toa.

### A porta para o teu ponto calibrado

Quando a tela de seleção de personagem virar região calibrada, `read_fun` troca de
uma checagem **negativa** ("a HUD sumiu") para uma **positiva** ("vejo a lista de
personagens"). O contrato `:gone | :present | :unreadable` não muda; só a
implementação de `read_fun`. Nada mais no módulo precisa saber.

## Parar absolutamente tudo

Auditei tudo que consegue mover a tela. O que `stop_all/0` já cobre:
`Fishing`, `Combat`, `Catcher`, `MiniGame`, `PlayerSupport` (poção, cura e revive são
os três o mesmo worker) e `Cavebot`.

Dois quase-buracos que **não** são buracos, verificados:

* **`Combos.Runner`** aperta pelo `Body` e é filho da aplicação, fora do
  `BotSupervisor`. Mas quando o `Combat` é parado ele publica o snapshot, e o Runner
  aborta o combo no meio ([`runner.ex:93`](../../../lib/pokex/combos/runner.ex)).
* **`StockAlerts`** só publica alarmes; nunca toca no `Body`.

### O buraco de verdade: `ShinyGuard`

Ele é filho direto da aplicação ([`application.ex:35`](../../../lib/pokex/application.ex)) e
`stop_all` não o alcança. Ele não aperta tecla — ele chama `emergency_escape/1`, que
chama `flee_to_escape/0`, que **traz o jogo para a frente de propósito** e anda o
personagem até a escada. O canto do pânico só o veta enquanto o mouse está no canto;
assim que o Lucas tira o mouse, uma shiny avistada ainda arrasta o personagem com
tudo "parado".

**A correção:** com o latch travado, o `ShinyGuard` nunca foge — mas continua gritando.

```elixir
# antes de agir sobre uma shiny confirmada
if InputGate.panic_latched?() do
  # alarme sempre: uma shiny é perigosa durante o jogo MANUAL também, e é
  # justamente para jogar na mão que ele foi para o canto
  alarme(state, motivo)
else
  case Settings.get(:shiny_action) do
    "fugir" -> state.escape_fun.(motivo)
    _ -> alarme(state, motivo)
  end
end
```

Essa divisão é deliberada. Quando o Lucas vai para o canto para jogar na mão, ele
*quer* saber que apareceu uma shiny; o que ele não quer é o bot arrastando o
personagem para a escada enquanto ele joga. Uma regra só, e ela cobre o canto do
pânico, o logout e as metas de sessão de uma vez — porque os três travam o latch.

### `Focus.ensure_front/0` — extração

`ensure_game_front/0` hoje é privada em `PlayerSupport.Worker`
([`player_support/worker.ex:154`](../../../lib/pokex/bots/player_support/worker.ex)). O
`Logout` precisa exatamente dela. Sobe para `Pokex.Bots.Focus` como `ensure_front/0`
público — é lá que ela pertence, `Focus` é o dono do foco — e o `PlayerSupport` passa
a chamá-la. Comportamento idêntico; os testes existentes do `PlayerSupport` são a rede.

## Sinal de vida: kill + minigame vencido

O `Guardian` hoje conta `fights` (do snapshot do combate) e `hooked` (do snapshot da
pesca). Passa a contar:

* `fights` — igual;
* `clears` — do snapshot do `MiniGame.Worker`, no tópico `"mini_game"`, ao qual o
  `Guardian` passa a assinar;
* `hooked` — **só quando o vigia do minigame não está rodando**. Sem esse recuo, uma
  pescaria com o vigia desligado (o Lucas jogando o minigame na mão) não teria nada
  zerando o relógio, e a regra deslogaria ele no meio de uma sessão que ia bem.

"O vigia não está rodando" é `BotSupervisor.active?(MiniGame.Worker.status())` —
a mesma pergunta que o painel já faz, com a mesma resposta.

## Ajustes novos

Todos em `@seed_settings` de [`lib/pokex/settings.ex`](../../../lib/pokex/settings.ex),
a fonte única.

| chave | padrão | o que é |
|---|---|---|
| `stagnation_action` | `"alarme"` | passa a aceitar `"deslogar"` além de `"alarme"` e `"parar"` |
| `stop_after_action` | `"parar"` | `"parar"` ou `"deslogar"` — o que fazer ao bater meta de tempo/kills |
| `logout_key` | `"ctrl+q"` | a tecla que abre o diálogo de logout |
| `logout_confirm_key` | `"enter"` | a tecla que confirma |
| `logout_confirm_delay_ms` | `300` | espera entre as duas teclas |
| `logout_verify_delay_ms` | `1500` | espera antes da primeira conferência de tela |
| `logout_attempts` | `3` | quantas vezes tenta antes de gritar |

`logout_key` e `logout_confirm_key` são ajustes (e não constantes) pelo mesmo motivo
que `defense_mode_key` e `attack_mode_key` são: o Lucas remapeia teclas no jogo e não
deveria precisar de mim para isso. `Rig.Mac.Commands` já entende o prefixo `ctrl+`
([`commands.ex:6`](../../../lib/pokex/rig/mac/commands.ex)); o combo cai no caminho
osascript, que é o correto para modificadores.

## Painel

Em **Ações & Regras**:

* botão **"Deslogar agora"** — chama `Logout.request("manual")`. Serve para testar o
  mecanismo ao vivo sem esperar cinco minutos de ociosidade, e para sair limpo sem ir
  até o jogo;
* o seletor de ação da estagnação ganha a opção **"deslogar"**;
* um seletor novo para a ação das metas de sessão (`"parar"` / `"deslogar"`);
* o resultado do último logout: quando, por qual motivo, e se confirmou.

O painel assina o tópico `"logout"` e **precisa de um `handle_info` pega-tudo**. A
ausência dele derrubaria a LiveView exatamente no momento do logout — foi o que quase
aconteceu no PR #86 com a caçada.

**Nota de merge:** o PR #86 mexe em `panel_live.ex` e ainda está aberto. Mergear #86
antes evita um conflito pequeno mas chato nesse arquivo.

## Testes

Nenhum toca a rede; nenhum captura a tela de verdade.

**`Logout.Logic` (puros):**
1. `start` devolve `:press` na tentativa 1
2. `after_press(:ok)` devolve `:verify`
3. duas leituras `:gone` seguidas → `{:finish, :out}`
4. `:gone` seguido de `:present` zera `confirms` — não confirma
5. `:unreadable` nunca confirma, por mais que se repita
6. esgotar `@reads_per_attempt` inicia nova tentativa com `:press`
7. esgotar `logout_attempts` → `{:finish, {:failed, _}}`
8. `after_press({:error, :panic_corner})` conta como tentativa falha

**`Logout` worker** (Body falso, `stop_fun`/`front_fun`/`read_fun` injetados):
9. caminho feliz: latch travado, `stop_fun` chamado, sequência de teclas correta na
   ordem `[press, wait, press]`, resultado `:out` publicado no tópico `"logout"`
10. HUD continua legível → depois das tentativas publica falha **e** alarme
11. `read_fun` devolvendo `:unreadable` sempre → **nunca** reporta `:out`
12. `request/1` durante um logout em voo é ignorado e conta em `duplicates`
13. `front_fun` devolvendo `{:error, :panic_corner}` → falha, e o `Body` nunca é chamado
14. o latch continua travado depois de um logout bem-sucedido

**`ShinyGuard`:**
15. latch travado + `shiny_action: "fugir"` → `escape_fun` **não** é chamado
16. latch travado → o alarme **é** publicado mesmo assim
17. latch livre + `"fugir"` → `escape_fun` é chamado (não regredimos o comportamento)

**`Guardian`:**
18. `stagnation_action: "deslogar"` → chama o `logout_fun` injetado com o motivo
19. `stop_after_action: "deslogar"` numa meta batida → idem
20. `stop_after_action: "parar"` continua parando como hoje
21. um `clears` do minigame zera o relógio da estagnação
22. com o vigia do minigame parado, um `hooked` zera o relógio
23. com o vigia do minigame rodando, um `hooked` **não** zera o relógio

**`Focus.ensure_front/0`:** a suíte existente do `PlayerSupport` é a rede da extração.

**Painel:**
24. o botão "Deslogar agora" chama `request/1`
25. uma mensagem `{:logout, _}` inesperada não derruba a LiveView

## Riscos conhecidos

* **A tecla pode não ser Ctrl+Q em todo cliente.** É ajuste; o Lucas troca no painel.
  O padrão nunca é `cmd+q`, que no macOS fecharia o cliente inteiro.
* **A checagem da HUD é negativa.** Ela prova "não vejo mais o jogo", não "vejo a tela
  de personagens". O viés para falha cobre a diferença até a calibração da tela de
  seleção existir.
* **`logout_verify_delay_ms` é um chute de 1,5s.** Se a tela do Lucas demorar mais, a
  primeira leitura sai `:present` e ele gasta uma tentativa à toa — mas ainda
  converge, e o número é ajuste.
* **Validação ao vivo pendente.** Nada disso foi visto funcionando no jogo real. O
  botão manual do painel existe exatamente para essa primeira prova.
