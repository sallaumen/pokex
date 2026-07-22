# Modos Parado × Movimento e o painel de duas colunas

**Data:** 2026-07-22
**Pedido do Lucas:** "trabalharemos nos combos e em melhora do painel e das
funcionalidades, organizando o que é parte de fluxo de bot Parado e o que é bot
em Movimento (como caçar na caverna por exemplo)" — mais: reduzir os comentários
em excesso, organizar em locais distintos que caibam na tela, coloração distinta,
botão de ligar mais eficiente, mais configurações padrões.

**Restrição dura dele:** o painel deve caber em **exatamente duas colunas** na
tela dele (3440×1440). Três colunas já foram testadas e ficaram demais.

---

## O problema

`player_mode` já existe em `Settings` desde o desenho da captura, mas é uma linha
perdida no meio de uma lista de onze automações chapadas, e faz uma coisa só:
liga/desliga o Catcher. O resto do sistema o ignora. Três consequências reais,
todas verificadas no código:

1. **`BotSupervisor.start_all/0` sempre liga a pesca.** Iniciar o bot em modo
   movimento começa arremessando a vara.
2. **O saque morre junto com a captura.** `loot_kill/1`
   (`catcher/worker.ex:283`) exige `player_mode == "parado"`. Mas saquear é
   apertar Espaço no kill — o corpo cai no tile adjacente onde a luta aconteceu,
   e isso funciona andando. Quem precisa de baseline do chão é a **bola**, e ela
   tem gate próprio em `advance/2` (`catcher/worker.ex:225`). O gate do saque foi
   herdado sem motivo.
3. **O reposicionamento ignora o modo.** `player_support/worker.ex:315` só olha
   `reposition_enabled`. Andando, depois de cada luta o bot dá o clique do meio
   no tile calibrado e arrasta o Lucas de volta pro spot de pesca.

E os combos, entregues na rodada anterior, não têm interface nenhuma: a única
porta é editar `~/.pokex/combos.json` na mão. Pior, o combo semeado troca para
**Jigglypuff**, que não está no time dele (ele tem **Wigglytuff**). `Combos.plan/3`
recusa antes do primeiro botão e a recusa sai em `Logger.debug`
(`combos/runner.ex:132`) — ele ligaria a chave, brigaria a noite inteira contra
Water e o painel não diria nada.

## O desenho

### 1. `Pokex.Modes` — o modo é um preset embutido, não um segundo dono da verdade

`Settings` continua sendo a única fonte da verdade. `Modes` é um módulo **puro**
que descreve, para cada modo, dois conjuntos:

```elixir
%{
  workers: [:fishing, :combat, :catcher, :mini_game, :player_support],
  settings: %{capture_enabled: true, reposition_enabled: true}
}
```

O pacote é deliberadamente **pequeno**: só entra nele o que genuinamente muda de
valor certo conforme o modo.

| chave | parado | movimento | porquê |
|---|---|---|---|
| `capture_enabled` | `true` | `false` | a bola depende da baseline do chão, que só existe parado |
| `reposition_enabled` | `true` | `false` | andando, voltar ao tile calibrado desfaz a caminhada |
| workers | pesca, luta, captura, mini game, suporte | luta, captura, suporte | vara e mini game não existem em movimento |

`loot_enabled`, `rescue_enabled`, `potion_enabled`, a fuga e o suporte valem nos
dois e **ficam fora do pacote**. `require_cooldowns` e `require_pokemon_hp` são
gates da pesca: em movimento não têm efeito, então mexer neles seria teatro.

API:

- `Modes.all/0` → `["parado", "movimento"]`
- `Modes.current/0` → o `player_mode` de `Settings`
- `Modes.bundle/1` → o mapa acima
- `Modes.apply!/1` — grava `player_mode` e os `settings` do pacote
- `Modes.overrides/1` → as chaves cujo valor atual **diverge** do pacote, como
  `[{:reposition_enabled, false}]`

`overrides/1` é o que faz o escape manual ser honesto: o painel marca cada linha
divergente com `manual: on/off` e oferece "restaurar padrão do modo".

