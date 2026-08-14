---
name: Pokex
description: Console escuro que roda por cima de um MMO em tela cheia — o que o bot vê, faz e erra, ao vivo.
colors:
  pk-bg: "#080b0d"
  pk-surface: "#111519"
  pk-raised: "#171c21"
  pk-sunken: "#0c1013"
  pk-line: "#232b30"
  pk-line-strong: "#313a40"
  pk-text: "#dfe3e7"
  pk-text-2: "#97a1a9"
  pk-text-3: "#838d95"
  pk-ok: "#37d07d"
  pk-ok-dim: "#0d3822"
  pk-ok-line: "#237d4d"
  pk-warn: "#f2c45b"
  pk-warn-dim: "#211b0d"
  pk-warn-line: "#674f20"
  pk-danger: "#ff9ca4"
  pk-danger-dim: "#241114"
  pk-danger-line: "#5f292f"
  pk-info: "#6cb8f2"
  pk-info-dim: "#0c1f2e"
  pk-info-line: "#2b6086"
typography:
  # Sem `fontSize` de propósito. A escala de três degraus existe e é maioria
  # (415 usos), mas 128 usos de `text-[Npx]` ainda vivem fora dela — declarar o
  # ramp aqui acenderia os 128 de uma vez e enterraria a deriva de verdade.
  # Os degraus estão na seção Typography, em prosa, e voltam pra cá quando a
  # migração fechar. Ver "A Regra dos Três Degraus".
  title:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontWeight: 700
    lineHeight: 1.3
  body:
    fontFamily: "ui-sans-serif, system-ui, sans-serif"
    fontWeight: 400
    lineHeight: 1.5
  label:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
    fontWeight: 600
    lineHeight: 1.2
    letterSpacing: "0.12em"
  readout:
    fontFamily: "ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace"
    fontWeight: 700
    lineHeight: 1.2
    fontFeature: "tabular-nums"
rounded:
  sm: "0.25rem"
  md: "0.375rem"
  lg: "0.5rem"
  xl: "0.75rem"
  2xl: "1rem"
  full: "9999px"
spacing:
  xs: "4px"
  sm: "6px"
  md: "8px"
  lg: "12px"
  xl: "16px"
components:
  button-primary:
    backgroundColor: "{colors.pk-ok}"
    textColor: "{colors.pk-bg}"
    typography: "{typography.title}"
    rounded: "{rounded.xl}"
    height: "48px"
    width: "100%"
  button-danger:
    backgroundColor: "{colors.pk-danger-dim}"
    textColor: "{colors.pk-danger}"
    typography: "{typography.title}"
    rounded: "{rounded.xl}"
    height: "48px"
    width: "100%"
  button-icon:
    backgroundColor: "transparent"
    textColor: "{colors.pk-text-2}"
    rounded: "{rounded.lg}"
    size: "32px"
  button-icon-hover:
    backgroundColor: "{colors.pk-raised}"
    textColor: "#ffffff"
  card:
    backgroundColor: "{colors.pk-surface}"
    textColor: "{colors.pk-text}"
    rounded: "{rounded.lg}"
    padding: "{spacing.lg}"
  card-sunken:
    backgroundColor: "{colors.pk-sunken}"
    textColor: "{colors.pk-text-2}"
    rounded: "{rounded.lg}"
    padding: "{spacing.md}"
  input:
    backgroundColor: "{colors.pk-raised}"
    textColor: "{colors.pk-text}"
    typography: "{typography.label}"
    rounded: "{rounded.lg}"
    padding: "0 8px"
    height: "32px"
  pill-status:
    backgroundColor: "transparent"
    textColor: "{colors.pk-text-2}"
    typography: "{typography.label}"
    rounded: "{rounded.full}"
    padding: "4px 10px"
  nav-item:
    backgroundColor: "transparent"
    textColor: "{colors.pk-text}"
    typography: "{typography.body}"
    rounded: "{rounded.md}"
    padding: "10px 12px"
  nav-item-active:
    backgroundColor: "{colors.pk-ok-dim}"
    textColor: "{colors.pk-ok}"
  strip-warn:
    backgroundColor: "{colors.pk-warn-dim}"
    textColor: "{colors.pk-text}"
    padding: "6px 8px"
