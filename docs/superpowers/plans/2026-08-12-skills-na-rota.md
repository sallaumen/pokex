# Skills na rota — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** o waypoint passa a carregar SKILLS (por categoria) e uma régua de
respiro editável, e a lição de cada luta para de cair no waypoint errado.

**Architecture:** um terceiro eixo `skills` no waypoint (categorias
`:buffs | :aoe | :single | :heal | :crowd`, nunca teclas), resolvido contra o
pokémon em campo na hora de apertar. Duas entregas conforme o momento: canto de
caminhada sai como ação `{:skills, cats}` que o Worker aperta pelo Body; ponto
de matança viaja no fato `:posture` e o Combat solta na frente da rajada. O
respiro vira precedência `waypoint > rota > global`, e a medição gravada vira
sugestão de tela.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, ExUnit. Sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-08-12-skills-na-rota-design.md`

## Global Constraints

- **Código, identificadores, `@moduledoc`, `@doc` e comentários em INGLÊS.**
  Português só em três lugares: texto que aparece na tela, texto de log pro
  Lucas, e **citações dele preservadas literalmente** dentro de um comentário
  (é assim que `route.ex` e `recording.ex` já são — prosa em inglês, a fala
  dele em português entre aspas com a data). ⚠️ **Os trechos de código deste
  plano trazem `@doc` e comentários em português porque o plano é escrito pro
  Lucas ler — ao implementar, escreva essa mesma prosa em INGLÊS**, mantendo o
  conteúdo e preservando as citações dele em português. (Convenção do repo,
  PRs #133/#135/#136.)
- **Categoria, nunca tecla literal**, no que a rota guarda. As cinco categorias
  são exatamente `SkillProfile.categories/0` = `[:buffs, :aoe, :single, :heal, :crowd]`.
- **Decodificação de arquivo é sempre whitelist**, nunca `String.to_atom/1`:
  `routes.json` é editável à mão e um typo não pode cunhar átomo.
- **Campo ausente em rota antiga lê como vazio**: `skills` → `[]`,
  `gather_wait_ms` → `nil`. Sem migração, sem script.
- **A caçada só atua pelo Body** — `grep 'Rig\.' lib/pokex/bots/cavebot/` tem que
  continuar vazio.
- **Toda tecla sai como toque depois de soltar o hold das setas** (`release_walk/1`),
  nunca por baixo de tecla presa.
- **O gravador nunca escreve nem apaga `skills` nem `gather_wait_ms`** — esses
  dois campos são só da mão dele.
- Ao final: `mix test`, `mix credo` e `mix dialyzer` limpos (o repo está zerado
  nos três e assim tem que ficar).

## Estrutura de arquivos

| arquivo | responsabilidade nesta mudança |
|---|---|
| `lib/pokex/bots/combat/loadout.ex` | ganha `keys/2` — a resolução categoria→teclas, hoje duplicada nos Timers |
| `lib/pokex/timers.ex` | passa a chamar `Loadout.keys/2` em vez da cópia local |
| `lib/pokex/bots/cavebot/route.ex` | o eixo `skills`, o `gather_wait_ms` (rota e waypoint) e a precedência |
| `lib/pokex/bots/cavebot/store.ex` | round-trip dos campos novos |
| `lib/pokex/bots/cavebot/logic.ex` | precedência do respiro (clampe sai), ação `{:skills, …}`, `orders/1` |
| `lib/pokex/bots/cavebot/worker.ex` | resolve categoria→tecla, aperta pelo Body, publica `orders` |
| `lib/pokex/bots/combat/worker.ex` | solta as ordens da rota na frente da rajada, deduplicadas |
| `lib/pokex/bots/cavebot/recording.ex` | a lição vai pro ponto de matança; `tidy/1` repara o que já foi gravado |
| `lib/pokex_web/live/cavebot_live.ex` | chips das categorias, campos do respiro, régua da rota |
| `test/support/fixtures/rota_meganium.json` | **já criado** — a rota real dele de 2026-08-12 |

---

### Task 1: `Loadout.keys/2` — uma resolução só

**Files:**
- Modify: `lib/pokex/bots/combat/loadout.ex`
- Modify: `lib/pokex/timers.ex:70-83`
- Test: `test/pokex/bots/combat/loadout_fight_test.exs`

**Interfaces:**
- Produces: `Pokex.Bots.Combat.Loadout.keys(loadout :: t | nil, category :: atom) :: [String.t()]`

`Pokex.Timers.keys_for/2` já resolve "qual é a aura DESTE pokémon" com um
`category_field/1` que é um mapa identidade. A caçada vai precisar da mesma
resposta; a função vira uma só, no dono do dado.

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/combat/loadout_fight_test.exs`, no fim do arquivo (antes do
`end` final), um bloco novo:

```elixir
  describe "keys/2 — a tecla desta categoria neste pokémon" do
    test "devolve as teclas classificadas da categoria" do
      loadout = Loadout.resolve("Vespiquen", %{"2" => :buffs, "3" => :aoe, "4" => :aoe})

      assert Loadout.keys(loadout, :buffs) == ["2"]
      assert Loadout.keys(loadout, :aoe) == ["3", "4"]
    end

    test "categoria sem tecla classificada é lista vazia, não erro" do
      loadout = Loadout.resolve("Sunkern", %{"3" => :aoe})

      assert Loadout.keys(loadout, :heal) == []
    end

    # Sem pokémon em campo a pergunta não tem resposta — e quem pergunta
    # (a caçada, os timers) não pode quebrar por causa disso.
    test "sem loadout é lista vazia" do
      assert Loadout.keys(nil, :buffs) == []
    end

    test "categoria que ninguém conhece é lista vazia" do
      loadout = Loadout.resolve("Gogoat", %{"1" => :buffs})

      assert Loadout.keys(loadout, :name) == []
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/combat/loadout_fight_test.exs
```

Esperado: FAIL com `function Pokex.Bots.Combat.Loadout.keys/2 is undefined`.

- [ ] **Step 3: Add `keys/2` to Loadout**

Em `lib/pokex/bots/combat/loadout.ex`, logo depois de `classified?/1`. Confira
que `alias Pokex.Pokedex.SkillProfile` já existe no topo do módulo (ele já usa
`SkillProfile.keys/2` em `resolve/2`):

```elixir
  @doc """
  As teclas desta categoria NESTE pokémon — `[]` quando não há resposta.

  A pergunta que uma ordem agendada faz ("qual é a aura dele?"), separada da
  que a luta faz (`attacks?/1`). Sem pokémon em campo, ou categoria que ele não
  classificou, a resposta é vazia e nunca uma exceção: quem pergunta é um
  worker no meio de um tick.
  """
  @spec keys(t | nil, atom) :: [String.t()]
  def keys(%__MODULE__{} = loadout, category) do
    if category in SkillProfile.categories(), do: Map.get(loadout, category, []), else: []
  end

  def keys(nil, _no_pokemon), do: []
```

- [ ] **Step 4: Point Timers at it**

Em `lib/pokex/timers.ex`, substitua as três cláusulas de `keys_for/2` e apague
o `category_field/1` inteiro (as cinco cláusulas nas linhas 79-83):

```elixir
  @spec keys_for(Timer.t(), Loadout.t() | nil) :: [String.t()]
  def keys_for(%Timer{category: nil, keys: keys}, _loadout),
    do: Enum.filter(keys, &(&1 in SkillProfile.hotbar_keys()))

  def keys_for(%Timer{category: category}, loadout), do: Loadout.keys(loadout, category)
```

- [ ] **Step 5: Run the tests**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/combat/loadout_fight_test.exs test/pokex/timers/schedule_test.exs test/pokex/bots/timers/worker_test.exs
```

Esperado: PASS em todos. Os testes dos timers provam que a troca não mudou o
comportamento deles.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/combat/loadout.ex lib/pokex/timers.ex test/pokex/bots/combat/loadout_fight_test.exs
git commit -m "refactor: categoria vira tecla num lugar só (Loadout.keys/2)"
```

---

### Task 2: o eixo `skills` e a régua do respiro no `Route`

**Files:**
- Modify: `lib/pokex/bots/cavebot/route.ex`
- Test: `test/pokex/bots/cavebot/route_action_test.exs`

