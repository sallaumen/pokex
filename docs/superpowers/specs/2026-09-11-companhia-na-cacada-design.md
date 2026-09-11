# Companhia na caçada: responder como gente quando alguém aparece

Data: 2026-09-11. Autor: a IA, a pedido do Lucas. Estado: **plano, aguardando a
revisão dele antes de qualquer código.** Identificadores em inglês; texto pro
usuário em pt-BR.

> "Quando identificar um player na minha tela ou uma mensagem em amarelo …
> parar tudo … depois de matar tudo, depois de usar o revive, quando estiver
> tudo seguro quanto ao keyboard, apertar Enter, escrever, Enter de novo e
> continuar a rota. … A ideia é responder GMs e gente que manda mensagem, pra
> não descobrirem que a gente é um bot."

## 0. O resumo, pra quem tem cinco minutos

Dois gatilhos, uma resposta, três lugares que já existem.

- **Gatilhos.** (a) Alguém **falou** perto: o cliente desenha a fala em amarelo
  sólido no mapa, em cima de quem falou (`Nome says: texto`). (b) Um **player
  com guilda parou na sua cola**: a ≤ `company_watch_tiles` de você por
  ≥ `company_watch_ms` (5 s). Player sem guilda e calado é invisível — decisão
  dele (§2.3), não limitação escondida.
- **Resposta.** Só quando a rodada fecha (a mesma borda da bola: pilha morta,
  revive confirmado, bola jogada), o cérebro segura estrada, fogo e revive por
  ~5 s, e pede UMA frase. A mão aperta `Enter`, digita a frase, `Enter`. A prova
  é a sua própria fala amarela aparecer em cima de você. Sem prova, trava de
  pânico e alarme: chat aberto é tecla de skill virando letra.
- **Ritmo humano.** Uma frase a cada 10–15 min, no máximo, guardada em disco
  (restart não repete). Frases dele, de encerrar papo ("to aqui .-.", "coe"),
  sorteadas sem repetir a última. Nada de "oi?".
- **Só isso.** A caçada não muda de postura nem sai do jogo por causa de
  companhia (opções 2 e 3 recusadas por ele).

Onde mora: o olho no `CrowdWatch` (mais duas leituras no quadro que ele já
captura), o cérebro em `Engine.Situation`/`Engine.Logic` (um estado, `:talking`,
na borda `round_closed?`), a mão no `PlayerSupport.Worker` (que já obedece
`orders.revive`). Nenhum worker novo, nenhum capturador novo, nenhum segundo
dono do "agora é seguro".

Três PRs (§6): o olho em sombra, a mão com botão manual, o cérebro. O que só
ele pode fazer está em §7.

## 1. As decisões dele, fechadas na conversa de 11/09

1. **Os dois gatilhos**, fala e player na cola — não só a fala. "Talvez o
   player não fale nada, só fique."
2. **Só fala.** Não muda a caçada pra "casual", não faz logout por vigia. Ele
   escolheu a opção 1 das três.
3. **Cooldown de 10–15 min** com o carimbo da última mensagem salvo, "pra se o
   cara decidir caçar mesmo assim me dando KS, não ficar óbvio que sou um bot
   pelas mensagens".
4. **Frases não convidativas.** "Cuidado com 'oi?', tem que ser mais algo pra
   acabar a conversa e ir embora caçando, tipo 'to aqui .-.' ou 'coe'."
5. **Parecer humano**: limpar o mapa, esperar pelo menos uns 5 s, aí falar.
6. **Não bugar o bot** é a prioridade — a sequência de teclas tem que ser
   provada.
7. **O cliente**: `Enter` abre o chat, `Enter` manda e FECHA; `Enter` em caixa
   vazia também fecha (é um toggle).
8. **Detecção de player pela linha de guilda + fala** (opções 2 e 5 de §2.3):
   "não acho que dê conta de fazer a barra que não cai sem muitos erros".

## 2. O que a tela mostra, medido

Quadro `~/.pokex/captures/crowd_scan.raw` (ultrawide, 2416×1440, 11/09) e os
prints dele da cidade. Os prints vieram comprimidos pelo chat: as cores deles
são aproximadas; as do `.raw` são exatas.

### 2.1 Nome e barra são a cor da VIDA, pra todo mundo

- O nome dele ("Lotavanon") é (0,188,0), a mesma tinta com que a barra se
  enche (`CreatureMarks`: "everything in the fight fills (0,188,0)"). Um
  Kabutops selvagem com vida cheia: nome (0,188,0) também.
