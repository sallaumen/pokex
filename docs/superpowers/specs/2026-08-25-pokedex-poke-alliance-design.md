# Desenho: a Pokédex no padrão do Poké Alliance

> Data: 25 de agosto de 2026
> Lido a partir de: `main` em `abb08bb`
> Natureza: desenho de arquitetura. Autoriza a sequência de PRs da seção 9, nada fora dela.
> Origem: Lucas, 25/08 — *"precisava que fizessemos uma limpa na wiki que fizemos do PXG e atualizassemos todo o código de pokemons e wiki para o padrão do poke alliance"*, com o link `https://wiki.pokealliance.com/pokemon`.
> Irmão de: a migração PXG → PA já registrada em memória (o repo quase não sabia o que era PXG; a Pokédex é a exceção — é o único subsistema inteiro construído em cima do site do PXG).

---

## 1. O problema, dito com precisão

Lucas parou de jogar PXG em 21/08. A Pokédex local é o único subsistema do repo que não é "recalibrar e re-medir": ela não lê a tela, ela lê **um site**, e o site mudou de dono.

Três coisas quebraram de uma vez:

1. **A base descreve um jogo que ele não joga.** 866 espécies do PXG contra 910 do PA — com 217 nomes que só existem no PXG e 267 que só existem no PA. `Pokex.Perception.Interpret` fecha a leitura de tela contra `Pokedex.names/0`: hoje o léxico do bot tem 217 nomes impossíveis e não tem 267 dos que vão aparecer na battle list.
2. **O extrator é de um formato que não existe mais.** `Pokex.Pokedex.Scraper` são 416 linhas de regex sobre markup de MediaWiki (`<b>Campo:</b> valor<br />`, `wikitable` com caption). O PA não é MediaWiki — é uma SPA com API JSON.
3. **Metade dos campos não tem dono.** Iscas, clans, matéria e boost por espécie são conceitos do PXG. O PA não publica nenhum deles em lugar nenhum da wiki (confirmado varrendo as 957 páginas do índice: zero páginas de isca, zero de clan, zero de efetividade).

A Pokédex não precisa de conserto. Precisa de troca de fonte, e de uma limpa no que ficou órfão.

---

## 2. O que o PA publica (medido, 25/08)

A wiki do PA é uma SPA servida por duas rotas de API. Nada de scraping de markup:

| rota | devolve | tamanho |
|---|---|---|
| `GET /api/pokemon` | índice completo, JSON | 910 entradas, 312 KB |
| `GET /api/page/<path>` | `{content: <html>, path}` | ~13 KB por espécie |
| `GET /api/pages` | os caminhos de toda a wiki | 957 (914 de espécie, 43 de sistema) |

**O índice** traz por entrada: `path` (`gen/1/001_bulbasaur`), `route`, `generation`, `number`, `name`, `displayName`, `image`, `level`, `tier`, `displayTier`, `role`, `elements[{name, icon}]`, `variant`, `detailAvailable`.

O índice é a fonte de verdade da base, não `/api/pages`: dos 914 caminhos de espécie, 4 não aparecem no índice e não são espécie (`gen/2/flower`, `gen/2/lava_hole`, `gen/2/spider_egg`, `gen/4/model`).

Distribuições medidas: 526 normais e 384 shinies; gerações 1–7; tiers `1`–`7` mais `Super Rare`, `Legendary`, `Mythic`, `Ultra Rare` e `None`; role `PVE` (806), `PVP` (12) e ausente (92); 18 elementos, exatamente os 18 tipos canônicos do Pokémon. `detailAvailable` é `true` nas 910. **Os 910 nomes são únicos** — o nome continua servindo de chave primária.

**A página** vem num template fixo. Amostra de 40 páginas ao acaso: `data-wiki-template="pokemon-v4"` em **40/40**. Regularidade das seções na mesma amostra:

