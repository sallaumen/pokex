# A escada é um passo — plano de implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** a caçada passa a saber que tomar uma escada é UMA tecla que anda DOIS
tiles, e para de tratar isso como caminhada comum com uma busca cega atrás.

**Architecture:** um reconhecedor PURO na `Route` (perna que muda de `z` com
delta ±2 num eixo e 0 no outro = escada, e o degrau é o ponto médio); a `Logic`
emite UM TOQUE nessa perna em vez de segurar a seta, com re-tentativa e o anel
existente como rede; a chegada no canto de partida de uma escada passa a exigir
tile exato; e a tela diagnostica os trechos mal marcados.

**Tech Stack:** Elixir/OTP, Phoenix LiveView, ExUnit. Sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-08-12-escada-e-um-passo-design.md`

## Global Constraints

- **Código, identificadores, `@moduledoc`, `@doc` e comentários em INGLÊS.**
  Português só em (a) texto de tela, (b) texto de log/aviso pro Lucas, (c)
  citação literal dele dentro de um comentário, com a data. É assim que
  `route.ex` e `logic.ex` já são.
- **`Route` e `Logic` são PUROS**: sem processo, relógio, tela, Settings ou IO.
  A Logic emite INTENÇÃO (`{:nudge, sx, sy}`), nunca tecla nem pixel.
- **A caçada atua só pelo `body` injetado.**
- **Toda tecla é toque depois de soltar o hold** — `{:nudge, _, _}` já faz isso
  no Worker (`release_walk/1` + `arrow_step/2`).
- **O anel de sondagem NÃO é removido** — ele continua sendo a rede dos trechos
  mal marcados. Esta mudança só evita que ele seja o caminho comum.
- Rota antiga sem os campos novos continua funcionando; sem migração.
- `mix credo`, `mix dialyzer`, `mix format --check-formatted` e
  **`MIX_ENV=test mix compile --force --warnings-as-errors`** todos limpos. O
  último pegou um bug que os outros três não viram na branch anterior. ⚠️ Tem
  que ser `--force`: `touch` no arquivo NÃO força recompilação (o Elixir checa
  digest, não mtime), e o gate devolve silêncio — medido na Task 1.

## Os fatos medidos (a régua de tudo)

Nas 5 rotas reais dele, 14 trocas de andar. **7 têm a assinatura** (um eixo ±2,
o outro 0) e 7 não:

| rota (fixture) | perna 0-based | dx | dy | limpo |
|---|---|---|---|---|
| `rota_meganium.json` | 6→7 | 0 | −2 | ✅ |
| `rota_meganium.json` | 60→61 | 0 | +2 | ✅ |
| `rota_xatu.json` | 21→22 | 0 | −2 | ✅ |
| `rota_xatu.json` | 24→25 | 0 | −2 | ✅ |
| `rota_xatu.json` | 26→27 | 0 | +2 | ✅ |
| `rota_xatu.json` | 48→49 | 0 | −2 | ✅ |
| `rota_azumaril.json` | 47→0 (perna de fechamento) | 0 | +2 | ✅ |
| `rota_xatu.json` | 0→1 | 0 | +3 | ❌ |
| `rota_xatu.json` | 15→16 | 0 | −4 | ❌ |
| `rota_xatu.json` | 29→30 | −1 | +2 | ❌ |
| `rota_xatu.json` | 33→34 | +2 | +3 | ❌ |
| `rota_azumaril.json` | 1→2 | +2 | −3 | ❌ |
| `rota_azumaril.json` | 10→11 | −4 | −4 | ❌ |
| `rota_azumaril.json` | 22→23 | +1 | +3 | ❌ |

As três fixtures **já existem** em `test/support/fixtures/`.

## Estrutura de arquivos

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/bots/cavebot/route.ex` | reconhece a perna de escada e devolve o degrau — puro |
| `lib/pokex/bots/cavebot/logic.ex` | toque em vez de hold; chegada exata; re-tentativa; anel como rede |
| `lib/pokex/settings.ex` | as duas settings novas do passo |
| `lib/pokex/bots/cavebot/worker.ex` | instrumentação da decisão de andar |
| `lib/pokex_web/live/cavebot_live.ex` | 🪜 no trecho, degrau, diagnóstico do torto |

