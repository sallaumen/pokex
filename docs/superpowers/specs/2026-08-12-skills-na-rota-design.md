# Skills na rota — a rota manda na hora certa

**Data:** 2026-08-12
**Pedido do Lucas:** "Preciso melhorar a forma de se fazer uma rota para eu poder
editar e colocar manualmente algumas skills no meio da rota (…) porque isso me
ajuda bastante a ter controle do que ele vai usar na hora certa, principalmente
para usar a parte de auras (…) Seja configurável ali na rota, que é o delay até
ele usar skill, depois que ele concluir, que ele já terminou de mobar, para eu
poder ir configurando e deixando a rota cada vez mais rápida. (…) Eu acabei de
criar uma rota que essa realmente eu vou usar (…) que é a rota de Megânia. Vamos
fazer ela ficar redondinha."

Ancorado na rota **Meganium 1** que ele gravou às 13:50 de 2026-08-12 (67
waypoints, 8 pontos de matança) — ela é a medida de tudo aqui, e vira fixture.

---

## O que foi medido antes de desenhar

Três leituras do estado real, não do que a gente imaginava:

1. **Metade dos pontos de matança guarda a lição no waypoint errado.** O clique
   do meio marca `até aqui` num canto (waypoints 5, 15, 39, 58 da Meganium),
   mas quando o `shift+3` fecha a luta ele já andou 1-2 tiles — e é onde ele
   está que o gravador escreve `fight_ms`, `gather_ms` e `combo` (waypoints 6,
   16, 40, 60). A caçada lê essas três coisas **só no `até aqui`**
   (`Logic.gather_wait/1` e `Logic.combo/1` olham o waypoint alcançado), então
   nesses 4 pontos ela cai nos 4s globais e ignora combos de 18, 16, 9 e 14
   teclas.

2. **A medição do respiro não serve como ordem.** Os oito valores medidos na
   Meganium vão de **569ms a 4534ms**. Obedecer isso não é fidelidade às mãos
   dele, é sorteio — e "deixar a rota mais rápida" fica impossível sem um botão.

3. **A aura que ele aperta andando é dado morto.** Os waypoints 2, 10, 23 e 36
   gravaram a tecla `2` no `combo`, mas `Logic.combo/1` só publica o combo
   quando o relógio do bolo está armado (chegada num `:lure_end`). Skill gravada
   em canto de caminhada nunca sai.

E uma quarta, que decide o formato: **os pokémon dele têm as teclas
classificadas** (Shiny Vileplume: 1 = aura, 3-6 = área, 7-9 = alvo; Vespiquen: 2
= aura). Quando a categoria existe ela ganha do combo gravado — o combo gravado
é o plano B de pokémon não classificado (`Combat.Worker.opening_keys/2`).

---

## As três decisões dele

Perguntadas e respondidas em 2026-08-12, antes do desenho:

| pergunta | resposta |
|---|---|
| a skill na rota é tecla ou categoria? | **categoria** (✨ aura, 💥 área…), resolvida contra o pokémon em campo |
| onde vive o "padrão de todas as rotas"? | **os /timers já são o padrão** — não criar padrão novo |
| quem manda no respiro? | **a régua da rota**, com ajuste por waypoint; a medição vira sugestão |

---

## 1. O waypoint ganha um terceiro eixo: `skills`

Hoje um waypoint carrega **função** (`:walk` | `:lure_start` | `:lure_end`) e
**paradas** (`:cooldown_revive` | `:sweep` | `:wait`). Entra um terceiro eixo:

```elixir
skills: [SkillProfile.category()]   # [:buffs, :aoe, :single, :heal, :crowd]
```

Eixo separado pelo mesmo motivo que as paradas não viraram função (decisão de
2026-08-10): o canto onde ele solta a aura pode ser exatamente o canto marcado
`até aqui`. Fazer os dois competirem por uma vaga tornaria impossível a
combinação mais útil.

**Categoria, não tecla.** O waypoint guarda "aperta a AURA aqui"; a tecla sai na
hora de apertar, do `Loadout.current()` — o pokémon que está em campo. Ele troca
de Vileplume (aura = `1`) pra Vespiquen (aura = `2`) e a rota continua certa. É
o mesmo mecanismo que os /timers já usam (`Timers.keys_for/2`), e essa
resolução vira função única em `Loadout.keys/2`, chamada pelos dois.

**Só da mão dele.** O gravador nunca escreve nem apaga `skills` — a mesma regra
do `hand_marked` que já protege as marcações feitas à mão. O `combo` gravado
continua sendo o que sempre foi: registro do que as mãos dele fizeram, matéria
de aprendizado e plano B da abertura.

**Nada pra apertar não trava nada.** Pokémon sem aquela categoria classificada,
ou sem pokémon em campo: uma linha no log dizendo isso, e a caçada segue. Um
waypoint que aponta pra uma skill inexistente não pode virar uma caçada parada.

## 2. Quando a skill sai

| onde ele colocou | quando sai |
|---|---|
| canto comum ou `mobar daqui` | **ao chegar** no canto |
| `até aqui` (ponto de matança) | **quando o fogo é liberado**, depois do respiro |