**Interfaces:**
- Produces:
  - `Route.skills() :: [atom]` (as cinco categorias, na ordem canônica)
  - `Route.set_skill(t, index :: non_neg_integer, category :: atom, on? :: boolean) :: t`
  - `Route.skills_at(waypoints :: [waypoint], index) :: [atom]`
  - `Route.set_gather_wait(t, ms :: non_neg_integer | nil) :: t` (a régua DA ROTA)
  - `Route.set_gather_wait(t, index, ms :: non_neg_integer | nil) :: t` (a do waypoint)
  - `Route.gather_wait(t, waypoint :: map, default :: non_neg_integer) :: non_neg_integer`
  - campo novo na struct: `gather_wait_ms: nil`
  - campos novos no waypoint: `skills: []`, `gather_wait_ms: nil`

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/route_action_test.exs`, adicione no fim (antes do
`end` final):

```elixir
  describe "skills — o terceiro eixo do waypoint" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, route} = Route.append(route, {12, 10, 5})
      %{route: route}
    end

    test "nasce sem nenhuma", %{route: route} do
      assert Route.skills_at(route.waypoints, 0) == []
    end

    test "liga e desliga uma categoria", %{route: route} do
      route = Route.set_skill(route, 0, :buffs, true)
      assert Route.skills_at(route.waypoints, 0) == [:buffs]

      route = Route.set_skill(route, 0, :buffs, false)
      assert Route.skills_at(route.waypoints, 0) == []
    end

    # A ordem é a canônica, não a de clique: duas rotas com as mesmas skills
    # têm que produzir a mesma sequência de teclas.
    test "guarda na ordem canônica, não na de clique", %{route: route} do
      route =
        route
        |> Route.set_skill(0, :single, true)
        |> Route.set_skill(0, :buffs, true)

      assert Route.skills_at(route.waypoints, 0) == [:buffs, :single]
    end

    test "ligar duas vezes não duplica", %{route: route} do
      route = route |> Route.set_skill(0, :buffs, true) |> Route.set_skill(0, :buffs, true)
      assert Route.skills_at(route.waypoints, 0) == [:buffs]
    end

    test "não vaza pro waypoint vizinho", %{route: route} do
      route = Route.set_skill(route, 0, :buffs, true)
      assert Route.skills_at(route.waypoints, 1) == []
    end

    # Mesma regra do set_stop: controle que não pode agir é no-op, nunca erro.
    test "índice inexistente e categoria desconhecida não mudam nada", %{route: route} do
      assert Route.set_skill(route, 99, :buffs, true) == route
      assert Route.set_skill(route, 0, :nadar, true) == route
      assert Route.skills_at(route.waypoints, 99) == []
    end
  end

  describe "gather_wait/3 — a régua do respiro" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      %{route: route, wp: hd(route.waypoints)}
    end

    test "sem nada escrito, manda o global", %{route: route, wp: wp} do
      assert Route.gather_wait(route, wp, 4_000) == 4_000
    end

    test "a régua da rota ganha do global", %{route: route, wp: wp} do
      route = Route.set_gather_wait(route, 1_800)
      assert Route.gather_wait(route, wp, 4_000) == 1_800
    end

    test "o waypoint ganha da régua da rota", %{route: route} do
      route = route |> Route.set_gather_wait(1_800) |> Route.set_gather_wait(0, 600)
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 600
    end

    # Zero é uma resposta legítima — "não espera nada aqui" — e não pode cair
    # no `||` pro próximo nível.
    test "zero é obedecido, não é ausência", %{route: route} do
      route = route |> Route.set_gather_wait(1_800) |> Route.set_gather_wait(0, 0)
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 0
    end

    test "apagar volta pro nível de cima", %{route: route} do
      route =
        route
        |> Route.set_gather_wait(1_800)
        |> Route.set_gather_wait(0, 600)
        |> Route.set_gather_wait(0, nil)

      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 1_800
    end

    # A medição das mãos dele continua guardada e continua NÃO mandando.
    test "o gather_ms medido não entra na conta", %{route: route} do
      route = Route.set_timing(route, 0, gather_ms: 4_534)
      assert Route.gather_wait(route, hd(route.waypoints), 1_000) == 1_000
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/route_action_test.exs
```

Esperado: FAIL com `function Pokex.Bots.Cavebot.Route.skills_at/2 is undefined`.

- [ ] **Step 3: Add the struct fields**

Em `lib/pokex/bots/cavebot/route.ex`, a struct (linhas 15-20) vira:

```elixir
  @enforce_keys [:name]
  defstruct name: nil,
            dungeon: nil,
            z: nil,
            enabled?: true,
            # a régua do respiro DESTA rota; nil = o número global do /config
            gather_wait_ms: nil,
            waypoints: []
```

No `@type waypoint`, acrescente os dois campos novos depois de `combo`:

```elixir
          combo: [String.t()],
          skills: [skill],
          gather_wait_ms: non_neg_integer | nil
```

No `@type t`, acrescente depois de `enabled?`:

```elixir
          gather_wait_ms: non_neg_integer | nil,
```

E o typedoc do eixo novo, junto dos outros dois (depois do bloco `@stops`):

```elixir
  @typedoc """
  Que trabalho o pokémon faz AQUI, dito por categoria e não por tecla.

  Terceiro eixo do waypoint, ao lado da função e das paradas, pelo mesmo motivo
  que separou os dois primeiros: o canto onde ele solta a aura costuma ser
  exatamente o canto marcado "até aqui", e fazer os dois competirem por uma vaga
  tornaria impossível a combinação mais útil.

  Categoria, nunca tecla: a tecla sai do pokémon que está em campo na hora de
  apertar, então trocar de Vileplume (aura no 1) pra Vespiquen (aura no 2) não
  faz a rota mentir. Escrito SÓ pela mão dele — o gravador nunca toca aqui.
  """
  @type skill :: :buffs | :aoe | :single | :heal | :crowd

  @skills [:buffs, :aoe, :single, :heal, :crowd]
```

- [ ] **Step 4: Give new waypoints the fields**

No `append/3` (linha ~114), o mapa do waypoint ganha as duas chaves no fim:

```elixir
      fight_ms: nil,
      gather_ms: nil,
      combo: [],
      skills: [],
      gather_wait_ms: nil
    }
```

- [ ] **Step 5: Write the four functions**

Em `lib/pokex/bots/cavebot/route.ex`, depois de `stops_at/2`:

```elixir
  @doc "Todas as categorias que um waypoint pode carregar, na ordem em que saem."
  @spec skills() :: [skill]
  def skills, do: @skills

  @doc """
  Liga ou desliga uma categoria no waypoint `index`.

  Guarda na ordem canônica e não na de clique: duas rotas com as mesmas skills
  têm que apertar a mesma sequência. Índice que ninguém tem, ou categoria que
  ninguém conhece, devolve a rota intocada — mesma regra do `set_stop/4`.
  """
  @spec set_skill(t, non_neg_integer, skill, boolean) :: t
  def set_skill(%__MODULE__{waypoints: waypoints} = route, index, skill, on?)
      when is_integer(index) and skill in @skills and is_boolean(on?) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        kept = if on?, do: [skill | wp[:skills] || []], else: (wp[:skills] || []) -- [skill]
        wp = Map.put(wp, :skills, Enum.filter(@skills, &(&1 in kept)))
        %{route | waypoints: List.replace_at(waypoints, index, wp)}
    end
  end

  def set_skill(%__MODULE__{} = route, _index, _unknown, _on?), do: route

  @doc "As categorias do waypoint `index` — `[]` pra índice que ninguém tem."
  @spec skills_at([waypoint], non_neg_integer) :: [skill]
  def skills_at(waypoints, index) when is_list(waypoints) and is_integer(index) do
    case Enum.at(waypoints, index) do
      %{skills: skills} when is_list(skills) -> skills
      _absent_or_old -> []
    end
  end

  @doc """
  A régua do respiro DESTA rota — quanto ela espera o bolo fechar antes de
  soltar a primeira skill. `nil` devolve o comando pro número global.

  Existe porque a medição da gravação não serve como ordem: os oito pontos de
  matança da Meganium 1 mediram de 569ms a 4534ms. Um número que ele dial pra
  baixo é o que deixa a rota mais rápida; a medição é só onde começar.
  """
  @spec set_gather_wait(t, non_neg_integer | nil) :: t
  def set_gather_wait(%__MODULE__{} = route, ms) when is_nil(ms) or (is_integer(ms) and ms >= 0),
    do: %{route | gather_wait_ms: ms}

  @doc "O respiro DESTE waypoint; `nil` devolve o comando pra régua da rota."
  @spec set_gather_wait(t, non_neg_integer, non_neg_integer | nil) :: t
  def set_gather_wait(%__MODULE__{waypoints: waypoints} = route, index, ms)
      when is_integer(index) and (is_nil(ms) or (is_integer(ms) and ms >= 0)) do
    case Enum.at(waypoints, index) do
      nil ->
        route

      wp ->
        %{route | waypoints: List.replace_at(waypoints, index, Map.put(wp, :gather_wait_ms, ms))}
    end
  end

  @doc """
  Quanto esperar o bolo fechar neste waypoint: a mão dele no canto, senão a
  régua da rota, senão o número global — nessa ordem.

  `nil` é ausência e zero é resposta ("não espera nada aqui"), então a escolha
  é por `is_integer/1` e nunca por `||`.
  """
  @spec gather_wait(t, waypoint, non_neg_integer) :: non_neg_integer
  def gather_wait(%__MODULE__{gather_wait_ms: route_ms}, waypoint, default) do
    cond do
      is_integer(waypoint[:gather_wait_ms]) -> waypoint[:gather_wait_ms]
      is_integer(route_ms) -> route_ms
      true -> default
    end
  end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/
