# O olho do cerco — PR 2a: a bancada vê, e o cérebro diz o que o olho diria

Data: 2026-09-08. Segue o PR 1 (#536, #543: as marcas e o card) e o tile por
tela (#545). Este PR não muda uma decisão: ele põe o julgamento do olho ao lado
de cada revive, no jogo e na bancada, para uma noite de diário mostrar onde o
olho e as regras de hoje discordam ANTES de o olho ganhar a chave (PR 3).

## O que entra

1. `Pokex.Bots.Engine.Siege` (puro): da leitura do `CrowdWatch` (fato
   `:crowd`), da contagem da lista e da cobertura do último controle, as
   quatro pilhas — `pinned` (colado no pokémon, `engine_pin_tiles`), `covered`
   (dormindo: sono fresco E estava no alcance quando o controle saiu), `loose`
   (acordado e longe), `unseen` (na lista, fora da foto) — e a brecha do
   recolhimento (`recall_gap_ok?`): ninguém acordado a menos de 4 tiles DELE
   com caveira, 2 sem ("sem caveira é brincadeira"). A caveira é da área,
   travada pelo cérebro até a lista esvaziar.
2. `Logic`: `stun_cover` (tirada nos três pontos em que o controle sai e na
   borda em que a corrente do cliente acaba) e `heavy_area?`; em toda ordem
   com revive dado ou segurado, `why` ganha " · o olho diria: …" e `siege`
   leva os números pro registro de decisão (`~/.pokex/events`). Sem olho na
   foto, nada muda.
3. `Sim.World.marks/1`: as barras que o olho veria, no tile do notebook, com a
   caveira da área (`heavy?`) e a perda determinística (`mark_miss_pct`);
   `siege_truth/1` é a régua do mundo. A bancada coloca as marcas com
   `CrowdScan.place/4` — o olho da produção — e o contrato proíbe a bancada de
   julgar o cerco por conta própria.

## O que fica pro PR 2b e pro PR 3

- 2b: estacionar a 2 tiles pelo olho e apagar o park antigo; os cenários do
  cerco (`straggler-at-recall`, `asleep-pile-plus-loner`, `blind-eye`…), as
  promessas (`:no_recall_with_awake_in_guard`, `:eye_agrees`), a física da
  mordida nele, o card verdade × leitura no /sim.
- 3: o cérebro obedece (`recall_safe?` v2 pelo olho, vermelho com brecha
  fechada, `engine_recall_guard_tiles`), medido antes × depois na bancada.