---

# Design System: Pokex

## Overview

**Creative North Star: "O Painel de Fósforo"**

O Pokex não é uma página: é um aparelho ligado ao lado de um jogo em tela cheia,
lendo pixels e movendo o mouse de verdade. A herança visual é de osciloscópio e
CRT — vidro quase preto (`pk-bg`), UM verde que significa que a máquina está
viva, e número monoespaçado tabular porque uma contagem que vai de 99 pra 100
não pode empurrar a linha inteira de lado a cada leitura. Escuro não é tema
escolhido: é o único tema, cravado em `root.html.heex`, porque uma segunda
aparência pra manter era um botão a mais em cada header e ninguém usava.

A densidade é deliberadamente alta. Este painel é lido de canto de olho, no meio
de uma caçada, por alguém cuja atenção principal está no jogo — não numa sessão
de leitura confortável. Por isso hairline em vez de caixa, quatro superfícies
tonais em vez de sombra, e um rótulo de 11px que existe pra dizer o nome do
número, não pra ser lido devagar. O lúdico está no equipamento e na paleta de
elementos da Pokédex, não em enfeite aplicado por cima: o charme vem do
artesanato — tipo disciplinado, paleta comprometida, movimento com propósito.

Duas coisas este sistema nunca pode virar, e ambas são armadilhas reais para
ele. **Dashboard SaaS genérico** — card claro flutuando, sombra difusa em tudo,
gráfico colorido por padrão, respiro largo — mata a densidade de que o painel
depende. **Site infantil de Pokémon** — amarelo-e-vermelho de marca, canto de
bolha, emoji como decoração, ilustração fofa — é lúdico virando infantil, que é
exatamente a linha que o `AGENTS.md` traça.

**Key Characteristics:**

- Um tema só, escuro, sem toggle: `data-theme="dark"` cravado no root.
- Quatro superfícies tonais (`bg` → `sunken` → `surface` → `raised`) e fio de
  1px fazendo todo o trabalho que sombra faria em outro sistema.
- Um sotaque só: Verde Ácido. Estado é sempre cor **mais** ícone ou rótulo.
- Monoespaçado tabular para todo número que muda sozinho.
- Três degraus de tipo e nada além; rótulo em caixa alta com `0.12em`.
- Foco visível obrigatório: o app comanda o mouse de verdade, então "onde estou"
  não pode depender de enxergar o cursor.

## Colors

Uma paleta de console noturno: quase-pretos frios separados por poucos pontos de
luminância, três níveis de texto e nada além, e cores de estado que só aparecem
quando há estado. A única saturação alta do sistema é o verde.

### Primary

- **Verde Ácido** (`pk-ok`): o bot te olhando. É a máquina viva — pill "Ativo",
  item de nav atual, botão Iniciar, anel de foco, leitura dentro do normal.
  Também é o `--color-primary`, `--color-secondary`, `--color-accent` e
  `--color-success` do tema daisyUI: um verde só, quatro papéis. Acompanha
  `pk-ok-dim` (fundo de pastilha) e `pk-ok-line` (fio da pastilha).

### Secondary

- **Âmbar de Aviso** (`pk-warn`): a única cor que interrompe. Reservada para o
  estado em que uma leitura pode estar errada — calibração de outra tela, outro
  Pokex na mesma máquina, som de alarme mudo. Com `pk-warn-dim` de fundo e
  `pk-warn-line` de fio, forma a tarja fixa abaixo do header.
- **Rosa de Perigo** (`pk-danger`): rosa dessaturado, não vermelho de alerta —
  ele precisa conviver com o quase-preto sem vibrar. Marca o que parou, falhou
  ou é destrutivo (botão Parar, HUD não localizado, hover de apagar).

### Tertiary

- **Azul de Modalidade** (`pk-info`): explicitamente **não** é estado. Nada em
  azul está ok, em atenção ou em erro — azul marca uma modalidade, hoje o trecho
  da rota andado mobando. 8.54:1 sobre a superfície.

### Neutral

