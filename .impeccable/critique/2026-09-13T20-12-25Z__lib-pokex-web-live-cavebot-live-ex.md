---
target: a pagina de cavebot
total_score: 27
max_score: 40
na_heuristics: 
p0_count: 2
p1_count: 3
timestamp: 2026-09-13T20-12-25Z
slug: lib-pokex-web-live-cavebot-live-ex
---
`Method: dual-agent (A: a8f25b1173765b4e4 · B: a297ba63e5a1aeeed)`

# Crítica de design — a página do Cavebot (`/cavebot`)

Alvo: `lib/pokex_web/live/cavebot_live.ex` · modo **Operate** · medido ao vivo no servidor dele (4004), sem clicar em nada.

## Placar de saúde de design

| # | Heurística | Nota | Problema central |
|---|---|---|---|
| 1 | Visibilidade do estado | **2** | O selo verde "pronto pra noite" é calculado de cinco fatos de **config** (`cavebot_live.ex:1959`) — está VERDE agora com posição, vida do personagem, barra de skills e olho do cerco todos sem leitura |
| 2 | Linguagem do mundo real | **4** | Cada rótulo é a frase dele; `hp_bar` separa `nil` ("sem leitura") de 0% |
| 3 | Controle e liberdade | **2** | Nenhum desfazer; cinco chaves de vida-ou-morte disparam em um clique, sem confirmação |
| 4 | Consistência e padrões | **3** | `rounded-pk` (`:3515`) é classe fantasma → `border-radius: 0px`. Heroicons convivendo com emoji colorido. Quatro blocos densos sem heading |
| 5 | Prevenção de erro | **2** | `data-confirm` protege apagar waypoint (`:3369`) mas **não** desarmar o resgate — proteção invertida |
| 6 | Reconhecer > lembrar | **2** | 39 `title=` no modo assistir; alcançar um tooltip tira o foco do jogo e dispara o `● PARADO` |
| 7 | Flexibilidade e eficiência | **2** | Zero atalho de teclado; sem controle de densidade |
| 8 | Estética e minimalismo | **3** | Bonito e disciplinado — mas um card de cerco **vazio** ocupa 298px contra 33px do feed vivo a 1280×800 |
| 9 | Diagnóstico e recuperação | **4** | `alert_strip` dá fato + link + `<details>`; a tira do buraco de coordenada diz **qual dígito** faltou |
| 10 | Ajuda e documentação | **3** | Divulgação progressiva exemplar; "Instrumentos ▸" não diz o conteúdo nem que custa captura |
| **Total** | | **27 / 40** | **Sólida, com dois furos que custam a noite** |

## Veredito de especificidade

**Avaliação sem âncora (A).** Não poderia ser transplantado para outro produto, e isso é raro. A composição vem do trabalho: rota como *selo* no assistir e *metade de bancada* no editar; nove quadrados de skill em que cada um é a própria calha de progresso; lista de batalha com duas linhas reservadas por decreto; um selo cujo único trabalho é responder "posso dormir?". Os tokens argumentam em prosa por que violeta é o shiny e azul é *modalidade*. A cópia é a segunda pessoa dele.

**Onde quebra: tipografia e ícones.** Verificado na fonte: 83 `text-pk-meta`, 28 `text-pk-body`, **0** `text-pk-title`, **0** `text-pk-clock` em 4043 linhas. A escala de três degraus é de dois — 11px e 13px. O `h1` é `text-pk-body`, 13px. E o sistema de heroicons é furado por 8 emoji coloridos (`:2425`, `:2434`, `cavebot_components.ex:833`).

**Varredura determinística (B).** `detect.mjs --json` na página e nos seis componentes: `[]`, exit 0 — zero achados. Zero estreito: `.ex` cai no motor de regex, que tem 9 regras e nenhuma de contraste, espaçamento, hierarquia ou a11y; o motor de HTML estático está degradado nesta máquina (htmlparser2/css-select/css-tree/domutils ausentes). B confirmou que o motor não é no-op (arquivo sintético → exit 2, 4 achados). O **teste de deriva passou inteiro**: `text-[Npx]` = 0, `text-xs|sm|base|lg|xl` = 0, `base-*` do daisyUI = 0, hex cru 0 na página. Console 0 erro/0 aviso; rede 4/4 em 200.