---

### Task 1: `Route` reconhece a perna de escada

**Files:**
- Modify: `lib/pokex/bots/cavebot/route.ex`
- Test: `test/pokex/bots/cavebot/route_stairs_test.exs` (criar)

**Interfaces:**
- Produces:
  - `Route.stair_leg(waypoints :: [waypoint], index :: non_neg_integer) :: {:stair, -1..1, -1..1} | nil`
  - `Route.stair_step(waypoints :: [waypoint], index :: non_neg_integer) :: {integer, integer} | nil`

- [ ] **Step 1: Write the failing test**

Crie `test/pokex/bots/cavebot/route_stairs_test.exs`:

```elixir
defmodule Pokex.Bots.Cavebot.RouteStairsTest do
  @moduledoc """
  Taking a staircase is ONE key that moves TWO tiles — the step and the tile
  past it — and changes floor. "se fui de um ponto X para um ponto Y à minha
  esquerda, a coordenada Y vai subir em 2 pontos, 1 bloco da escada e 1 bloco
  de depois da escada, com 1 passo só" (Lucas, 2026-08-12). He marks the corner
  right before and right after, so the pair describes the whole staircase and
  the step itself is the midpoint.
  """
  use ExUnit.Case, async: true

  alias Pokex.Bots.Cavebot.{Route, Store}

  defp legs(coords) do
    Enum.reduce(coords, Route.new("r"), fn {x, y, z}, route ->
      {:ok, route} = Route.append(route, {x, y, z})
      route
    end).waypoints
  end

  describe "stair_leg/2 — the signature he described" do
    test "two tiles on one axis with a floor change is a stair, and gives the direction" do
      wps = legs([{2368, 30030, 5}, {2368, 30028, 6}])

      assert Route.stair_leg(wps, 0) == {:stair, 0, -1}
    end

    test "the way back down is the same leg, mirrored" do
      wps = legs([{2368, 30028, 6}, {2368, 30030, 5}])

      assert Route.stair_leg(wps, 0) == {:stair, 0, 1}
    end

    test "it reads on the x axis too" do
      wps = legs([{100, 50, 3}, {102, 50, 4}])

      assert Route.stair_leg(wps, 0) == {:stair, 1, 0}
    end

    # The route is a LOOP, so the closing leg is a real leg — his Azumaril
    # takes its stairs there.
    test "the closing leg of the loop counts" do
      wps = legs([{10, 10, 2}, {14, 10, 2}, {10, 12, 2}])
      wps = List.replace_at(wps, 0, %{Enum.at(wps, 0) | z: 3, x: 10, y: 10})

      assert Route.stair_leg(wps, 2) == nil
    end

    test "same floor is never a stair, however far apart" do
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 12, 5}]), 0) == nil
    end

    # These are the seven legs of his real routes where the marking has extra
    # walking folded in. They fall through to the ring search on purpose.
    test "a floor change that is not exactly two-and-zero is not a stair" do
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 13, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {10, 14, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {9, 12, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {12, 13, 6}]), 0) == nil
      assert Route.stair_leg(legs([{10, 10, 5}, {12, 12, 6}]), 0) == nil
    end

    test "an index nobody has is not a stair" do
      assert Route.stair_leg(legs([{10, 10, 5}]), 9) == nil
      assert Route.stair_leg([], 0) == nil
    end
  end

  describe "stair_step/2 — where the step itself is" do
    test "the step is the midpoint of the pair" do
      wps = legs([{2368, 30030, 5}, {2368, 30028, 6}])

      assert Route.stair_step(wps, 0) == {2368, 30029}
    end

    test "a leg that is not a stair has no step to name" do
      assert Route.stair_step(legs([{10, 10, 5}, {10, 13, 6}]), 0) == nil
    end
  end

  # The real thing. These three files are his own routes, frozen.
  describe "his real routes" do
    setup %{tmp_dir: tmp} do
      Application.put_env(:pokex, :home_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
      :ok
    end

    defp stair_legs(fixture, tmp) do
      File.cp!("test/support/fixtures/#{fixture}", Path.join(tmp, "routes.json"))
      [route] = Store.all()

      for index <- 0..(length(route.waypoints) - 1)//1,
          leg = Route.stair_leg(route.waypoints, index),
          leg != nil,
          do: {index, leg}
    end

    @tag :tmp_dir
    test "Meganium 1 has exactly the two clean stair legs", %{tmp_dir: tmp} do
      assert stair_legs("rota_meganium.json", tmp) == [{6, {:stair, 0, -1}}, {60, {:stair, 0, 1}}]
    end

    @tag :tmp_dir
    test "Xatu easy has four clean ones, and the four dirty ones stay out", %{tmp_dir: tmp} do
      assert stair_legs("rota_xatu.json", tmp) == [
               {21, {:stair, 0, -1}},
               {24, {:stair, 0, -1}},
               {26, {:stair, 0, 1}},
               {48, {:stair, 0, -1}}
             ]
    end

    @tag :tmp_dir
    test "Azumaril easy has only its closing leg", %{tmp_dir: tmp} do
      assert stair_legs("rota_azumaril.json", tmp) == [{47, {:stair, 0, 1}}]
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex/bots/cavebot/route_stairs_test.exs
```