Os dois momentos são diferentes porque a pergunta é diferente. Num canto de
caminhada não há luta pra ordenar: a chegada já solta as setas hoje (toda ação
que não é andar solta — regra do #201), e a tecla entra nessa brecha, como toque
pelo Body. Num ponto de matança, "chegar" é o clique do meio com o bolo ainda se
fechando; o momento que ele descreveu — *"depois que ele já terminou de mobar"* —
é a liberação do fogo.

No ponto de matança a skill **viaja junto com a rajada**, pelo mesmo canal por
onde o combo gravado já viaja (o fato `:posture`, que ganha um campo `orders`),
na frente da primeira skill de dano. O Body executa em ordem, então a aura nunca
sai depois do estouro — é a mesma solução que fez a tecla de postura funcionar
no #247. **Uma tecla já presente na abertura do pokémon não é apertada duas
vezes**: a ordem da rota e a abertura da estratégia são deduplicadas antes de
virar ação.

Uma vez por chegada, nunca por tick — a mesma disciplina do `stops_done`. E
"chegada" é exatamente a que já conta waypoint no log (`wp_index` mudou), sem
inventar um segundo conceito de chegar.

## 3. O respiro vira régua dele

Precedência nova, do mais específico pro mais geral:

```
waypoint (mão dele)  >  rota  >  global (cavebot_gather_wait_ms, 4s)
```

A rota ganha `gather_wait_ms` (nil = usa o global) e o waypoint ganha o **seu
próprio `gather_wait_ms`**, campo NOVO e escrito só à mão (nil = usa o da rota).
O `gather_ms` medido continua existindo intocado ao lado dele — são duas
perguntas diferentes: "quanto ele esperou" e "quanto eu quero esperar". Ele dial
a régua da rota pra baixo — 4000 → 2500 → 1800 — até achar o limite onde o bolo
ainda fecha, e um canto difícil pode carregar o seu próprio número.

**A medição para de mandar.** O `gather_ms` gravado deixa de ser lido pela Logic
e vira sugestão na tela: *"suas mãos esperaram 1,8s aqui"*, com um botão que
adota o valor (escrevendo-o no `gather_wait_ms` do waypoint). O clampe
`gather_wait_min_ms`/`gather_wait_max_ms` **sai da Logic** — número escrito à
mão é obedecido como está — mas as duas settings continuam existindo com o mesmo
significado, agora como filtro de plausibilidade da sugestão: medição fora da
faixa não é oferecida.

## 4. O conserto do ponto de matança partido

Duas metades:

**Na gravação:** a lição da luta (`fight_ms`, `gather_ms`, `combo`) passa a ser
escrita **no ponto de matança daquela luta**, não no tile onde ele estava quando
apertou `shift+3`. O gravador já sabe responder "de qual matança é essa luta" —
é o `same_fight_spot/3` (6 tiles / 10s) que o clique do meio e o `shift+1` já
usam. Sem ponto de matança por perto, o comportamento de hoje continua: escreve
onde está.

**No que já foi gravado:** o botão **"otimizar rota"** (`Recording.tidy/1`)
passa a mover as lições órfãs de volta pro ponto de matança delas. A Meganium 1
e as outras quatro rotas se consertam sem ele andar nada de novo.

## 5. A tela

Na linha do waypoint, os chips das cinco categorias (✨ 💥 🎯 ❤️ 🌀), clicáveis,
ligados/desligados como as paradas já são. No ponto de matança, o campo do
respiro com a medição ao lado como sugestão adotável. No cabeçalho da rota, a
régua.

Grade com `@container` e tokens `pk-*` — a convenção que saiu da calibração
(#256): o que decide o layout de uma linha é a largura da coluna em que ela
vive, e `.input` do daisyUI solto num flex come a linha inteira.

## 6. O que este spec NÃO faz

Recusas explícitas, anotadas pra não voltarem sozinhas:

- **Nenhum padrão global novo.** Os /timers (`aura na mobada, 8s`, disparo uma
  vez por trecho, em qualquer rota) já são o padrão que vale pra todas as rotas.
- **Nenhuma tecla crua na rota.** Só categoria — tecla literal quebra em
  silêncio quando ele troca o pokémon ativo.
- **Nenhuma rota-modelo.**
- **Nenhum passo do mobado (fase 7)** e nenhuma mexida no `Strategy.opening/1`.

---

## Riscos declarados

**A caçada passa a apertar tecla de skill fora da luta.** Toda tecla nova é
risco de tecla presa. Mitigação: sai como toque (`Body.perform`), na chegada,
depois do `release_walk` — nunca por baixo do hold das setas. É a mesma forma
do clique do park, que já convive com o hold.

**Duas fontes mandando na abertura do ponto de matança** (a ordem da rota e a
abertura da estratégia). Mitigação: dedup por tecla resolvida, e a ordem da rota
sempre na frente.

**Rota antiga não tem os campos novos.** `skills` ausente lê como `[]`,
`gather_wait_ms` ausente lê como `nil` — nenhuma migração, como as rotas sem
`action` já leem hoje.

## Como se prova

- `Route` (puro): o eixo novo liga/desliga; precedência do respiro nas três
  camadas.
- `Logic` (pura): waypoint com `skills` produz a ordem no momento certo e em
  lugar nenhum mais; pokémon não classificado produz `[]` sem quebrar.
- `Recording`: **a Meganium 1 real como fixture** — 8 pontos de matança, 8
  lições no lugar certo depois do `tidy/1`; hoje são 4.
- `Worker`: aperta pelo Body uma vez por chegada, com o hold solto antes.
- `Store`: round-trip dos campos novos e leitura de rota antiga sem eles.