**Onde A e B se encontram sozinhas:** `text-pk-text-3` (#838d95) sobre `bg-pk-ok-dim` (#0d3822) = **3,87:1** em 11px, 8 instâncias (`:2505`, classe de `tile_class/1` em `:1406`). Única falha de contraste de texto visível da página.

**Sobreposições visuais: não existem.** B recusou injetar overlay para não mutar o DOM do console enquanto o bot real roda. Sinal de retorno: geometria exata via `javascript_tool`.

## Impressão geral

É um instrumento, não um dashboard. O que está quebrado não é o gosto, é o **orçamento**: a disciplina aplicada às tiras de aviso nunca foi aplicada à cabine que elas protegem. A maior oportunidade cabe numa frase: o selo que diz "pode dormir" não pergunta se o bot está enxergando.

## O que está funcionando

1. **`alert_strip` (`:3720`)** resolveu um problema de orçamento, não de estilo: o custo de um aviso se mede em pixels roubados da coisa avisada. Uma linha (fato + saída) com a prosa num `<details>` abrível pelo teclado faz a camada de aviso escalar com o tamanho da desgraça. O par `group-open:hidden` / `hidden group-open:inline` faz a afordância rotular o próprio estado.
2. **`nil` não é zero, no sistema inteiro.** `hp_bar` desenha "sem leitura" com trilho morto; `countdown/1` separa "—" de "esfriando"; `revive_stock/0` divide `:left`/`:out`/`:uncounted`. Num bot que lê pixel, ausência de leitura é o estado mais perigoso — e quase toda UI desenha isso igual a um valor benigno.
3. **Os tokens argumentam por si e os argumentos estão certos.** `--color-pk-info` como modalidade; violeta pro shiny porque dourado colidiria com o âmbar; `--color-pk-text-3` movido com o 4,02:1 → 5,42:1 escrito no comentário; `prefers-reduced-motion` matando `animation-iteration-count` em vez de encurtar duração (encurtar um `infinite` vira estrobo).

## Problemas prioritários

### [P0] O selo "pronto pra noite" atesta configuração enquanto os olhos estão cegos
`night_blockers/1` (`:1959`) avalia cinco settings e recebe **só `rack`** — estruturalmente não consegue considerar se algo está sendo lido. Verde agora com `player_hp == nil`, `hp_pct == nil`, `ready_skills() == nil`, posição ilegível, 0/2 leituras. É o único elemento cujo propósito é ser confiado sem ninguém olhando, e seu modo de falha é a morte já registrada: resgate armado, cérebro nunca avisado. Selo verde sobre seis leituras âmbar ensina a parar de ler as seis.
**Conserto:** `night_blockers(rack, world, pos)` com três bloqueios de percepção ANTES dos de config; cegueira vence todo item de config na ordem. **Comando:** `/impeccable harden`

### [P0] O feed desenha a 0px no notebook, e a página não rola pra recuperar
A 1280×720 `#cavebot-log-lines` tem altura **0**; a 1280×800, 33px. A 1280×620, `#cavebot-world`, `#tile-hp`, `#tile-hunt` e o feed são cortados: `lg:overflow-hidden` em `:2325`, `:2334`, `:2355` com `document.scrollHeight === innerHeight`. O feed é o único `flex-1` da coluna, então é o amortecedor de todo condicional acima — quanto pior a noite, menos dela dá pra ler, em silêncio.
**Conserto:** `lg:overflow-y-auto` em `:2355` + `lg:min-h-[7rem]` no `#cavebot-log`; melhor ainda, inverter a prioridade (feed `shrink-0` com orçamento de linhas, condicionais rolando por dentro). No mesmo passe, tetar o card do cerco em `lg:max-h-[16rem]` sem leitura — hoje vazio ocupa 298px contra 33px do feed (`siege_components.ex:126`). **Comando:** `/impeccable layout`

### [P1] As chaves de vida-ou-morte têm menos proteção que um waypoint
Apagar waypoint pergunta (`:3369`); desarmar o resgate é clique único num botão de 11px (`cavebot_components.ex:127`), igual a `toggle-gather-piles` e `toggle-reset-revive` (política de revive) dentro da tira de leitura do cérebro (`cavebot_components.ex:850,872`) — no modo cujo comentário-fonte (`:2302`) diz "nada que possa ser clicado por acidente".
**Conserto:** `data-confirm` só no desarmar (armar continua um clique); mover as duas chaves do `engine_brain` para Instrumentos. **Comando:** `/impeccable harden`

### [P1] 3,87:1 nas nove telhas do rack — o mesmo bug que o código já corrigiu uma vez
`text-pk-text-3` sobre `bg-pk-ok-dim`, 11px, 3,87:1 contra 4,5:1 exigidos; 8 instâncias em `:2505`. O mesmo token dá 5,42:1 na superfície normal — só o chão verde derruba. O comentário em `:2699` já registra "Cinza sobre o verde escuro da linha DELE dava 3,87:1": a lição foi aprendida num lugar e não virou regra.
**Conserto:** `pk-text-2` (#97a1a9) no mesmo verde = 4,97:1. **Comando:** `/impeccable audit`

### [P1] 39 tooltips ilegíveis enquanto o bot roda
39 `title=` no modo assistir, incluindo `tile_title/1` (`:1425`), a lista de bloqueios do selo e toda nota truncada de `world_tile` — medido ao vivo, a frase mais diagnóstica está cortada em "…a coordenada saiu ileg…". Informação que só existe num `title=` aqui é informação que só existe com a máquina parada: ler exige focar o navegador, o que tira o foco do jogo, o que dispara o `● PARADO`. Falha inteiro no teclado e no toque.
**Conserto:** auditar as 39; o que responde pergunta feita durante a caçada precisa de casa visível (o `#cavebot-rack-conflict` é o padrão). Trocar `truncate` + `title` por duas linhas com altura reservada. **Comando:** `/impeccable clarify`

## Bandeiras vermelhas por persona

**O operador no meio da caçada:** feed a 0–33px; `#tile-pos` cortado na palavra diagnóstica; 39 tooltips inalcançáveis sem pausar o bot; `job_short` a 11px/3,87:1 no elemento feito pra ser lido de longe; nenhum atalho de teclado.

**Ele às 3 da manhã:** selo verde sobre seis leituras âmbar; três vocabulários de estado (`● PARADO`, `pronto pra noite`, `CAÇADA: parada`) sem relação; `Instrumentos ▸` sem indicação de conteúdo nem de custo (custa captura); "limpar" e "apagar rota" como o texto menos proeminente do card, colados.

**Leitor de tela / zoom 150%:** **zero `aria-live` no `<main>`** — a tira de caçada bloqueada, o "sem leitura de vida", o alarme de shiny e o feed anunciam nada. Headings pulam `#cavebot-loadout`, `#cavebot-vision`, `#cavebot-world`, `#cavebot-resumo`. A 768–1023px a página é travada em 560px (`:2088`): 544px de conteúdo em 1023px, 47% morto — é o navegador ao lado do jogo no ultrawide, e é onde cai 1440px a 150% de zoom. (B mediu 768×1024 sem cortes: travado não é quebrado, é desperdiçado.)

## Observações menores

- **A e B discordam sobre 375px, e B ganha.** A disse pilha mobile limpa; B mediu três quebras estáveis: dropdown de personagem (`w-72`, `right-0` dentro de `<details>`) desenhando de x=−88 a x=200 (30,6% inalcançável, input de nome com 79 de 213px fora da tela); barra "Segurança" escapando do card em 101px (`scrollWidth 314` × `clientWidth 212`, culpado é o FORM do tropeço com 302px numa linha que não quebra); marca "P Pokex" colapsada a `clientWidth 0` por `min-w-0`. O shell tem `lg:`/`lg:h-dvh`, então o layout mobile foi escrito de propósito — são bugs dentro dele. Impacto baixo, mas "mobile limpo" era falso.
- `rounded-pk` (`:3515`) não é utilitário definido; computa 0px. Único card de canto reto do app. Deveria ser `rounded-lg`.
- `--text-pk-title` (15px) e `--text-pk-clock` (24px): 0 usos nesta página (confirmado na fonte).
- `#engine-brain` tem `:if={@situation}` e some inteiro — pop-in de ~35px que a lista de batalha ganhou altura fixa pra evitar. Mesma coisa na linha do caderninho, no aviso de rajada e no `#safety-no-reading`.
- Alvos de toque: 17 interativos visíveis, 13 sob 32px; contra o critério AA real (24px) só 3 falham (dois links de 16,5px e um checkbox de 14px). Resto é falso positivo num console de mouse.
- 55,5% do texto a 11px (121 de 218) e 0 abaixo disso — é o degrau `pk-meta` declarado. Os 48 "fora da escala" são benignos: 43 `<title>` de SVG, 4 overlays do Phoenix, 1 `pk-clock`.
- `focus-visible`: contorno de 2px em `--color-pk-ok`, 9,85:1 contra o fundo, 22 de 22 tabuláveis cobertos.
- Abas de modo com `aria-current="page"` e persistência na URL: acerto.
- `lang="pt-br"` setado. A linha `revives: ~948 no bolso` usa `~` para estimativa — tique tipográfico honesto.

## Perguntas para considerar

1. Se o selo que diz "pode dormir" não enxerga se o bot enxerga, o que ele atesta — e você venderia um detector de fumaça que só verifica a própria pilha? Todo bloqueio em `night_blockers/1` é coisa que ELE esqueceu de configurar; nenhum é coisa que a MÁQUINA perdeu. As mortes no caderno são todas do segundo tipo.
2. Você orçou as tiras de aviso para que uma noite barulhenta não comesse a cabine — por que não orçou a cabine? O feed é o único `flex-1` da coluna direita: absorve até zerar, e aí as telhas começam a ser fatiadas.
3. Você escreveu vinte linhas de CSS pra barra de rolagem não ser azul de macOS — o que o 💥 em cor cheia da Apple faz três linhas abaixo do `--color-pk-ok`?