- **Vidro** (`pk-bg`): o fundo de tudo, mais escuro que qualquer card.
- **Superfície** (`pk-surface`): o card padrão e o header.
- **Elevado** (`pk-raised`): hover, campo dentro de card, linha destacada.
- **Afundado** (`pk-sunken`): o poço — trecho de log, leitura crua, o que está
  DENTRO de um card e é conteúdo, não moldura.
- **Fio** (`pk-line`) e **Fio Forte** (`pk-line-strong`): a separação padrão e a
  do que é operável. Borda de controle é sempre a forte.
- **Texto**, **Texto 2**, **Texto 3** (`pk-text`, `pk-text-2`, `pk-text-3`):
  leitura, apoio e etiqueta. `pk-text-3` é `#838d95` e não mais apagado por um
  motivo medido: `#6d7780` dava 4.02:1 sobre a superfície e reprovava nos 4.5:1
  da WCAG AA.

### A Paleta de Elementos

Sistema à parte e legítimo: `PokexWeb.PokedexStyle` guarda 20 pares
`{texto, fundo}`, um por elemento (fire, water, grass…), tunados para a
superfície quase-preta — saturados o bastante para ler como "o de Fogo" de
relance, escuros o bastante para não vibrarem numa lista densa. Os clãs do PXG
vestem a paleta do seu elemento (Volcanic usa Fogo, Seavell usa Água), então o
olho aprende UMA paleta, não duas. Os valores são normativos e vivem no sidecar
`.impeccable/design.json` (`extensions.colorMeta.element-*`); nunca escreva um
par de elemento à mão — chame `PokedexStyle.element_style/1`.

### Named Rules

**A Regra do Sotaque Único.** Verde Ácido é a única cor saturada do sistema e
significa uma coisa só: algo está vivo agora. Se o elemento não representa
máquina rodando, estado ok ou o lugar onde você está, ele não é verde. Verde
como enfeite, como cor de marca ou como "cor bonita de destaque" é defeito.

**A Regra da Cor Acompanhada.** Cor de estado nunca viaja sozinha. Todo uso de
`pk-ok`/`pk-warn`/`pk-danger` carrega ícone ou rótulo textual junto — quem não
distingue as três matizes ainda precisa saber o que está acontecendo.

**A Regra do Azul Sem Estado.** Azul não é um quarto estado. Se você quer dizer
"ok", "atenção" ou "erro", há três cores para isso. `pk-info` marca modalidade —
outro modo de operação da mesma coisa.

## Typography

**Display / Body Font:** stack de sistema (`ui-sans-serif, system-ui, sans-serif`)
**Label / Readout Font:** stack mono do sistema (`ui-monospace, SFMono-Regular, Menlo, Monaco, Consolas, monospace`)

Nenhuma fonte é carregada: zero `@font-face`, zero Google Fonts. Um console que
sobe em `localhost` ao lado de um jogo não paga request de fonte, e a stack de
sistema no macOS já é exatamente a voz certa — neutra na leitura, técnica no
número. **Character:** a sans some de propósito; o mono é que tem sotaque. 341
usos de `font-mono` fazem dele o traço tipográfico mais reconhecível do app.

### Hierarchy

- **Title** (700, `0.9375rem` / 15px, `--text-pk-title`): título de card, marca no
  header, e a leitura-chave de um bloco (o HP, o px da estrela). É o maior tamanho
  do sistema — não existe display aqui.
- **Body** (400, `0.8125rem` / 13px, `--text-pk-body`): todo texto corrido, item
  de nav, linha de tarja. O piso do corpo é 12px, então este é o texto de leitura.
- **Label** (600, `0.6875rem` / 11px, `--text-pk-meta`): nome do número, título de
  grupo no menu, pill de estado. Em caixa alta com `tracking-[0.12em]` quando é
  cabeçalho de seção; em caixa normal quando é apoio.
- **Readout** (700, mono, `tabular-nums` via `.pk-num`): qualquer número que muda
  sozinho — contagem, coordenada, percentual, cronômetro.

### Named Rules

**A Regra dos Três Degraus.** A escala tem três tamanhos: 11, 13 e 15px. Não há
um quarto. Antes deles o painel tinha OITO tamanhos diferentes espalhados pelo
template, incluindo 8px e 9px, e nada estava desalinhado por acaso — não havia
sistema para alinhar. Texto de leitura nunca abaixo de 12px.

