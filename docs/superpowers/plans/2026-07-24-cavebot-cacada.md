# Cavebot — caçada automática (estilo constante) + seleção de personagem — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Um worker novo (`Cavebot`) que percorre uma rota de waypoints gravada andando, deixa o combate existente matar um-a-um (estilo **constante**), e um seletor de **personagem** no topo do painel que troca o time e as marcações da Pokédex — mais o gate de combo por dungeon. O estilo **mobado** fica esboçado para uma entrega posterior.

**Architecture:** O cavebot é um GenServer *peer* (molde `Combos.Runner`) que atua SÓ pelo `Pokex.Bots.Body`, confirma movimento relendo o fato `:minimap`, e dirige o `Combat.Worker` existente por `run/1`/`halt/1` — sem NUNCA modificá-lo. Toda decisão vive numa `Cavebot.Logic` PURA, testável sem tela nem processo. Um novo modo "Caçada" em `Pokex.Modes` sobe o cavebot em vez de rodar o combate direto.

**Tech Stack:** Elixir, Phoenix LiveView, ExUnit. Persistência JSON sob `Pokex.Home.dir()`. Blackboard `Pokex.Perception.WorldState` (ETS) + feeds demand-driven. daisyUI + tokens `pk-*`.

## Global Constraints

Copiadas verbatim do spec (`docs/superpowers/specs/2026-07-24-cavebot-cacada-design.md`). Toda tarefa herda isto:

- Toda tecla/clique passa pelo `Pokex.Bots.Body` (`minimap_step/3` e `perform/3`), atrás de `InputGate` + `Focus` guard + `mini_game_gate`. O cavebot NÃO tem caminho de atuação que fale direto com o Rig.
- O `Combat.Worker` NÃO é modificado. O cavebot é peer: escuta broadcasts e dirige o combate só por `run/1`/`halt/1`.
- Movimento só é concluído quando `x`, `y` ou `z` muda de verdade — reler o fato `:minimap`. Nunca inferir "andei" do retorno do `perform` (ação barrada retorna `:ok` como no-op).
- Settings: uma fonte da verdade, `@seed_settings` em `lib/pokex/settings.ex`. Sem defaults espalhados.
- Testes NUNCA tocam a rede nem capturam a tela real; nenhum servidor sobe. Padrão de worker sempre-ligado com flag `:*_active` false em teste.
- Toda ação: pré-condição, comando, confirmação visual, timeout, recuperação.
- Worktree compartilhado: nunca `git add -A`/`git add .`, nunca `--amend`; re-checar `git rev-parse HEAD` e a branch antes de cada commit; commitar só arquivos da própria tarefa. Commits terminam com `Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>`.
- Nomes/UI em português; código em inglês.

## File Structure

**Fase 0 — Personagem (independente; pode ser executada e mergeada sozinha):**
- Create `lib/pokex/characters.ex` — enumerar/criar/renomear/deletar personagens sob `chars_dir()`; ler/gravar `active_character`.
- Modify `lib/pokex/pokedex/team.ex` — `file/0` roteia legado ↔ `chars/<slug>/team.json`.
- Modify `lib/pokex/settings.ex` — `active_character: ""` no `@seed_settings`.
- Modify `lib/pokex_web/live/panel_live.ex` — seletor de personagem no header.
- Tests: `test/pokex/characters_test.exs`, adições em `test/pokex/pokedex/team_test.exs`, `test/pokex_web/live/panel_live_test.exs`.

**Fases 1–6 — Cavebot constante:**
- Create `lib/pokex/bots/cavebot/route.ex` — `%Route{}` + validação single-floor.
- Create `lib/pokex/bots/cavebot/store.ex` — `routes.json` (molde `Combos.Store`).
- Create `lib/pokex/bots/cavebot/logic.ex` — a máquina de estados PURA (constante).
- Create `lib/pokex/bots/cavebot/worker.ex` — o GenServer peer.
- Modify `lib/pokex/perception.ex` — accessor `minimap/1`.
- Modify `lib/pokex/settings.ex` — chaves `cavebot_*`, `hunt_style`, teclas de postura.
- Modify `lib/pokex/modes.ex` — bundle "caçada".
- Modify `lib/pokex/bots/bot_supervisor.ex` — child + `@run_order` + `run_worker`/`halt_worker`.
- Modify `lib/pokex/bots/focus.ex` — cavebot em `default_running?`.
- Modify `lib/pokex/combos.ex` + `lib/pokex/combos/store.ex` + `lib/pokex/combos/runner.ex` — gate por dungeon.
- Modify `lib/pokex/application.ex` — cavebot no supervisor de app (idle).
- Create `lib/pokex_web/live/cavebot_live.ex` + rota em `router.ex` — gravar/editar rota.
- Tests: um `test/…` por módulo novo.

**Fase 7 — Mobada (esboço, não implementar agora):** estende `Cavebot.Logic` com `:gathering`/`:nuking`/`:cleanup`.

---

## Fase 0 — Seleção de personagem

### Task 0.1: Setting `active_character` + `Pokex.Characters`