```

Esperado: PASS em todos os arquivos de cavebot.

- [ ] **Step 7: Commit**

```bash
git add lib/pokex/bots/cavebot/route.ex test/pokex/bots/cavebot/route_action_test.exs
git commit -m "feat: o waypoint carrega skills por categoria e uma régua de respiro"
```

---

### Task 3: `Store` — os campos novos sobrevivem ao disco

**Files:**
- Modify: `lib/pokex/bots/cavebot/store.ex:79-88` (decode), `:92-105` (decode_waypoint), `:142-166` (encode)
- Test: `test/pokex/bots/cavebot/store_test.exs`

**Interfaces:**
- Consumes: `Route.skills/0`, `Route.set_skill/4`, `Route.set_gather_wait/2`, `Route.set_gather_wait/3`

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/store_test.exs`, no fim do arquivo:

```elixir
  describe "os campos novos no disco" do
    test "skills e as duas réguas fazem round-trip" do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})

      route =
        route
        |> Route.set_skill(0, :buffs, true)
        |> Route.set_skill(0, :aoe, true)
        |> Route.set_gather_wait(1_800)
        |> Route.set_gather_wait(0, 600)

      :ok = Store.add(route)
      [read] = Store.all()

      assert read.gather_wait_ms == 1_800
      assert Route.skills_at(read.waypoints, 0) == [:buffs, :aoe]
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 600
    end

    test "nil não vira zero na ida e volta" do
      {:ok, route} = Route.append(Route.new("sem régua"), {10, 10, 5})
      :ok = Store.add(route)
      [read] = Store.all()

      assert read.gather_wait_ms == nil
      assert hd(read.waypoints)[:gather_wait_ms] == nil
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 4_000
    end

    # O arquivo é editável à mão: um typo não pode cunhar átomo nem quebrar a
    # leitura da rota inteira. Mesma regra que já vale pra action e pros stops.
    test "categoria que ninguém conhece é descartada, não cunhada" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"suja","dungeon":null,"z":5,"enabled":true,
      "waypoints":[{"x":1,"y":2,"z":5,"skills":["buffs","voar","aoe"]}]}]}
      """)

      [read] = Store.all()

      assert Route.skills_at(read.waypoints, 0) == [:buffs, :aoe]
    end

    # As cinco rotas que ele já tem foram gravadas antes destes campos.
    test "rota antiga, sem os campos, lê como vazia" do
      File.write!(Path.join(Pokex.Home.dir(), "routes.json"), """
      {"routes":[{"name":"antiga","dungeon":null,"z":5,"enabled":true,
      "waypoints":[{"x":1,"y":2,"z":5,"action":"lure_end","stops":["sweep"]}]}]}
      """)

      [read] = Store.all()

      assert read.gather_wait_ms == nil
      assert Route.skills_at(read.waypoints, 0) == []
      assert Route.gather_wait(read, hd(read.waypoints), 4_000) == 4_000
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/store_test.exs
```

Esperado: FAIL — `read.gather_wait_ms` vem `nil` no primeiro teste (o campo não
é escrito nem lido ainda).

- [ ] **Step 3: Decode**

Em `lib/pokex/bots/cavebot/store.ex`, `decode_route/1` ganha a régua:

```elixir
  defp decode_route(map) do
    %Route{
      name: map["name"],
      dungeon: map["dungeon"],
      z: map["z"],
      enabled?: map["enabled"] != false,
      gather_wait_ms: decode_dwell(map["gather_wait_ms"]),
      waypoints: Enum.map(map["waypoints"] || [], &decode_waypoint/1)
    }
  end
```

`decode_waypoint/1` ganha as duas chaves no fim do mapa:

```elixir
      combo: decode_combo(map["combo"]),
      skills: decode_skills(map["skills"]),
      gather_wait_ms: decode_dwell(map["gather_wait_ms"])
    }
```

E, junto dos outros decodificadores (depois de `decode_combo/1`):

```elixir
  # Whitelist, como a action e os stops: `routes.json` é editável à mão e um
  # typo nele não pode cunhar átomo. Ordem canônica na saída, não a do arquivo.
  defp decode_skills(list) when is_list(list),
    do: Enum.filter(Route.skills(), &(Atom.to_string(&1) in list))

  defp decode_skills(_absent), do: []
```

- [ ] **Step 4: Encode**

`encode/1` ganha a régua depois de `"enabled"`:

```elixir
      "enabled" => route.enabled?,
      "gather_wait_ms" => route.gather_wait_ms,
```

`encode_waypoint/1` ganha as duas chaves depois de `"combo"`:

```elixir
      "combo" => Map.get(waypoint, :combo) || [],
      "skills" => Enum.map(Map.get(waypoint, :skills) || [], &Atom.to_string/1),
      "gather_wait_ms" => Map.get(waypoint, :gather_wait_ms)
    }
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/store_test.exs test/pokex/bots/cavebot/
```

Esperado: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/cavebot/store.ex test/pokex/bots/cavebot/store_test.exs
git commit -m "feat: skills e réguas sobrevivem ao routes.json"
```

---

### Task 4: `Logic` — a precedência e o momento de cada skill

**Files:**
- Modify: `lib/pokex/bots/cavebot/logic.ex` (`@type action`, `on_arrival/2`, `arrived_at/3`, `gather_wait/1`, `combo/1` vizinhança)
- Test: `test/pokex/bots/cavebot/logic_test.exs`

**Interfaces:**
- Consumes: `Route.gather_wait/3`, `Route.skills_at/2`
- Produces:
  - ação nova `{:skills, [Route.skill()]}` no vocabulário da Logic
  - `Logic.orders(t) :: [Route.skill()]` — as categorias do ponto de matança em que a caçada está, `[]` em qualquer outro lugar

A Logic é PURA: ela emite CATEGORIA, nunca tecla — quem tem o pokémon em campo
é o Worker. Mesma disciplina do `{:park, spot}`, que emite lugar e nunca pixel.

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/logic_test.exs`, no fim (antes do `end` final). O
arquivo já tem `@cfg` (mapa de config), `route/0` e
`world(pos, enemies \\ 0, combat \\ :hunting)` — os blocos abaixo usam esses
mesmos:

```elixir
  describe "skills da rota — o momento de cada uma" do
    # Dois cantos: o primeiro é caminhada com AURA, o segundo é o ponto de
    # matança. Chegar em cada um é o que arma cada coisa.
    defp aura_route do
      {:ok, r} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, r} = Route.append(r, {12, 10, 5})

      r
      |> Route.set_skill(0, :buffs, true)
      |> Route.set_action(1, :lure_end)
      |> Route.set_skill(1, :heal, true)
    end

    defp at_first_corner(route) do
      logic = Logic.new(route, @cfg)
      {logic, :run_combat} = Logic.step(logic, world({10, 10, 5}), 0)
      Logic.step(logic, world({10, 10, 5}), 200)
    end

    test "chegar num canto de caminhada com skill emite a ordem" do
      {_logic, action} = at_first_corner(aura_route())

      assert action == {:skills, [:buffs]}
    end

    # Uma vez por chegada, nunca por tick: o canto seguinte já é outro destino.
    test "o tick seguinte não repete a ordem" do
      {logic, _arrival} = at_first_corner(aura_route())
      {_logic, again} = Logic.step(logic, world({10, 10, 5}), 400)

      refute match?({:skills, _}, again)
    end

    test "canto sem skill nenhuma não emite ordem" do
      {:ok, r} = Route.append(Route.new("lisa"), {10, 10, 5})
      {:ok, r} = Route.append(r, {12, 10, 5})
      {_logic, action} = at_first_corner(r)

      refute match?({:skills, _}, action)
    end

    # No ponto de matança a ordem NÃO sai como ação: ela viaja com a postura,
    # porque ali existe uma rajada pra entrar na frente.
    test "no ponto de matança a ordem vai pra postura, não pra ação" do
      {logic, _} = at_first_corner(aura_route())
      {logic, action} = Logic.step(logic, world({12, 10, 5}), 1_000)

      refute match?({:skills, _}, action)
      assert Logic.orders(logic) == [:heal]
    end

    test "fora de ponto de matança não há ordem pra rajada" do
      {logic, _} = at_first_corner(aura_route())

      assert Logic.orders(logic) == []
    end
  end

  describe "respiro — a régua ganha da medição" do
    # Chega no ponto de matança (waypoint 1) no instante 1_000, que é quando o
    # relógio do bolo começa a contar.
    defp arrived_at_kill(edit) do
      {:ok, r} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, r} = Route.append(r, {12, 10, 5})
      route = r |> Route.set_action(1, :lure_end) |> then(edit)

      logic = Logic.new(route, @cfg)
      {logic, :run_combat} = Logic.step(logic, world({10, 10, 5}), 0)
      {logic, _} = Logic.step(logic, world({10, 10, 5}), 200)
      {logic, _} = Logic.step(logic, world({12, 10, 5}), 1_000)
      logic
    end

    test "sem régua nenhuma, segura o fogo pelos 4s do @cfg" do
      logic = arrived_at_kill(& &1)

      assert Logic.gathering?(logic, 4_900)
      refute Logic.gathering?(logic, 5_100)
    end

    test "a régua da rota manda no global" do
      logic = arrived_at_kill(&Route.set_gather_wait(&1, 1_800))

      assert Logic.gathering?(logic, 2_700)
      refute Logic.gathering?(logic, 2_900)
    end

    test "o waypoint manda na régua da rota" do
      logic =
        arrived_at_kill(fn r ->
          r |> Route.set_gather_wait(1_800) |> Route.set_gather_wait(1, 600)
        end)

      assert Logic.gathering?(logic, 1_500)
      refute Logic.gathering?(logic, 1_700)
    end

    test "zero no waypoint libera o fogo na hora" do
      logic = arrived_at_kill(&Route.set_gather_wait(&1, 1, 0))

      refute Logic.gathering?(logic, 1_000)
    end

    # A medição das mãos dele parou de mandar: 569ms a 4534ms nos oito pontos
    # da Meganium 1 não é uma ordem, é um sorteio.
    test "o gather_ms medido não segura mais o fogo" do
      logic = arrived_at_kill(&Route.set_timing(&1, 1, gather_ms: 8_000))

      refute Logic.gathering?(logic, 5_100)
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/logic_test.exs
```