Esperado: FAIL com `function Pokex.Bots.Cavebot.Route.stair_leg/2 is undefined`.

- [ ] **Step 3: Implement both functions**

Em `lib/pokex/bots/cavebot/route.ex`, depois de `floor_change/2`:

```elixir
  @doc """
  The leg LEAVING `index`, when it is a staircase step — `{:stair, sx, sy}` with
  the direction to press, `nil` otherwise.

  Taking a staircase is ONE key that moves TWO tiles: the step and the tile past
  it. "se fui de um ponto X para um ponto Y à minha esquerda, a coordenada Y vai
  subir em 2 pontos, 1 bloco da escada e 1 bloco de depois da escada, com 1
  passo só" (Lucas, 2026-08-12). He marks the corner right before and the one
  right after, so the pair describes the whole staircase.

  The signature is therefore exact and narrow: the floor changes AND one axis
  moved exactly two tiles while the other did not move at all. Seven of the
  fourteen floor changes in his five real routes match it; the other seven have
  extra walking folded into the same corner and are left to the ring search,
  which is what that search is for.

  Same leg convention as `lure_leg?/2` and `floor_change/2`: the closing leg of
  the loop is a real leg — his Azumaril takes its stairs there.
  """
  @spec stair_leg([waypoint], non_neg_integer) :: {:stair, -1..1, -1..1} | nil
  def stair_leg(waypoints, index) when is_list(waypoints) and is_integer(index) do
    count = length(waypoints)

    with true <- index in 0..(count - 1)//1,
         %{x: x1, y: y1, z: z1} <- Enum.at(waypoints, index),
         %{x: x2, y: y2, z: z2} when z2 != z1 <- Enum.at(waypoints, rem(index + 1, count)),
         {dx, dy} when abs(dx) + abs(dy) == 2 and (dx == 0 or dy == 0) <- {x2 - x1, y2 - y1} do
      {:stair, sign(dx), sign(dy)}
    else
      _not_a_stair -> nil
    end
  end

  defp sign(0), do: 0
  defp sign(n) when n > 0, do: 1
  defp sign(_negative), do: -1

  @doc """
  The staircase tile itself: the midpoint of the pair — `nil` unless the leg
  leaving `index` is a stair.

  Derivable, never calibrated: two tiles apart with the step in between is what
  makes the midpoint exact. The screen shows it so he can see the route agrees
  with the map.
  """
  @spec stair_step([waypoint], non_neg_integer) :: {integer, integer} | nil
  def stair_step(waypoints, index) do
    with {:stair, _sx, _sy} <- stair_leg(waypoints, index),
         %{x: x1, y: y1} <- Enum.at(waypoints, index),
         %{x: x2, y: y2} <- Enum.at(waypoints, rem(index + 1, length(waypoints))) do
      {div(x1 + x2, 2), div(y1 + y2, 2)}
    else
      _not_a_stair -> nil
    end
  end
```

⚠️ `abs(dx) + abs(dy) == 2 and (dx == 0 or dy == 0)` é a guarda inteira: ela
aceita `{0,±2}` e `{±2,0}` e recusa `{±1,±1}` (que soma 2 mas anda na diagonal —
não é a assinatura dele).