**Files:**
- Modify: `lib/pokex/settings.ex` (adicionar `active_character: ""` ao `@seed_settings`)
- Create: `lib/pokex/characters.ex`
- Test: `test/pokex/characters_test.exs`

**Interfaces:**
- Consumes: `Pokex.Home.dir/0`; `Pokex.Settings.get/2`, `Pokex.Settings.put/3`.
- Produces:
  - `Pokex.Characters.chars_dir() :: String.t()` — `Path.join(Home.dir(), "chars")`
  - `Pokex.Characters.slugify(name) :: {:ok, slug} | {:error, :invalid_name}` — downcase, só `[a-z0-9-]`, não vazio
  - `Pokex.Characters.list() :: [%{slug: String.t(), name: String.t()}]` — subpastas de `chars_dir()`, ordenadas
  - `Pokex.Characters.create(name) :: {:ok, slug} | {:error, reason}` — cria `chars/<slug>/` com um `name.txt` guardando o nome original
  - `Pokex.Characters.rename(slug, new_name) :: {:ok, new_slug} | {:error, reason}`
  - `Pokex.Characters.delete(slug) :: :ok`
  - `Pokex.Characters.active() :: String.t()` — `Settings.get(:active_character)` (`""` = sem personagem)
  - `Pokex.Characters.set_active(slug) :: :ok` — `Settings.put(:active_character, slug)`

- [ ] **Step 1: Failing test — round-trip e slug**

```elixir
# test/pokex/characters_test.exs
defmodule Pokex.CharactersTest do
  use ExUnit.Case, async: false
  alias Pokex.{Characters, Settings}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    {:ok, s} = Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    %{settings: s}
  end

  @moduletag :tmp_dir

  test "slugify normaliza e recusa vazio" do
    assert Characters.slugify("Meu Char 2") == {:ok, "meu-char-2"}
    assert Characters.slugify("  ") == {:error, :invalid_name}
  end

  test "create/list/delete round-trip" do
    assert {:ok, "lowbie"} = Characters.create("Lowbie")
    assert Enum.any?(Characters.list(), &(&1.slug == "lowbie" and &1.name == "Lowbie"))
    assert :ok = Characters.delete("lowbie")
    refute Enum.any?(Characters.list(), &(&1.slug == "lowbie"))
  end

  test "active lê e escreve o setting, default vazio", %{settings: s} do
    assert Characters.active(s) == ""
    :ok = Characters.set_active("lowbie", s)
    assert Characters.active(s) == "lowbie"
  end
end
```

- [ ] **Step 2: Run — verify fail** `mix test test/pokex/characters_test.exs` → FAIL (module undefined).
- [ ] **Step 3: Add setting** — em `lib/pokex/settings.ex`, dentro do `@seed_settings`, adicionar a linha `active_character: "",` (perto das outras chaves de topo). `put/3` já rejeita `nil` e dropa valor == seed, então `""` funciona como default.
- [ ] **Step 4: Implement `Pokex.Characters`** — `chars_dir/0`, `slugify/1` (regex `~r/[^a-z0-9]+/` → `-`, trim `-`, vazio → erro), `list/0` via `File.ls(chars_dir())` lendo `name.txt` (fallback: slug), `create/1` (`File.mkdir_p!` + grava `name.txt`), `rename/2`, `delete/1` (`File.rm_rf!`), `active/1` e `set_active/2` com `server \\ Settings`. Espelhe o estilo de `Calibration.list_profiles` (`lib/pokex/calibration.ex:187`).
- [ ] **Step 5: Run** → PASS.
- [ ] **Step 6: Commit**

```bash
git add lib/pokex/characters.ex lib/pokex/settings.ex test/pokex/characters_test.exs
git commit -m "personagem: Pokex.Characters (list/create/delete) + setting active_character"
```

### Task 0.2: `Team.file/0` roteia por personagem

**Files:**
- Modify: `lib/pokex/pokedex/team.ex:228` (`defp file`) e os call sites internos
- Test: `test/pokex/pokedex/team_test.exs` (adicionar casos)

**Interfaces:**
- Consumes: `Pokex.Characters.active/0` (Task 0.1); `Pokex.Home.dir/0`.
- Produces: `Team.file/0` devolve `Home.dir()/team.json` quando `active_character == ""`, senão `Home.dir()/chars/<slug>/team.json`. Comportamento legado (arquivo atual) preservado quando não há personagem.

- [ ] **Step 1: Failing test**

```elixir
# adicionar em test/pokex/pokedex/team_test.exs
test "sem personagem lê o team.json legado; com personagem lê chars/<slug>", %{tmp_dir: tmp} do
  Application.put_env(:pokex, :home_dir, tmp)
  {:ok, s} = Pokex.Settings.start_link(name: nil, path: Path.join(tmp, "settings.json"))
  on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

  # legado
  Pokex.Settings.put(:active_character, "", s)
  # NOTE: Team lê Settings global; este teste roda com o Settings de app.
  # Ver Task 0.1 sobre reset em on_exit.
  assert Team.file() == Path.join(tmp, "team.json")

  Pokex.Settings.put(:active_character, "lowbie", s)
  assert Team.file() == Path.join([tmp, "chars", "lowbie", "team.json"])
end
```