Esperado: FAIL com `function Pokex.Bots.Cavebot.Logic.orders/1 is undefined`.

- [ ] **Step 3: Add the action to the vocabulary**

Em `lib/pokex/bots/cavebot/logic.ex`, `@type action` (linha ~59) ganha uma linha:

```elixir
          | {:park, Route.spot()}
          | {:skills, [Route.skill()]}
          | {:block, atom}
```

E no `@moduledoc`, no parágrafo do vocabulário, nada muda — mas o `@doc` da
`orders/1` explica o par.

- [ ] **Step 4: Emit the order on arrival**

Substitua as duas cláusulas de `on_arrival/2` (linhas 337-344):

```elixir
  # Parking the pokémon is the FIRST thing that happens on arrival, before the
  # huddle clock has run: he middle-clicks a spot so the pile closes in around
  # the pokémon instead of around him, and the four seconds are counted from
  # that click. WHERE is the waypoint's business (its own distance, its own
  # recorded click) with the hunt's default distance behind it — and it stays a
  # spec, never a screen point: this module has no calibration and no screen.
  #
  # A kill spot's own skills do NOT come out here: there is a burst to get in
  # front of, so they travel with the posture (`orders/1`) instead.
  defp on_arrival(logic, %{action: :lure_end} = wp) do
    case Route.park_spot(wp, default_park(logic)) do
      nil -> :none
      spot -> {:park, spot}
    end
  end

  # A walking corner carrying skills: the aura he presses himself in the middle
  # of a mob stretch. Nothing is fighting here, so nobody is competing for the
  # keyboard — the order goes out as an action and the Worker taps it. Once per
  # arrival, like every other thing a corner does.
  defp on_arrival(_logic, %{skills: [_ | _] = skills}), do: {:skills, skills}

  defp on_arrival(_logic, _plain_arrival), do: :none
```

- [ ] **Step 5: Resolve the huddle by precedence, and drop the clamp**

Substitua `arrived_at/3` (:lure_end clause, linha ~359) e as duas cláusulas
privadas de `gather_wait/1` (linhas 319-329) por:

```elixir
  defp arrived_at(logic, %{action: :lure_end} = wp, now),
    do: %{
      logic
      | since: Map.put(logic.since, :gather, now),
        gather_wait: Route.gather_wait(logic.route, wp, config_gather_wait(logic))
    }
```

```elixir
  # A régua dele, resolvida na chegada: o canto, senão a rota, senão o global
  # (`Route.gather_wait/3`). O `gather_ms` MEDIDO saiu desta conta em
  # 2026-08-12 — as oito medições da Meganium 1 vão de 569ms a 4534ms, e metade
  # delas nem estava no waypoint certo. Medição virou sugestão de tela; o que
  # a caçada obedece é número escrito à mão, sem clampe no meio.
  defp gather_wait(%__MODULE__{gather_wait: ms}) when is_integer(ms), do: ms
  defp gather_wait(%__MODULE__{} = logic), do: config_gather_wait(logic)

  defp config_gather_wait(%__MODULE__{config: config}), do: Map.get(config, :gather_wait_ms, 0)
```

**Não mexa** ainda no `@type config` (linhas ~94-95): as chaves
`gather_wait_min_ms`/`gather_wait_max_ms` continuam chegando do Worker, e tirar
só do tipo deixaria o Dialyzer vendo um mapa com chave a mais. As duas pontas
saem juntas no Task 5, Step 5.

- [ ] **Step 6: Add `orders/1`**

Logo depois de `combo/1` (linha ~304), e reusando o `kill_spot_combo/1` como
molde:

```elixir
  @doc """
  As categorias que ELE mandou usar no ponto de matança em que a caçada está —
  `[]` em qualquer outro lugar.

  Par do `combo/1` e entregue pelo mesmo caminho (o fato `:posture`), por um
  motivo que a ação `{:skills, _}` não resolveria: aqui existe uma rajada, e uma
  aura que sai DEPOIS do estouro em área não serviu pra nada. Viajando com a
  postura, o Combat monta uma lista só e o Body executa em ordem — a mesma
  solução que fez a tecla de postura funcionar.

  Categoria, não tecla: quem tem o pokémon em campo é o Worker.
  """
  @spec orders(t) :: [Route.skill()]
  def orders(%__MODULE__{since: since} = logic) do
    if Map.has_key?(since, :gather), do: kill_spot_skills(logic), else: []
  end

  defp kill_spot_skills(%__MODULE__{route: %Route{waypoints: []}}), do: []

  defp kill_spot_skills(%__MODULE__{route: %Route{waypoints: waypoints}} = logic) do
    Route.skills_at(waypoints, Integer.mod(logic.wp_index - 1, length(waypoints)))
  end
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/
```

Esperado: PASS. Se algum teste antigo de `logic_test.exs` provava o clampe
min/max, ele agora falha — apague esse teste e anote no relatório: o clampe saiu
de propósito (Task 4, Step 5), e a defesa contra medição implausível passou a
viver na sugestão de tela (Task 8).

- [ ] **Step 8: Commit**

```bash
git add lib/pokex/bots/cavebot/logic.ex test/pokex/bots/cavebot/logic_test.exs
git commit -m "feat: a Logic emite a skill do canto e obedece a régua, não a medição"
```

---

### Task 5: `Worker` — categoria vira tecla e sai pelo Body

**Files:**
- Modify: `lib/pokex/bots/cavebot/worker.ex` (state, `init`, `@config_keys`, `translate/2`, `publish_posture/2`)
- Test: `test/pokex/bots/cavebot/worker_test.exs`