**A Regra do Número Tabular.** Todo número que se atualiza sozinho é mono e
tabular (`.pk-num` ou `tabular-nums`). Sem isso, uma contagem que vai de 99 pra
100 empurra a linha inteira de lado a cada leitura.

### Dívida conhecida: a escala ainda não fechou

Medido em 2026-08-14, em `lib/`: 415 usos dos três degraus (`text-pk-meta` 247,
`text-pk-body` 143, `text-pk-title` 25) contra **128 usos de `text-[Npx]` fora
deles** — `10px` (73), `9px` (28), `11px` (24), `12px` (2), `8px` (1) — mais 140
usos da escala padrão do Tailwind (`text-sm` 66, `text-xs` 39, `text-base` 19,
`text-lg` 11, `text-xl` 3, `text-2xl` 2). A concentração é em `team_live.ex`,
`pokedex_live.ex` e `pokedex_detail_live.ex`, páginas escritas antes dos tokens.

Por isso o frontmatter **não declara `fontSize`**: a regra `design-system-font-size`
está deliberadamente dormente. Declarar o ramp de três degraus hoje produz **105
achados** de uma vez (medido, não estimado: `pokedex_detail_live` 35,
`team_live` 25, `calibration_overlay` 15, `pokedex_live` 15, `world_live` 9…) —
ruído que enterra deriva de verdade em vez de revelá-la. Quando essas páginas
migrarem, acrescente `fontSize` aos quatro papéis e a regra acende sozinha.

Vale saber o que isso custa: `design-system-font-size` é a **única** regra do
detector que enxerga classe utilitária do Tailwind (`text-[10px]`). As outras
—`design-system-color` e `design-system-radius`— só leem declaração CSS de
verdade (`style="color: #…"`, `border-radius: …`), e passam batido por
`bg-[#090d0f]` / `border-[#8b949d]`, que é a forma que a deriva de cor tem neste
repositório. Ou seja: o hook cobre o piso mecânico e guarda contra deriva futura
em CSS, mas a dívida de hex listada abaixo é responsabilidade da revisão humana,
não da máquina.

## Layout

Coluna centrada com largura variável por página: `max-w-[1600px]` para o header e
as tarjas (que atravessam a tela inteira), e um `max_width` por página no
`Layouts.app` — `max-w-3xl` no padrão, `max-w-[1080px]`/`max-w-[900px]` nas
telas que mostram grade. Padding horizontal fixo e apertado (`px-2`), porque
margem larga é espaço que o painel não tem.

O header tem `h-12` e é `sticky top-0 z-40`. As tarjas de aviso montam abaixo
dele em `sticky top-12 z-30`, dentro do mesmo bloco fixo, para que rolar a página
nunca deixe um aviso pra trás. Popover e menu abrem em `absolute right-0 top-10
z-50`.

**Ritmo:** o passo é de 4px (escala padrão do Tailwind), e o sistema usa poucos
degraus. Padding de card: `p-3` (12px) é o padrão, `p-4` (16px) para o card mais
respirado, `p-2` (8px) para caixa de controles. Gap: `gap-2` (8px) domina, com
`gap-1`/`gap-1.5` (4/6px) dentro de uma linha e `gap-3` (12px) entre blocos.
Controles têm altura fixa `h-8` (32px), o CTA tem `h-12` (48px).

**Responsivo:** o alvo real é uma janela de desktop ao lado do jogo, e o app é
construído para ela. Só o que precisa colapsa: o rótulo da página no header
aparece a partir de `sm`, e as tarjas usam `flex-wrap`. Não há layout mobile e
não se deve inventar um.

## Elevation & Depth

Este sistema é **plano**. Profundidade é tom e fio: quatro superfícies separadas
por poucos pontos de luminância (`pk-bg` → `pk-sunken` → `pk-surface` →
`pk-raised`) e um fio de 1px (`pk-line`, ou `pk-line-strong` no que é operável).
Um card não sobe: ele muda de tom e ganha contorno. Isso é o que sustenta a
densidade — sombra em cada card viraria borrão numa tela com trinta blocos.