- [ ] **Step 2: Run** → FAIL (`file/0` é privada e não roteia).
- [ ] **Step 3: Implement** — tornar `file/0` pública (`def file`), e:

```elixir
def file do
  case Pokex.Characters.active() do
    "" -> Path.join(Home.dir(), "team.json")
    slug -> Path.join([Home.dir(), "chars", slug, "team.json"])
  end
end
```

Manter todos os call sites internos usando `file()`. Em `persist/1`, trocar `File.mkdir_p!(Home.dir())` por `File.mkdir_p!(Path.dirname(file()))` para criar a pasta do personagem.

- [ ] **Step 4: Run** → PASS. Rodar TAMBÉM `mix test test/pokex/pokedex/` inteiro (garante que os testes existentes, que usam o caminho legado, seguem verdes — o default `""` preserva o comportamento).
- [ ] **Step 5: Guard de reset (obrigatório)** — auditar `team_test.exs`, `team_live_test.exs`, `pokedex_detail_live_test.exs`: qualquer teste que faça `Settings.put(:active_character, ...)` DEVE resetar em `on_exit(fn -> Settings.put(:active_character, "") end)`. Isto evita o sangramento cross-teste via ETS que o projeto já sofreu (`settings.ex:585` documenta o incidente do nil).
- [ ] **Step 6: Commit**

```bash
git add lib/pokex/pokedex/team.ex test/pokex/pokedex/team_test.exs
git commit -m "personagem: Team.file/0 roteia legado ou chars/<slug>/team.json"
```

### Task 0.3: Seletor de personagem no header do painel

**Files:**
- Modify: `lib/pokex_web/live/panel_live.ex` (header, ~linha 1541; mount; um handle_event)
- Test: `test/pokex_web/live/panel_live_test.exs`

**Interfaces:**
- Consumes: `Pokex.Characters.list/0`, `active/0`, `set_active/1`, `create/1` (Task 0.1).
- Produces: header com um `<select id="character-picker">` listando personagens + "sem personagem", e um botão "novo personagem". Trocar publica nada no bot — só muda qual `team.json` a UI de time/Pokédex lê.

- [ ] **Step 1: Failing test**

```elixir
test "o seletor de personagem troca o active_character", %{conn: conn} do
  Pokex.SettingsStash.stash_keys!([:active_character])
  {:ok, view, _} = live(conn, ~p"/")
  assert has_element?(view, "#character-picker")
  view |> element("#character-picker") |> render_change(%{"character" => ""})
  assert Pokex.Settings.get(:active_character) == ""
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — no `mount`, assign `characters: Characters.list()` e `active_character: Characters.active()`. No header (perto do logo, `panel_live.ex:1541`), um `<form phx-change="set_character">` com `<select id="character-picker" name="character">` (option `""` = "sem personagem", uma option por char). Handler:

```elixir
def handle_event("set_character", %{"character" => slug}, socket) do
  :ok = Pokex.Characters.set_active(slug)
  {:noreply, assign(socket, active_character: slug)}