- [ ] **Step 4: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex/bots/cavebot/
```

Esperado: PASS.

- [ ] **Step 5: Gates and commit**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix credo && mix dialyzer && mix format --check-formatted && MIX_ENV=test mix compile --force --warnings-as-errors
git add lib/pokex/bots/cavebot/route.ex test/pokex/bots/cavebot/route_stairs_test.exs test/support/fixtures/rota_xatu.json test/support/fixtures/rota_azumaril.json
git commit -m "feat: a rota reconhece o trecho de escada, e sabe onde é o degrau"
```

---

### Task 2: a `Logic` toma a escada com um toque

**Files:**
- Modify: `lib/pokex/bots/cavebot/logic.ex` (`follow_route/3`, `@type config`, struct)
- Modify: `lib/pokex/settings.ex`
- Modify: `lib/pokex/bots/cavebot/worker.ex` (`@config_keys`)
- Test: `test/pokex/bots/cavebot/logic_test.exs`

**Interfaces:**
- Consumes: `Route.stair_leg/2`
- Produces: settings `cavebot_stair_step_ms` (padrão 700) e `cavebot_stair_step_taps` (padrão 3); campo novo na struct da Logic: `stair_taps: 0`

**O que muda no comportamento, em uma frase:** hoje uma perna de escada vira
`{:walk, 0, -2}` — **segurar a seta** — e a busca do anel só entra quando a
leitura pega o personagem dentro da tolerância no andar errado. Passa a valer:
perna de escada = **um toque**, e o anel só depois de esgotar os toques.

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/logic_test.exs`, no fim (antes do `end` final). O
arquivo já tem `@cfg`, `route/0` e `world(pos, enemies \\ 0, combat \\ :hunting)`:

```elixir
  describe "a staircase is one tap, not a held key" do
    # Two corners: the one right before the staircase and the one right after,
    # two tiles up and one floor above. His signature.
    defp stair_route do
      {:ok, r} = Route.append(Route.new("meganium"), {2368, 30030, 5})
      {:ok, r} = Route.append(r, {2368, 30028, 6})
      r
    end

    defp standing_before(cfg \\ @cfg) do
      logic = Logic.new(stair_route(), cfg)
      {logic, :run_combat} = Logic.step(logic, world({2368, 30030, 5}), 0)
      {logic, _arrival} = Logic.step(logic, world({2368, 30030, 5}), 200)
      logic
    end

    test "standing on the corner before it, the leg is ONE tap toward the step" do
      {_logic, action} = Logic.step(standing_before(), world({2368, 30030, 5}), 400)

      assert action == {:nudge, 0, -1}
    end

    # A held key takes the stair on the first press and keeps walking on the
    # floor above until the next tick — the overshoot he reported.
    test "it is never a held walk" do
      {_logic, action} = Logic.step(standing_before(), world({2368, 30030, 5}), 400)

      refute match?({:walk, _, _}, action)
    end

    # One tap per stair_step_ms, not one per 200ms tick: the client needs time
    # to answer, and a second key on top of the first is a second stair.
    test "it does not tap again before the step has had time to answer" do
      logic = standing_before()
      {logic, {:nudge, 0, -1}} = Logic.step(logic, world({2368, 30030, 5}), 400)
      {_logic, again} = Logic.step(logic, world({2368, 30030, 5}), 600)

      assert again == :none
    end

    test "still on the old floor after the wait, it taps again" do
      logic = standing_before()
      {logic, {:nudge, 0, -1}} = Logic.step(logic, world({2368, 30030, 5}), 400)
      {_logic, again} = Logic.step(logic, world({2368, 30030, 5}), 1_200)

      assert again == {:nudge, 0, -1}
    end

    test "the floor changed: it arrived, and the taps reset" do
      logic = standing_before()
      {logic, {:nudge, 0, -1}} = Logic.step(logic, world({2368, 30030, 5}), 400)
      {logic, _} = Logic.step(logic, world({2368, 30028, 6}), 1_200)

      assert logic.wp_index == 0
      assert logic.state == :walking
    end

    # The ring search is the NET, not the road: it only gets its turn once the
    # taps are spent.
    test "taps spent falls back to the ring search" do
      cfg = Map.merge(@cfg, %{stair_step_ms: 100, stair_step_taps: 2})
      logic = standing_before(cfg)

      {logic, {:nudge, 0, -1}} = Logic.step(logic, world({2368, 30030, 5}), 400)
      {logic, {:nudge, 0, -1}} = Logic.step(logic, world({2368, 30030, 5}), 600)
      {logic, _third} = Logic.step(logic, world({2368, 30030, 5}), 800)

      assert logic.state == :stairs
    end
  end

  describe "the corner before a staircase is reached EXACTLY" do
    defp approach_route do
      {:ok, r} = Route.append(Route.new("meganium"), {2368, 30030, 5})
      {:ok, r} = Route.append(r, {2368, 30028, 6})
      {:ok, r} = Route.append(r, {2360, 30028, 6})
      r
    end

    # Arrival tolerance is one tile, and from one tile off the tap misses the
    # step entirely — so the corner a staircase leaves from is the one place
    # the tolerance may not apply.
    test "one tile off the corner before a stair is not arrival" do
      logic = Logic.new(approach_route(), @cfg)
      {logic, :run_combat} = Logic.step(logic, world({2368, 30031, 5}), 0)
      {logic, action} = Logic.step(logic, world({2368, 30031, 5}), 200)

      assert logic.wp_index == 0
      assert match?({:walk, _, _}, action)
    end

    test "an ordinary corner still arrives within the tolerance" do
      logic = Logic.new(approach_route(), @cfg)
      {logic, :run_combat} = Logic.step(logic, world({2360, 30029, 6}), 0)
      {logic, _} = Logic.step(logic, world({2360, 30029, 6}), 200)

      assert logic.wp_index == 0
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex/bots/cavebot/logic_test.exs
```

Esperado: FAIL — a primeira asserção recebe `{:walk, 0, -2}` em vez de
`{:nudge, 0, -1}`.

- [ ] **Step 3: Add the settings**

Em `lib/pokex/settings.ex`, junto de `cavebot_stair_probe_ms` (~linha 880):

```elixir
    cavebot_stair_step_ms: 700,
    cavebot_stair_step_taps: 3,