Sombra existe, e só para o que literalmente sai do fluxo. O header e as tarjas
usam `backdrop-blur` sobre fundo a 95% de opacidade, que é separação por camada,
não por elevação.

### Shadow Vocabulary

- **Flutuante** (`box-shadow: shadow-2xl shadow-black/50`): popover, menu de
  navegação e gerenciador de personagem — os três elementos que se sobrepõem ao
  conteúdo. Sombra preta e forte porque a superfície abaixo é quase preta.
- **Brilho de partida** (`box-shadow: 0 8px 24px rgba(57,205,118,0.16)`): exceção
  nomeada, uma só, no botão Iniciar. É o único momento em que o verde emite luz
  em vez de apenas colorir.

### Named Rules

**A Regra do Plano por Padrão.** Superfície não tem sombra. Profundidade se faz
com tom e fio. Sombra é permitida exclusivamente no que sai do fluxo — popover,
menu, overlay. O brilho do botão Iniciar é a única exceção do sistema, e é
exceção mesmo: não a estenda para outro botão sem decidir que ela virou padrão.

## Shapes

Retângulo de canto suave, sem gesto de forma. O raio padrão é **8px**
(`rounded-lg`, 166 usos) e coincide com `--radius-box`, `--radius-field` e
`--radius-selector` do tema daisyUI — card, campo, botão de ícone, popover e
tarja usam todos ele. Abaixo dele, **4px** (`rounded`, 152 usos) para o que é
pequeno e interno: item de menu, chip, célula. Acima, **12px** (`rounded-xl`, 26
usos) para os dois botões de altura 48 do painel e para as caixas que agrupam
controles; **16px** (`rounded-2xl`, 9 usos) aparece pouco e não é um degrau que
valha ampliar.

`rounded-full` (27 usos) é reservado a duas formas com significado: a pill de
estado do header e o ponto de status dentro dela, e a barra de progresso fina
(`h-1`/`h-1.5`). Círculo aqui quer dizer "isto é um indicador", não "isto é
fofo".

Borda é sempre 1px (o tema define `--border: 1.5px` para os componentes daisyUI,
mas o sistema próprio usa a de 1px do Tailwind). Nada usa borda dupla, borda
lateral de destaque, gradiente em borda ou clipping.

## Components

**Caráter: tenso e legível sob pressão.** Todo componente aqui existe para você
ler certo no meio de uma caçada em andamento — contraste alto, número tabular,
estado sempre acompanhado de ícone ou rótulo. Nenhum deles é confortável no
sentido de espaçoso; todos são confiáveis no sentido de que não te fazem errar
às duas da manhã.

### Buttons

- **Shape:** canto suave de 8px (`rounded-lg`) no botão comum e de ícone; 12px
  (`rounded-xl`) nos dois botões de comando de 48px de altura.
- **Primary (Iniciar):** o único elemento cheio de verde do app. Fundo `pk-ok`,
  texto `pk-bg` (texto escuro sobre verde, nunca branco), `h-12`, largura total,
  ícone `hero-play-solid` à esquerda, e o brilho verde nomeado na seção
  Elevation. Hover clareia o verde; `active:scale-[0.99]` dá o afundar do clique.
- **Danger (Parar):** mesma silhueta, invertida — fundo `pk-danger-dim`, fio
  `pk-danger-line`, texto `pk-danger`. Parar nunca é um botão vermelho cheio: ele
  precisa ser óbvio sem gritar mais que o estado do jogo.
- **Icon button:** `size-8`, grade centrada, fio `pk-line-strong`, fundo
  transparente, ícone `size-4`. Hover troca o fio para `pk-ok/60`, o fundo para
  `pk-raised` e o ícone para branco. É a forma padrão de tudo que abre popover.
- **Ghost / xs:** `btn btn-xs h-6`, fio `pk-line-strong`, fundo transparente,
  texto `pk-meta` — para ação secundária dentro de card (sondar, testar, medir).

### Cards / Containers

- **Corner Style:** 8px (`rounded-lg`).
- **Background:** `pk-surface` para o card padrão (21 usos), `pk-sunken` para o
  que é conteúdo cru dentro dele (15 usos), `pk-raised` para o destacado (5).
