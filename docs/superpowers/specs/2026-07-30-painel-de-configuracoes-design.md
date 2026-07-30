# Painel de configurações sobre o dashboard — design

**Data:** 2026-07-30 · **Aprovado por:** Lucas (chat, opção "a")

## Problema

O dashboard acumulou duas coisas diferentes: o que o Lucas olha COM O BOT
RODANDO e o que ele ajusta uma vez e esquece. São 3.468 linhas e 54 eventos num
arquivo só. Ele quer o dia a dia limpo.

**Achado que reformulou o pedido:** não há configuração espalhada pelas outras
páginas — `/cavebot` são rotas, `/time` são retratos, `/world`, `/mini-game` e
`/diagnostics` são observação, `/pokedex` é referência. NENHUMA delas escreve
Settings. O corte é dentro do painel, não entre páginas.

## Critério do corte: tempo de uso, não tema

Fica no dashboard o que se olha com o bot rodando; vai pro ⚙️ o que se ajusta e
esquece. A exceção deliberada (escolha do Lucas, opção "a"): os liga/desliga
que mudam POR SESSÃO ficam no dashboard como faixa compacta.

### Dashboard

Iniciar/Parar + modo + motivo da parada · 6 pílulas dos workers · vida do
Pokémon (barra + contadores + "usar poção agora") · feed de atividade ·
alarmes · card do mundo · **faixa rápida**: Pesca, Luta, Captura, Loot,
Revive, Poção.

### ⚙️ (rota `/config`)

1. **Automações & limiares** — as 4 chaves de política (suporte espera a
   captura, reposicionar após lutas, só pescar quando dá pra matar, só pescar
   com vida) + skills necessárias pra matar + vida mínima pra puxar a vara +
   fuga de emergência + limiares de revive/poção + o seletor de combo do
   resgate (hoje espalhados entre o bloco Automações e o card de vida).
2. **Sessão & segurança** — metas, anti-estagnação, logout, ShinyGuard. *(PR 2)*
3. **Combos** — lista + editor. *(PR 2)*
4. **Presets por Pokémon**. *(PR 2)*
5. **Avançado** — ordem das skills, timing do combate, sensibilidade do brilho,
   captura de tela. *(PR 2)*

Rodapé com atalhos pra Calibração e Diagnóstico (não moram no ⚙️, mas é onde
ele vai procurar).

### Sai da configuração de vez (PR 2)

Card **Captura (Medir)** e **Prints & diagnóstico** → `/diagnostics`. Medição
não é configuração.

## Forma

`live "/config", PanelLive, :config` — MESMA LiveView, `live_action` decide o
overlay. O dashboard continua montado e vivo atrás (as pílulas se mexem
enquanto ele configura), a URL é própria (F5 não perde o lugar), fechar é
`patch` de volta pra `/`. Abre pelo ⚙️ do dashboard e pelo item novo no menu do
header (de qualquer página cai no dashboard com o painel aberto).

Um modal puro (só assign) não daria URL nem F5; uma página separada mataria o
dashboard vivo atrás. O `live_action` dá os dois.

## O que NÃO muda

Nenhuma chave de Settings, nenhum comportamento de bot, nenhum efeito colateral
dos handlers (`arm_support` no revive, `Catcher.mode_changed` no preset, etc.).
É mudança de LUGAR. Os handlers ficam onde estão — eventos de function
components sobem pra mesma LiveView.

## PR 1 (esta fatia)

- Rota `/config` + overlay (backdrop, Esc/clique fora/botão fecham via patch).
- ⚙️ no dashboard + item no header.
- Faixa rápida com as 6 chaves (a de Captura carrega o selo "manual" quando o
  modo foi sobrescrito, como a linha antiga fazia).
- Bloco Automações inteiro migra pro overlay MENOS as 6 rápidas, como
  componente novo `PokexWeb.Panel.SettingsOverlay`; `automation_row/1` e
  `group_header/1` migram junto (não sobra usuário deles no painel).
- Limiares de revive/poção + seletor de combo do resgate saem do card de vida
  pro overlay; a barra de HP e o botão manual de poção FICAM.

### Testes

- `/config` renderiza o overlay E o dashboard atrás (as pílulas continuam lá).
- Cada uma das 6 chaves rápidas dispara o mesmo evento de antes.
- Os controles movidos existem em `/config` e NÃO no dashboard.
- Os testes existentes que achavam esses controles em `/` passam a apontar pra
  `/config` — se algum sumir de verdade, quebram.

## Fora de escopo (PR 2)

Seções 2-5 do ⚙️, mudança do Medir/Prints pro diagnóstico, e a quebra do resto
do `panel_live.ex` em componentes.