end
```

Estilo com tokens `pk-*`; `aria-label="Personagem ativo"`. (Botão "novo personagem" pode ser um `<details>` com um form `phx-submit="create_character"` chamando `Characters.create/1` — incluir no mesmo commit.)

- [ ] **Step 4: Run** → PASS. Rodar `mix test test/pokex_web/live/panel_live_test.exs`.
- [ ] **Step 5: Commit**

```bash
git add lib/pokex_web/live/panel_live.ex test/pokex_web/live/panel_live_test.exs
git commit -m "personagem: seletor no header troca time e marcações da Pokédex"
```

---

## Fase 1 — Route store + Settings do cavebot

### Task 1.1: `Cavebot.Route` (struct + validação single-floor)

**Files:**
- Create: `lib/pokex/bots/cavebot/route.ex`
- Test: `test/pokex/bots/cavebot/route_test.exs`

**Interfaces:**
- Produces:
  - `%Pokex.Bots.Cavebot.Route{name: String.t(), dungeon: String.t() | nil, z: integer | nil, enabled?: boolean, waypoints: [%{x: integer, y: integer, z: integer}]}`
  - `Route.new(name, dungeon \\ nil) :: %Route{}` — waypoints `[]`, `z` nil, `enabled? true`
  - `Route.append(route, {x, y, z}) :: {:ok, route} | {:error, :floor_mismatch}` — fixa `z` no 1º waypoint; recusa waypoint com `z` diferente
  - `Route.validate(route) :: :ok | {:error, reason}` — `:empty` se sem waypoints; `:floor_mismatch` se algum `z` difere

- [ ] **Step 1: Failing test**

```elixir
# test/pokex/bots/cavebot/route_test.exs
defmodule Pokex.Bots.Cavebot.RouteTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.Route

  test "append fixa o andar e recusa z divergente" do
    r = Route.new("cavena", "cavena-dg")
    assert {:ok, r} = Route.append(r, {100, 200, 7})
    assert r.z == 7
    assert {:ok, r} = Route.append(r, {101, 200, 7})
    assert length(r.waypoints) == 2
    assert {:error, :floor_mismatch} = Route.append(r, {101, 201, 6})
  end

  test "validate exige waypoints e andar único" do
    assert {:error, :empty} = Route.validate(Route.new("x"))
    {:ok, r} = Route.append(Route.new("x"), {1, 1, 3})
    assert Route.validate(r) == :ok
  end
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — `defstruct` com defaults; `append/2` fixando `z` no primeiro e comparando nos demais; `validate/1`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/cavebot/route.ex test/pokex/bots/cavebot/route_test.exs
git commit -m "cavebot: Route struct com invariante single-floor"
```

### Task 1.2: `Cavebot.Store` (routes.json) + chaves de Settings

**Files:**
- Create: `lib/pokex/bots/cavebot/store.ex`
- Modify: `lib/pokex/settings.ex` (chaves `cavebot_*`, `hunt_style`, teclas de postura)
- Test: `test/pokex/bots/cavebot/store_test.exs`

**Interfaces:**
- Consumes: `Pokex.Home.dir/0`; `Pokex.Bots.Cavebot.Route` (Task 1.1).
- Produces (espelha `Combos.Store`, `lib/pokex/combos/store.ex`):
  - `Store.all() :: [%Route{}]` — lê `~/.pokex/routes.json`; arquivo ausente/corrupto → `[]`
  - `Store.add(%Route{}) :: :ok | {:error, :invalid_name}` — substitui por nome
  - `Store.put([%Route{}]) :: :ok`
  - `Store.delete(name) :: :ok`
  - `Store.set_enabled(name, bool) :: :ok`

**Settings novas** (adicionar ao `@seed_settings` verbatim):
```
hunt_style: "constante",
defense_mode_key: "shift+3",
attack_mode_key: "shift+1",
cavebot_arrival_tolerance_tiles: 1,
cavebot_walk_timeout_ms: 3000,
cavebot_minimap_fact_max_age_ms: 800,
cavebot_stuck_max_retries: 4,
cavebot_group_min_enemies: 3,
cavebot_group_max_wait_ms: 4000,
cavebot_stance_settle_ms: 400,
cavebot_post_kill_dwell_ms: 1200,
cavebot_clear_debounce_ms: 800,
cavebot_fight_timeout_ms: 20000,
cavebot_combo_timeout_ms: 6000,
cavebot_cleanup_timeout_ms: 8000,
```

- [ ] **Step 1: Failing test**

```elixir
# test/pokex/bots/cavebot/store_test.exs
defmodule Pokex.Bots.Cavebot.StoreTest do
  use ExUnit.Case, async: false
  alias Pokex.Bots.Cavebot.{Route, Store}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  @moduletag :tmp_dir

  test "round-trip de rota com waypoints" do
    {:ok, r} = Route.append(Route.new("cavena", "cavena-dg"), {10, 20, 7})
    assert :ok = Store.add(r)
    [got] = Store.all()
    assert got.name == "cavena"
    assert got.dungeon == "cavena-dg"
    assert got.waypoints == [%{x: 10, y: 20, z: 7}]
  end

  test "arquivo corrompido vira lista vazia, não derruba" do
    File.write!(Path.join(tmp, "routes.json"), "{ not json")
    assert Store.all() == []
  end
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — copiar a forma de `Combos.Store` (encode/decode JSON tolerante, `rescue → []`, `add` rejeita nome vazio e substitui por nome, `path/0` sob `Home.dir()`). Waypoints como lista de mapas `%{"x"=>.., "y"=>.., "z"=>..}`. Adicionar as chaves de Settings.
- [ ] **Step 4: Run** → PASS. Rodar `mix test test/pokex/settings_test.exs` (garante que o seed cresceu sem quebrar).
- [ ] **Step 5: Commit**

```bash
git add lib/pokex/bots/cavebot/store.ex lib/pokex/settings.ex test/pokex/bots/cavebot/store_test.exs
git commit -m "cavebot: Store routes.json + chaves cavebot_* e hunt_style"
```

---

## Fase 2 — `Cavebot.Logic` pura (o coração, estilo constante)

### Task 2.1: Accessor `Perception.minimap/1`

**Files:**
- Modify: `lib/pokex/perception.ex` (novo `minimap/1`, molde do `pokemon/1`, `perception.ex:71`)
- Test: `test/pokex/perception_test.exs` (ou o arquivo de teste do módulo)

**Interfaces:**
- Consumes: `WorldState.get/3`; `Settings.get(:cavebot_minimap_fact_max_age_ms)`.
- Produces: `Perception.minimap(now_ms \\ System.monotonic_time(:millisecond)) :: {:ok, %{pos: {x,y,z}}} | :unknown` — fail-open (stale/missing → `:unknown`).