**Interfaces:**
- Consumes: `Logic.orders/1`, ação `{:skills, [category]}`, `Loadout.keys/2`
- Produces: fato `:posture` com o campo novo `orders: [String.t()]` (teclas já
  resolvidas — o Combat não resolve nada)

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/worker_test.exs`, no fim. O arquivo já define
`Pokex.Bots.Cavebot.WorkerTest.FakeBody` no topo, cujo `perform/3` manda
`{:performed, priority, actions}` pro pid do teste — e `Worker.translate/2` é
público. `release_walk/1` com `held_keys: []` é no-op, então um estado mínimo
basta:

```elixir
  describe "as skills da rota" do
    setup do
      start_supervised!({FakeBody, self()})
      :ok
    end

    defp skill_state(loadout),
      do: %{body: FakeBody, held_keys: [], loadout: loadout}

    test "a ordem do canto vira tecla do pokémon em campo e sai pelo Body" do
      state = skill_state(Loadout.resolve("Vespiquen", %{"2" => :buffs}))

      Worker.translate(state, {:skills, [:buffs]})

      assert_receive {:performed, :normal, [{:press, "2"}]}
    end

    # Trocar de pokémon muda a tecla sem mexer na rota — é o motivo de a rota
    # guardar categoria e não tecla.
    test "o mesmo canto aperta outra tecla com outro pokémon" do
      state = skill_state(Loadout.resolve("Shiny Vileplume", %{"1" => :buffs}))

      Worker.translate(state, {:skills, [:buffs]})

      assert_receive {:performed, :normal, [{:press, "1"}]}
    end

    test "duas categorias saem na ordem, sem repetir tecla" do
      state = skill_state(Loadout.resolve("Gogoat", %{"1" => :buffs, "4" => :aoe}))

      Worker.translate(state, {:skills, [:buffs, :aoe]})

      assert_receive {:performed, :normal, [{:press, "1"}, {:press, "4"}]}
    end

    # Rota apontando pra skill que este pokémon não tem não pode travar caçada.
    test "categoria não classificada não aperta nada e não quebra" do
      state = skill_state(Loadout.resolve("Sunkern", %{"3" => :aoe}))

      assert %{} = Worker.translate(state, {:skills, [:heal]})
      refute_receive {:performed, _priority, _actions}, 50
    end

    test "sem pokémon em campo não aperta nada e não quebra" do
      state = skill_state(nil)

      assert %{} = Worker.translate(state, {:skills, [:buffs]})
      refute_receive {:performed, _priority, _actions}, 50
    end

    # Tecla presa é o pior bug possível: a skill só sai depois que as setas
    # foram soltas.
    test "solta o hold das setas antes de apertar" do
      state = %{skill_state(Loadout.resolve("Vespiquen", %{"2" => :buffs})) | held_keys: ["right"]}

      Worker.translate(state, {:skills, [:buffs]})

      assert_receive {:held, []}
      assert_receive {:performed, :normal, [{:press, "2"}]}
    end
  end
```

Acrescente ao topo do arquivo de teste, junto dos outros aliases:
`alias Pokex.Bots.Combat.Loadout` e `alias Pokex.Bots.Cavebot.WorkerTest.FakeBody`.

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/worker_test.exs
```

Esperado: FAIL — `Worker.translate/2` não tem cláusula pra `{:skills, _}`
(`FunctionClauseError`).

- [ ] **Step 3: Keep the loadout in state**

Em `lib/pokex/bots/cavebot/worker.ex`, no mapa de `start_link/1` (~linha 95),
acrescente depois de `held_keys: []`:

```elixir
      # o pokémon em campo, pra virar tecla quando a rota manda uma categoria.
      # Guardado e renovado no evento, nunca lido por tick: `Loadout.current/0`
      # lê o arquivo do time.
      loadout: Pokex.Bots.Combat.Loadout.current(),
```

No `init/1`, junto das outras assinaturas (perto da linha 158), acrescente:

```elixir
    Phoenix.PubSub.subscribe(Pokex.PubSub, Pokex.Team.topic())
```

E uma cláusula de `handle_info` junto das outras:

```elixir
  # Trocar de pokémon muda qual tecla é a aura — a rota guarda a categoria e é
  # aqui que ela vira tecla, então esta cópia tem que acompanhar.
  def handle_info({:team_changed}, state),
    do: {:noreply, %{state | loadout: Loadout.current()}}
```

O módulo já tem `alias Pokex.Bots.BotSupervisor` e vizinhos no topo (linha ~50);
acrescente ali:

```elixir
  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Pokedex.Team
```

`Pokex.Pokedex.Team.topic/0` é o mesmo tópico que `Bots.Timers.Worker` assina
(`lib/pokex/bots/timers/worker.ex:72`), e quem publica `{:team_changed}` é
`lib/pokex/pokedex/team.ex:37`. Se `Combat` já estiver aliasado no arquivo, use
`Combat.Loadout` e não adicione o alias novo — dois caminhos pro mesmo módulo
fazem o Credo reclamar.

- [ ] **Step 4: Translate the action**

Em `lib/pokex/bots/cavebot/worker.ex`, junto das outras cláusulas de
`translate/2` (depois da do `{:park, spot}`):

```elixir
  # A skill que ELE colocou neste canto — a aura no meio da mobada, quase
  # sempre. Categoria vira tecla aqui e não na Logic, porque quem sabe qual
  # pokémon está em campo é este processo. Toque, nunca hold, e depois de
  # soltar as setas: tecla presa é o pior bug possível.
  def translate(state, {:skills, categories}) do
    state = release_walk(state)

    case skill_keys(state.loadout, categories) do
      [] ->
        log(:macro, "✨ não apertei nada aqui: #{Loadout.describe(state.loadout)} não tem #{skills_text(categories)}")
        state

      keys ->
        log(:macro, "✨ skill da rota: #{Enum.join(keys, ", ")}")
        Body.perform(Enum.map(keys, &{:press, &1}), :normal, state.body)
        state
    end
  end
```

E os dois auxiliares privados, junto dos outros do módulo:

```elixir
  # Ordem canônica das categorias, dedup por TECLA: duas categorias podem
  # cair na mesma tecla, e apertar duas vezes não é o que ele pediu.
  defp skill_keys(loadout, categories) do
    categories
    |> Enum.flat_map(&Loadout.keys(loadout, &1))
    |> Enum.uniq()
  end

  defp skills_text(categories),
    do: Enum.map_join(categories, ", ", &"#{SkillProfile.icon(&1)} #{SkillProfile.label(&1)}")
```

`SkillProfile.icon/1` e `SkillProfile.label/1` já existem
(`lib/pokex/pokedex/skill_profile.ex:76-96`) e devolvem `"✨"`/`"aura"`,
`"💥"`/`"área"`, `"🎯"`/`"alvo único"`, `"❤️"`/`"cura"`, `"🌀"`/`"controle"`.
`Loadout.describe/1` também já existe e trata `nil` ("sem pokémon escolhido").

- [ ] **Step 5: Drop the clamp keys from both ends**

O clampe saiu da Logic no Task 4 — agora as duas chaves param de viajar. Em
`lib/pokex/bots/cavebot/worker.ex`, apague estas duas linhas do `@config_keys`
(linhas ~82-84, mantendo `gather_wait_ms`):

```elixir
    gather_wait_min_ms: :cavebot_gather_wait_min_ms,
    gather_wait_max_ms: :cavebot_gather_wait_max_ms,
```

E em `lib/pokex/bots/cavebot/logic.ex`, apague as mesmas duas chaves do
`@type config` (linhas ~94-95). As settings `cavebot_gather_wait_min_ms` e
`cavebot_gather_wait_max_ms` **continuam existindo** em `settings.ex` com o
mesmo significado — quem passa a lê-las é a sugestão de tela (Task 8).

- [ ] **Step 6: Publish the orders with the posture**

Em `publish_posture/2` (linha ~317), a linha do `WorldState.put` vira:

```elixir
    # …e WHAT to open with when the fire is released: his own combo from
    # this kill spot, plus the categories he ORDERED there — already resolved
    # to keys, because Combat has no business asking which pokémon is out.
    WorldState.put(
      :posture,
      %{
        posture: posture,
        combo: Logic.combo(state.logic),
        orders: skill_keys(state.loadout, Logic.orders(state.logic))
      },
      now
    )
```

- [ ] **Step 7: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/ test/pokex/bots/
```

Esperado: PASS.

- [ ] **Step 8: Commit**

```bash
git add lib/pokex/bots/cavebot/worker.ex lib/pokex/bots/cavebot/logic.ex test/pokex/bots/cavebot/worker_test.exs
git commit -m "feat: a caçada aperta a skill do canto com a tecla do pokémon em campo"
```

---

### Task 6: `Combat.Worker` — a ordem da rota abre a rajada

**Files:**
- Modify: `lib/pokex/bots/combat/worker.ex:255-320`
- Test: `test/pokex/bots/combat/worker_test.exs`

**Interfaces:**
- Consumes: fato `:posture` com `orders: [String.t()]`

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/combat/worker_test.exs`, no fim. Modele nos testes que já
existem ali (veja "the hunt's combo opens the fight, once, on the edge", linha
~168): o arquivo tem `%{worker: worker}` no setup, `presses/0`, `world!/2`,
`battle_obs/1`, `eventually/1`, `now_ms/0`, e cada teste leva `@tag :tmp_dir`.
Sem time classificado no home temporário, a abertura cai no combo gravado — é
esse caminho que os testes usam:

