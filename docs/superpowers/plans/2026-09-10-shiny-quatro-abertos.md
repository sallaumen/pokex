# Os quatro que ficaram abertos no shiny — plano de implementação

> **Para quem executa:** use superpowers:subagent-driven-development (preferido) ou
> superpowers:executing-plans, tarefa por tarefa. Os passos usam `- [ ]` pra marcar.

**Objetivo:** fechar os quatro achados da revisão de 09/09 (#570, #574) que ficaram
sem conserto por precisarem de decisão de projeto, e não de correção pontual.

**Arquitetura:** nenhuma peça nova. Três dos quatro são um dado que já existe e não
atravessa uma fronteira (os pontos dos renascidos, a origem da leitura, a ampliação
da tela); o quarto troca "a maior mancha" por "toda mancha acima do gatilho" em dois
juízes que hoje descartam informação. Toda mudança é local ao módulo que já manda
naquela decisão.

**Stack:** Elixir/Phoenix LiveView, ExUnit. Nada de dependência nova.

## Restrições do projeto

- **Credo lê a palavra portuguesa "todo" como tag de TODO** e reprova. Já custou um
  retrabalho nesta parte do código: escreva "qualquer", "cada" ou "toda".

- Identificadores, comentários e NOMES DE TESTE em inglês (a guarda de
  `test/pokex/english_only_test.exs` reprova acento em nome de teste). Só IO em pt-BR.
- Nunca rodar nada dentro de `~/projects/pokex`; trabalhar em worktree sob
  `.claude/worktrees/`.
- `~/.pokex/` é UM diretório compartilhado pelo checkout e por todas as worktrees.
  Escrever lá só com backup ao lado.
- Portão: `mix precommit`, depois `mix credo` e `mix dialyzer` SEPARADAMENTE.
- `git add` explícito por arquivo. Nunca `git add -A`.
- Re-rodar só o arquivo/linha que falhou; suíte cheia apenas no fim.
- Toda regra nova valida na bancada (`Pokex.Sim`, `/sim`) ANTES do jogo.
- Repo público: nenhuma fixture com o nome do personagem dele.

## O que só ELE decide

Estas três não têm resposta técnica; cada uma muda o que ele vê ou o que ele gasta.
A recomendação está marcada, e a tarefa correspondente diz onde o número mora.

1. **Teto de candidatos da mira (Tarefa 3).** Julgar toda mancha acima do gatilho
   pode render mais de um alvo por varredura, e cada alvo é uma bola.
   *Recomendo 3*, num ajuste novo (`shiny_aim_max_candidates`), com o alarme de bola
   seca já existente como segunda cerca.
2. **O vigia anuncia todas as manchas ou só a maior (Tarefa 3).** Anunciar todas não
   custa bola nenhuma (o vigia não arremessa) e é o que faz o quadrado certo acender
   no cartão do cerco quando a lava é maior que o bicho. *Recomendo todas.*
3. **Prova de outra ampliação: recusar ou reescalar (Tarefa 4).** Reescalar as caixas
   e as contagens por 4× é uma conta simples e uma mentira plausível — a prova foi
   medida noutro mundo. *Recomendo recusar*, com o mesmo aviso da região.

## Estrutura de arquivos

| Arquivo | Responsabilidade | Tarefa |
|---|---|---|
| `lib/pokex/bots/crowd_scan.ex` | devolver os PONTOS dos renascidos, não só a contagem | 1 |
| `lib/pokex/bots/catcher/shiny_aim.ex` | cerca de corpo vivo inclui renascidos; candidatos deixam de ser um só | 1, 3 |
| `lib/pokex/bots/catcher/logic.ex` | uma leitura só julga a bola que ela mesma poderia ter visto | 2 |
| `lib/pokex/bots/shiny_guard.ex` | julgar toda mancha acima do gatilho; prova conferida também pela ampliação | 3, 4 |
| `lib/pokex/vision/color_rules.ex` | a prova guarda a ampliação | 4 |
| `lib/pokex/bots/shiny_readiness.ex` | o selo pergunta a ampliação junto com a região | 4 |
| `lib/pokex/settings.ex` + `settings/locked.ex` | o teto de candidatos como ajuste visível | 3 |

---

## Tarefa 1: o renascido é um corpo vivo, e a mira tem que vê-lo

**Por que:** um bicho que ele já matou levanta de novo como renascido (magenta). O
cliente não o põe na lista de batalha e `CrowdScan.place/4` o separa de `hostiles`,
devolvendo apenas `passive: length(passive)` — a contagem, nunca os pontos. A cerca da
mira (`ShinyAim.bodies/1`) é feita de `hostiles` + `pet`, e `screen_clear/2` conta a
lista. As duas cercas são cegas a ele. Resultado: a bola voa num pokémon VIVO e, pior,
depois de `corpse_max_balls` o ponto entra em `ignored` com o nome dele por
`corpse_ignore_ttl_ms` (45 s) — quando o bicho morrer de verdade naquele tile, o corpo
real é vetado e não leva bola nenhuma.

**Arquivos:**
- Modificar: `lib/pokex/bots/crowd_scan.ex:195-200` (o mapa que `place/4` devolve) e
  `:70-78` (o typespec `placed`)
- Modificar: `lib/pokex/bots/catcher/shiny_aim.ex:152-161` (`bodies/1`)
- Teste: `test/pokex/bots/crowd_scan_test.exs`, `test/pokex/bots/catcher/shiny_aim_test.exs`

**Interfaces:**
- Produz: `place/4` passa a devolver `passive_points: [{integer, integer}]` ao lado do
  `passive: non_neg_integer` que já existe. **A contagem NÃO muda de tipo** — só
  `test/pokex/bots/crowd_scan_test.exs:353` a lê hoje, mas trocar um inteiro por uma
  lista é mudança silenciosa de contrato.
- Consome: `ShinyAim.bodies/1` soma `passive_points` à cerca.

- [ ] **Passo 1: escreva o teste que falha, no olho**

```elixir
# test/pokex/bots/crowd_scan_test.exs, dentro do describe de place/4
# O RENASCIDO É UM CORPO VIVO. Ele sai de `hostiles` porque não vem na lista de
# batalha, e a contagem sozinha não serve pra cerca de ninguém: quem precisa
# saber que há algo VIVO naquele tile precisa do ponto.
test "the reading carries where the respawned creatures are, not just how many" do
  marks = [mark({0, 2}, hp: 100), mark({2, 2}, hp: 100, passive?: true)]

  placed = CrowdScan.place(marks, @me, @tile)

  assert placed.passive == 1
  assert placed.passive_points == [mark({2, 2}).point]
end
```

- [ ] **Passo 2: rode e confirme a falha**

Rode: `mix test test/pokex/bots/crowd_scan_test.exs -k "respawned creatures are"`
Esperado: FALHA com `key :passive_points not found`.

- [ ] **Passo 3: devolva os pontos**

Em `lib/pokex/bots/crowd_scan.ex`, no mapa de `place/4`:

```elixir
    %{
      read?: true,
      me: {px, py},
      pet: pet && pet_of(pet, me, tile),
      hostiles: hostiles,
      passive: length(passive),
      # …E ONDE ELES ESTÃO. A contagem responde "a caçada está lenta"; a cerca da
      # mira por cor precisa de outra pergunta — "tem algo VIVO neste tile?" — e
      # pra essa a contagem não serve. O renascido não vem na lista de batalha e
      # não está em `hostiles`: sem o ponto, ele é invisível pras duas cercas e
      # a bola voa num pokémon vivo.
      passive_points: Enum.map(passive, & &1.point)
    }
```

E no typespec `placed` (`:70-78`), acrescente `passive_points: [{integer, integer}]`.

- [ ] **Passo 4: rode e confirme o verde**

Rode: `mix test test/pokex/bots/crowd_scan_test.exs`
Esperado: PASSA, e os 31 testes que já existiam continuam passando.

- [ ] **Passo 5: escreva o teste que falha, na mira**

Primeiro dê ao helper `crowd/2` do arquivo um terceiro argumento, porque hoje ele não
sabe dizer "há um renascido aqui":

```elixir
  defp crowd(hostiles, pet \\ nil, passive \\ []),
    do: %{
      read?: true,
      hostiles: Enum.map(hostiles, &%{point: &1}),
      pet: pet && %{point: pet},
      passive: length(passive),
      passive_points: passive
    }
```

E o teste (a mancha de `frame_com_mancha/0` cai em `{117, 117}` em pontos de tela, como
o primeiro teste do arquivo já afirma):

```elixir
# O RENASCIDO É UM CORPO VIVO. A lista de batalha não o carrega e `hostiles` o
# separa, então a mancha de cor em cima de um bicho VIVO passava por corpo.
test "a respawned creature is a live body and fences the blob out" do
  assert ShinyAim.judge(
           frame_com_mancha(),
           @region,
           rules(),
           [],
           crowd([], nil, [{117, 117}]),
           @tile
         ) == []
end
```

- [ ] **Passo 6: rode e confirme a falha**

Rode: `mix test test/pokex/bots/catcher/shiny_aim_test.exs -k "respawned creature is a live body"`
Esperado: FALHA — a lista volta com um candidato.

- [ ] **Passo 7: some os renascidos à cerca**

```elixir
  # QUALQUER CORPO VIVO, e o renascido é um deles. Magenta quer dizer que o bicho não
  # vem atrás dele, não que o bicho não está lá: o cliente não o põe na lista de
  # batalha e o olho o separa dos hostis, de modo que ele era invisível aqui — e
  # a bola voava num pokémon vivo. Pior: gastas as bolas, o ponto entrava em
  # `ignored` com o nome dele por 45 s, e o corpo de verdade daquele bicho, no
  # mesmo tile, era vetado depois.
  defp bodies(%{read?: true} = crowd) do
    vivos =
      Map.get(crowd, :hostiles, [])
      |> Enum.map(& &1.point)
      |> Enum.concat(Map.get(crowd, :passive_points, []))

    case Map.get(crowd, :pet) do
      %{point: point} -> [point | vivos]
      _no_pet -> vivos
    end
  end
```

- [ ] **Passo 8: rode e confirme o verde**

Rode: `mix test test/pokex/bots/catcher/shiny_aim_test.exs test/pokex/bots/crowd_scan_test.exs`
Esperado: PASSA.

- [ ] **Passo 9: commit**

```bash
git add lib/pokex/bots/crowd_scan.ex lib/pokex/bots/catcher/shiny_aim.ex test/pokex/bots/crowd_scan_test.exs test/pokex/bots/catcher/shiny_aim_test.exs
git commit -m "o renascido é um corpo vivo, e a mira por cor volta a vê-lo"
```

---

## Tarefa 2: uma leitura só julga a bola que ela mesma poderia ter visto

**Por que:** um `Catcher.Logic` guarda UMA bola no ar e recebe leituras de DOIS
detectores com lentes diferentes. A varredura de corpos (`SpotScan`) só reporta corpos
ensinados na biblioteca de sprites; a mira por cor (`ShinyAim`) só reporta manchas da
cor. `confirm/3` trata "ausente de `obs.corpses`" como capturado, sem perguntar se
aquela leitura teria como ver aquele corpo.

Cenário confirmado (modo `still`, captura ligada, sessão de mira aberta): a mira
arremessa no corpo do shiny; 800 ms depois o despertar roda a varredura de corpos, que
não conhece o corpo do shiny (é a premissa da mira por cor existir); `corpses: []` cai
no ramo `true -> captured`; o feed diz "capturado", a bola sai da conta e a sessão
fecha. O corpo do shiny continua no chão e não leva outra bola. O espelho é igual: um
tique da mira com `corpses: []` confirma a bola de um corpo comum.

**Arquivos:**
- Modificar: `lib/pokex/bots/catcher/logic.ex:105-160` (`confirm/3`) e `:249-266`
  (`maybe_throw/3`)
- Teste: `test/pokex/bots/catcher/logic_test.exs`

**Interfaces:**
- Produz: o registro `throw` ganha `source: atom`. `source_of/1` devolve
  `Map.get(obs, :source, :corpse_scan)` — `ShinyAim.obs/3` já marca `:shiny_aim` e a
  varredura de corpos não marca nada, então o padrão nomeia a que não se nomeia.
- Consome: nada fora do módulo. `Logic.pending/1` e `next_wake/2` não mudam.

**A válvula que impede o impasse:** o teto duro `@confirmation_cap_ms` (60 s) resolve
a bola como "inconclusiva" e a limpa. A conferência de origem tem que vir DEPOIS dele,
senão uma bola cuja sessão de mira fechou nunca sai da conta e `aim_done?/1` nunca
fecha nada. A ordem dos ramos é a parte que importa nesta tarefa.

- [ ] **Passo 1: escreva o teste que falha**

O arquivo já tem `armed/0` (um `%Logic{}` iniciado com `config/0`) e `obs/2`. Some um
`obs/3` que marca a lente, porque é isso que falta poder dizer:

```elixir
  defp obs(corpses, at, source),
    do: %{scanning?: true, source: source, corpses: corpses, captured_at: at}
```

E os dois testes (com `corpse_confirm_after_ms: 800` do `config/0` e o teto duro de
60 s do módulo):

```elixir
  # CADA LENTE JULGA A SUA BOLA. A varredura de corpos não conhece o corpo do
  # shiny (é a razão de a mira por cor existir), então a ausência dele numa
  # leitura da varredura não é prova de captura nenhuma.
  test "a reading from the other detector proves nothing about this ball" do
    # a mira por cor acha o corpo e arremessa
    {logic, acoes} = Logic.step(armed(), obs([{100, 200}], 10, :shiny_aim), 10)
    assert Enum.any?(acoes, &match?({:capture_sequence, {100, 200}, _}, &1))

    # a varredura de corpos, que não vê aquele corpo, não pode dar por capturado
    {logic, acoes} = Logic.step(logic, obs([], 900), 900)
    assert acoes == []
    assert logic.counters.captures == 0

    # …e a mira, que vê, dá
    {logic, acoes} = Logic.step(logic, obs([], 1_000, :shiny_aim), 1_000)
    assert Enum.any?(acoes, &match?({:log, _}, &1))
    assert logic.counters.captures == 1
  end

  # E A VÁLVULA: uma bola cuja lente calou não pode ficar presa pra sempre.
  test "past the hard ceiling any reading releases the ball" do
    {logic, _} = Logic.step(armed(), obs([{100, 200}], 10, :shiny_aim), 10)

    {logic, acoes} = Logic.step(logic, obs([], 70_000), 70_000)

    assert Enum.any?(acoes, fn a -> match?({:log, t} when is_binary(t), a) end)
    assert logic.throw == nil
  end
```

- [ ] **Passo 2: rode e confirme a falha**

Rode: `mix test test/pokex/bots/catcher/logic_test.exs -k "proves nothing about this ball"`
Esperado: FALHA — a segunda leitura devolve `{:log, "capturado..."}` e `pending` vira 0.

- [ ] **Passo 3: marque a origem na bola**

Em `maybe_throw/3`:

```elixir
    throw = %{
      point: point,
      balls: 1,
      at: now,
      name: name_in(obs, point, logic.config.corpse_match_tolerance_px),
      # DE QUAL LENTE ESTA BOLA É. Duas leituras alimentam um `Logic` só e cada
      # uma vê um conjunto diferente de corpos: a varredura só conhece os corpos
      # ensinados na biblioteca, a mira só conhece manchas da cor. Sem isto, a
      # ausência numa lente dava por capturada a bola da outra.
      source: source_of(obs)
    }
```

- [ ] **Passo 4: cale a leitura da outra lente, DEPOIS do teto duro**

Em `confirm/3`, entre o ramo do teto e o de `outra_especie?`:

```elixir
      # A LENTE ERRADA NÃO PROVA NADA — como um quadro de aquecimento. Vem
      # depois do teto duro de propósito: se a lente desta bola calar (a sessão
      # de mira fecha por TTL), é o teto que a solta, senão ela fica na conta pra
      # sempre e `aim_done?/1` nunca fecha a caçada.
      source_of(obs) != Map.get(throw, :source, :corpse_scan) ->
        {logic, []}
```

E no fim do módulo:

```elixir
  # A varredura de corpos não se nomeia; a mira por cor sim (`ShinyAim.obs/3`).
  defp source_of(obs), do: Map.get(obs, :source, :corpse_scan)
```

- [ ] **Passo 5: rode e confirme o verde**

Rode: `mix test test/pokex/bots/catcher/logic_test.exs`
Esperado: PASSA. Depois `mix test test/pokex/bots/catcher/` inteiro — o worker tem 43
testes que passam por aqui.

- [ ] **Passo 6: commit**

```bash
git add lib/pokex/bots/catcher/logic.ex test/pokex/bots/catcher/logic_test.exs
git commit -m "cada lente julga a sua bola: a ausência numa não é captura na outra"
```

---

## Tarefa 3: toda mancha acima do gatilho, não só a maior

**Por que:** `ShinyGuard.judge/5` e `ShinyAim.judge/6` fazem
`List.first(result.manchas)` — a lista vem ordenada por px decrescente. Quando a lava
sobrevive ao cone de matiz como uma mancha de 40.000 px e o shiny tem 9.000, as duas
passam do gatilho, mas só a lava é olhada: o diário, o troféu, o fato `:special`, o
quadrado do cartão e a bola apontam pra lava, e o shiny a dois tiles NUNCA é
inspecionado. Ele não está "abaixo do limiar"; ele não foi olhado.

**Arquivos:**
- Modificar: `lib/pokex/bots/shiny_guard.ex:211-241` (`judge/5`)
- Modificar: `lib/pokex/bots/catcher/shiny_aim.ex:100-127` (`judge/6`)
- Modificar: `lib/pokex/settings.ex` (ajuste novo) e `lib/pokex/settings/locked.ex` (rótulo)
- Teste: `test/pokex/bots/shiny_guard_test.exs`, `test/pokex/bots/catcher/shiny_aim_test.exs`

**Interfaces:**
- `ShinyGuard`: `vistos` continua `[{rule, mancha}]`, agora com mais de uma entrada por
  regra. `publish_special/1` e `keepsake/3` já recebem lista; conferir que
  `keepsake` fotografa a PRIMEIRA (`keep/7` casa `[{rule, mancha} | _]`) — a foto segue
  sendo uma, e a maior.
- `ShinyAim`: `judge/6` devolve até `Settings.get(:shiny_aim_max_candidates)` candidatos
  por regra, ordenados por px decrescente, depois de descontar os que têm corpo vivo por
  perto.
- Ajuste novo: `shiny_aim_max_candidates`, faixa `1..8`, padrão **3**.

- [ ] **Passo 1: escreva o teste que falha, no vigia**

```elixir
# test/pokex/bots/shiny_guard_test.exs
# A LAVA MAIOR TAPAVA O BICHO. Só a maior mancha era julgada, então o fato, o
# troféu, o diário e a bola apontavam pro cenário e o shiny nunca era olhado.
test "a bigger blob of scenery does not hide the creature's own", %{region: region} do
  regra_provada(%{"name" => "Electrode shiny", "min_px" => 50})

  # duas manchas da cor, a do cenário maior que a do bicho
  frame = frame(elem(region, 2), elem(region, 3), {40, 40, 40},
                [{{10, 10, 120, 120}, @verde}, {{300, 300, 40, 40}, @verde}])

  start_guard_journaling(fn _region, _name -> {:ok, frame} end)

  assert_receive {:journal, :special, %{tag: "seen"}}, 2_000

  assert eventually(fn ->
           case WorldState.get(:special, 5_000, System.monotonic_time(:millisecond)) do
             {:ok, %{vistos: vistos}} -> length(vistos) == 2
             _ -> false
           end
         end)
end
```

- [ ] **Passo 2: rode e confirme a falha**

Rode: `mix test test/pokex/bots/shiny_guard_test.exs -k "does not hide the creature"`
Esperado: FALHA — `vistos` tem 1.

- [ ] **Passo 3: julgue todas no vigia**

Troque, dentro do `Enum.reduce` de `judge/5`:

```elixir
        # TODA MANCHA ACIMA DO GATILHO. Pegar só a maior fazia a lava tapar o
        # bicho: as duas passam do gatilho, mas só a lava era olhada, e o shiny
        # dois tiles ao lado não ficava "abaixo do limiar" — ficava sem ser
        # olhado. O vigia não arremessa, então anunciar todas não custa bola.
        achadas =
          result.manchas
          |> Enum.filter(&(&1.px >= rule.min_px))
          |> Enum.map(&on_screen(&1, region, frame.scale))

        maior = List.first(result.manchas)
        hit? = achadas != []

        {advance(state, rule, maior && on_screen(maior, region, frame.scale), hit?),
         max(best, (maior && maior.px) || 0),
         Enum.map(achadas, &{rule, &1}) ++ vistos}
```

`advance/4` (a confirmação e o refratário) continua olhando a MAIOR: uma segunda
mancha não é um segundo avistamento.

- [ ] **Passo 4: rode e confirme o verde**

Rode: `mix test test/pokex/bots/shiny_guard_test.exs`
Esperado: PASSA, com os 19 testes anteriores.

- [ ] **Passo 5: escreva o teste que falha, na mira**

Some um quadro com duas manchas da cor, a do cenário maior que a do bicho:

```elixir
  # a lava dele: uma mancha grande da mesma cor, longe do bicho
  defp frame_com_duas_manchas,
    do:
      frame(300, 300, {40, 40, 40}, [
        {{10, 10, 60, 60}, @verde},
        {{200, 200, 14, 14}, @verde}
      ])
```

```elixir
  test "every blob past the trigger is a candidate, up to the ceiling" do
    candidatos =
      ShinyAim.judge(frame_com_duas_manchas(), @region, rules(), [], crowd([]), @tile)

    assert length(candidatos) == 2
    # a maior primeiro: a fila da bola segue a força da prova
    assert [%{px: maior}, %{px: menor}] = candidatos
    assert maior > menor
  end

  test "the ceiling caps how many balls one scan can queue" do
    Pokex.SettingsStash.stash!(shiny_aim_max_candidates: 1)

    assert [_uma] =
             ShinyAim.judge(frame_com_duas_manchas(), @region, rules(), [], crowd([]), @tile)
  end
```

O arquivo é `async: false` e mexe em ajuste global, então o `SettingsStash` é
obrigatório (ele restaura no `on_exit`).

- [ ] **Passo 6: rode e confirme a falha**

Rode: `mix test test/pokex/bots/catcher/shiny_aim_test.exs -k "every blob past the trigger"`
Esperado: FALHA — vem 1 candidato.

- [ ] **Passo 7: o ajuste novo**

Em `lib/pokex/settings.ex`, junto das outras chaves de shiny:

```elixir
    shiny_aim_max_candidates: 3,
```

e na tabela de faixas:

```elixir
    shiny_aim_max_candidates: 1..8,
```

Em `lib/pokex/settings/locked.ex`:

```elixir
    shiny_aim_max_candidates:
      {"Shiny (visão)", "quantos alvos por varredura a mira por cor pode enfileirar"},
```

- [ ] **Passo 8: julgue todas na mira, com teto**

```elixir
          teto = Settings.get(:shiny_aim_max_candidates)

          result.manchas
          |> Enum.filter(&(&1.px >= rule.min_px))
          |> Enum.map(&on_screen(&1, rule, region, frame.scale))
          |> Enum.take(teto)
```

no lugar do `case List.first(result.manchas) do ... end`. A rejeição por corpo vivo
(`Enum.reject(... within? ...)`) fica onde está, DEPOIS do flat_map, como hoje.

- [ ] **Passo 9: rode e confirme o verde**

Rode: `mix test test/pokex/bots/catcher/shiny_aim_test.exs`
Esperado: PASSA.

- [ ] **Passo 10: valide na bancada ANTES do jogo**

Rode: `mix test test/pokex/sim/` e depois uma corrida de `/sim` com uma cena de shiny.
Esperado: o número de bolas por avistamento não passa do teto, e o `Verdict` do
cenário de shiny continua cobrando a promessa que já cobrava.

- [ ] **Passo 11: commit**

```bash
git add lib/pokex/bots/shiny_guard.ex lib/pokex/bots/catcher/shiny_aim.ex lib/pokex/settings.ex lib/pokex/settings/locked.ex test/pokex/bots/shiny_guard_test.exs test/pokex/bots/catcher/shiny_aim_test.exs
git commit -m "toda mancha acima do gatilho é olhada: a lava maior parava de tapar o bicho"
```

---

## Tarefa 4: a prova também é de uma AMPLIAÇÃO, não só de uma região

**Por que:** `mark_proven/4` guarda `floor_px` (uma CONTAGEM de pixels), `chrome`
(caixas em pixels do QUADRO) e `region` (pontos de TELA). `proof_fits?/2` confere só a
região. As duas primeiras dependem da ampliação e a terceira não, então uma troca de
backend de captura passa pela porteira sem ser vista: `Frame` documenta que o
ScreenCaptureKit responde 196×215 pra uma região de 196×215 pontos (1×) e o
`screencapture` responde 392×430 (2×) — e `Capture` tem esse fallback.

Prova medida a 1× e caçada a 2×: a região é idêntica, `proof_fits?` diz que serve, as
caixas do HUD passam a cobrir um quarto de onde o HUD está, e toda mancha vem com
quatro vezes mais pixels, de modo que o gatilho é vencido por chão vazio. O vigia
anuncia shiny no hotbar, uma vez por refratário, a noite inteira. Ao contrário
(prova a 2×, caçada a 1×) a regra fica quatro vezes mais rígida e não dispara nunca.

**Arquivos:**
- Modificar: `lib/pokex/vision/color_rules.ex:89-103` (`mark_proven/4`), `:145-147`
  (`proof_fits?/2`), `:270-280` (o mapa de `armed/0`), `:299-300` (`proven_region/1`)
- Modificar: `lib/pokex/bots/shiny_guard.ex:215` (a chamada) e o texto de `warn_stale/2`
- Modificar: `lib/pokex_web/live/calibration_live.ex` (a chamada de `mark_proven`)
- Modificar: `lib/pokex/bots/shiny_readiness.ex` (o selo)
- Teste: `test/pokex/vision/color_rules_test.exs`, `test/pokex/bots/shiny_guard_test.exs`

**Interfaces:**
- Produz: a prova ganha `"scale" => number | nil`. `armed/0` ganha `proven_scale`.
  `proof_fits?/2` passa a receber `{region, scale}` no segundo argumento.
- Prova antiga sem `scale` continua confiável (mesma convenção da região, que já
  trata `nil` como "medida no mundo que ele tinha então").

- [ ] **Passo 1: escreva o teste que falha**

```elixir
# test/pokex/vision/color_rules_test.exs
# UMA PROVA É DE UM MUNDO. As caixas do HUD são pixels do QUADRO e o chão é uma
# CONTAGEM: os dois quadruplicam quando o backend de captura troca e serve a
# mesma região com o dobro da largura. A região não muda, e a porteira deixava
# passar.
test "a proof measured at another scale does not fit" do
  %{"slug" => slug} = regra()
  :ok = ColorRules.mark_proven(slug, 3, [], {0, 0, 100, 100}, 1.0)

  [armada] = ColorRules.armed()

  assert ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 1.0})
  refute ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 2.0})
end

test "a proof from before the scale field is still trusted" do
  %{"slug" => slug} = regra()
  :ok = ColorRules.mark_proven(slug, 3, [], {0, 0, 100, 100})

  [armada] = ColorRules.armed()

  assert ColorRules.proof_fits?(armada, {{0, 0, 100, 100}, 2.0})
end
```

- [ ] **Passo 2: rode e confirme a falha**

Rode: `mix test test/pokex/vision/color_rules_test.exs -k "another scale does not fit"`
Esperado: FALHA — `mark_proven/5` não existe.

- [ ] **Passo 3: guarde a ampliação**

```elixir
  def mark_proven(slug, floor_px, chrome \\ [], region \\ nil, scale \\ nil)
      when is_integer(floor_px) and floor_px >= 0 do
    mutate(slug, fn entry ->
      Map.put(entry, "proven", %{
        "floor_px" => floor_px,
        "chrome" => Enum.map(chrome, fn {l, t, r, b} -> [l, t, r, b] end),
        "region" => region && Tuple.to_list(region),
        # …E EM QUE AMPLIAÇÃO. `floor_px` é uma contagem e `chrome` são pixels do
        # quadro: os dois quadruplicam quando o backend troca e serve a mesma
        # região com o dobro da largura. A região sozinha não vê essa troca.
        "scale" => scale,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end
```

Em `armed/0`, ao lado de `proven_region: proven_region(e)`:

```elixir
                proven_scale: proven_scale(e)
```

e as leitoras:

```elixir
  defp proven_scale(%{"proven" => %{"scale" => scale}}) when is_number(scale), do: scale
  defp proven_scale(_older_proof), do: nil
```

`proof_fits?/2` passa a olhar os dois, e uma prova sem `scale` segue confiável:

```elixir
  @spec proof_fits?(map, {tuple, number} | nil) :: boolean
  def proof_fits?(rule, {region, scale}),
    do: region_fits?(rule, region) and scale_fits?(rule, scale)

  def proof_fits?(_rule, nil), do: true

  defp region_fits?(%{proven_region: nil}, _region), do: true
  defp region_fits?(%{proven_region: stored}, region), do: stored == region
  defp region_fits?(_no_proof, _region), do: true

  defp scale_fits?(%{proven_scale: nil}, _scale), do: true
  defp scale_fits?(%{proven_scale: stored}, scale), do: stored == scale
  defp scale_fits?(_no_proof, _scale), do: true
```

- [ ] **Passo 4: passe a ampliação nos três chamadores**

- `lib/pokex/bots/shiny_guard.ex:215` — o quadro está em mão:
  `Enum.split_with(rules, &ColorRules.proof_fits?(&1, {region, frame.scale}))`
- `lib/pokex_web/live/calibration_live.ex` — na chamada de `mark_proven`, passe a
  ampliação DA FOTO que acabou de medir (a última amostra), não a da calibração:
  a foto é a testemunha.
- `lib/pokex/bots/shiny_readiness.ex` — `region_now/0` passa a devolver
  `{region, calib.scale}`. O selo não tem quadro, então usa a ampliação calibrada;
  é a melhor resposta disponível pra um selo, e a divergência real quem vê é o vigia.

Ajuste também o texto de `warn_stale/2` pra não prometer só a região: **"a prova do
chão foi medida noutro quadro (ou noutra ampliação de tela) — meça de novo na
calibração"**.

- [ ] **Passo 5: rode e confirme o verde**

Rode: `mix test test/pokex/vision/color_rules_test.exs test/pokex/bots/shiny_guard_test.exs test/pokex/bots/shiny_readiness_test.exs test/pokex_web/live/calibration_live_test.exs`
Esperado: PASSA.

- [ ] **Passo 6: commit**

```bash
git add lib/pokex/vision/color_rules.ex lib/pokex/bots/shiny_guard.ex lib/pokex/bots/shiny_readiness.ex lib/pokex_web/live/calibration_live.ex test/pokex/vision/color_rules_test.exs test/pokex/bots/shiny_guard_test.exs
git commit -m "a prova do chão também é de uma ampliação de tela, não só de uma região"
```

---

## Achado extra, FORA das quatro: o cone de matiz também casa o HUD

**Por que:** `chrome = if rule_dark?(entry), do: chrome_of(samples), else: []` — só a
banda escura aprende o HUD, com o argumento de que "um cone de matiz nunca casou com o
cliente (ele é preto e cinza)". A conta desmente: `ColorMark.matches?/4` recusa como
cinza só `delta == 0`, e um pixel quase-preto com `delta == 1` sobrevive; com saturação
e brilho dividindo uma tolerância só em unidades absolutas, um tom apagado aceita
`(30, 29, 29)` — e todo quase-cinza cujo canal máximo é o vermelho cai no matiz 0.

Consequência: um tom apagado ensinado como cone de matiz conta o hotbar, a toolbar e a
Tracker window, o HUD nunca é proibido, e a regra nasce provada, armada e muda — a
mesma doença que a Tarefa 4 do #574 acabou de curar pro tom preto.

**Correção:** tirar o `if rule_dark?` e deixar toda regra aprender o HUD. O
aprendizado por quórum de fotos (corrigido no #574) já protege quem não precisa: o que
se mexe não vira cliente.

**Arquivos:** `lib/pokex_web/live/calibration_live.ex` (a linha do `chrome`),
`test/pokex_web/live/calibration_live_test.exs`.

**Por que fica fora deste plano:** a mudança é de uma linha, mas muda o comportamento
de TODA regra de matiz existente, inclusive as que hoje funcionam — vale medir uma vez
na tela dele antes de decidir. Se ele aprovar, entra como tarefa própria com o mesmo
rigor das quatro.

---

## Ordem e portão

Faça 1, 2, 4 em qualquer ordem (não se tocam). A 3 depois da 1: o teste do teto de
candidatos usa a cerca já corrigida.

No fim, e só no fim:

```bash
mix precommit
mix credo
mix dialyzer
```

Depois: PR, esperar verde, mergear e continuar. Nada de main à frente do origin.

## Riscos

- **Tarefa 2 é a que mais mexe em caminho quente.** A ordem dos ramos de `confirm/3` é
  a correção; trocá-la prende uma bola pra sempre. O teste da válvula existe pra isso.
- **Tarefa 3 pode gastar mais bolas.** O teto e o alarme de bola seca são as cercas; a
  bancada mede antes do jogo.
- **Tarefa 4 aposenta as provas dele de novo** se a ampliação gravada não casar com a
  do quadro. É o comportamento certo, mas ele vai ter que medir o chão outra vez — vale
  avisar antes de mergear.
- **Nenhuma das quatro conserta as regras que ele tem hoje.** Elas continuam pedindo
  14,6 e 6,0 tiles de cor sólida até ele medir o chão de novo com a correção do #574.