- A barra fica **embaixo** do nome, nos dois casos (player e bicho). A caveira,
  quando existe, fica em cima do nome. Nada aqui diferencia player de bicho.
- Por isso "cada player tem uma cor": um player ferido tem nome laranja, um
  cheio tem verde. Não é cor de player, é cor de vida.

### 2.2 A linha de guilda é uma segunda linha de texto, de cor por guilda

- Acima do nome dele: "Poke Titans", tinta exata **(0,154,205)**, 9 px de
  altura (linhas 589–597), 80 px de largura, contorno preto, um ícone à
  esquerda; o nome começa 5 px abaixo (linha 603).
- Nos prints da cidade: "Hunter" em laranja, "The Shoal" em amarelo, "Brock
  Brothers" em ciano. **A cor varia por guilda.** Tom exato não serve.
- O que não varia: é uma **segunda linha de texto colorido logo acima do
  nome**, numa cor que não é a cor da vida daquela barra. Bicho selvagem tem
  uma linha (o nome) e, no máximo, a caveira branca em cima.
- Players sem guilda ("Millogan", "Cariocajr") têm só o nome. Ficam invisíveis
  pra este detector.

### 2.3 As três opções que ele viu, e a que escolheu

1. A barra que não cai depois da corrente (não apanha da sua área → não é
   bicho). A mais geral; ele recusou pelo risco de erro.
2. **A linha de guilda.** Barata, sem tom a ensinar, cega pra quem não tem
   guilda. **Escolhida.**
3. Ícone de outfit na lista de batalha — não medido; descartado.
4. Caveira/escudo/emblema — só às vezes; descartado.
5. **A fala amarela.** Escolhida junto com a 2.

### 2.4 A fala e o banner de skill

- Fala: amarelo sólido, "Nome says: texto", desenhada em cima de quem falou
  (o print dele com "Lotavanon says: teste"). O tom exato ainda não foi
  medido num quadro sem perda (§7.1). Quem falou é um ponto: acima do SEU
  ponto calibrado é você; em qualquer outro lugar é outra pessoa.
- Banner de skill ("SLASH!", "ANCIENT POWER!"): tinta **(253,169,40)**,
  laranja-amarelo, também sobre o mapa. Se o amarelo da fala for o amarelo
  puro que o print sugere, a separação é por tom, com um teste de fixture
  que garante que o banner NÃO conta como fala.
- NPC ("Nurse Joy"): nome em azul claro, sem barra. Não há NPC em área de
  caça; fora do escopo.

### 2.5 O que a lista de batalha não resolve

`Engine.BattleRows`: o leitor de nome das linhas devolve `nil` em campo
(`:by_name` zero vezes em duas noites). "Nome que não está na Pokédex = player"
não vale hoje. E o pokémon de outro player aparece como bicho (nome verde,
barra) — a régua já o conta como inimigo hoje; este plano não muda isso (§8).

## 3. O olho: `Pokex.Vision.Company` + `CrowdWatch`

### 3.1 O que lê

Módulo puro novo, `Pokex.Vision.Company.find(frame, marks, me, geo)`, chamado
pelo `CrowdScan.look/1` no MESMO quadro e com as MESMAS marcas
(`CreatureMarks`) que ele já tem. Nenhuma captura nova. Devolve:

```elixir
%{
  players: [%{x: integer, y: integer, tiles: float}],   # tiles a partir DELE
  speech: :none | :mine | :theirs
}
```

**Player** = uma marca (barra) que não é ele e não é o pet, com uma **linha de
guilda**: uma forma de `Ink.find/3` na faixa logo acima do nome (a faixa entre
`name_top − 2·text_h` e `name_top`, em pontos × `frame.scale`), com altura de
texto (7–12 pt), largura de texto (≥ 2,5 × altura), tinta colorida (saturação
≥ 60 e canal máximo ≥ 140: nem preto, nem cinza, nem branco — a caveira é
branca) e de uma **cor diferente da tinta da barra** daquela marca. A
distância em tiles é a da própria marca, que o `CrowdScan.place/3` já calcula.