- [ ] **Step 1: Failing test** — injeta o fato `:minimap` no WorldState e afirma `{:ok, %{pos: {337,46107,4}}}`; sem fato → `:unknown`.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — copiar o corpo de `pokemon/1` trocando a chave para `:minimap` e o max-age para `:cavebot_minimap_fact_max_age_ms`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "perception: accessor minimap/1 com staleness fail-open"`

### Task 2.2: `Cavebot.Logic` — máquina de estados constante

**Files:**
- Create: `lib/pokex/bots/cavebot/logic.ex`
- Test: `test/pokex/bots/cavebot/logic_test.exs`

**Interfaces:**
- Consumes: `Pokex.Bots.Cavebot.Route` (Task 1.1); nomes das Settings (Task 1.2) — mas a Logic NÃO lê Settings; recebe uma `config` (mapa) por parâmetro (mantém pureza total).
- Produces:
  - `%Logic{state, route, wp_index, combat_running?, since, retries}` — estado interno
  - `Logic.new(route, config) :: %Logic{}` — `state: :walking`, `wp_index: 0`, `combat_running?: false`
  - `Logic.step(logic, world, now) :: {logic, action}` onde:
    - `world :: %{pos: {x,y,z} | nil, enemies: non_neg_integer, combat_state: atom}`
    - `action ::` um de: `:none` | `{:walk, dx, dy}` | `:run_combat` | `:halt_combat` | `{:nudge, dx, dy}` | `{:block, reason}`
    - `config :: %{arrival_tolerance, walk_timeout_ms, stuck_max_retries, clear_debounce_ms, fight_timeout_ms, post_kill_dwell_ms}`

**Vocabulário de ação (fixo — o Worker na Task 3 depende disto exatamente):** `:none`, `{:walk, dx, dy}`, `:run_combat`, `:halt_combat`, `{:nudge, dx, dy}`, `{:block, reason}`.

**Transições da constante** (o Combat roda o tempo todo; a Logic liga no arranque e só desliga em `:blocked`):
- `:walking` + `world.enemies > 0` → estado `:fighting`, action `:none` (o Combat já está lutando)
- `:walking` + posição chegou no waypoint (dentro de `arrival_tolerance`) → avança `wp_index` (wrap no fim), action `:none`
- `:walking` + posição NÃO chegou → action `{:walk, dx, dy}` com `dx = wp.x - pos.x`, `dy = wp.y - pos.y`
- `:walking` + `pos == nil` (leitura desconhecida) → action `:none` (segura; nunca anda às cegas)
- `:walking` + sem progresso por `walk_timeout_ms` → `:stuck`
- `:stuck` → re-emite `{:walk, dx, dy}`; após `stuck_max_retries` → `{:block, :stuck}`
- `:fighting` + `enemies == 0` sustentado por `clear_debounce_ms` → `:post_fight`
- `:fighting` + `fight_timeout_ms` → `:fight_stalled`
- `:fight_stalled` → `{:nudge, dx, dy}` (um tile em direção; primeiro corte pode nudge=0,0 e ir direto a `:block` após retries) → após retries `{:block, :fight_stalled}`
- `:post_fight` + dwell `post_kill_dwell_ms` cumprido → `:walking`
- z mudou (pos.z != route.z) em qualquer estado → `{:block, :floor_changed}`
- No arranque (primeira `step`) com `combat_running? == false` → action `:run_combat`, seta `combat_running? true`

- [ ] **Step 1: Failing test — anda até o waypoint e confirma pela posição**

```elixir
# test/pokex/bots/cavebot/logic_test.exs
defmodule Pokex.Bots.Cavebot.LogicTest do
  use ExUnit.Case, async: true
  alias Pokex.Bots.Cavebot.{Logic, Route}

  @cfg %{arrival_tolerance: 1, walk_timeout_ms: 3000, stuck_max_retries: 4,
         clear_debounce_ms: 800, fight_timeout_ms: 20000, post_kill_dwell_ms: 1200}

  defp route do
    {:ok, r} = Route.append(Route.append(Route.new("r"), {10, 10, 7}) |> elem(1), {20, 10, 7})
    r
  end

  defp world(pos, enemies \\ 0, combat \\ :hunting),
    do: %{pos: pos, enemies: enemies, combat_state: combat}

  test "no arranque liga o combate" do
    l = Logic.new(route(), @cfg)
    assert {l, :run_combat} = Logic.step(l, world({0, 0, 7}), 0)
    assert l.combat_running?
  end

  test "anda em direção ao waypoint e avança quando chega" do
    {l, :run_combat} = Logic.step(Logic.new(route(), @cfg), world({5, 10, 7}), 0)
    assert {l, {:walk, dx, dy}} = Logic.step(l, world({5, 10, 7}), 10)
    assert {dx, dy} == {5, 0}   # 10-5, 10-10
    # chegou no wp 0 (10,10) → avança pro wp 1 (20,10)
    assert {l, _} = Logic.step(l, world({10, 10, 7}), 20)
    assert l.wp_index == 1
  end

  test "inimigo aparece → estado fighting, sem novo comando (o Combat já luta)" do
    {l, _} = Logic.step(Logic.new(route(), @cfg), world({10, 10, 7}, 2), 0)
    assert {l, :none} = Logic.step(l, world({10, 10, 7}, 2), 10)
    assert l.state == :fighting
  end

  test "luta limpa sustentada por debounce volta a andar após o dwell" do
    l = %{Logic.new(route(), @cfg) | state: :fighting, combat_running?: true}
    {l, :none} = Logic.step(l, world({10, 10, 7}, 0), 0)     # clear começa
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900)       # debounce cumprido → post_fight
    assert l.state == :post_fight
    {l, _} = Logic.step(l, world({10, 10, 7}, 0), 900 + 1300) # dwell cumprido → walking
    assert l.state == :walking
  end

  test "z mudou → block" do
    l = Logic.new(route(), @cfg)
    assert {_l, {:block, :floor_changed}} = Logic.step(l, world({10, 10, 6}), 0)
  end
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — máquina pura seguindo a tabela acima. Guardar timers como timestamps em `logic.since` (mapa por-marco: `clear_since`, `walk_progress_since`, `dwell_since`). "Sem progresso" = mesma posição desde `walk_progress_since` por `walk_timeout_ms`. `arrival` = `abs(dx) <= tol and abs(dy) <= tol`. Nenhuma chamada a Settings, tela ou processo.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "cavebot: Logic pura (estilo constante) — anda, confirma posição, delega a luta"`

---

## Fase 3 — `Cavebot.Worker` peer (constante)

### Task 3.1: `Cavebot.Worker`

**Files:**
- Create: `lib/pokex/bots/cavebot/worker.ex`
- Test: `test/pokex/bots/cavebot/worker_test.exs`

**Interfaces:**
- Consumes: `Cavebot.Logic` (Task 2.2), `Cavebot.Store` (Task 1.2), `Perception.minimap/1` (Task 2.1); `Body.minimap_step/3` e `Body.perform/3`; `Combat.Worker.run/1`/`halt/1`/`topic/0`; `Perception.attach/1`; `Settings`.
- Produces (molde `Combos.Runner` + `Combat.Worker`):
  - `Worker.run(server \\ __MODULE__) :: :ok | {:error, [String.t()]}`
  - `Worker.halt(server \\ __MODULE__) :: :ok`
  - `Worker.status(server \\ __MODULE__) :: %{state, wp_index, route, ...}`
  - `Worker.topic() :: "cavebot"`
  - `start_link(opts)` com `:name`, `:body`, `:combat`, `:active` (default `Application.get_env(:pokex, :cavebot_active, true)`)

- [ ] **Step 1: Failing test — o worker dirige a Logic injetando fatos**

```elixir
# test/pokex/bots/cavebot/worker_test.exs — worker isolado, Body fake, Combat fake
# Padrão: name: nil, body: FakeBody, combat: FakeCombat, active: true.
# Injeta o fato :minimap via WorldState.put e afirma que o Body recebeu {:click,...}
# (minimap_step) OU que FakeCombat recebeu :run. Espelha
# test/pokex/combos/runner_test.exs e test/pokex/bots/catcher/worker_test.exs.
```

Detalhar: (a) `run` carrega a rota ativa de `Store`, faz `Perception.attach(:minimap)` + `attach(:battle)` com `Process.monitor(Feed.name(:minimap))`, `Combat.Worker.run(combat)`, agenda o primeiro tick; (b) num tick, lê `Perception.minimap/1` + a contagem de inimigos do fato `:battle` + o snapshot do Combat, chama `Logic.step`, e traduz a action: `{:walk,dx,dy}` → `Body.minimap_step(dx,dy)`; `:run_combat`/`:halt_combat` → `Combat.Worker.run/halt`; `{:block,r}` → `InputGate.set_panic_latch(true)` + `BotSupervisor.stop_all` + broadcast de alarme; (c) `halt` faz `Combat.Worker.halt`, `Perception.detach`, cancela timers.

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** o GenServer. Tick agendado por `Process.send_after` (cadência `cavebot_walk_timeout_ms`/N ou uma chave própria — reusar um tick curto ~200ms). Guardar `%{logic, body, combat, active?, attached?, feed_ref, timer}`. `active? == false` (teste) → `run` prepara mas não agenda tick contra o Rig real. Broadcast `{:cavebot, status}` no tópico `"cavebot"`.
- [ ] **Step 4: Run** → PASS.
- [ ] **Step 5: Commit** `git commit -m "cavebot: Worker peer dirige o Body e o Combat pela Logic (constante)"`

---

## Fase 4 — Fiação: modo "Caçada"

### Task 4.1: Modo "Caçada" + cavebot na frota + Focus

**Files:**
- Modify: `lib/pokex/modes.ex` (bundle "caçada")
- Modify: `lib/pokex/bots/bot_supervisor.ex` (child + `@run_order` + `run_worker`/`halt_worker`)
- Modify: `lib/pokex/bots/focus.ex` (`default_running?` inclui cavebot)
- Modify: `lib/pokex/application.ex` (cavebot idle no supervisor de app)
- Modify: `lib/pokex_web/live/panel_live.ex` (3º botão de modo)
- Test: `test/pokex/modes_test.exs`, `test/pokex/bots/bot_supervisor_test.exs`

**Interfaces:**
- Consumes: `Cavebot.Worker.run/halt` (Task 3.1); `Pokex.Modes` (existente); `BotSupervisor` (existente).
- Produces:
  - `Modes.bundle("caçada") == %{workers: [:catcher, :player_support, :cavebot], settings: %{}}`
  - `Modes.all() == ["parado", "movimento", "caçada"]`
  - `BotSupervisor` sobe/desce o `:cavebot` (novo em `@run_order`, por último).

- [ ] **Step 1: Failing test — bundle e frota**

```elixir
# em test/pokex/modes_test.exs
test "caçada roda catcher/suporte/cavebot, sem combat direto" do
  w = Pokex.Modes.bundle("caçada").workers
  assert :cavebot in w
  assert :catcher in w
  assert :player_support in w
  refute :combat in w
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — adicionar `"caçada"` ao `@bundles` de `Modes` (workers acima, settings `%{}`). Em `BotSupervisor`: adicionar o child `Cavebot.Worker`, incluir `:cavebot` em `@run_order` (por último, após `:catcher`), cláusulas `run_worker(:cavebot, ...)` e `halt_worker(:cavebot, ...)`, e `:cavebot` no mapa `servers`. Em `Focus.default_running?` incluir o cavebot na consideração de "algo rodando" (senão o alt-tab mata a caçada — REQUISITO do spec). Em `Application`, adicionar o `Cavebot.Worker` idle. 3º botão de modo no `#mode-picker` do painel (`hero-map` ou similar).
- [ ] **Step 4: Run** → PASS. Rodar `mix test test/pokex/modes_test.exs test/pokex/bots/bot_supervisor_test.exs test/pokex/bots/focus_test.exs`.
- [ ] **Step 5: Commit** `git commit -m "cavebot: modo Caçada na frota + cavebot em Focus.default_running?"`