```

E nas faixas de validação, junto de `cavebot_stair_probe_ms: 100..5_000`:

```elixir
    cavebot_stair_step_ms: 100..10_000,
    cavebot_stair_step_taps: 1..10,
```

Documente as duas no mesmo estilo das vizinhas: uma escada se toma com UMA
tecla que anda dois tiles, `cavebot_stair_step_ms` é quanto esperar o cliente
responder antes de repetir, e `cavebot_stair_step_taps` quantas vezes tentar
antes de entregar pro anel.

Em `lib/pokex/bots/cavebot/worker.ex`, `@config_keys` ganha as duas:

```elixir
    stair_step_ms: :cavebot_stair_step_ms,
    stair_step_taps: :cavebot_stair_step_taps,
```

E em `logic.ex`, `@type config` ganha `stair_step_ms: non_neg_integer` e
`stair_step_taps: non_neg_integer`.

- [ ] **Step 4: Add the counter to the struct**

Em `lib/pokex/bots/cavebot/logic.ex`, na `defstruct`, junto de `probe_steps: 0`:

```elixir
            # how many taps this staircase has already been given — spent, the
            # ring search gets its turn
            stair_taps: 0,
```

E no `@type t`, `stair_taps: non_neg_integer`.

- [ ] **Step 5: Take the stair with a tap**

Em `follow_route/3`, a cláusula da chegada passa a exigir tile EXATO quando a
perna que sai deste waypoint é uma escada, e entra uma cláusula nova para a
perna de escada. Substitua o `cond` inteiro por:

Compute the two stair answers ONCE, before the `cond` — a `cond` cannot bind,
and calling `stair_step_due/2` in both a guard and its own body is the kind of
double evaluation a reviewer rightly flags:

```elixir
    stair = stair_leg(logic)
    tap = stair_step_due(logic, stair, now)

    cond do
      # ARRIVING means standing there, floor included: the tile at the top of
      # the stairs has the same x/y as the one at their foot, and "arriving"
      # from below would tick the waypoint off without ever climbing.
      #
      # On the corner a STAIRCASE leaves from, the tolerance does not apply: the
      # tap that takes the step only works from the exact tile, and one tile off
      # presses an arrow into whatever is beside the staircase.
      arrived_here?(logic, dx, dy, z, wp, tol) ->
        next = rem(logic.wp_index + 1, length(logic.route.waypoints))
        logic = note_progress(logic, pos, now)
        {%{arrived(logic, wp, now) | wp_index: next, skips: 0}, on_arrival(logic, wp)}

      # A staircase is ONE key that moves TWO tiles. Holding the arrow takes the
      # step on the first press and keeps walking on the floor above until the
      # next tick — so this leg taps, waits for the client to answer, and taps
      # again. The ring search below is the NET for the legs his marking left
      # crooked, not the road.
      tap != nil ->
        {sx, sy} = tap

        {%{
           logic
           | stair_taps: logic.stair_taps + 1,
             since: Map.put(logic.since, :stair_tap, now)
         }, {:nudge, sx, sy}}

      stair != nil and logic.stair_taps < stair_step_taps(logic) ->
        {logic, :none}

      # The right tile on the WRONG floor: the staircase is here somewhere and
      # was not taken. Standing on it asks for nothing — dx and dy are zero —
      # so this used to time out into :stuck and then skip the corner. Search
      # for the step instead.
      (abs(dx) <= tol and abs(dy) <= tol) or stair != nil ->
        stairs(enter_stairs(logic, pos, now), world, now)

      pos != logic.last_pos ->
        {note_progress(logic, pos, now), {:walk, dx, dy}}

      now - Map.get(logic.since, :walk_progress, now) >= logic.config.walk_timeout_ms ->
        {%{logic | state: :stuck, retries: 0}, {:walk, dx, dy}}

      true ->
        {logic, {:walk, dx, dy}}
    end