**Fala** = formas de `Ink.find/3` com a tinta amarela da fala (constante medida
no quadro sem perda, §7.1; tolerância pequena, e o banner (253,169,40) fora
dela), altura de texto, em qualquer lugar do quadro. `:mine` se alguma forma
está a ≤ 1,5 tile acima do ponto calibrado dele; senão `:theirs`. A fala dele
enquanto ele mesmo digita no jogo também vira `:mine`: sem uma fala em
andamento, o cérebro ignora.

### 3.2 O que publica

O fato `:crowd` que o `CrowdWatch` já escreve ganha a chave `company` com o
mapa acima. Cadência inalterada: a cada `crowd_scan_every_ms` na luta, 1 s
andando. Custo: uma passada de tinta por faixa de nome (faixas de ~80×20 px)
mais uma passada amarela no quadro, do mesmo tipo que o `NameLabels` já faz
em 14–31 ms.

### 3.3 Em sombra primeiro

A PR do olho (§6) não muda comportamento: a Central mostra 👀 "player na cola
há 12 s" e 💬 "alguém falou", o diário registra, e ele lê uma noite antes de
ligar a mão. É a disciplina do olho do cerco (PR 1 → uma noite de sombra).

## 4. O cérebro: `Engine.Situation` + `Engine.Logic`

### 4.1 A leitura vira memória

`Situation` ganha:

```elixir
company: %{
  watched_for_ms: non_neg_integer,   # player a ≤ company_watch_tiles, acumulado
  spoken_at: integer | nil,          # última fala :theirs vista
  last_talk_at: integer | nil        # do fato :talk (§5.3)
}
```

`watched_for_ms` acumula entre leituras enquanto algum player está a
≤ `company_watch_tiles` dele; tolera UMA leitura sem player (efeito de skill
cobre rótulos, e o `NameLabels` já conta pra baixo por isso) e zera na segunda.
`spoken_at` fica valendo por `company_pending_ttl_ms` (60 s): quem fala no meio
da luta ainda é companhia quando a rodada fecha.

### 4.2 Companhia pendente

```
pending? = company_enabled
       and (watched_for_ms ≥ company_watch_ms or spoken_at recente)
       and (last_talk_at == nil or now − last_talk_at ≥ cooldown_atual)
```

`cooldown_atual` = `company_talk_cooldown_ms` + um sorteio em
`0..company_talk_cooldown_jitter_ms`, feito uma vez por frase enviada e guardado
junto do carimbo — "10–15 min", e não "12 min cravados".

### 4.3 O estado `:talking`

- **Entra** numa borda só: `round_closed?/2` (a mesma da bola) com `pending?`.
  Se a bola foi chamada nesse tique (`capture: :now`), a fala espera o fato
  `:capture` terminar (`capturing?` falso) — a bola vai antes da fala. Enquanto
  espera, o cérebro guarda `talk_due` no `since`.
- **Segura tudo**: `Orders.standing(:talking, band, why)` — `route: :hold`,
  `fire: :hold`, `revive: :hold`. É o contrato que Cavebot, Combat e Suporte já
  obedecem; nada novo neles.
- **Espera** `company_settle_ms` + sorteio em `0..company_settle_jitter_ms`
  (5–8 s; "pelo menos uns 5 segundinhos" sem cravar 5,0).
- **Chama a mão UMA vez**: `{:talk_now}` como mensagem no tópico do engine,
  igual `{:capture_now}` — a hora é uma borda, e uma borda não sobrevive num
  fato com idade. Marca `since[:talk_cued]`.
- **Sai** quando o fato `:talk` diz `:proven` ou `:unproven`, ou quando
  `company_talk_timeout_ms` (10 s) passa desde a chamada. Depois volta pra
  decisão normal, com a companhia zerada (`spoken_at` e `watched_for_ms`) —
  a próxima frase precisa de companhia nova E cooldown vencido.
- **Bicho novo antes da chamada**: sai do `:talking` e volta pra luta; a
  companhia continua pendente pra próxima rodada.
- **Bicho novo depois da chamada**: **fica** segurando até o veredito. São no
  máximo 5 s de pokémon apanhando; a alternativa é uma corrente inteira
  digitada num chat aberto. Esta é a regra que ele pediu — "cuidado pra não
  bugar" — escrita como preferência explícita.

### 4.4 As duas mãos que não olham `orders.fire`

- `Timers.Worker.mobbing?/1` liga a aura em qualquer `route: :hold`. Passa a
  ser falso quando `orders.phase == :talking` — um `shift+3` no meio da
  digitação viraria "#" no chat.