---

## Fase 5 — Gate de combo por dungeon

### Task 5.1: Campo `:dungeon` no combo + filtro por dungeon corrente

**Files:**
- Modify: `lib/pokex/combos.ex` (`Combo` struct + `match/3`)
- Modify: `lib/pokex/combos/store.ex` (encode/decode do `:dungeon`)
- Modify: `lib/pokex/combos/runner.ex` (lê o fato `:dungeon` e passa pro `match`)
- Modify: `lib/pokex/bots/cavebot/worker.ex` (publica o fato `:dungeon` no run, forget no halt)
- Test: `test/pokex/combos_test.exs`, `test/pokex/combos/runner_test.exs`

**Interfaces:**
- Consumes: `Combos.Combo` (existente); `WorldState` (fato `:dungeon`).
- Produces:
  - `%Combos.Combo{... , dungeon: String.t() | nil}` (default nil = global)
  - `Combos.match(combos, enemy_name, current_dungeon \\ nil)` — combo com `dungeon` casa só se `dungeon == current_dungeon`; combo com `dungeon: nil` casa sempre. `match/2` continua funcionando (dungeon default nil).

- [ ] **Step 1: Failing test**

```elixir
# em test/pokex/combos_test.exs
test "combo com dungeon só casa na DG certa; global casa sempre" do
  glob = %Combos.Combo{name: "g", trigger: {:enemy_element, "Water"}, steps: [], dungeon: nil}
  dg   = %Combos.Combo{name: "d", trigger: {:enemy_element, "Water"}, steps: [], dungeon: "cavena"}
  # Tentacool é Water (Pokedex)
  assert Combos.match([dg], "Tentacool", "cavena").name == "d"
  assert Combos.match([dg], "Tentacool", "outra") == nil
  assert Combos.match([glob], "Tentacool", "qualquer").name == "g"
end
```

- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — adicionar `dungeon: nil` ao `defstruct` do `Combo`; em `match`, adicionar o parâmetro `current_dungeon \\ nil` e filtrar `applicable` também por `combo.dungeon == nil or combo.dungeon == current_dungeon`; encode/decode do campo no `Store`; no `Runner`, ler `WorldState.get(:dungeon, ...)` e passar o id pro `match`; no `Cavebot.Worker`, `WorldState.put(:dungeon, %{id: route.dungeon}, now)` no run e `forget(:dungeon)` no halt.
- [ ] **Step 4: Run** → PASS. Rodar `mix test test/pokex/combos_test.exs test/pokex/combos/runner_test.exs`.
- [ ] **Step 5: UI** — no `combos_card.ex`, o form de combo ganha um `<input name="dungeon">` opcional (vazio = global); o chip do combo mostra a DG. Incluir no mesmo commit + um assert no `panel_live_test`.
- [ ] **Step 6: Commit** `git commit -m "combos: gate por dungeon — combo pode valer só numa DG"`

---

## Fase 6 — `CavebotLive` (gravar/editar rota) + verificação

### Task 6.1: Página de gravar-andando e editar rota

**Files:**
- Create: `lib/pokex_web/live/cavebot_live.ex`
- Modify: `lib/pokex_web/router.ex` (rota `/cavebot`)
- Modify: `lib/pokex_web/live/panel_live.ex` (link de nav para `/cavebot`)
- Test: `test/pokex_web/live/cavebot_live_test.exs`