- **Shadow Strategy:** nenhuma. Ver Elevation & Depth.
- **Border:** 1px `pk-line`; `pk-line-strong` quando o card inteiro é operável.
- **Internal Padding:** `p-3` padrão, `p-4` quando respira, `p-2` em caixa de
  controles.
- **Cabeçalho de seção:** rótulo mono, caixa alta, `tracking-[0.12em]`,
  `pk-text-3`, geralmente com uma contagem à direita na mesma linha.

### Inputs / Fields

- **Style:** `h-8 min-h-0`, canto de 8px, fio `pk-line-strong`, fundo `pk-raised`
  (ou `pk-bg` quando dentro de card claro), texto no degrau de rótulo,
  `px-2`. Placeholder em `pk-text-3`.
- **Focus:** o fio vira `pk-ok/60` e o outline nativo é desligado — mas apenas
  porque `:focus-visible` global já desenha `outline: 2px solid var(--color-pk-ok)`
  com `outline-offset: 2px` em todo botão, input, select, summary, `a` e
  `[role="button"]`. Nunca remova foco sem substituir.
- **Renomear inline:** campo com fio transparente que só aparece no hover; Enter
  confirma, Esc desiste. Não existe modo de edição para entrar nem Salvar para
  achar.

### Navigation

- Menu em `<details>`, aberto por botão de ícone, ancorado à direita
  (`absolute right-0 top-10 z-50 w-52`), card `pk-surface` com fio forte e a
  sombra flutuante.
- Item: `rounded-md`, `px-3 py-2.5`, texto no degrau de corpo, ícone `size-4` em
  `pk-text-2`. Ativo: fundo `pk-ok-dim`, texto e ícone `pk-ok`, `font-semibold`,
  e `aria-current="page"`. Inativo no hover: fundo `pk-raised`, texto branco.
- Destinos são agrupados por assunto ("Pokémon", "No jogo", "Máquina") com
  cabeçalho mono em caixa alta. Nenhum título de grupo repete o rótulo de um
  destino.

### Pill de estado

O componente que diz, no header de toda página, se a máquina está viva: cápsula
`rounded-full` com fio `pk-line-strong`, `px-2.5 py-1`, texto mono em caixa alta
com `tracking-[0.14em]`, precedido de um ponto `size-1.5 rounded-full` que é
`pk-ok` quando ativo e `pk-text-3` quando parado. A cor está no ponto; a palavra
("Ativo"/"Parado") está do lado.

### Tarja de aviso

A faixa fixa abaixo do header, para o estado que torna TODA leitura errada
(calibração de outra tela, outro Pokex na mesma máquina). Ocupa a largura toda,
fundo `pk-warn-dim/95` com `backdrop-blur`, fio inferior `pk-warn-line`, ícone
heroicon à esquerda, frase em negrito `pk-warn` seguida da explicação em
`pk-text-2`, e o botão de resolver à direita. Ela some sozinha quando a condição
passa — nunca vira aviso permanente.

### Chip de elemento (componente-assinatura)

O único lugar onde o sistema é colorido, e o charme assumido do produto: nome do
elemento (ou do clã) com `color`/`background-color` vindos de
`PokedexStyle.element_style/1`, mais o ícone oficial do wiki quando
`priv/static/images/pokedex/elements/<element>.png` existe. A cor é a camada
garantida (dado puro, sempre disponível); o ícone é o bônus. Vinte paletas, um
par cada, e nenhuma delas escrita à mão no template.

### Barra de leitura

Trilho `h-1`/`h-1.5` `rounded-full` em `pk-line`, preenchimento
`rounded-full transition-[width]` cuja cor é o estado da leitura (`pk-ok` seguro,
`pk-warn` limítrofe, `pk-danger` estourado, `pk-line-strong` sem dado), largura
por `style="width: N%"`. Usada para HP, progresso de estrela de shiny e barras de
skill. É a única animação de layout do sistema, e ela existe porque o valor muda
sozinho e o olho precisa perceber a direção.

## Do's and Don'ts

### Do:

- **Do** pedir um papel, não uma cor: `bg-pk-surface`, `text-pk-text-2`,
  `border-pk-line`. Os tokens `--color-pk-*` são a fonte da verdade; hex literal
  em template é deriva mesmo quando acerta o valor.