```

E os auxiliares privados, junto dos outros:

```elixir
  # The leg the character is walking RIGHT NOW is the one leaving the waypoint
  # before the target — same convention as `lure_leg?/2`.
  defp stair_leg(%__MODULE__{route: %Route{waypoints: []}}), do: nil

  defp stair_leg(%__MODULE__{route: %Route{waypoints: waypoints}, wp_index: index}) do
    Route.stair_leg(waypoints, Integer.mod(index - 1, length(waypoints)))
  end

  # A tap is due when this leg is a staircase, the taps are not spent, and the
  # client has had `stair_step_ms` to answer the last one.
  defp stair_step_due(logic, stair, now) do
    with {:stair, sx, sy} <- stair,
         true <- logic.stair_taps < stair_step_taps(logic),
         true <- tap_settled?(logic, now) do
      {sx, sy}
    else
      _not_due -> nil
    end
  end

  defp tap_settled?(%__MODULE__{since: since} = logic, now) do
    case Map.get(since, :stair_tap) do
      nil -> true
      at -> now - at >= Map.get(logic.config, :stair_step_ms, 700)
    end
  end

  defp stair_step_taps(%__MODULE__{config: config}),
    do: Map.get(config, :stair_step_taps, 3)

  # Arrival, with the one exception the staircase forces: the corner a stair
  # leaves from is reached EXACTLY, because the tap only works from that tile.
  defp arrived_here?(logic, dx, dy, z, wp, tol) do
    exact? = Route.stair_leg(logic.route.waypoints, logic.wp_index) != nil
    reach = if exact?, do: 0, else: tol

    abs(dx) <= reach and abs(dy) <= reach and wp.z == z
  end
```

⚠️ **Zere `stair_taps` e o carimbo `:stair_tap` na chegada.** Em `arrived/3`
(que já zera `stops_done`), acrescente `stair_taps: 0` e
`since: Map.delete(logic.since, :stair_tap)` — senão a próxima escada da volta
começa com os toques já gastos. Faça o mesmo em `enter_stairs/3`.

- [ ] **Step 6: Run tests to verify they pass**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex/bots/cavebot/
```

Esperado: PASS. Se algum teste antigo do anel falhar, leia por quê antes de
mexer: o anel só deve ter perdido os casos em que a perna É uma escada limpa.