**Interfaces:**
- Consumes: `Cavebot.Store` (Task 1.2), `Cavebot.Route` (Task 1.1), `World.snapshot/1`, `Perception.attach/1`.
- Produces: página em `/cavebot` com: seletor de rota ativa, botão "marcar waypoint aqui" (lê `World.snapshot().pos` → `Route.append` → `Store.put`), lista editável (reordenar/apagar), campo de DG e de estilo. **`attach(:minimap)` no mount** (senão o pos de gravação vem nil).

- [ ] **Step 1: Failing test** — monta `/cavebot`, injeta o fato `:minimap` (pos `{10,20,7}`), clica "marcar waypoint", afirma que `Store.all()` ganhou o waypoint. Segundo teste: apagar um waypoint.
- [ ] **Step 2: Run** → FAIL.
- [ ] **Step 3: Implement** — LiveView com `Perception.attach(:minimap)` no `mount` (guardar como consumidor enquanto a página vive); assigns `routes`, `active_route`, `pos`; handlers `mark_waypoint`, `delete_waypoint`, `save_route_meta` (nome/DG/estilo), `select_route`. Estilo com tokens `pk-*`. Rota no router. Link de nav no painel.
- [ ] **Step 4: Run** → PASS. Rodar `mix test test/pokex_web/`.
- [ ] **Step 5: Commit** `git commit -m "cavebot: página de gravar rota andando + editar waypoints"`

### Task 6.2: Verificação whole-branch (constante)

- [ ] **Step 1:** `mix test` — toda a suíte verde (esperado: ~830 + novos, 0 falhas).
- [ ] **Step 2:** `mix format --check-formatted` — só arquivos próprios; reverter formatação de arquivos fora da faixa.
- [ ] **Step 3:** `mix compile --warnings-as-errors` — limpo.
- [ ] **Step 4:** Grep de segurança: `grep -rn "Rig\." lib/pokex/bots/cavebot/` deve dar VAZIO (o cavebot só fala com o Body). `grep -rn "Combat.Worker" lib/pokex/bots/cavebot/` só pode conter `run`/`halt`/`topic`/`status` — nunca acesso a estado interno.
- [ ] **Step 5:** Whole-branch review (superpowers:requesting-code-review) focado em: caminho de atuação 100% via Body; Combat intocado; confirmação de movimento por releitura; sem vazamento de `active_character` nos testes.
- [ ] **Step 6:** Atualizar a memória (`pokex-*`) com o estado entregue e o que falta validar ao vivo.

---

## Fase 7 — Estilo MOBADA (ESBOÇO — detalhar em entrega posterior)

Não implementar agora (o Lucas não tem personagem forte pra testar). Quando chegar:

- Estender `Cavebot.Logic` com os estados `:gathering` (defesa shift+3 + andar puxando aggro até `cavebot_group_min_enemies`), `:nuking` (ataque shift+1 + disparar o combo de área associado — via Body/Combos, SEM ligar o Combat), `:cleanup` (ligar o Combat de relance pra varrer sobras, halt ao limpar). Novas actions: `{:press, defense_key}`, `{:press, attack_key}`, `{:fire_combo, name}`.
- O "combo de área associado" reusa o sistema de Combos (combo com `:dungeon` da rota), disparado pelo cavebot em vez do Combat — decidir na hora se o `Combos.Runner` ganha um gatilho manual ou se o cavebot chama `Combos.plan/key_for` direto.
- Seletor de estilo constante/mobado na `CavebotLive`/painel, lendo/escrevendo `hunt_style`.
- Confirmar com o Lucas: kite ativo vs. parar-e-esperar; e o critério de "combo não matou todos" (contagem residual de inimigos após o `cavebot_combo_timeout_ms`).

---

## Self-Review (feito)

**Cobertura do spec:** personagem (0.1–0.3) ✓; route store + settings (1.1–1.2) ✓; Logic constante (2.2) + accessor minimap (2.1) ✓; Worker (3.1) ✓; modo Caçada + Focus (4.1) ✓; combo por DG (5.1) ✓; CavebotLive (6.1) ✓; verificação (6.2) ✓; mobada esboçada (Fase 7) ✓. Confirmações do spec (estilo como sub-toggle, pausa na luta, captcha por parada manual, migração team.json) ficam para a revisão do Lucas — a #1 (forma na UI) aparece na Task 4.1 (3º botão) e 7 (sub-toggle).

**Consistência de tipos:** vocabulário de ação da Logic (`:none`/`{:walk,dx,dy}`/`:run_combat`/`:halt_combat`/`{:nudge,dx,dy}`/`{:block,reason}`) fixado na Task 2.2 e consumido igual na 3.1. `Route`/`Store`/`Characters`/`Combos.match/3` com assinaturas idênticas onde citadas. `Modes.bundle("caçada")` com o mesmo nome em 4.1.

**Sem placeholders:** cada Task tem test code + implementação guiada + comando + commit.