| seção | presente em |
|---|---|
| Informações Básicas (`HP`, `Experiência`, `Nível necessário`) | 40/40 |
| Informações Básicas (`Tier`, `Função`) | 38/40 |
| Evolução (`Evolui de` e/ou `Pode evoluir para`) | 40/40 |
| Descrição da Pokédex | 36/40 |
| Ataques & Magias (`Slot`, `Nome`, `Cooldown`, `Elemento`) | 36/40 |
| Habilidades | 24/40 |

**Assets**: sprite em `/pokemon/<numero>.png` e shiny em `/pokemon/<numero>.1.png` (~25 KB cada); ícone de elemento em `/elements/<n>.png`, com o mapa número→elemento vindo de graça no próprio índice.

### 2.1 O que o PA NÃO publica

Varredura das 957 páginas: nenhuma página de efetividade de elemento, de isca/lure, ou de clan. Nas páginas de espécie: nenhuma tag de mecânica no move (`AOE`, `Target`, `Stun`, `Lifesteal`, `Focus Blocked`), nenhum level por move, nenhuma data de edição, e nenhum moveset PVP — o botão PVE/PVP existe no renderizador (`<pokemon-combat-mode>`), mas nenhuma página da amostra carrega uma segunda tabela atrás dele.

---

## 3. As quatro decisões (Lucas, 25/08)

| pergunta | decisão |
|---|---|
| Efetividade, que o PA não publica | **Matriz de tipos canônica embutida no código.** Os 18 elementos do PA batem 1:1 com os tipos canônicos (o PXG tinha `Crystal` a mais; o PA não tem), então a matriz 18×18 padrão vira dado nosso. |
| Iscas, clans, matéria, boost por espécie | **Apagar tudo** — código, UI, testes e dados. O histórico do PXG fica no git. |
| As 43 páginas de sistema da wiki do PA | **Fora de escopo.** Só a Pokédex agora. |
| "Novidades" (hoje = a wiki editou nos últimos 7 dias) | **Cortar.** O PA não publica data de edição nenhuma, e novidade por sync já tinha sido rejeitada antes ("novo é novo NA WIKI"). |

**Ressalva registrada:** a matriz canônica é uma aposta sobre o jogo, não uma medição dele. Servidor de PokeTibia costuma mexer no chart. Por isso ela mora num módulo próprio de dado puro e a efetividade é **derivada no load, nunca gravada no JSON** — corrigir uma célula depois não pede re-sync de 910 páginas.

---

## 4. A forma da entrada

`priv/pokedex/pokedex.json` passa a guardar, por espécie, **só o que a wiki disse**:

```
name          "Bulbasaur"                    chave primária (única nas 910)
number        1                              inteiro; shiny compartilha o número da forma normal
generation    1
variant       "normal" | "shiny"
shiny_of      "Bulbasaur" | nil              ligado por (number, variant)
level         1 | nil
tier          "1".."7" | "Super Rare" | "Legendary" | "Mythic" | "Ultra Rare" | nil
role          "PVE" | "PVP" | nil
hp            600 | nil
experience    900 | nil
elements      ["Grass", "Poison"]            capitalizado, como o resto do app já usa
habilidades   ["Cut", "Strength", "Headbutt"]
description   "..." | nil
moves         [%{slot: "M1", name: "Tackle", cooldown_s: 12, element: "Normal"}]
evolves_to    [%{name: "Ivysaur", level: 40, items: ["Leaf Stone"]}]
evolves_from  [%{name: ..., level: ..., items: [...]}]
sprite        "images/pokedex/001.png"
path          "gen/1/001_bulbasaur"          origem do link de volta pra wiki
first_seen_at / changed_at / scraped_at      escrituração do sync, como hoje
```

**Derivados no load, fora do JSON:** `weak_to`, `resists`, `immune`, `neutral` e `effectiveness` — calculados por `TypeChart` a partir de `elements` quando `Pokedex` monta o `:persistent_term`.

**Some do JSON:** `boost`, `materia`, `evolution_stones`, `edited_at`, `moves_pvp`, `lures` (raiz), e o `evolutions` linear (vira `evolves_to`/`evolves_from`, que é a forma que o PA publica e a única que sabe o item exigido).