- A corrente do Combat sai por `Rig.press_many` direto, mas só na borda
  `hold → free` do fogo; em `:talking` o fogo é `:hold` e a rodada acabou de
  fechar, então não há corrente em voo. Sem mudança, com teste (§5.4).

## 5. A mão: `PlayerSupport.Worker`

### 5.1 A sequência

Ao receber `{:talk_now}`, com `company_enabled` e a caçada ativa:

```elixir
Body.perform([:still, {:press, "return"}, {:type, phrase}, {:press, "return"}], :high)
```

Uma sequência só, atômica no Body: ninguém interpõe tecla entre o primeiro
`Enter` e o segundo. `:still` solta as setas antes (a regra do #495: tecla que
não anda junto). `{:type, text}` é ação nova do Body, mapeada em
`Rig.type/1`; no `Rig.Mac` é o `keystroke "texto"` por osascript que
`Rig.Mac.Commands` já monta pra tecla não mapeada (o chat quer caracteres, não
eventos de tecla); `Rig.Fake` e `Rig.Sim` registram a chamada.

A frase: sorteio de `company_phrases` sem repetir a última enviada.

### 5.2 A prova

Depois do `Body.perform`, o worker publica o fato `:talk` como `:typing` e
observa o `:crowd`: `speech: :mine` em até `company_proof_ms` (5 s) →
`:proven`, grava o carimbo e o cooldown sorteado, feed 💬 "disse 'coe'".

Sem prova → **`InputGate.set_panic_latch(true)` PRIMEIRO**, depois
`BotSupervisor.safe_halt`/stop da frota, alarme (`Siren`, categoria própria) e
diário "a frase não apareceu na tela: chat pode estar aberto". Ninguém aperta
mais nada até ele olhar e dar Iniciar. É a ordem do caminho de pânico da casa,
e o único desfecho aceitável pra "não sei se o chat fechou".

### 5.3 O fato `:talk` e o carimbo em disco

```elixir
%{status: :idle | :typing | :proven | :unproven, phrase: String.t() | nil,
  at: integer, last_talk_at: integer | nil, cooldown_ms: integer | nil}
```

`last_talk_at` e `cooldown_ms` vivem em `~/.pokex/company.json`
(`Pokex.StateFile`), lidos no boot do worker e republicados no fato: restart no
meio da noite não repete a frase. O cérebro lê `last_talk_at` do fato sem
cobrar idade (é memória, não leitura).

### 5.4 O botão manual

Na Central, com a frota PARADA: "falar agora" manda `{:talk_now}` direto pro
suporte. Ele testa a sequência inteira (Enter, texto, Enter, prova) olhando a
tela, antes de qualquer cérebro chamar. Só aparece com a frota parada, porque
parada não há outra mão.

## 6. Config, calibração e diário

### 6.1 Knobs (`Settings`, com faixa no `/config`)

| chave | default | o que é |
|---|---|---|
| `company_enabled` | `false` | nasce desligado; ele liga depois da noite de sombra |
| `company_phrases` | `["to aqui .-.", "coe"]` | as frases dele |
| `company_watch_tiles` | 4 | "na cola", em tiles dele |
| `company_watch_ms` | 5 000 | quanto tempo parado vale como vigia |
| `company_pending_ttl_ms` | 60 000 | quanto tempo uma fala/vigia espera a rodada fechar |
| `company_settle_ms` | 5 000 | parado antes de falar |
| `company_settle_jitter_ms` | 3 000 | sorteio somado ao anterior |
| `company_talk_cooldown_ms` | 600 000 | mínimo entre frases |
| `company_talk_cooldown_jitter_ms` | 300 000 | sorteio somado ao anterior (10–15 min) |
| `company_proof_ms` | 5 000 | prazo da prova |
| `company_talk_timeout_ms` | 10 000 | teto do `:talking` depois da chamada |

**Frase inválida** no `/config`: contém dígito (tecla de skill; se o primeiro
`Enter` não abrir o chat, "1" vira corrente). A página diz qual caractere. Uma
letra que é tecla ("e" da poção de status, "q" do stun) só gera AVISO — sem o
chat aberto ela aperta uma tecla inofensiva, e proibir "coe" seria proibir a
frase dele.

### 6.2 Calibração

Nada a ensinar por clique. O amarelo da fala é constante medida (§7.1) com
teste de fixture, como o verde do nome e o laranja do banner; a linha de
guilda é forma, não tom. O ponto dele já está calibrado.