- **Do** usar os três degraus de tipo (`text-pk-meta`, `text-pk-body`,
  `text-pk-title`). Nenhuma tela nova precisa de um quarto tamanho.
- **Do** marcar todo número que muda sozinho com `.pk-num` ou `tabular-nums`,
  em `font-mono`.
- **Do** acompanhar cor de estado com ícone heroicon ou rótulo textual.
- **Do** fazer profundidade com tom e fio (`pk-sunken`/`pk-surface`/`pk-raised`
  + `border-pk-line`), e reservar sombra para popover e overlay.
- **Do** usar 8px (`rounded-lg`) como raio padrão, e `rounded-full` só onde
  círculo significa "indicador".
- **Do** chamar `PokedexStyle.element_style/1` para qualquer cor de elemento ou
  de clã.
- **Do** deixar o foco visível: o app comanda o mouse de verdade, então "onde
  estou" não pode depender de enxergar o cursor.
- **Do** respeitar `prefers-reduced-motion` — o app já zera transição e animação
  nesse modo, e qualquer movimento novo precisa cair junto.

### Don't:

- **Don't** parecer dashboard SaaS genérico: card claro flutuando, sombra difusa
  em todo bloco, respiro largo, gráfico colorido por padrão. A densidade aqui é
  requisito, não descuido.
- **Don't** parecer site infantil de Pokémon: amarelo-e-vermelho de marca, canto
  de bolha, ilustração fofa, emoji de enfeite. Lúdico vem do artesanato — tipo
  disciplinado, paleta comprometida, movimento com propósito.
- **Don't** usar emoji na interface. Onde hoje há emoji em rótulo, opção ou
  título, o alvo é heroicon — o app já embute o set inteiro. Ver a dívida abaixo.
- **Don't** escrever `text-[10px]`, `text-[9px]` ou qualquer tamanho arbitrário;
  e nunca texto de leitura abaixo de 12px.
- **Don't** usar verde fora de "algo está vivo". Verde não é cor de marca nem
  destaque decorativo.
- **Don't** usar azul como estado. `pk-info` é modalidade.
- **Don't** adicionar um segundo tema ou um toggle claro/escuro. Um tema só,
  cravado em `root.html.heex`, é decisão tomada.
- **Don't** carregar fonte externa. A stack de sistema é a voz do produto.
- **Don't** aplicar borda lateral de destaque, texto com gradiente, glow em
  texto ou neon roxo-e-ciano. É o vocabulário de cheat/trainer, e é o que este
  sistema não é.

### Dívida conhecida: emoji na interface

Medido em 2026-08-14: **109 ocorrências de emoji fora de comentário**, em 14
arquivos de `lib/pokex_web` — a maior concentração em `panel_live.ex` (✨ 16,
⚙ 12, ⚔ 8, 🔔 7, 💥 7, 🎯 6, 🎣 6…). O caminho é substituir por heroicon caso a
caso, não em varredura cega: alguns carregam significado de jogo (fugir 🏃 /
lutar ⚔️ numa mesma opção) e precisam de um ícone que diga o mesmo antes de
sair. Até lá, código novo não acrescenta emoji.

### Dívida conhecida: hex literal fora dos tokens

Medido em 2026-08-14: **72 hexes distintos** em `lib/` fora da paleta de
elementos, concentrados em `team_live.ex` (116 ocorrências),
`pokedex_detail_live.ex` (103) e `pokedex_live.ex` (55) — as páginas escritas
antes dos tokens. Quase todos são o mesmo sistema digitado à mão (`#232b30` É
`pk-line`; `#111519` É `pk-surface`; `#8b949d` quase é `pk-text-2`). Os botões
Iniciar e Parar do painel também carregam literais (`#45da83` no hover,
`#703136` no fio, `#35171b` no hover).

O detector **não** vê essa deriva: ela vive em classe utilitária
(`border-[#8b949d]`), e `design-system-color` só lê declaração CSS. Nenhum
waiver foi emitido para ela e nenhum deve ser — ela não está silenciada, está
invisível para a máquina. Trocar literal por token nessas três páginas é
trabalho de revisão, e cada arquivo migrado fecha uma parte desta seção.