Some também `shiny_name`, e ele tem dois consumidores que precisam de substituto: `pokedex_detail_live.ex:82` (o link "ver o shiny") e `pokedex.ex:316` (o bônus de shiny no score da caçada). Os dois passam a perguntar ao par `(number, variant)` — `Pokedex.variant_of(entry, :shiny)` —, que é a mesma pergunta feita à chave que o PA realmente publica.

---

## 5. Os módulos

### Nascem

**`Pokex.Pokedex.Api`** — o único módulo que sabe uma URL. `index/0`, `page/1`, `asset/1`. Erros de rede voltam como `{:error, term}`; nada de exceção subindo pro `Sync`.

**`Pokex.Pokedex.PageParser`** — HTML do template `pokemon-v4` → mapa. Puro, sem rede, testado contra páginas reais em fixture. Herda a disciplina do `Scraper` de hoje: seção ausente devolve `nil`/`[]` (é normal — 4 em 10 páginas não têm Habilidades), e página sem "Informações Básicas" é `{:error, :unrecognized}`.

**`Pokex.Pokedex.TypeChart`** — a matriz 18×18 canônica como dado puro. `weak_to/1`, `resists/1`, `immune/1`, `neutral/1` e `effectiveness/1` recebem a lista de elementos da espécie e multiplicam os multiplicadores das duas colunas. `weak_to` é multiplicador > 1; `resists` é entre 0 e 1; `immune` é 0; `neutral` é 1. Um lugar só pra corrigir quando a medição em jogo divergir.

### Morrem

`Pokex.Pokedex.Scraper` (416 linhas) e `Pokex.Pokedex.Clans` (36 linhas).

### Mudam

**`Pokex.Pokedex.Sync`** — reescrito em cima de `Api` + `PageParser`. Mantém o contrato de hoje: upsert por nome (uma rodada refresca o que buscou, o resto fica), `--only`, `--fresh`, `--limit`, `--skip-sprites`, `--delay-ms`, e o mesmo `summary` que o botão "Sincronizar" da tela já consome.

**`Pokex.Pokedex`** — enxuga. Saem `lures/0`, `shinies_for_lure/1`, `lures_for/1`, `novelty/2`, `novelty_days/0`, `wiki_age_days/2`, os filtros `:clans`, `:edited_after`, `:only_novelty` e os sorts `:edited`/`:changed`. Entram os filtros `:generations`, `:tiers`, `:roles`, `:variant` e os sorts `:tier`/`:generation`. `wiki_url/1` passa a montar `<<base>>/<<path>>`. O load deriva a efetividade via `TypeChart`.

### Ficam intactos

`Pokex.Pokedex.Team`, `SkillProfile`, `ShinyLog`, `TeamIcons`. O `Team` volta a funcionar inteiro assim que `weak_to`/`resists` reaparecem derivados. Duas mudanças pequenas em `target_row`: perde o bônus de isca, e o bônus de shiny passa a vir de `variant_of/2` em vez de `shiny_name`.

### Mix task

`mix pokedex.scrape` → `mix pokedex.sync`. Não fica alias: a task é local, ninguém depende do nome antigo, e "scrape" descreve um mecanismo que deixou de existir.

---

## 6. Sync e sprites

O sync passa a ser uma chamada de índice mais 910 chamadas de página. Continua com `--delay-ms` — a wiki do PA é de terceiros e a educação não muda com o formato.

**Sprites.** Baixa `<numero>.png` e `<numero>.1.png` para `priv/static/images/pokedex/` (~23 MB pras 910) e os 18 ícones de elemento para `priv/static/images/pokedex/elements/`. Apaga os 428 `.gif` e 401 `.png` do PXG — 61 MB no working tree.

Nota honesta: apagar do working tree não encolhe o `.git` (41 MB de pack hoje). Reescrever histórico é outra empreitada e não entra aqui.

Os sprites da Pokédex são **decoração de tela**. `Pokex.Bots.PokemonSprites` é outro acervo — recortes que Lucas captura da tela, em `~/.pokex/pokemon_sprites.json`. Nada nesta migração toca nele.

---

## 7. As telas