```elixir
  # A skill que ELE deixou marcada no canto da rota abre a rajada. Ela vem na
  # frente porque uma aura depois do estouro em área não serviu pra nada.
  @tag :tmp_dir
  test "a ordem da rota abre a rajada, na frente do combo", %{worker: worker} do
    posture = fn value, combo, orders ->
      WorldState.put(:posture, %{posture: value, combo: combo, orders: orders}, now_ms())
    end

    posture.(:hold_fire, ~w(3 4), ~w(1))
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    posture.(:free_fight, ~w(3 4), ~w(1))
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "4" in presses() end)
    assert Enum.filter(presses(), &(&1 in ~w(1 3 4))) == ~w(1 3 4)
  end

  # Ele pode ter posto 💥 área no canto onde a abertura já é em área. Apertar a
  # mesma tecla duas vezes só queima cooldown.
  @tag :tmp_dir
  test "tecla que já está na abertura não é apertada duas vezes", %{worker: worker} do
    posture = fn value ->
      WorldState.put(:posture, %{posture: value, combo: ~w(3 4), orders: ~w(3)}, now_ms())
    end

    posture.(:hold_fire)
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    posture.(:free_fight)
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "4" in presses() end)
    assert Enum.count(presses(), &(&1 == "3")) == 1
  end

  # Uma caçada de versão anterior ainda publicando o fato sem o campo novo não
  # pode derrubar o combate nem calar a abertura.
  @tag :tmp_dir
  test "fato sem o campo orders é lido como sem ordem", %{worker: worker} do
    WorldState.put(:posture, %{posture: :hold_fire, combo: ~w(3)}, now_ms())
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    WorldState.put(:posture, %{posture: :free_fight, combo: ~w(3)}, now_ms())
    world!(worker, battle_obs(enemies: [0, 1, 2]))

    assert eventually(fn -> "3" in presses() end)
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/combat/worker_test.exs
```

Esperado: FAIL — a primeira asserção recebe `[{:press, "3"}, {:press, "4"}]`,
sem o `"1"` na frente.

- [ ] **Step 3: Read the orders off the fact**

Em `lib/pokex/bots/combat/worker.ex`, `posture/0` (linha ~310) vira:

```elixir
  defp posture do
    case WorldState.get(:posture, Settings.get(:posture_max_age_ms), now()) do
      {:ok, %{posture: :hold_fire} = fact} -> {:hold_fire, combo_of(fact), orders_of(fact)}
      {:ok, fact} -> {:free_fight, combo_of(fact), orders_of(fact)}
      _stale_or_missing -> {:free_fight, [], []}
    end
  end

  defp combo_of(fact), do: Map.get(fact, :combo) || []
  defp orders_of(fact), do: Map.get(fact, :orders) || []
```

- [ ] **Step 4: Put them in front of the burst**

Na chamada (linha ~255) e em `open_with_combo/4`:

```elixir
    {posture, combo, orders} = posture()
    state = open_with_combo(state, state.logic.posture, posture, combo, orders)
```

```elixir
  defp open_with_combo(state, :hold_fire, :free_fight, recorded, orders) do
    {source, keys} = opening_keys(state.loadout, recorded)

    # A ordem que ELE deixou no canto vem primeiro: uma aura depois do estouro
    # em área não serviu pra nada, e o Body executa a lista em ordem. Dedup por
    # tecla — a mesma tecla duas vezes só queima cooldown.
    case orders ++ Enum.reject(keys, &(&1 in orders)) do
      [] ->
        state

      all ->
        Phoenix.PubSub.broadcast(
          Pokex.PubSub,
          @topic,
          {:combat_log, :macro, "combate: 💥 abrindo #{open_source(source, orders)}: #{Enum.join(all, ", ")}"}
        )

        dispatch(state, Enum.map(all, &{:press, &1}))
    end
  end

  defp open_with_combo(state, _was, _now, _combo, _orders), do: state

  defp open_source(source, []), do: source
  defp open_source(source, _orders), do: "com a ordem da rota + #{source}"
```

- [ ] **Step 5: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/combat/ test/pokex/bots/cavebot/
```

Esperado: PASS.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/combat/worker.ex test/pokex/bots/combat/worker_test.exs
git commit -m "feat: a ordem da rota abre a rajada, na frente e sem repetir tecla"
```

---

### Task 7: a lição da luta vai pro ponto de matança

**Files:**
- Modify: `lib/pokex/bots/cavebot/recording.ex` (novo `lesson_index/3`, novo passo no `tidy/1`)
- Modify: `lib/pokex_web/live/cavebot_live.ex:294-302` (`write_timings/3`)
- Create: `test/pokex/bots/cavebot/meganium_route_test.exs`
- Test: `test/pokex/bots/cavebot/recording_test.exs`
- Fixture: `test/support/fixtures/rota_meganium.json` (**já existe no worktree**)

**Interfaces:**
- Produces:
  - `Recording.lesson_index(route :: Route.t(), index :: non_neg_integer, opts :: keyword) :: non_neg_integer`
  - `Recording.tidy/1` passa a mover lições órfãs (assinatura inalterada)

**O fato medido que define a regra:** na `rota_meganium.json` (índices 0-based)
os pontos de matança são **4, 14, 23, 30, 38, 51, 57, 66**. Carregam lição os
waypoints **1, 5, 9, 15, 22, 23, 30, 35, 39, 51, 59, 66**. Cruzando:

- lição JÁ no lugar certo: 23, 30, 51, 66;
- lição de LUTA órfã: 5 → 4, 15 → 14, 39 → 38, 59 → 57 (todas com `fight_ms`);
- combo órfão que **NÃO É LIÇÃO DE LUTA**: 1, 9, 22, 35 — combo `["2"]`,
  `["2","2"]`, `["2","2"]`, `["2","2","2"]`, **sem `fight_ms`**. É a AURA que
  ele aperta andando. Mover isso pra um ponto de matança destruiria exatamente
  o sinal que esta feature existe pra dar.

**Portanto a regra é: só é lição de luta o waypoint que carrega `fight_ms`.**

- [ ] **Step 1: Write the failing test (a rota real dele)**

Crie `test/pokex/bots/cavebot/meganium_route_test.exs`. Copie o `setup` de
`test/pokex/bots/cavebot/mobada_route_test.exs:19` (que já monta um `~/.pokex`
temporário e copia uma fixture pra `routes.json`), trocando a fixture:

```elixir
defmodule Pokex.Bots.Cavebot.MeganiumRouteTest do
  # A rota que ele gravou em 2026-08-12 e disse que ia usar de verdade. Ela
  # existe aqui porque nenhum teste inventado tinha imaginado a forma que ela
  # tem: metade das lutas fecha um ou dois tiles DEPOIS do "até aqui".
  use ExUnit.Case, async: false

  alias Pokex.Bots.Cavebot.{Recording, Route, Store}

  @kill_spots [4, 14, 23, 30, 38, 51, 57, 66]
  @orphan_fights %{5 => 4, 15 => 14, 39 => 38, 59 => 57}
  # os cantos onde ele aperta a AURA andando: combo sem luta nenhuma
  @aura_corners [1, 9, 22, 35]

  setup do
    tmp = Path.join(System.tmp_dir!(), "pokex-meganium-#{System.unique_integer([:positive])}")
    File.mkdir_p!(tmp)
    File.cp!("test/support/fixtures/rota_meganium.json", Path.join(tmp, "routes.json"))
    Application.put_env(:pokex, :home_dir, tmp)

    on_exit(fn ->
      Application.put_env(:pokex, :home_dir, tmp)
      File.rm_rf!(tmp)
    end)

    [route] = Store.all()
    %{route: route}
  end

  test "a gravação dele tem 8 pontos de matança e só 4 com a lição no lugar", %{route: route} do
    kills = for {wp, i} <- Enum.with_index(route.waypoints), wp.action == :lure_end, do: i
    assert kills == @kill_spots

    with_lesson = for {wp, i} <- Enum.with_index(route.waypoints), wp.fight_ms, do: i
    assert Enum.filter(with_lesson, &(&1 in @kill_spots)) == [23, 30, 51, 66]
  end

  test "otimizar a rota devolve as 8 lições pros 8 pontos de matança", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    for kill <- @kill_spots do
      wp = Enum.at(tidied.waypoints, kill)
      assert wp.fight_ms, "o ponto de matança #{kill} ficou sem a lição da luta"
      assert wp.combo != [], "o ponto de matança #{kill} ficou sem combo"
    end

    for {orphan, _kill} <- @orphan_fights do
      wp = Enum.at(tidied.waypoints, orphan)
      assert wp.fight_ms == nil, "o waypoint #{orphan} continuou com a lição"
      assert wp.combo == []
    end
  end

  test "a lição vai pro ponto de matança CERTO, com o respiro junto", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    # o waypoint 5 mediu 11310ms de luta e 1851ms de respiro; eles pertencem ao 4
    assert Enum.at(tidied.waypoints, 4).fight_ms == 11_310
    assert Enum.at(tidied.waypoints, 4).gather_ms == 1_851
    assert Enum.at(tidied.waypoints, 14).fight_ms == 14_469
    assert Enum.at(tidied.waypoints, 38).fight_ms == 12_213
    assert Enum.at(tidied.waypoints, 57).fight_ms == 8_528
  end

  # A aura que ele aperta ANDANDO não é lição de luta e não pode ser recolhida
  # pro ponto de matança — é o sinal inteiro que esta feature existe pra ler.
  test "o combo apertado andando fica onde está", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    for corner <- @aura_corners do
      wp = Enum.at(tidied.waypoints, corner)
      assert wp.combo != [], "a aura do waypoint #{corner} foi movida"
      assert wp.fight_ms == nil
    end
  end

  test "otimizar não move nenhum canto de lugar", %{route: route} do
    {tidied, _note} = Recording.tidy(route)

    assert Enum.map(tidied.waypoints, &{&1.x, &1.y, &1.z}) ==
             Enum.map(route.waypoints, &{&1.x, &1.y, &1.z})
  end

  # Rodar duas vezes não pode continuar mexendo: quem já está no lugar fica.
  test "otimizar é idempotente", %{route: route} do
    {once, _} = Recording.tidy(route)
    {twice, _} = Recording.tidy(once)

    assert twice.waypoints == once.waypoints
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/meganium_route_test.exs
```