**Trocar de modo reaplica o pacote** — as exceções anteriores são descartadas.
Isso é dito no próprio botão, não escondido.

### 2. Iniciar ciente do modo

`BotSupervisor.start_all/1` passa a receber a lista de workers do modo e liga
só ela. A ordem de dependência (mini game antes dos demais, pesca → luta →
captura) e a garantia de "falhou no meio, para tudo" continuam valendo.

O botão deixa de ser mudo: rótulo "Iniciar — modo parado" e, embaixo, quais
workers vão subir. É isso que o Lucas chamou de botão mais eficiente — um clique
em vez de conferir seis chaves.

### 3. Saque em movimento

Remover `Settings.get(:player_mode) == "parado"` de `loot_kill/1`. Permanecem:
`loot_enabled` e o gate do mini game (Espaço é a tecla da cápsula). A bola
continua parado-only pelo gate de `advance/2`, que **não** muda.

O reposicionamento passa a checar o modo junto com a chave.

### 4. Combos: editor e o fim do silêncio

Card no painel com a lista de combos: nome, gatilho, passos em chips, ligar/
desligar, apagar. O construtor lê **o time da tela** (`World.snapshot().team`),
então escolher para quem trocar é escolher de uma lista real — não digitar um
nome que pode não existir em atalho nenhum.

`Combos.Runner` passa a transmitir `{:combo_skipped, %{combo:, enemy:, reason:}}`
onde hoje só há `Logger.debug`. O card mostra o último motivo em português:
"não rodou: Wigglytuff não está nos atalhos". A diferença entre "nenhum combo
casou" e "o combo casou e não pôde rodar" deixa de ser invisível.

O seed continua o mesmo arquivo; o card é que valida contra o time lido e avisa.

### 5. O painel em duas colunas

`main` perde o `2xl:grid-cols-3`. Duas colunas em toda largura de desktop.

**Coluna esquerda — Comando** (verde, o accent que já existe): avisos, pílulas de
estado, seletor de modo, botão Iniciar, automações agrupadas em *Só no parado* /
*Só no movimento* / *Sempre*, e a vida do Pokémon com revive e poção.

**Coluna direita — Percepção e ajustes** (azul para o que é leitura, neutro para
o que é configuração): o card do mundo expandido (HUD, time com os C+N lidos,
posição, inimigos), combos, presets, cooldowns, avançado e o registro.

A cor **nunca** é o único sinal: cada grupo carrega rótulo e ícone.

**Densidade do texto.** As descrições das automações hoje chegam a 118
caracteres. Passam a caber em uma linha curta, com o texto longo migrando para o
atributo `title` — continua a um hover de distância e sai da frente.

**Decomposição.** `panel_live.ex` tem 2645 linhas, das quais 1306 são um único
`render/1`. As seções viram componentes de função em
`lib/pokex_web/components/panel/`, um arquivo por zona. O LiveView fica com
estado e eventos; o desenho sai de dentro dele.

## Testes

Tudo que decide comportamento é puro e testado sem tela:

- `Modes`: pacote de cada modo, `apply!/1` gravando, `overrides/1` detectando
  divergência nos dois sentidos.
- `BotSupervisor.start_all/1`: em movimento a pesca e o mini game **não** rodam;
  falha no meio para tudo.
- `Catcher`: o saque dispara em movimento; a bola **não**.
- `PlayerSupport`: o reposicionamento não dispara em movimento.
- `Runner`: a recusa vira broadcast.
- Painel: renderiza os dois modos, marca a exceção manual, mostra o motivo da
  recusa do combo.

Nenhum teste toca a rede nem captura a tela real, e nenhum servidor novo sobe —
a instância que o Lucas mantém aberta comanda o mouse dele de verdade.

## Fora de escopo

Waypoints de cavebot, gatilhos de combo por vida ou por andar, e qualquer
mudança no `Combat.Worker`. O `Runner` continua um peer que escuta: o caminho
que mantém o Pokémon vivo não é lugar de experimento.