**`/pokedex`** — some o painel de iscas (e o parâmetro `?isca=`), os chips de clan, o botão e o badge de novidades, e o sort por edição. Entram chips de geração (1–7), tier, variante (normais / shinies / ambos) e role. Ficam nome, elementos, fraco-contra (agora derivado), level mín/máx, e sort por número, nome, level e tier. A URL continua sendo a fonte única de verdade dos filtros.

**`/pokedex/:name`** — some as tags de move, matéria, boost, iscas e "editado em". Entram HP, experiência, tier, geração, role, e as duas pontas da evolução com o item exigido e o level.

**`/time`** — `hunt_suggestions` volta inteiro. Única perda: o bônus de isca no score.

**`PokexWeb.PokedexStyle`** — apaga a cor `crystal` (elemento que só o PXG tinha) e o mapa clan→elemento.

---

## 8. Testes

A disciplina de hoje é a certa e fica: **página real presa em fixture**, pra que uma mudança na wiki quebre alto em teste em vez de baixo em dado.

Fixtures novas em `test/fixtures/pokedex/`:

| fixture | por que essa |
|---|---|
| `api_index.json` | fatia do índice real — cobre normal, shiny, tier numérico e tier nominal |
| `bulbasaur.json` | página completa: todas as 5 seções |
| `groudon.json` | sem Ataques e sem Habilidades — o caso que 4 em 10 páginas exercitam |
| `shiny_rattata.json` | shiny sem Habilidades |
| `mewtwo.json` | sem descrição (`No description.`) e sem evolução cadastrada |

Testes novos: `page_parser_test.exs` (substitui `scraper_test.exs`), `api_test.exs`, `type_chart_test.exs`.

`type_chart_test.exs` prova a matriz contra casos que não dependem de opinião: Grass é fraco a Fire/Ice/Flying/Poison/Bug; Ground é imune a Electric; a dupla Grass+Poison resiste a Grass duas vezes (multiplicador 0.25); Normal é imune a Ghost.

Somem `clans_test.exs` e, dos arquivos que ficam, os testes de isca, novidade e `edited_after` em `pokedex_test.exs`, `pokedex_live_test.exs` e `sync_test.exs`.

---

## 9. A sequência de PRs

Cada etapa fecha com `mix precommit` verde no worktree.

1. **`TypeChart` + testes.** Dado puro, ninguém consome ainda. Nada quebra.
2. **`Api` + `PageParser` + fixtures.** O `Sync` continua no caminho do PXG. Nada quebra.
3. **`Sync` reescrito + schema novo + `mix pokedex.sync`.** Roda o sync de verdade: novo `pokedex.json` e novos sprites entram no repo, os do PXG saem.
4. **`Pokedex` enxuto.** Corta iscas/clans/novidade, deriva a efetividade, ganha os filtros novos. `Team` acompanha.
5. **As telas.** `/pokedex`, `/pokedex/:name`, `/time`, `PokedexStyle`.
6. **Varredura final.** `scraper.ex`, `clans.ex`, sprites do PXG, `config/config.exs`, e as menções a PokeTibia/PXG em `README.md`, `AGENTS.md` e `DESIGN.md`.

A ordem tem uma propriedade: da 1 à 2 o app roda com a base velha; a 3 é o único ponto em que a base troca; da 4 à 6 a base já é a certa e o que se ajusta é quem lê. Se a 3 der errado, o `revert` é de um commit.

---

## 10. O que este desenho não faz

- Não importa as 43 páginas de sistema do PA (helds, prey, talentos, boost). Fora de escopo por decisão.
- Não guarda a base do PXG em arquivo. Fora por decisão — o git guarda.
- Não reescreve o histórico do git pra recuperar os 61 MB de sprites antigos.
- Não mede a efetividade real do PA em jogo. A matriz canônica entra como aposta declarada, corrigível numa célula.
- Não toca em `PokemonSprites`, `PokemonTracker` nem em nada da camada de visão. A Pokédex ganha nomes novos em `Pokedex.names/0` e o `Interpret` colhe isso de graça.