- [ ] **Step 7: Gates and commit**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test && mix credo && mix dialyzer && mix format --check-formatted && MIX_ENV=test mix compile --force --warnings-as-errors
git add lib/pokex/bots/cavebot/logic.ex lib/pokex/settings.ex lib/pokex/bots/cavebot/worker.ex test/pokex/bots/cavebot/logic_test.exs
git commit -m "feat: escada se toma com um toque, e o anel vira a rede"
```

---

### Task 3: a instrumentação que mede a caminhada

**Files:**
- Modify: `lib/pokex/bots/cavebot/worker.ex`
- Test: `test/pokex/bots/cavebot/worker_test.exs`

**Interfaces:**
- Consumes: `Pokex.Perception.WorldState.age(:minimap, now)` — já existe

**Por que:** as duas queixas dele fora da escada ("passa do ponto e volta",
"fica empurrando parede") são HIPÓTESES. O journal de 2026-08-11 não as prova —
os 5 "BLOQUEADO: mudou de andar" de lá são o bug de duas rotas armadas do #214.
Ninguém mediu a velocidade dele em tiles/s, nem quantos tiles ele anda por
decisão, nem se a decisão foi tomada sobre um fato velho
(`cavebot_minimap_fact_max_age_ms` admite 800ms). Uma caçada na Meganium com
isso ligado responde as três.

- [ ] **Step 1: Write the failing test**

Em `test/pokex/bots/cavebot/worker_test.exs`, no fim:

```elixir
  describe "the walk decision is measurable" do
    test "a walk log carries the distance it decided from and the age of the reading" do
      Phoenix.PubSub.subscribe(Pokex.PubSub, Worker.topic())

      state = %{body: FakeBody, held_keys: [], logic: nil, loadout: nil}
      Worker.log_walk_decision(state, {:walk, 4, -3}, 250)

      assert_receive {:cavebot_log, :debug, text}
      assert text =~ "4"
      assert text =~ "3"
      assert text =~ "250"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex/bots/cavebot/worker_test.exs
```

Esperado: FAIL com `function Pokex.Bots.Cavebot.Worker.log_walk_decision/3 is undefined`.

- [ ] **Step 3: Carry the age through `observe/2`**

Em `lib/pokex/bots/cavebot/worker.ex`, `observe/2` guarda a idade da leitura no
state, junto de `pos_at`:

```elixir
  defp observe(state, now) do
    pos = position(now)
    # How old the reading the decision is about to be made ON is. `get/3` hides
    # the age of a fresh fact on purpose, so ask for it directly: a decision
    # taken on an 800ms-old position is a decision taken about where he WAS.
    age = Pokex.Perception.WorldState.age(:minimap, now)
```

(mantendo o resto do corpo igual e acrescentando `pos_age: age` no state
devolvido; declare `pos_age: nil` no mapa de `start_link/1`.)

- [ ] **Step 4: Log the decision**

Uma função PÚBLICA (o teste a chama direto), junto das outras de log:

```elixir
  @doc """
  One line per walking decision, with the two numbers nobody has: how far the
  target was WHEN THE DECISION WAS TAKEN, and how old the position reading it
  was taken on was.

  Public because it is instrumentation: the point is to be callable from a test
  without standing up a whole hunt. "a movimentação tá muito ruim ainda"
  (Lucas, 2026-08-12) — and neither the overshoot nor the wall-pushing has ever
  been measured, only watched.
  """
  @spec log_walk_decision(map, tuple, non_neg_integer | nil) :: :ok
  def log_walk_decision(_state, {kind, dx, dy}, age_ms) do
    log(:debug, "andar #{kind}: faltam #{dx},#{dy} tiles · leitura de #{age_ms || "?"}ms atrás")
  end

  def log_walk_decision(_state, _other_action, _age), do: :ok