Esperado: o primeiro teste PASSA (é o diagnóstico do estado atual) e o segundo
FALHA com "o ponto de matança 4 ficou sem a lição da luta".

- [ ] **Step 3: Write `lesson_index/3`**

Em `lib/pokex/bots/cavebot/recording.ex`, depois de `mark_gathering_start/3`:

```elixir
  @doc """
  Em qual waypoint a lição desta luta deve ser escrita.

  Medido na rota Meganium 1 (2026-08-12): quatro das oito lutas fecharam um ou
  dois tiles DEPOIS do "até aqui" — ele mata, dá um passo, e só então aperta o
  shift+3 que fecha a luta. O `fight_ms`, o `gather_ms` e o combo caíam no tile
  onde ele estava, e a caçada lê essas três coisas só no ponto de matança: 4 das
  8 lições eram invisíveis.

  A resposta é a mesma régua que o clique do meio e o shift+1 já usam pra
  decidir "isso é a mesma luta" — 6 tiles e 10 segundos. Sem ponto de matança
  por perto, a lição fica onde está.
  """
  @spec lesson_index(Route.t(), non_neg_integer, keyword) :: non_neg_integer
  def lesson_index(%Route{} = route, index, opts \\ []) do
    same_fight_spot(route, index, opts) || index
  end
```

- [ ] **Step 4: Move the orphan lessons in `tidy/1`**

Ainda em `recording.ex`, `tidy/1` (linha ~130) ganha um passo:

```elixir
  @spec tidy(Route.t()) :: {Route.t(), String.t()}
  def tidy(%Route{} = route) do
    {merged, merges} = merge_kill_spots(route)
    {cleaned, note} = pair_marks(merged)
    {moved, moves} = move_lessons(cleaned)
    {moved, merge_note(merges) <> move_note(moves) <> note}
  end
```

E as funções novas, junto das outras privadas:

```elixir
  # A lição de uma luta que fechou fora do ponto de matança volta pra ele.
  #
  # O marcador de "isto é lição de luta" é o `fight_ms`: um combo SEM luta é a
  # aura que ele aperta andando no meio da mobada (waypoints 2, 10, 23 e 36 da
  # Meganium 1, todos com a tecla 2 e nenhum com luta), e recolher isso pro
  # ponto de matança apagaria justamente o que ele quer ver.
  defp move_lessons(%Route{} = route) do
    kills = kill_spots(route)

    route.waypoints
    |> Enum.with_index()
    |> Enum.filter(fn {wp, index} -> wp[:fight_ms] != nil and index not in kills end)
    |> Enum.reduce({route, 0}, fn {_wp, index}, {acc, moved} ->
      case same_fight_spot(acc, index, []) do
        nil -> {acc, moved}
        target -> {move_lesson(acc, index, target), moved + 1}
      end
    end)
  end

  # O destino fica com o que ele não tinha; o que ele já tinha é dele. Combos
  # se somam na ordem da rota, porque as duas metades são a mesma luta.
  defp move_lesson(%Route{waypoints: waypoints} = route, from, to) do
    orphan = Enum.at(waypoints, from)
    target = Enum.at(waypoints, to)

    kept = [
      fight_ms: target[:fight_ms] || orphan[:fight_ms],
      gather_ms: target[:gather_ms] || orphan[:gather_ms],
      combo: (target[:combo] || []) ++ (orphan[:combo] || [])
    ]

    route
    |> Route.set_timing(to, kept)
    |> clear_lesson(from)
  end

  # `set_timing/3` só escreve inteiro, de propósito (put_timing/3): apagar é
  # outra operação, e é esta.
  defp clear_lesson(%Route{waypoints: waypoints} = route, index) do
    wp = waypoints |> Enum.at(index) |> Map.merge(%{fight_ms: nil, gather_ms: nil, combo: []})
    %{route | waypoints: List.replace_at(waypoints, index, wp)}
  end

  defp move_note(0), do: ""

  defp move_note(count),
    do: "levei #{count} lição(ões) de luta de volta pro ponto de matança; "
```

- [ ] **Step 5: Write the lesson where it belongs, live**

Em `lib/pokex_web/live/cavebot_live.ex`, `write_timings/3` (linha ~296):

```elixir
  # A lição vai pro ponto de matança desta luta, não pro tile em que ele estava
  # quando o shift+3 fechou: ele mata, dá um passo, e só então fecha — quatro
  # das oito lutas da Meganium 1 caíram um waypoint adiante do "até aqui", onde
  # a caçada não lê. (Recording.lesson_index/3.)
  defp write_timings(socket, index, timings) when is_integer(index) and index >= 0 do
    route = socket.assigns.active_route
    updated = Route.set_timing(route, Recording.lesson_index(route, index), timings)
    :ok = Store.add(updated)
    reload_routes(socket, updated.name)
  end
```

Faça o mesmo em `flush_combo/1` (linha ~286), que lê o combo existente — ele
tem que ler do MESMO waypoint em que vai escrever:

```elixir
  defp flush_combo(%{assigns: %{pending_index: index, pending_combo: combo}} = socket) do
    route = socket.assigns.active_route
    existing = Enum.at(route.waypoints, Recording.lesson_index(route, index))[:combo] || []

    socket
    |> write_timings(index, combo: existing ++ combo)
    |> assign(pending_combo: [], pending_index: nil)
  end
```

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex/bots/cavebot/ test/pokex_web/live/cavebot_live_test.exs
```

Esperado: PASS, incluindo os seis testes da Meganium.

- [ ] **Step 7: Commit**

```bash
git add lib/pokex/bots/cavebot/recording.ex lib/pokex_web/live/cavebot_live.ex test/pokex/bots/cavebot/meganium_route_test.exs test/support/fixtures/rota_meganium.json
git commit -m "fix: a lição da luta vai pro ponto de matança, não pro tile seguinte"
```

---

### Task 8: o editor na `/cavebot`

**Files:**
- Modify: `lib/pokex_web/live/cavebot_live.ex` (handlers novos + a linha do waypoint + o cabeçalho da rota)
- Test: `test/pokex_web/live/cavebot_live_test.exs`

**Interfaces:**
- Consumes: `Route.skills/0`, `Route.set_skill/4`, `Route.skills_at/2`,
  `Route.set_gather_wait/2`, `Route.set_gather_wait/3`,
  `SkillProfile.icon/1`, `SkillProfile.label/1`

- [ ] **Step 1: Write the failing test**

Em `test/pokex_web/live/cavebot_live_test.exs`, no fim, um bloco novo. Ele monta
a própria rota no `setup` em vez de depender da do arquivo, pra não quebrar se
aquela mudar de forma:

```elixir
  describe "skills e respiro no editor" do
    # `put/1` e não `add/1`: esta rota tem que ser a ÚNICA, senão qual delas a
    # página abre como ativa vira sorte, e `[route] = Store.all()` nas
    # asserções vira flake. O waypoint 0 é ponto de matança porque é onde o
    # campo do respiro aparece.
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {10, 10, 5})
      {:ok, route} = Route.append(route, {12, 10, 5})
      :ok = Store.put([Route.set_action(route, 0, :lure_end)])
      :ok
    end

    test "clicar no chip liga a categoria no waypoint", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view
      |> element("#waypoint-skill-0-buffs")
      |> render_click()

      [route] = Store.all()
      assert Route.skills_at(route.waypoints, 0) == [:buffs]
    end

    test "clicar de novo desliga", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> element("#waypoint-skill-0-buffs") |> render_click()
      view |> element("#waypoint-skill-0-buffs") |> render_click()

      [route] = Store.all()
      assert Route.skills_at(route.waypoints, 0) == []
    end

    test "a régua da rota é salva", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view
      |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"})
      |> render_submit()

      [route] = Store.all()
      assert route.gather_wait_ms == 1_800
    end

    test "campo vazio devolve o comando pro número global", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"}) |> render_submit()
      view |> form("#route-gather-wait", %{"gather_wait_ms" => ""}) |> render_submit()

      [route] = Store.all()
      assert route.gather_wait_ms == nil
    end

    test "o respiro do waypoint é salvo e ganha da rota", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      view |> form("#route-gather-wait", %{"gather_wait_ms" => "1800"}) |> render_submit()

      view
      |> form("#waypoint-gather-wait-0", %{"gather_wait_ms" => "600"})
      |> render_submit()

      [route] = Store.all()
      assert Route.gather_wait(route, hd(route.waypoints), 4_000) == 600
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex_web/live/cavebot_live_test.exs
```

Esperado: FAIL — elemento `#waypoint-skill-0-buffs` não existe.