### 6.3 Central, feed, eventos

- Card da caçada: 👀 "player na cola há 12 s", 💬 "alguém falou (há 8 s)",
  🗨 "disse 'coe' às 02:41", ⏳ "próxima frase em 9 min".
- Feed e `Engine.Events`: `company_seen`, `talk_cued`, `talk_sent`,
  `talk_proven`, `talk_unproven`. O diário conta as frases de saída, que é como
  ele mede régua (a régua medida no diário).
- Foto com marcas no momento da chamada: o `CrowdWatch` já guarda 30; ganha o
  rótulo `talk`.

## 7. O que só ele pode fazer

### 7.1 Dois PNGs sem perda (cmd+shift+3)

1. **A cidade**, com players com e sem guilda e um NPC: vira fixture da linha
   de guilda (quem é player, quem não é; a régua é a lista dos nomes que ele
   mesmo aponta).
2. **Ele falando**: digita qualquer coisa e tira o print em até 3 s. Fixa o
   amarelo exato da fala e vira a fixture da prova.

Com o quadro da morte de 01:34 (guardado em `~/.pokex/captures/morte-0134.raw`: banners, caveiras, sem player)
como fixture negativa.

### 7.2 As frases

Escrever `company_phrases` como ele escreveria. Sem dígito.

### 7.3 Uma noite de sombra com a PR 1

Ler o diário: quantos 👀 e 💬, e se algum foi falso (banner lido como fala,
skull ou efeito lido como linha de guilda). Só então PR 2 e 3.

### 7.4 O botão manual com a PR 2

Frota parada, no meio da caçada dele, apertar "falar agora" e ver a frase
sair e a prova fechar. Se o `Enter` do cliente dele se comportar diferente do
que ele descreveu (§1.7), é aqui que aparece — com ele olhando.

## 8. Fora do escopo, anotado

- Modo pesca e `hunt: nil`: o `:talking` mora no ramo da caçada.
- Mudar a postura de caça ou sair do jogo por vigia (opções 2 e 3, recusadas).
- Player sem guilda e calado (decisão de §2.3).
- Ler o TEXTO que o outro falou; responder a GM por cor própria (nunca medida).
- O pokémon de outro player contado como inimigo pela régua (§2.5): assunto da
  régua, não deste plano.
- Detectar o chat aberto pela caixa de texto (região calibrável): refinamento
  possível se a prova pela fala se mostrar insuficiente.

## 9. Testes

- **Visão** (`test/pokex/vision/company_test.exs`, fixtures de §7.1): players
  com guilda achados com a distância certa; players sem guilda ausentes;
  Kabutops com caveira NÃO é player; o próprio personagem não é player; fala
  dele é `:mine`, fala de outro é `:theirs`; banner "SLASH!" não é fala.
- **Situation**: `watched_for_ms` acumula, tolera um buraco, zera no segundo;
  `spoken_at` expira em `company_pending_ttl_ms`.
- **Logic**: entra só na borda `round_closed?`; espera a bola; uma chamada por
  rodada; respeita cooldown e carimbo; sai por `:proven`/`:unproven`/timeout;
  bicho antes da chamada solta, bicho depois segura; `company_enabled: false`
  nunca entra.
- **Timers**: `mobbing?` falso em `:talking`.
- **Suporte** (Body falso, padrão dos testes de revive): a sequência exata com
  `:still` na frente; `:proven` grava carimbo e cooldown; `:unproven` chama o
  latch ANTES do halt e `InputGate.allowed?` fica falso; frase não repete a
  última; `{:type, _}` chega ao `Rig.Fake`.
- **Settings**: dígito reprova, letra-tecla avisa.
- **Bancada/sim**: nada muda; o sim não tem players.

## 10. As PRs

1. **O olho em sombra** — `Vision.Company`, fixtures, `company` no `:crowd`,
   Central e diário. Zero comportamento. Depende de §7.1.
2. **A mão** — `{:type, _}` no Body/Rig, executor no suporte, fato `:talk`,
   carimbo em disco, knobs e validação das frases, botão manual. Nada chama a
   mão além do botão.
3. **O cérebro** — `Situation.company`, `:talking`, `{:talk_now}`, `Timers`,
   eventos. Armado por `company_enabled`.

Cada uma fecha sozinha; a ordem é a da confiança: ver, depois apertar com ele
olhando, depois deixar o cérebro apertar.