```

E chame-a de `translate/2`, nas cláusulas `{:walk, _, _}` e `{:nudge, _, _}`,
passando `state.pos_age`.

⚠️ **Isso é `:debug`, não `:macro`** — o log macro é a narrativa que ele lê, e
uma linha a cada 200ms a enterraria. A regra do módulo é explícita: "Nothing
here may speak per tick".

- [ ] **Step 5: Run tests and gates, commit**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test && mix credo && mix dialyzer && mix format --check-formatted && MIX_ENV=test mix compile --force --warnings-as-errors
git add lib/pokex/bots/cavebot/worker.ex test/pokex/bots/cavebot/worker_test.exs
git commit -m "feat: a decisão de andar diz de que distância e sobre que leitura decidiu"
```

---

### Task 4: a tela diz quais escadas estão limpas

**Files:**
- Modify: `lib/pokex_web/live/cavebot_live.ex`
- Test: `test/pokex_web/live/cavebot_live_test.exs`

**Interfaces:**
- Consumes: `Route.stair_leg/2`, `Route.stair_step/2`, `Route.floor_change/2`

- [ ] **Step 1: Write the failing test**

Em `test/pokex_web/live/cavebot_live_test.exs`, no fim:

```elixir
  describe "the staircase legs on the page" do
    setup do
      {:ok, route} = Route.append(Route.new("meganium"), {2368, 30030, 5})
      {:ok, route} = Route.append(route, {2368, 30028, 6})
      {:ok, route} = Route.append(route, {2360, 30025, 5})
      :ok = Store.put([route])
      :ok
    end

    test "a clean stair leg says where the step is", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cavebot")

      assert html =~ "🪜"
      assert html =~ "2368, 30029"
    end

    # Waypoint 1 → 2 changes floor with dy = +3: extra walking folded into the
    # corner. It must be called out, not silently left to the ring search.
    test "a dirty stair leg is named as dirty", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cavebot")

      assert html =~ "não está limpa"
    end
  end
```

- [ ] **Step 2: Run test to verify it fails**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test test/pokex_web/live/cavebot_live_test.exs
```

Esperado: FAIL — `html =~ "🪜"` é falso.

- [ ] **Step 3: The badge and the diagnosis**

Em `lib/pokex_web/live/cavebot_live.ex`, junto de `climb_label/2` (que já existe
e rotula a troca de andar), acrescente:

```elixir
  # A floor change is either a staircase the route describes exactly — one key,
  # two tiles, the step in the middle — or a corner with extra walking folded
  # into it, which costs the hunt the ring search. Saying which is which is the
  # difference between "it is slow at the stairs" and a corner he can fix.
  defp stair_label(waypoints, index) do
    case {Route.floor_change(waypoints, index), Route.stair_leg(waypoints, index)} do
      {nil, _no_stair} ->
        nil

      {_floor, {:stair, _sx, _sy}} ->
        {x, y} = Route.stair_step(waypoints, index)
        {:ok, "🪜 escada: o degrau é #{x}, #{y}"}

      {_floor, nil} ->
        {:warn, "🪜 troca de andar, mas a marcação não está limpa — o passo da escada é " <>
           "1 tecla que anda 2 tiles: marque o canto logo ANTES e o logo DEPOIS"}
    end
  end
```

E renderize junto do `climb_label` existente na linha do waypoint, com o tom
`pk-ok` para `{:ok, _}` e `pk-warn` para `{:warn, _}` — siga exatamente como os
selos vizinhos daquela linha já fazem (tokens `pk-*`, `text-pk-meta`, e a
grade em `@container`).

- [ ] **Step 4: Run tests and gates, commit**

```bash
cd /Users/tavano/projects/pokex-claude-escada && mix test && mix credo && mix dialyzer && mix format --check-formatted && MIX_ENV=test mix compile --force --warnings-as-errors
git add lib/pokex_web/live/cavebot_live.ex test/pokex_web/live/cavebot_live_test.exs
git commit -m "feat: a página diz qual escada está limpa e onde é o degrau"
```

---

## Verificação final (o controller faz)

- [ ] `mix test` verde, `credo`/`dialyzer`/`format` limpos e
      `mix clean && MIX_ENV=test mix compile --warnings-as-errors` sem aviso.
- [ ] Nas 3 fixtures reais: 7 pernas de escada reconhecidas, 7 recusadas — e as
      recusadas continuam achando a escada pelo anel.
- [ ] `grep -rn "Rig\." lib/pokex/bots/cavebot/` não ganhou nada novo.