- [ ] **Step 3: Add the handlers**

Em `lib/pokex_web/live/cavebot_live.ex`, junto de `toggle_waypoint_stop`
(linha ~588):

```elixir
  # A skill que ELE quer neste canto, dita por categoria — a aura no meio da
  # mobada é o caso que ele pediu. Terceiro eixo, ao lado da função e das
  # paradas: o canto da aura costuma ser o canto do "até aqui".
  def handle_event("toggle_waypoint_skill", %{"index" => index, "skill" => skill}, socket) do
    index = String.to_integer(index)
    skill = decode_skill(skill)
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      on? = skill not in Route.skills_at(route.waypoints, index)

      {Route.set_skill(route, index, skill, on?),
       "waypoint #{index + 1}: #{SkillProfile.label(skill)} #{if on?, do: "ligada", else: "desligada"}"}
    end)
  end

  # A régua da rota inteira: o número que ele dial pra baixo até achar o limite
  # onde o bolo ainda fecha. Campo vazio devolve o comando pro /config.
  def handle_event("set_route_gather_wait", %{"gather_wait_ms" => raw}, socket) do
    with_route(socket, fn route ->
      {Route.set_gather_wait(route, parse_ms(raw)), gather_wait_note("a rota", parse_ms(raw))}
    end)
  end

  def handle_event("set_waypoint_gather_wait", %{"index" => index} = params, socket) do
    index = String.to_integer(index)
    ms = parse_ms(params["gather_wait_ms"])
    socket = remember_hand_mark(socket, index)

    with_route(socket, fn route ->
      {Route.set_gather_wait(route, index, ms), gather_wait_note("o waypoint #{index + 1}", ms)}
    end)
  end
```

E os auxiliares privados, junto de `decode_stop/1`:

```elixir
  # Whitelist, nunca String.to_atom/1: o valor vem do DOM.
  defp decode_skill(value), do: Enum.find(Route.skills(), &(Atom.to_string(&1) == value))

  # Campo vazio é "não tenho régua aqui", que é diferente de zero ("não espera
  # nada aqui"). Lixo digitado também vira nil, nunca crash.
  defp parse_ms(raw) when is_binary(raw) do
    case Integer.parse(String.trim(raw)) do
      {ms, ""} when ms >= 0 -> ms
      _empty_or_junk -> nil
    end
  end

  defp parse_ms(_absent), do: nil

  defp gather_wait_note(what, nil), do: "#{what} voltou a usar o respiro do /config"
  defp gather_wait_note(what, ms), do: "#{what} espera #{ms}ms o bolo fechar"

  # A medição das mãos dele, oferecida como ponto de partida — e só quando é
  # plausível. As duas settings que antes limitavam a Logic vivem aqui agora:
  # 12s medidos num ponto de matança não são ele esperando o bolo, são o
  # gravador tendo cronometrado outra coisa.
  defp gather_suggestion(%{gather_ms: ms}) when is_integer(ms) do
    if ms >= Settings.get(:cavebot_gather_wait_min_ms) and
         ms <= Settings.get(:cavebot_gather_wait_max_ms),
       do: ms
  end

  defp gather_suggestion(_no_measurement), do: nil
```

- [ ] **Step 4: Add the chips and the fields to the waypoint row**

Em `lib/pokex_web/live/cavebot_live.ex`, dentro do `<li>` de cada waypoint,
logo DEPOIS do parágrafo `waypoint-taught-#{index}` (linha ~2090):

```heex
                  <%!-- O terceiro eixo: o que o pokémon FAZ aqui, por
                        categoria. Chip ligado é ordem; a tecla sai do pokémon
                        que estiver em campo na hora. --%>
                  <div class="mt-1 flex flex-wrap items-center gap-1 pl-7">
                    <button
                      :for={skill <- Route.skills()}
                      id={"waypoint-skill-#{index}-#{skill}"}
                      phx-click="toggle_waypoint_skill"
                      phx-value-index={index}
                      phx-value-skill={skill}
                      aria-pressed={to_string(skill in Route.skills_at(@active_route.waypoints, index))}
                      title={SkillProfile.label(skill)}
                      class={[
                        "cursor-pointer rounded border px-1.5 py-0.5 text-pk-meta transition",
                        if(skill in Route.skills_at(@active_route.waypoints, index),
                          do: "border-pk-ok-line bg-pk-ok-dim text-pk-ok",
                          else: "border-pk-line text-pk-text-3 hover:border-pk-line-strong"
                        )
                      ]}
                    >
                      {SkillProfile.icon(skill)} {SkillProfile.label(skill)}
                    </button>

                    <%!-- O respiro só faz sentido onde o bolo fecha. --%>
                    <.form
                      :if={wp.action == :lure_end}
                      id={"waypoint-gather-wait-#{index}"}
                      for={%{}}
                      phx-submit="set_waypoint_gather_wait"
                      class="ml-2 flex items-center gap-1"
                    >
                      <input type="hidden" name="index" value={index} />
                      <label for={"gather-wait-input-#{index}"} class="text-pk-meta text-pk-text-3">
                        respiro
                      </label>
                      <input
                        type="number"
                        id={"gather-wait-input-#{index}"}
                        name="gather_wait_ms"
                        value={wp[:gather_wait_ms]}
                        min="0"
                        step="100"
                        placeholder={@active_route.gather_wait_ms || Settings.get(:cavebot_gather_wait_ms)}
                        class="pk-num w-20 rounded border border-pk-line bg-pk-sunken px-1 py-0.5 text-pk-meta"
                      />
                      <span class="text-pk-meta text-pk-text-3">ms</span>
                      <span :if={gather_suggestion(wp)} class="text-pk-meta text-pk-text-3">
                        (suas mãos esperaram {gather_suggestion(wp)}ms aqui)
                      </span>
                    </.form>
                  </div>
```

- [ ] **Step 5: Add the route ruler to the header**

Ainda em `cavebot_live.ex`, na barra de ações da seção "Waypoints" — o
`<div class="flex items-center gap-3">` da linha ~1944, imediatamente ANTES do
botão `#tidy-marks` ("otimizar rota"):

```heex
              <.form
                id="route-gather-wait"
                for={%{}}
                phx-submit="set_route_gather_wait"
                class="flex items-center gap-1"
              >
                <label for="route-gather-wait-input" class="text-pk-meta text-pk-text-3">
                  respiro da rota
                </label>
                <input
                  type="number"
                  id="route-gather-wait-input"
                  name="gather_wait_ms"
                  value={@active_route.gather_wait_ms}
                  min="0"
                  step="100"
                  placeholder={Settings.get(:cavebot_gather_wait_ms)}
                  class="pk-num w-24 rounded border border-pk-line bg-pk-sunken px-1.5 py-0.5 text-pk-meta"
                />
                <span class="text-pk-meta text-pk-text-3">ms</span>
              </.form>
```

Confira que `alias Pokex.Pokedex.SkillProfile` e `alias Pokex.Settings` estão no
topo do módulo; acrescente o que faltar.

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test test/pokex_web/live/cavebot_live_test.exs
```

Esperado: PASS.

- [ ] **Step 7: Full suite, lint and types**

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix test
```

Esperado: 0 failures. `Combat.WorkerTest:138` é flaky conhecido e falha ~metade
das vezes **na main também** (medido em 2026-08-12) — se só ele falhar, rode de
novo e anote no relatório; não conserte aqui.

```bash
cd /Users/tavano/projects/pokex-claude-skills && mix credo && mix dialyzer
```

Esperado: os dois zerados, sem ignorar nada.

- [ ] **Step 8: Commit**

```bash
git add lib/pokex_web/live/cavebot_live.ex test/pokex_web/live/cavebot_live_test.exs
git commit -m "feat: os chips das skills e as duas réguas do respiro na /cavebot"
```

---

## Verificação final (o controller faz, não um subagente)

- [ ] `grep -rn "Rig\." lib/pokex/bots/cavebot/` continua vazio.
- [ ] `mix test` verde (fora o flaky conhecido do Combat.WorkerTest:138).
- [ ] `mix credo` e `mix dialyzer` zerados.
- [ ] A Meganium 1 real dele, depois de "otimizar rota", tem as 8 lições nos 8
      pontos de matança e as 4 auras andando intactas.
