# Pokédex no padrão do Poké Alliance — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Trocar a fonte da Pokédex do wiki do PokeXGames (MediaWiki, raspado por regex) para a API JSON do Poké Alliance, e apagar tudo que só existia no PXG (iscas, clans, matéria, boost por espécie, novidades).

**Architecture:** O `Scraper` monolítico (416 linhas) vira cinco módulos puros de responsabilidade única — `Api` (o único que faz IO), `Index` (JSON do índice → entradas), `PageParser` (HTML do template `pokemon-v4` → mapa), `Upsert` (a escrituração de `first_seen_at`/`changed_at`, herdada intacta) e `TypeChart` (a matriz 18×18 canônica). `Sync` orquestra os quatro primeiros. `Pokedex` deriva a efetividade do `TypeChart` no load, então o JSON guarda só o que a wiki disse.

**Tech Stack:** Elixir ~> 1.15, Phoenix LiveView, `Req` (já em `mix.exs:62`), `JSON` (nativo do OTP 27+). Sem dependência nova.

## Global Constraints

- **Worktree:** `/Users/tavano/projects/worktrees/pokedex-alliance`, branch `pokedex/padrao-poke-alliance`. **Nunca compilar, testar ou rodar em `~/projects/pokex`** — tem `phx.server` vivo lá.
- **Todo código em inglês.** Strings visíveis ao usuário em pt-BR. Comentários raros — só onde explicam *por quê*, nunca *o quê*.
- **Nomes de teste são frases em inglês** descrevendo o comportamento (`test "a page without the Informações Básicas table is unrecognized do"`), no estilo dos testes existentes.
- **`mix precommit` verde ao fim de cada task** (`format`, `compile --warnings-as-errors`, `deps.unlock --unused`, `test --warnings-as-errors`). Rodar `mix format` ANTES do teste — o gate já mordeu uma vez por testar um build que o formatter tinha mudado.
- **Um commit por task**, empurrado no mesmo movimento: `git push origin pokedex/padrao-poke-alliance`.
- **Origem dos dados:** `https://wiki.pokealliance.com`, em `config :pokex, :wiki_base`.
- **Os 18 elementos** vêm capitalizados na base (`"Grass"`), como o resto do app já usa. A API os entrega minúsculos.

---

## Estrutura de arquivos

**Nascem:**

| arquivo | responsabilidade |
|---|---|
| `lib/pokex/pokedex/type_chart.ex` | a matriz 18×18 canônica; puro, sem dependência |
| `lib/pokex/pokedex/api.ex` | o único módulo que sabe uma URL: `index/0`, `page/1`, `asset/1` |
| `lib/pokex/pokedex/index.ex` | JSON decodificado do índice → lista de entradas; puro |
| `lib/pokex/pokedex/page_parser.ex` | HTML `pokemon-v4` → mapa de atributos; puro |
| `lib/pokex/pokedex/upsert.ex` | `merge/2` — a escrituração de novidade, movida de `Scraper.upsert/2` |
| `lib/mix/tasks/pokedex.sync.ex` | substitui `pokedex.scrape.ex` |

**Morrem:** `lib/pokex/pokedex/scraper.ex`, `lib/pokex/pokedex/clans.ex`, `lib/mix/tasks/pokedex.scrape.ex`, `test/pokex/pokedex/scraper_test.exs`, `test/pokex/pokedex/clans_test.exs`, `test/fixtures/pokedex/*.html`.

**Mudam:** `lib/pokex/pokedex.ex`, `lib/pokex/pokedex/sync.ex`, `lib/pokex_web/live/pokedex_live.ex`, `lib/pokex_web/live/pokedex_detail_live.ex`, `lib/pokex_web/pokedex_style.ex`, `config/config.exs`.

**Intactos:** `team.ex`, `skill_profile.ex`, `shiny_log.ex`, `team_icons.ex`.

---

## Task 1: TypeChart — a matriz canônica

Dado puro. Ninguém consome ainda, nada quebra.

**Files:**
- Create: `lib/pokex/pokedex/type_chart.ex`
- Test: `test/pokex/pokedex/type_chart_test.exs`

**Interfaces:**
- Consumes: nada.
- Produces:
  - `TypeChart.elements() :: [String.t()]` — os 18, capitalizados, em ordem alfabética
  - `TypeChart.multiplier(attacking :: String.t(), defending :: [String.t()]) :: float`
  - `TypeChart.weak_to([String.t()]) :: [String.t()]` — multiplicador > 1
  - `TypeChart.resists([String.t()]) :: [String.t()]` — 0 < multiplicador < 1
  - `TypeChart.immune([String.t()]) :: [String.t()]` — multiplicador == 0
  - `TypeChart.neutral([String.t()]) :: [String.t()]` — multiplicador == 1
  - `TypeChart.effectiveness([String.t()]) :: [%{label: String.t(), kind: String.t(), elements: [String.t()]}]` — `kind` é `"weak" | "neutral" | "resists" | "immune"`

- [ ] **Step 1: Write the failing test**

Create `test/pokex/pokedex/type_chart_test.exs`:

```elixir
defmodule Pokex.Pokedex.TypeChartTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.TypeChart

  describe "elements/0" do
    test "lists the eighteen canonical types and none of PokeXGames' own" do
      elements = TypeChart.elements()

      assert length(elements) == 18
      assert "Fairy" in elements
      refute "Crystal" in elements
      assert elements == Enum.sort(elements)
    end
  end

  describe "multiplier/2 — a single defending element" do
    test "a super-effective attack doubles" do
      assert TypeChart.multiplier("Fire", ["Grass"]) == 2.0
    end

    test "a resisted attack halves" do
      assert TypeChart.multiplier("Fire", ["Water"]) == 0.5
    end

    test "an immunity zeroes" do
      assert TypeChart.multiplier("Electric", ["Ground"]) == 0.0
      assert TypeChart.multiplier("Ghost", ["Normal"]) == 0.0
    end

    test "an unrelated pairing is neutral" do
      assert TypeChart.multiplier("Normal", ["Water"]) == 1.0
    end
  end

  describe "multiplier/2 — a dual type multiplies both columns" do
    test "two resistances stack to a quarter" do
      assert TypeChart.multiplier("Grass", ["Grass", "Poison"]) == 0.25
    end

    test "two weaknesses stack to quadruple" do
      assert TypeChart.multiplier("Rock", ["Fire", "Flying"]) == 4.0
    end

    test "a weakness cancelled by a resistance lands back on neutral" do
      assert TypeChart.multiplier("Water", ["Water", "Ground"]) == 1.0
    end

    test "one immune half zeroes the whole pairing" do
      assert TypeChart.multiplier("Ground", ["Ground", "Flying"]) == 0.0
    end
  end

  describe "weak_to/1, resists/1, immune/1, neutral/1" do
    test "Bulbasaur's Grass and Poison answer the four buckets" do
      elements = ["Grass", "Poison"]

      assert TypeChart.weak_to(elements) == ["Fire", "Flying", "Ice", "Psychic"]
      assert "Water" in TypeChart.resists(elements)
      assert "Grass" in TypeChart.resists(elements)
      assert TypeChart.immune(elements) == []
      assert "Normal" in TypeChart.neutral(elements)
    end

    test "a Ground type is immune to Electric and nothing else" do
      assert TypeChart.immune(["Ground"]) == ["Electric"]
    end

    test "the four buckets partition the eighteen elements with no overlap" do
      elements = ["Ghost", "Dark"]

      buckets =
        TypeChart.weak_to(elements) ++
          TypeChart.resists(elements) ++
          TypeChart.immune(elements) ++ TypeChart.neutral(elements)

      assert Enum.sort(buckets) == TypeChart.elements()
    end

    test "an empty or unknown element list leaves everything neutral" do
      assert TypeChart.weak_to([]) == []
      assert TypeChart.neutral([]) == TypeChart.elements()
      assert TypeChart.weak_to(["Bogus"]) == []
    end
  end

  describe "effectiveness/1 — the tiers the detail page shows" do
    test "a quadruple weakness gets its own tier above the double one" do
      tiers = TypeChart.effectiveness(["Fire", "Flying"])

      assert %{label: "Muito Efetivo", kind: "weak", elements: ["Rock"]} = hd(tiers)
      assert Enum.any?(tiers, &(&1.label == "Efetivo" and "Water" in &1.elements))
    end

    test "empty tiers are dropped, so a type with no immunity shows no immunity row" do
      labels = ["Grass", "Poison"] |> TypeChart.effectiveness() |> Enum.map(& &1.label)

      refute "Imune" in labels
    end
  end
end
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix test test/pokex/pokedex/type_chart_test.exs`
Expected: FAIL — `** (UndefinedFunctionError) function Pokex.Pokedex.TypeChart.elements/0 is undefined (module Pokex.Pokedex.TypeChart is not available)`

- [ ] **Step 3: Write the implementation**

Create `lib/pokex/pokedex/type_chart.ex`:

```elixir
defmodule Pokex.Pokedex.TypeChart do
  @moduledoc """
  Element effectiveness for the Poké Alliance, as the canonical 18-type chart.

  The PA wiki publishes no effectiveness anywhere — not a page, not a field
  (measured 25/08 across all 957 wiki paths). Its 18 elements are exactly the
  canonical Pokémon types, though (PokeXGames carried a nineteenth, `Crystal`;
  the PA does not), so the standard chart is the best available answer.

  It is an ASSUMPTION, not a measurement: a PokeTibia server can retune the
  chart. That is precisely why it lives here as pure data and why
  `Pokex.Pokedex` derives the buckets at LOAD time instead of writing them
  into pokedex.json — correcting one cell later costs an edit, not a re-sync
  of 910 pages.

  The matrix is written as the exceptions only: `@chart` maps an attacking
  element to what it does UNUSUALLY well or badly. Everything unlisted is 1.0.
  """

  @elements ~w(Bug Dark Dragon Electric Fairy Fighting Fire Flying Ghost
               Grass Ground Ice Normal Poison Psychic Rock Steel Water)

  # attacking => %{defending => multiplier}. Only the non-1.0 cells.
  @chart %{
    "Bug" => %{
      "Dark" => 2.0,
      "Grass" => 2.0,
      "Psychic" => 2.0,
      "Fairy" => 0.5,
      "Fighting" => 0.5,
      "Fire" => 0.5,
      "Flying" => 0.5,
      "Ghost" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Dark" => %{
      "Ghost" => 2.0,
      "Psychic" => 2.0,
      "Dark" => 0.5,
      "Fairy" => 0.5,
      "Fighting" => 0.5
    },
    "Dragon" => %{"Dragon" => 2.0, "Steel" => 0.5, "Fairy" => 0.0},
    "Electric" => %{
      "Flying" => 2.0,
      "Water" => 2.0,
      "Dragon" => 0.5,
      "Electric" => 0.5,
      "Grass" => 0.5,
      "Ground" => 0.0
    },
    "Fairy" => %{
      "Dark" => 2.0,
      "Dragon" => 2.0,
      "Fighting" => 2.0,
      "Fire" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Fighting" => %{
      "Dark" => 2.0,
      "Ice" => 2.0,
      "Normal" => 2.0,
      "Rock" => 2.0,
      "Steel" => 2.0,
      "Bug" => 0.5,
      "Fairy" => 0.5,
      "Flying" => 0.5,
      "Poison" => 0.5,
      "Psychic" => 0.5,
      "Ghost" => 0.0
    },
    "Fire" => %{
      "Bug" => 2.0,
      "Grass" => 2.0,
      "Ice" => 2.0,
      "Steel" => 2.0,
      "Dragon" => 0.5,
      "Fire" => 0.5,
      "Rock" => 0.5,
      "Water" => 0.5
    },
    "Flying" => %{
      "Bug" => 2.0,
      "Fighting" => 2.0,
      "Grass" => 2.0,
      "Electric" => 0.5,
      "Rock" => 0.5,
      "Steel" => 0.5
    },
    "Ghost" => %{"Ghost" => 2.0, "Psychic" => 2.0, "Dark" => 0.5, "Normal" => 0.0},
    "Grass" => %{
      "Ground" => 2.0,
      "Rock" => 2.0,
      "Water" => 2.0,
      "Bug" => 0.5,
      "Dragon" => 0.5,
      "Fire" => 0.5,
      "Flying" => 0.5,
      "Grass" => 0.5,
      "Poison" => 0.5,
      "Steel" => 0.5
    },
    "Ground" => %{
      "Electric" => 2.0,
      "Fire" => 2.0,
      "Poison" => 2.0,
      "Rock" => 2.0,
      "Steel" => 2.0,
      "Bug" => 0.5,
      "Grass" => 0.5,
      "Flying" => 0.0
    },
    "Ice" => %{
      "Dragon" => 2.0,
      "Flying" => 2.0,
      "Grass" => 2.0,
      "Ground" => 2.0,
      "Fire" => 0.5,
      "Ice" => 0.5,
      "Steel" => 0.5,
      "Water" => 0.5
    },
    "Normal" => %{"Rock" => 0.5, "Steel" => 0.5, "Ghost" => 0.0},
    "Poison" => %{
      "Fairy" => 2.0,
      "Grass" => 2.0,
      "Ghost" => 0.5,
      "Ground" => 0.5,
      "Poison" => 0.5,
      "Rock" => 0.5,
      "Steel" => 0.0
    },
    "Psychic" => %{
      "Fighting" => 2.0,
      "Poison" => 2.0,
      "Psychic" => 0.5,
      "Steel" => 0.5,
      "Dark" => 0.0
    },
    "Rock" => %{
      "Bug" => 2.0,
      "Fire" => 2.0,
      "Flying" => 2.0,
      "Ice" => 2.0,
      "Fighting" => 0.5,
      "Ground" => 0.5,
      "Steel" => 0.5
    },
    "Steel" => %{
      "Fairy" => 2.0,
      "Ice" => 2.0,
      "Rock" => 2.0,
      "Electric" => 0.5,
      "Fire" => 0.5,
      "Steel" => 0.5,
      "Water" => 0.5
    },
    "Water" => %{
      "Fire" => 2.0,
      "Ground" => 2.0,
      "Rock" => 2.0,
      "Dragon" => 0.5,
      "Grass" => 0.5,
      "Water" => 0.5
    }
  }

  # {label, kind} by multiplier — the words the detail page prints, in the
  # order it prints them (hardest hit first).
  @tiers [
    {4.0, "Muito Efetivo", "weak"},
    {2.0, "Efetivo", "weak"},
    {1.0, "Normal", "neutral"},
    {0.5, "Inefetivo", "resists"},
    {0.25, "Muito Inefetivo", "resists"},
    {0.0, "Imune", "immune"}
  ]

  @doc "The eighteen canonical elements, capitalised and alphabetical."
  def elements, do: @elements

  @doc """
  How hard `attacking` hits a species whose elements are `defending` — the
  product of one column per defending element. An unknown element contributes
  1.0, so a typo in the base narrows nothing instead of erasing everything.
  """
  def multiplier(attacking, defending) when is_binary(attacking) and is_list(defending) do
    row = Map.get(@chart, attacking, %{})
    Enum.reduce(defending, 1.0, fn element, acc -> acc * Map.get(row, element, 1.0) end)
  end

  @doc "Elements that hit these elements HARD (multiplier above 1)."
  def weak_to(defending), do: bucket(defending, &(&1 > 1.0))

  @doc "Elements these elements shrug off (multiplier between 0 and 1)."
  def resists(defending), do: bucket(defending, &(&1 > 0.0 and &1 < 1.0))

  @doc "Elements that do NOTHING to these elements (multiplier 0)."
  def immune(defending), do: bucket(defending, &(&1 == 0.0))

  @doc "Elements with no opinion either way (multiplier exactly 1)."
  def neutral(defending), do: bucket(defending, &(&1 == 1.0))

  @doc """
  The buckets as the detail page shows them: one row per strength tier,
  worded like the old PokeTibia pages did, with empty tiers dropped.
  """
  def effectiveness(defending) do
    for {value, label, kind} <- @tiers,
        elements = bucket(defending, &(&1 == value)),
        elements != [],
        do: %{label: label, kind: kind, elements: elements}
  end

  defp bucket(defending, keep?) do
    Enum.filter(@elements, &keep?.(multiplier(&1, defending)))
  end
end
```

- [ ] **Step 4: Run the tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex/pokedex/type_chart_test.exs`
Expected: PASS, 14 tests, 0 failures.

If `the four buckets partition` fails, a cell is duplicated or missing in `@chart` — the four predicates are mutually exclusive by construction, so a failure there means `multiplier/2` returned something outside `{0, 0.25, 0.5, 1, 2, 4}`.

- [ ] **Step 5: Commit and push**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add lib/pokex/pokedex/type_chart.ex test/pokex/pokedex/type_chart_test.exs && git commit -m "a efetividade vira matriz canônica, porque a wiki do PA não publica nenhuma

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance
```

---

## Task 2: Api, Index, PageParser e as fixtures

Os três módulos que substituem o `Scraper`. O `Sync` continua no caminho do PXG — nada quebra ainda.

**Files:**
- Create: `lib/pokex/pokedex/api.ex`, `lib/pokex/pokedex/index.ex`, `lib/pokex/pokedex/page_parser.ex`
- Create: `test/fixtures/pokedex/api_index.json`, `bulbasaur.json`, `groudon.json`, `shiny_rattata.json`, `mewtwo.json`
- Test: `test/pokex/pokedex/index_test.exs`, `test/pokex/pokedex/page_parser_test.exs`

**Interfaces:**
- Consumes: nada das tasks anteriores.
- Produces:
  - `Api.base() :: String.t()` — de `Application.get_env(:pokex, :wiki_base)`
  - `Api.index() :: {:ok, map} | {:error, term}` — o JSON decodificado de `/api/pokemon`
  - `Api.page(path :: String.t()) :: {:ok, String.t()} | {:error, term}` — o campo `content`
  - `Api.asset(path :: String.t()) :: {:ok, binary} | {:error, term}`
  - `Index.parse(map) :: [entry]` onde `entry` é
    `%{path:, name:, number: integer, generation: integer, variant: "normal" | "shiny", level: integer | nil, tier: String.t() | nil, role: String.t() | nil, elements: [String.t()], image: String.t()}`
  - `Index.element_icons(map) :: %{String.t() => String.t()}` — `%{"Grass" => "/elements/4.png"}`
  - `PageParser.parse(html) :: {:ok, map} | {:error, :unrecognized}` onde o mapa é
    `%{description:, hp:, experience:, level:, tier:, role:, habilidades:, moves:, evolves_to:, evolves_from:}`

- [ ] **Step 1: Download the real fixtures**

As fixtures são páginas REAIS. Elas prendem o formato: se o PA mudar o template, o teste quebra alto aqui em vez de baixo no dado.

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance/test/fixtures/pokedex && \
curl -s -H 'User-Agent: Mozilla/5.0' https://wiki.pokealliance.com/api/pokemon -o /tmp/pa_full_index.json && \
curl -s -H 'User-Agent: Mozilla/5.0' https://wiki.pokealliance.com/api/page/gen/1/001_bulbasaur -o bulbasaur.json && \
curl -s -H 'User-Agent: Mozilla/5.0' https://wiki.pokealliance.com/api/page/gen/3/383_groudon -o groudon.json && \
curl -s -H 'User-Agent: Mozilla/5.0' https://wiki.pokealliance.com/api/page/shiny/019_shiny_rattata -o shiny_rattata.json && \
curl -s -H 'User-Agent: Mozilla/5.0' https://wiki.pokealliance.com/api/page/gen/1/150_mewtwo -o mewtwo.json && \
python3 -c "
import json
d = json.load(open('/tmp/pa_full_index.json'))['pokemon']
wanted = {'Bulbasaur','Shiny Bulbasaur','Ivysaur','Rattata','Shiny Rattata','Mewtwo','Groudon','Unown A'}
slice = [x for x in d if x['name'] in wanted]
assert len(slice) == len(wanted), sorted(wanted - {x['name'] for x in slice})
json.dump({'pokemon': slice}, open('api_index.json','w'), ensure_ascii=False, indent=2)
print(len(slice), 'entries')
"
```

Expected: `8 entries`, e cinco arquivos novos em `test/fixtures/pokedex/`.

A fatia é escolhida: `Bulbasaur` (normal completo), `Shiny Bulbasaur` (variante), `Ivysaur` (alvo de evolução), `Rattata`/`Shiny Rattata` (o par da fixture de página), `Mewtwo` (tier 1 sem evolução), `Groudon` (tier nominal `Legendary`), `Unown A` (o caso `tier: "None"` + `role: null`).

- [ ] **Step 2: Write the failing test for Index**

Create `test/pokex/pokedex/index_test.exs`:

```elixir
defmodule Pokex.Pokedex.IndexTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Index

  # A REAL slice of https://wiki.pokealliance.com/api/pokemon, downloaded
  # 2026-08-25 — it pins the API's shape the way the old HTML fixtures pinned
  # the wiki's markup.
  defp raw, do: "test/fixtures/pokedex/api_index.json" |> File.read!() |> JSON.decode!()

  defp entry(name), do: Enum.find(Index.parse(raw()), &(&1.name == name))

  describe "parse/1" do
    test "a normal species carries its number, generation and level as integers" do
      bulbasaur = entry("Bulbasaur")

      assert bulbasaur.number == 1
      assert bulbasaur.generation == 1
      assert bulbasaur.level == 1
      assert bulbasaur.variant == "normal"
      assert bulbasaur.path == "gen/1/001_bulbasaur"
      assert bulbasaur.image == "/pokemon/001.png"
    end

    test "elements arrive capitalised, the way the rest of the app spells them" do
      assert entry("Bulbasaur").elements == ["Grass", "Poison"]
    end

    test "a shiny is marked as one and shares its base form's number" do
      shiny = entry("Shiny Bulbasaur")

      assert shiny.variant == "shiny"
      assert shiny.number == 1
      assert shiny.image == "/pokemon/001.1.png"
    end

    test "the tier shown is the display one, so an ULTIMATE reads as ULTIMATE" do
      assert entry("Mewtwo").tier == "ULTIMATE"
      assert entry("Groudon").tier == "Legendary"
    end

    test "a missing tier or role is nil, never the string None" do
      unown = entry("Unown A")

      assert unown.tier == nil
      assert unown.role == nil
    end

    test "every parsed entry has a name and a path" do
      entries = Index.parse(raw())

      assert length(entries) == 8
      assert Enum.all?(entries, &(is_binary(&1.name) and is_binary(&1.path)))
    end
  end

  describe "element_icons/1" do
    test "maps each capitalised element to the icon the API points at" do
      icons = Index.element_icons(raw())

      assert icons["Grass"] == "/elements/4.png"
      assert icons["Poison"] == "/elements/8.png"
    end
  end
end
```

- [ ] **Step 3: Run it to verify it fails**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix test test/pokex/pokedex/index_test.exs`
Expected: FAIL — `function Pokex.Pokedex.Index.parse/1 is undefined`

- [ ] **Step 4: Write Index**

Create `lib/pokex/pokedex/index.ex`:

```elixir
defmodule Pokex.Pokedex.Index do
  @moduledoc """
  The Poké Alliance's `/api/pokemon` payload → one entry per species.

  Pure: it takes ALREADY-DECODED JSON so the whole shape can be pinned against
  a real slice in a fixture, with no network in the test.

  The index — not `/api/pages` — is the base's source of truth. Of the 914
  species-looking paths the wiki lists, four are not species at all
  (`gen/2/flower`, `gen/2/lava_hole`, `gen/2/spider_egg`, `gen/4/model`) and
  the index leaves them out.
  """

  @doc """
  One entry per species: `%{path, name, number, generation, variant, level,
  tier, role, elements, image}`.

  `tier` is the DISPLAY tier — 27 species read `1` in `tier` and `ULTIMATE`
  in `displayTier`, and ULTIMATE is what the wiki's own filter offers. The
  string `"None"` and a null role both come back as nil.
  """
  def parse(%{"pokemon" => list}) when is_list(list), do: Enum.map(list, &entry/1)
  def parse(_unrecognized), do: []

  @doc "Element name → the icon path the API serves it at, for the sprite pass."
  def element_icons(%{"pokemon" => list}) when is_list(list) do
    for species <- list, element <- species["elements"] || [], into: %{} do
      {capitalize(element["name"]), element["icon"]}
    end
  end

  def element_icons(_unrecognized), do: %{}

  defp entry(map) do
    %{
      path: map["path"],
      name: map["name"],
      number: to_integer(map["number"]),
      generation: to_integer(map["generation"]),
      variant: map["variant"],
      level: to_integer(map["level"]),
      tier: present(map["displayTier"]),
      role: present(map["role"]),
      elements: Enum.map(map["elements"] || [], &capitalize(&1["name"])),
      image: map["image"]
    }
  end

  # The API writes numbers both ways — `"001"` for the pokédex number, a bare
  # integer for the level.
  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp to_integer(_absent), do: nil

  # "None" is how the API spells an absent tier; it is not a tier.
  defp present(value) when is_binary(value) and value not in ["", "None"], do: value
  defp present(value) when is_integer(value), do: Integer.to_string(value)
  defp present(_absent), do: nil

  defp capitalize(nil), do: nil
  defp capitalize(name), do: String.capitalize(name)
end
```

- [ ] **Step 5: Run the Index tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex/pokedex/index_test.exs`
Expected: PASS, 7 tests.

- [ ] **Step 6: Write the failing test for PageParser**

Create `test/pokex/pokedex/page_parser_test.exs`:

```elixir
defmodule Pokex.Pokedex.PageParserTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.PageParser

  # REAL pages from https://wiki.pokealliance.com/api/page/..., downloaded
  # 2026-08-25. Every one of them is the `pokemon-v4` template, which was the
  # template on 40 out of 40 sampled pages — these break loudly if it moves.
  defp parsed(name) do
    {:ok, attributes} =
      "test/fixtures/pokedex/#{name}.json"
      |> File.read!()
      |> JSON.decode!()
      |> Map.fetch!("content")
      |> PageParser.parse()

    attributes
  end

  describe "parse/1 — a complete page" do
    test "reads the four basic-information numbers" do
      bulbasaur = parsed("bulbasaur")

      assert bulbasaur.hp == 600
      assert bulbasaur.experience == 900
      assert bulbasaur.level == 1
      assert bulbasaur.tier == "6"
      assert bulbasaur.role == "PVE"
    end

    test "reads the pokédex description" do
      assert parsed("bulbasaur").description =~ "strange seed was planted"
    end

    test "reads every move slot with its cooldown in seconds and its own element" do
      moves = parsed("bulbasaur").moves

      assert length(moves) == 8
      assert %{slot: "M1", name: "Tackle", cooldown_s: 12, element: "Normal"} = hd(moves)
      assert %{slot: "M2", name: "Razor Leaf", cooldown_s: 10, element: "Grass"} = Enum.at(moves, 1)
    end

    test "reads the field abilities" do
      assert parsed("bulbasaur").habilidades == ["Cut", "Strength", "Headbutt"]
    end

    test "reads what it evolves into, with the level and the items the evolution asks for" do
      assert [%{name: "Ivysaur", level: 40, items: ["Leaf Stone"]}] = parsed("bulbasaur").evolves_to
    end
  end

  describe "parse/1 — pages missing sections" do
    test "a page with no moves table reports no moves instead of failing" do
      assert parsed("groudon").moves == []
    end

    test "a page with no abilities reports an empty list" do
      assert parsed("shiny_rattata").habilidades == []
    end

    test "the placeholder description reads as no description at all" do
      assert parsed("mewtwo").description == nil
    end

    test "a species with nothing to evolve into carries empty evolution lists" do
      mewtwo = parsed("mewtwo")

      assert mewtwo.evolves_to == []
      assert mewtwo.evolves_from == []
    end

    test "a shiny still reports its own numbers" do
      shiny = parsed("shiny_rattata")

      assert is_integer(shiny.hp)
      assert is_integer(shiny.level)
    end
  end

  describe "parse/1 — a page that is not a species" do
    test "html without the basic-information table is unrecognized" do
      assert PageParser.parse("<div><h1>Boost</h1><p>texto</p></div>") == {:error, :unrecognized}
    end

    test "an empty body is unrecognized" do
      assert PageParser.parse("") == {:error, :unrecognized}
    end
  end
end
```

- [ ] **Step 7: Run it to verify it fails**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix test test/pokex/pokedex/page_parser_test.exs`
Expected: FAIL — `function Pokex.Pokedex.PageParser.parse/1 is undefined`

- [ ] **Step 8: Write PageParser**

Create `lib/pokex/pokedex/page_parser.ex`:

```elixir
defmodule Pokex.Pokedex.PageParser do
  @moduledoc """
  The Poké Alliance species page (`/api/page/<path>` → `content`) → attributes.

  The markup is machine-generated from one template — `data-wiki-template="pokemon-v4"`
  on 40 of 40 pages sampled on 25/08 — with inline styles and no classes to
  anchor on. Targeted regexes beat a full HTML parser here: same reasoning the
  PokeXGames scraper used, plus real pages pinned in fixtures so a template
  change breaks in tests instead of in data.

  Sections are genuinely optional on the live wiki: 4 pages in 10 have no
  Habilidades, 1 in 10 has no moves table (Groudon), 1 in 10 has no description.
  An absent section is `nil`/`[]`, never an error. Only a page with no
  "Informações Básicas" is `{:error, :unrecognized}` — that is a wiki page
  that is not a species.
  """

  @doc """
  `{:ok, %{description, hp, experience, level, tier, role, habilidades, moves,
  evolves_to, evolves_from}}`, or `{:error, :unrecognized}`.
  """
  def parse(html) when is_binary(html) do
    case basic_info(html) do
      nil ->
        {:error, :unrecognized}

      info ->
        {:ok,
         %{
           description: description(html),
           hp: info["HP"],
           experience: info["Experiência"],
           level: info["Nível necessário"],
           tier: tier(info),
           role: role(html),
           habilidades: habilidades(html),
           moves: moves(html),
           evolves_to: evolutions(html, "Pode evoluir para"),
           evolves_from: evolutions(html, "Evolui de")
         }}
    end
  end

  def parse(_not_html), do: {:error, :unrecognized}

  # The table is `<td>❤️ HP</td><td><strong>600</strong></td>` — the emoji and
  # the whitespace vary, the label and the bolded value do not.
  defp basic_info(html) do
    rows =
      ~r{<td[^>]*>[^<]*?([A-Za-zÀ-ÿ][A-Za-zÀ-ÿ ]+?)\s*</td>\s*<td[^>]*><strong>\s*([^<]+?)\s*</strong>}
      |> Regex.scan(html)
      |> Map.new(fn [_all, label, value] -> {String.trim(label), value} end)

    if Map.has_key?(rows, "HP"), do: numeric_values(rows)
  end

  # HP, experience and level are counts; tier and role are labels.
  defp numeric_values(rows) do
    Map.new(rows, fn
      {label, value} when label in ["HP", "Experiência", "Nível necessário"] ->
        {label, to_integer(value)}

      {label, value} ->
        {label, value}
    end)
  end

  defp tier(info) do
    case info["Tier"] do
      value when is_binary(value) and value not in ["", "None"] -> value
      _absent -> nil
    end
  end

  defp role(html) do
    case Regex.run(~r{Função\s*</td>\s*<td[^>]*><strong>\s*([^<]+?)\s*</strong>}, html) do
      [_all, value] when value not in ["", "None"] -> value
      _absent -> nil
    end
  end

  # "No description." is the template's own placeholder, not a description.
  defp description(html) do
    with [_all, section] <- Regex.run(~r{Descrição da Pokédex.*?<p[^>]*>(.*?)</p>}s, html),
         text when text != "" and text != "No description." <- strip_tags(section) do
      text
    else
      _absent -> nil
    end
  end

  defp habilidades(html) do
    case Regex.run(~r{Habilidades</h2>(.*?)</div>\s*</div>}s, html) do
      [_all, section] ->
        ~r{border-radius: 999px[^>]*>([^<]+)</span>}
        |> Regex.scan(section)
        |> Enum.map(fn [_all, name] -> String.trim(name) end)

      _absent ->
        []
    end
  end

  # One row per slot: `<td><strong>M1</strong></td><td><strong>Tackle</strong></td>
  # <td>12s</td><td><img alt="normal" …/></td>`.
  defp moves(html) do
    case Regex.run(~r{Ataques &amp; Magias(.*?)</table>}s, html) do
      [_all, section] ->
        ~r{<td[^>]*><strong>(M\d+|P)</strong></td>\s*<td[^>]*><strong>([^<]+)</strong></td>\s*<td[^>]*>\s*(\d+)s\s*</td>\s*<td[^>]*>(.*?)</td>}s
        |> Regex.scan(section)
        |> Enum.map(fn [_all, slot, name, cooldown, element_cell] ->
          %{
            slot: slot,
            name: String.trim(name),
            cooldown_s: to_integer(cooldown),
            element: element_of(element_cell)
          }
        end)

      _absent ->
        []
    end
  end

  # Each evolution card holds two linked forms, the level and the item chips.
  # `heading` picks the direction: the same card markup appears under both
  # "Evolui de" and "Pode evoluir para".
  defp evolutions(html, heading) do
    case Regex.run(~r{#{Regex.escape(heading)}</h3>(.*?)(?:<h3|<!-- pokemon-evolution:end)}s, html) do
      [_all, section] ->
        section
        |> String.split(~r{<div style="background: rgba\(7, 13, 27}, trim: true)
        |> Enum.map(&evolution_card/1)
        |> Enum.reject(&is_nil/1)

      _absent ->
        []
    end
  end

  defp evolution_card(card) do
    names = Regex.scan(~r{<strong[^>]*>([^<]+)</strong></a>}, card)

    case List.last(names) do
      [_all, name] ->
        %{
          name: String.trim(name),
          level: card |> capture(~r{Level do Pokémon:\s*<strong[^>]*>\s*(\d+)}) |> to_integer(),
          items: items(card)
        }

      nil ->
        nil
    end
  end

  defp items(card) do
    ~r{<span style="display: inline-flex; align-items: center; height: 30px[^>]*>([^<]+)</span>}
    |> Regex.scan(card)
    |> Enum.map(fn [_all, item] -> String.trim(item) end)
  end

  defp element_of(cell) do
    case Regex.run(~r{alt="([a-z]+)"}, cell) do
      [_all, element] -> String.capitalize(element)
      _absent -> nil
    end
  end

  defp capture(text, regex) do
    case Regex.run(regex, text) do
      [_all, value] -> value
      _absent -> nil
    end
  end

  defp to_integer(nil), do: nil

  defp to_integer(value) when is_binary(value) do
    case value |> String.replace(~r/[^\d]/, "") |> Integer.parse() do
      {number, _rest} -> number
      :error -> nil
    end
  end

  defp strip_tags(html), do: html |> String.replace(~r/<[^>]+>/, "") |> String.trim()
end
```

- [ ] **Step 9: Run the PageParser tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex/pokedex/page_parser_test.exs`
Expected: PASS, 12 tests.

Se um regex de seção falhar, imprima a fixture e ajuste o padrão contra o HTML REAL — nunca ajuste o teste para aceitar `nil`:

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && python3 -c "
import json; print(json.load(open('test/fixtures/pokedex/bulbasaur.json'))['content'])" | head -60
```

- [ ] **Step 10: Write Api**

Não tem teste próprio — é IO puro, sem lógica; o que ele devolve já está preso nas fixtures de `Index` e `PageParser`. Create `lib/pokex/pokedex/api.ex`:

```elixir
defmodule Pokex.Pokedex.Api do
  @moduledoc """
  The Poké Alliance wiki's HTTP surface, and the only module in the app that
  knows a URL.

  Two routes carry the whole Pokédex: `/api/pokemon` (the index, 910 species)
  and `/api/page/<path>` (one species, `{content, path}`). The origin lives in
  config (`:wiki_base`) — the one place the specific server is named.

  Errors come back as `{:error, term}`. Nothing raises: a sync that loses one
  page keeps the other 909.
  """

  @doc "The wiki origin, e.g. `https://wiki.pokealliance.com`."
  def base, do: Application.get_env(:pokex, :wiki_base)

  @doc "The decoded `/api/pokemon` payload — feed it to `Pokex.Pokedex.Index`."
  def index do
    with {:ok, body} <- get("/api/pokemon"),
         {:ok, json} <- JSON.decode(body) do
      {:ok, json}
    end
  end

  @doc "One species page's HTML — feed it to `Pokex.Pokedex.PageParser`."
  def page(path) when is_binary(path) do
    with {:ok, body} <- get("/api/page/" <> path),
         {:ok, %{"content" => content}} when is_binary(content) <- JSON.decode(body) do
      {:ok, content}
    else
      {:ok, _no_content} -> {:error, :no_content}
      error -> error
    end
  end

  @doc "A sprite or icon's bytes, by the path the API points at (`/pokemon/001.png`)."
  def asset(path) when is_binary(path), do: get(path)

  defp get(path) do
    case Req.get(base() <> path, retry: :transient, max_retries: 2) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 200, body: body}} when is_map(body) -> {:ok, JSON.encode!(body)}
      other -> {:error, other}
    end
  end
end
```

- [ ] **Step 11: Point the config at the Poké Alliance**

Modify `config/config.exs:20`. Replace:

```elixir
  wiki_base: "https://wiki.pokexgames.com"
```

with:

```elixir
  wiki_base: "https://wiki.pokealliance.com"
```

- [ ] **Step 12: Run the full suite**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix precommit`
Expected: PASS. O `Sync` ainda aponta pro caminho velho, mas nada nos testes bate na rede — `sync_test.exs` só exercita funções puras.

Se `scraper_test.exs` quebrar por causa do `wiki_base`, é porque ele monta URL — nesse caso deixe o teste como está e siga; ele morre na Task 3.

- [ ] **Step 13: Commit and push**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add lib/pokex/pokedex/api.ex lib/pokex/pokedex/index.ex lib/pokex/pokedex/page_parser.ex test/pokex/pokedex/index_test.exs test/pokex/pokedex/page_parser_test.exs test/fixtures/pokedex/ config/config.exs && git commit -m "a wiki do PA é uma API, então o extrator vira três módulos e um cliente

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance
```

---

## Task 3: Upsert, Sync reescrito, e a base trocada

O único ponto em que a base troca. Se der errado, o revert é de um commit.

**Files:**
- Create: `lib/pokex/pokedex/upsert.ex`, `lib/mix/tasks/pokedex.sync.ex`
- Modify: `lib/pokex/pokedex/sync.ex` (reescrita completa)
- Delete: `lib/mix/tasks/pokedex.scrape.ex`, `lib/pokex/pokedex/scraper.ex`, `test/pokex/pokedex/scraper_test.exs`, `test/fixtures/pokedex/*.html`
- Modify: `test/pokex/pokedex/sync_test.exs`
- Test: `test/pokex/pokedex/upsert_test.exs`

**Interfaces:**
- Consumes: `Api.index/0`, `Api.page/1`, `Api.asset/1`, `Index.parse/1`, `Index.element_icons/1`, `PageParser.parse/1` (Task 2).
- Produces:
  - `Upsert.merge(existing :: [map], fresh :: [map]) :: [map]`
  - `Sync.run(opts, progress) :: {:ok, %{updated: integer, base: integer, shinies: integer, failed: integer}}`
  - `Sync.start(opts) :: :ok | {:error, :already_running}`, `Sync.running?/0`, `Sync.topic/0` — inalterados

- [ ] **Step 1: Write the failing test for Upsert**

Create `test/pokex/pokedex/upsert_test.exs`:

```elixir
defmodule Pokex.Pokedex.UpsertTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Upsert

  defp entry(name, extra \\ %{}) do
    Map.merge(
      %{
        name: name,
        number: 1,
        level: 10,
        elements: ["Water"],
        scraped_at: "2026-08-25T10:00:00Z"
      },
      extra
    )
  end

  describe "merge/2 — the bookkeeping stamps" do
    test "a brand-new entry gets first_seen_at and changed_at from the current sync" do
      [seadra] = Upsert.merge([], [entry("Seadra")])

      assert seadra.first_seen_at == "2026-08-25T10:00:00Z"
      assert seadra.changed_at == "2026-08-25T10:00:00Z"
    end

    test "a re-sync with no content change preserves both dates" do
      [old] = Upsert.merge([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Upsert.merge([old_json], [entry("Seadra", %{scraped_at: "2026-08-26T10:00:00Z"})])

      assert again.first_seen_at == "2026-08-25T10:00:00Z"
      assert again.changed_at == "2026-08-25T10:00:00Z"
    end

    test "a changed field moves changed_at forward but not first_seen_at" do
      [old] = Upsert.merge([], [entry("Seadra")])
      old_json = old |> JSON.encode!() |> JSON.decode!()

      [again] =
        Upsert.merge([old_json], [
          entry("Seadra", %{level: 55, scraped_at: "2026-08-26T10:00:00Z"})
        ])

      assert again.first_seen_at == "2026-08-25T10:00:00Z"
      assert again.changed_at == "2026-08-26T10:00:00Z"
    end
  end

  describe "merge/2 — what survives a partial run" do
    test "an entry this run did not fetch stays in the base untouched" do
      existing = [%{"name" => "Horsea", "level" => 20}]

      merged = Upsert.merge(existing, [entry("Seadra")])

      assert length(merged) == 2
      assert Enum.any?(merged, &(Map.get(&1, "name") == "Horsea"))
    end

    test "a freshly fetched entry replaces its own older version, never duplicates it" do
      existing = [%{"name" => "Seadra", "level" => 20, "scraped_at" => "2026-08-01T10:00:00Z"}]

      merged = Upsert.merge(existing, [entry("Seadra", %{level: 50})])

      assert [%{name: "Seadra", level: 50}] = merged
    end
  end
end
```

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix test test/pokex/pokedex/upsert_test.exs`
Expected: FAIL — `function Pokex.Pokedex.Upsert.merge/2 is undefined`

- [ ] **Step 3: Write Upsert**

Create `lib/pokex/pokedex/upsert.ex` — a lógica vem intacta de `Scraper.upsert/2`, que já era pura e testada:

```elixir
defmodule Pokex.Pokedex.Upsert do
  @moduledoc """
  Merging a sync's harvest into the base on disk, with the two dates the app
  keeps about each entry: when it ENTERED the base (`first_seen_at`) and when
  its content last actually changed (`changed_at`).

  Every run upserts: freshly fetched entries replace their names, everything
  else stays. That is what makes `--only Seadra` safe — it refreshes one
  species without dropping the other 909.
  """

  @doc "The base on disk plus this run's harvest, stamped."
  def merge(existing, fresh) do
    by_name = Map.new(existing, &{entry_name(&1), &1})
    fresh_names = MapSet.new(fresh, & &1.name)

    stamped = Enum.map(fresh, &stamp(&1, Map.get(by_name, &1.name)))

    Enum.reject(existing, &MapSet.member?(fresh_names, entry_name(&1))) ++ stamped
  end

  # Volatile/bookkeeping keys never count as a content change.
  @bookkeeping ~w(scraped_at first_seen_at changed_at)

  defp stamp(fresh, previous) do
    case Map.get(fresh, :scraped_at) do
      nil ->
        fresh

      now ->
        changed_at =
          cond do
            previous == nil -> now
            content(fresh) == content(previous) -> field(previous, "changed_at") || now
            true -> now
          end

        Map.merge(fresh, %{
          first_seen_at: (previous && field(previous, "first_seen_at")) || now,
          changed_at: changed_at
        })
    end
  end

  # Compare on STRING keys with the bookkeeping dropped: existing entries come
  # from JSON, fresh ones are atom-keyed maps — round-tripping the fresh one
  # through JSON makes the two directly comparable.
  defp content(entry) do
    entry
    |> JSON.encode!()
    |> JSON.decode!()
    |> Map.drop(@bookkeeping)
  end

  defp entry_name(entry), do: field(entry, "name")

  defp field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))
end
```

- [ ] **Step 4: Run the Upsert tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex/pokedex/upsert_test.exs`
Expected: PASS, 5 tests.

- [ ] **Step 5: Rewrite Sync**

Replace the whole of `lib/pokex/pokedex/sync.ex` with:

```elixir
defmodule Pokex.Pokedex.Sync do
  @moduledoc """
  The one sync pipeline, shared by `mix pokedex.sync` (terminal) and the
  /pokedex "Sincronizar" button (UI): the Poké Alliance index, one page per
  species, sprites into priv/static/images/pokedex/, and an UPSERT into
  priv/pokedex/pokedex.json.

  `run/2` is synchronous and reports through the injected `progress` callback
  (the mix task prints, the UI broadcasts). `start/1` is the UI entry: ONE
  async sync at a time (registered name), progress + completion broadcast on
  the "pokedex_sync" PubSub topic, and the in-memory dataset reloaded on done
  — no server restart needed.

  ## No gap pass

  The PokeXGames pipeline ended every run re-scraping entries with no moveset,
  because its regexes missed headings and left 202 of 866 entries silently
  empty. The PA serves one machine-generated template, where an absent moves
  table is the truth about that species (Groudon has none). A page that fails
  to FETCH simply does not update its entry — the upsert keeps the old one —
  and the count comes back in the summary as `failed`.

  Network-bound and polite (delay between fetches) — safe to run alongside the
  bots; sprite downloads skip files that already exist.
  """

  alias Pokex.Pokedex
  alias Pokex.Pokedex.{Api, Index, PageParser, Upsert}

  @topic "pokedex_sync"
  @process_name :pokedex_sync

  def topic, do: @topic

  @doc "True while a UI-started sync is in flight."
  def running?, do: Process.whereis(@process_name) != nil

  @doc """
  Starts ONE async sync (`:ok` | `{:error, :already_running}`). Progress,
  completion and failure are broadcast on `topic/0`; on completion the
  Pokédex dataset is reloaded in place.
  """
  def start(opts \\ []) do
    if running?() do
      {:error, :already_running}
    else
      {:ok, _pid} =
        Task.start(fn ->
          # atomic take-the-slot: a concurrent second click raises here and
          # dies silently — the first sync keeps running untouched
          try do
            Process.register(self(), @process_name)
          rescue
            ArgumentError -> exit(:normal)
          end

          try do
            {:ok, summary} = run(opts, &broadcast({:progress, &1}))
            Pokedex.reload()
            broadcast({:done, summary})
          catch
            kind, reason -> broadcast({:failed, Exception.format(kind, reason, [])})
          end
        end)

      :ok
    end
  end

  @doc """
  The synchronous pipeline. Options: `:only` ("Seadra,Horsea"), `:fresh`,
  `:limit`, `:delay_ms` (default 120), `:skip_sprites`. Returns
  `{:ok, %{updated, base, shinies, failed}}`.
  """
  def run(opts, progress) when is_function(progress, 1) do
    delay = opts[:delay_ms] || 120

    progress.("índice de espécies…")
    {:ok, raw_index} = Api.index()
    index = Index.parse(raw_index)
    progress.("#{length(index)} espécies no índice")

    targets = narrow_to_only(index, opts[:only], progress)
    targets = if opts[:limit], do: Enum.take(targets, opts[:limit]), else: targets
    total = length(targets)
    scraped_at = DateTime.utc_now() |> DateTime.to_iso8601()

    results =
      targets
      |> Enum.with_index(1)
      |> Enum.map(fn {target, i} ->
        if rem(i, 25) == 0 or i == total, do: progress.("#{i}/#{total} #{target.name}")
        Process.sleep(delay)
        harvest(target, opts, scraped_at, progress)
      end)

    species = Enum.reject(results, &is_nil/1)
    failed = total - length(species)

    merged = if opts[:fresh], do: species, else: Upsert.merge(existing_species(), species)
    merged = link_shinies(merged)
    save_element_icons(raw_index, opts, progress)

    File.mkdir_p!(out_dir())

    json = %{scraped_at: scraped_at, base: Api.base(), species: merged}
    File.write!(Path.join(out_dir(), "pokedex.json"), JSON.encode!(json))

    {:ok,
     %{
       updated: length(species),
       base: length(merged),
       shinies: Enum.count(merged, &shiny_entry?/1),
       failed: failed
     }}
  end

  # One species: the index row carries identity and stats, the page carries the
  # prose, the moves and the evolutions. A page that fails leaves the entry
  # alone rather than writing a half-entry over a good one.
  defp harvest(target, opts, scraped_at, progress) do
    with {:ok, html} <- Api.page(target.path),
         {:ok, page} <- PageParser.parse(html) do
      to_entry(target, page, opts, scraped_at)
    else
      _fetch_or_parse_error ->
        progress.("! falhou: #{target.name} (#{target.path})")
        nil
    end
  end

  defp to_entry(target, page, opts, scraped_at) do
    %{
      name: target.name,
      number: target.number,
      generation: target.generation,
      variant: target.variant,
      # filled by link_shinies/1 once the whole harvest is in hand
      shiny_of: nil,
      # the index's level is the one the wiki filters by; the page repeats it
      level: target.level || page.level,
      tier: target.tier || page.tier,
      role: target.role || page.role,
      hp: page.hp,
      experience: page.experience,
      elements: target.elements,
      habilidades: page.habilidades,
      description: page.description,
      moves: page.moves,
      evolves_to: page.evolves_to,
      evolves_from: page.evolves_from,
      sprite: download_sprite(target.image, opts),
      path: target.path,
      scraped_at: scraped_at
    }
  end

  # A shiny points at the normal form sharing its number. Done AFTER the merge
  # so a `--only Shiny Rattata` run still links against the base on disk.
  defp link_shinies(species) do
    normals =
      for entry <- species,
          field(entry, "variant") == "normal",
          into: %{},
          do: {field(entry, "number"), field(entry, "name")}

    Enum.map(species, fn entry ->
      if field(entry, "variant") == "shiny" do
        put_field(entry, "shiny_of", Map.get(normals, field(entry, "number")))
      else
        entry
      end
    end)
  end

  # The wiki's own type icons, one small PNG per element, cached under
  # priv/static/images/pokedex/elements/ so the UI can show them instead of
  # plain words. Best-effort: a failed download leaves the coloured text chip.
  defp save_element_icons(raw_index, opts, progress) do
    if opts[:skip_sprites] do
      :ok
    else
      icons = Index.element_icons(raw_index)
      dir = Path.join(sprites_dir(), "elements")
      File.mkdir_p!(dir)

      Enum.each(icons, fn {element, url} ->
        fetch_asset(url, Path.join(dir, String.downcase(element) <> ".png"))
      end)

      progress.("ícones de elemento: #{map_size(icons)}")
    end
  end

  # skip_sprites must mean "don't FETCH", never "forget": a --fresh
  # --skip-sprites run once nulled the sprite of every entry in the base and
  # 824 paths had to be restored by hand. What is on disk stays claimed.
  @doc false
  def download_sprite(nil, _opts), do: nil

  def download_sprite(url, opts) do
    file = Path.basename(url)
    dest = Path.join(sprites_dir(), file)

    unless opts[:skip_sprites] do
      File.mkdir_p!(sprites_dir())
      fetch_asset(url, dest)
    end

    if File.exists?(dest), do: "images/pokedex/" <> file
  end

  # What is on disk is never fetched again — the sync is resumable.
  defp fetch_asset(url, dest) do
    if File.exists?(dest) do
      :skip
    else
      case Api.asset(url) do
        {:ok, body} -> File.write!(dest, body)
        _error -> :skip
      end
    end
  end

  # --only "Seadra,Horsea": sync just these; unknown names are reported, never
  # silently dropped.
  defp narrow_to_only(targets, only, _progress) when only in [nil, ""], do: targets

  defp narrow_to_only(targets, only, progress) do
    wanted = only |> String.split(",") |> Enum.map(&(&1 |> String.trim() |> String.downcase()))
    narrowed = Enum.filter(targets, &(String.downcase(&1.name) in wanted))

    missing = wanted -- Enum.map(narrowed, &String.downcase(&1.name))
    if missing != [], do: progress.("! não achei no índice: #{Enum.join(missing, ", ")}")

    narrowed
  end

  defp existing_species do
    with {:ok, bin} <- File.read(Path.join(out_dir(), "pokedex.json")),
         {:ok, %{"species" => species}} when is_list(species) <- JSON.decode(bin) do
      species
    else
      _missing_or_corrupt -> []
    end
  end

  defp broadcast(event),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:pokedex_sync, event})

  defp shiny_entry?(entry), do: field(entry, "variant") == "shiny"

  defp field(entry, key) when is_map(entry),
    do: Map.get(entry, key) || Map.get(entry, String.to_existing_atom(key))

  defp put_field(entry, key, value) do
    if Map.has_key?(entry, key),
      do: Map.put(entry, key, value),
      else: Map.put(entry, String.to_existing_atom(key), value)
  end

  # Relative to the repo root — where both `mix pokedex.sync` and the dev
  # server run from (dev-only tooling; priv/ is symlinked into _build).
  defp out_dir, do: "priv/pokedex"

  defp sprites_dir,
    do: Application.get_env(:pokex, :pokedex_sprites_dir, "priv/static/images/pokedex")
end
```

- [ ] **Step 6: Replace the mix task**

Delete `lib/mix/tasks/pokedex.scrape.ex` and create `lib/mix/tasks/pokedex.sync.ex`:

```elixir
defmodule Mix.Tasks.Pokedex.Sync do
  @shortdoc "Syncs the Poké Alliance wiki into priv/pokedex/pokedex.json (+ sprites)"

  @moduledoc """
  Terminal wrapper around `Pokex.Pokedex.Sync` (the /pokedex "Sincronizar"
  button runs the same pipeline). Every run UPSERTS: freshly fetched entries
  replace their names in the existing pokedex.json, everything else stays.

  Deliberately does NOT boot the :pokex app (only :req) — running a sync
  from the terminal must never start the bot's workers against the real
  mouse/screen.

      mix pokedex.sync                        # full run (910 species, be nice to the wiki)
      mix pokedex.sync --only "Seadra,Horsea" # refresh just these
      mix pokedex.sync --fresh                # ignore the existing JSON (full rebuild)
      mix pokedex.sync --limit 20             # first N species (pipeline check)
      mix pokedex.sync --delay-ms 400         # slower pace
      mix pokedex.sync --skip-sprites         # JSON only
  """

  use Mix.Task

  alias Pokex.Pokedex.Sync

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          delay_ms: :integer,
          skip_sprites: :boolean,
          only: :string,
          fresh: :boolean
        ]
      )

    {:ok, _apps} = Application.ensure_all_started(:req)

    {:ok, summary} = Sync.run(opts, fn text -> Mix.shell().info(text) end)

    Mix.shell().info(
      "pronto: #{summary.updated} atualizadas nesta rodada, " <>
        "#{summary.base} na base (#{summary.shinies} shinies)" <>
        if(summary.failed > 0, do: ", #{summary.failed} falharam", else: "") <>
        " — priv/pokedex/pokedex.json"
    )
  end
end
```

- [ ] **Step 7: Delete the PokeXGames extractor and its fixtures**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git rm -q lib/pokex/pokedex/scraper.ex test/pokex/pokedex/scraper_test.exs lib/mix/tasks/pokedex.scrape.ex test/fixtures/pokedex/fishing_slice.html test/fixtures/pokedex/florges.html test/fixtures/pokedex/index_slice.html test/fixtures/pokedex/sceptile.html test/fixtures/pokedex/seadra.html test/fixtures/pokedex/venusaur.html
```

- [ ] **Step 8: Cut the gap-pass tests from sync_test**

`test/pokex/pokedex/sync_test.exs` tests `Sync.incomplete/2`, which no longer exists. Open it and delete every `describe`/`test` block that names `incomplete` or `fill_gaps`. Keep the ones about `download_sprite/2` and adjust their arity — the signature changed from `download_sprite(url, name, opts)` to `download_sprite(url, opts)`, and the destination file is now the basename of the URL (`/pokemon/001.png` → `images/pokedex/001.png`), not a slug of the name.

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && /usr/bin/grep -n "incomplete\|fill_gaps\|download_sprite" test/pokex/pokedex/sync_test.exs`

- [ ] **Step 9: Run the suite (the Pokédex will be red — expected)**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix compile --warnings-as-errors 2>&1 | head -40`
Expected: erros em `lib/pokex/pokedex.ex` (chama `Clans`, campos que sumiram) e nos LiveViews. **Isso é esperado** — a Task 4 conserta `Pokedex`, a Task 5 conserta as telas.

Se aparecer erro dentro de `sync.ex`, `upsert.ex`, `api.ex`, `index.ex` ou `page_parser.ex`, conserte AGORA: esses são o entregável desta task.

- [ ] **Step 10: Run the real sync**

Este é o passo que troca a base. Ele fala com a wiki de verdade e leva alguns minutos.

Primeiro um ensaio pequeno:

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && mix pokedex.sync --limit 6 --fresh
```

Expected: `pronto: 6 atualizadas nesta rodada, 6 na base (3 shinies) — priv/pokedex/pokedex.json`, e seis arquivos novos em `priv/static/images/pokedex/` (`001.png`, `001.1.png`, …).

Confira o formato antes de gastar a rodada inteira:

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && python3 -c "
import json
d = json.load(open('priv/pokedex/pokedex.json'))
print('base:', d['base'])
b = d['species'][0]
print(json.dumps({k: b[k] for k in ['name','number','generation','variant','shiny_of','level','tier','role','hp','experience','elements','sprite','path']}, ensure_ascii=False, indent=2))
print('moves:', len(b['moves']), '| evolves_to:', b['evolves_to'], '| habilidades:', b['habilidades'])
"
```

Expected: `base: https://wiki.pokealliance.com`, Bulbasaur com `tier: "6"`, `hp: 600`, `experience: 900`, 8 moves, e `evolves_to` com Ivysaur/level 40/Leaf Stone.

Se algum campo vier `null` que não deveria, o defeito está no `PageParser` — volte à Task 2 Step 9 e ajuste contra a fixture antes de rodar tudo.

Com o formato conferido, a rodada inteira:

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && mix pokedex.sync --fresh
```

Expected: `pronto: 910 atualizadas nesta rodada, 910 na base (384 shinies) — priv/pokedex/pokedex.json`. `failed` deve ser 0; se for mais que 5, pare e investigue antes de commitar.

- [ ] **Step 11: Delete the PokeXGames sprites**

Os sprites do PA entraram com nome numérico (`001.png`); os do PXG têm nome de slug (`bulbasaur.gif`). Nada mais aponta pros antigos.

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && \
ls priv/static/images/pokedex/*.gif | wc -l && \
git rm -q priv/static/images/pokedex/*.gif && \
git rm -q $(git ls-files 'priv/static/images/pokedex/*.png' | /usr/bin/grep -v '/[0-9]') && \
du -sh priv/static/images/pokedex
```

Expected: 428 gifs listados antes de apagar; a pasta fica com ~23 MB.

- [ ] **Step 12: Commit and push**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add -A && git commit -m "a base troca de jogo: 910 espécies do Poké Alliance no lugar de 866 do PXG

O Scraper e o gap pass morrem juntos. O gap pass existia porque as regexes
do MediaWiki perdiam cabeçalho e deixavam 202 de 866 entradas vazias em
silêncio; o template do PA é um só, e tabela de moves ausente é a verdade
sobre a espécie (Groudon não tem). Página que falha ao buscar não escreve
meia-entrada em cima de uma boa — o upsert mantém a antiga e a contagem
volta no summary.

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance
```

---

## Task 4: Pokedex enxuto, efetividade derivada, filtros novos

**Files:**
- Modify: `lib/pokex/pokedex.ex`
- Modify: `lib/pokex/pokedex/team.ex` (uma linha)
- Delete: `lib/pokex/pokedex/clans.ex`, `test/pokex/pokedex/clans_test.exs`
- Modify: `test/pokex/pokedex_test.exs`

**Interfaces:**
- Consumes: `TypeChart.weak_to/1`, `resists/1`, `immune/1`, `neutral/1`, `effectiveness/1` (Task 1); o schema novo do JSON (Task 3).
- Produces:
  - `Pokedex.variant_of(entry, "shiny" | "normal") :: entry | nil`
  - `Pokedex.generations() :: [integer]`, `Pokedex.tiers() :: [String.t()]`, `Pokedex.roles() :: [String.t()]`
  - `Pokedex.elements() :: [String.t()]` — passa a delegar ao `TypeChart`
  - filtros: `:name, :elements, :weak_to, :generations, :tiers, :roles, :variant, :min_level, :max_level`
  - sorts: `:number` (default), `:name`, `:level`, `:element`, `:weak_to`, `:shiny`, `:tier`, `:generation`
  - some: `lures/0`, `shinies_for_lure/1`, `lures_for/1`, `novelty/2`, `novelty_days/0`, `wiki_age_days/2`

- [ ] **Step 1: Write the failing test**

Replace the `@dataset` at the top of `test/pokex/pokedex_test.exs` with the new shape, and add the new cases. The dataset:

```elixir
  @dataset %{
    "species" => [
      %{
        "name" => "Bulbasaur",
        "number" => 1,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 1,
        "tier" => "6",
        "role" => "PVE",
        "hp" => 600,
        "experience" => 900,
        "elements" => ["Grass", "Poison"],
        "habilidades" => ["Cut"],
        "moves" => [%{"slot" => "M1", "name" => "Tackle", "cooldown_s" => 12, "element" => "Normal"}],
        "evolves_to" => [%{"name" => "Ivysaur", "level" => 40, "items" => ["Leaf Stone"]}],
        "evolves_from" => [],
        "sprite" => "images/pokedex/001.png",
        "path" => "gen/1/001_bulbasaur"
      },
      %{
        "name" => "Shiny Bulbasaur",
        "number" => 1,
        "generation" => 1,
        "variant" => "shiny",
        "shiny_of" => "Bulbasaur",
        "level" => 40,
        "tier" => "5",
        "role" => "PVE",
        "hp" => 900,
        "experience" => 1800,
        "elements" => ["Grass", "Poison"],
        "habilidades" => [],
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => "images/pokedex/001.1.png",
        "path" => "shiny/001_shiny_bulbasaur"
      },
      %{
        "name" => "Charmander",
        "number" => 4,
        "generation" => 1,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 1,
        "tier" => "ULTIMATE",
        "role" => "PVE",
        "hp" => 500,
        "experience" => 800,
        "elements" => ["Fire"],
        "habilidades" => [],
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => "images/pokedex/004.png",
        "path" => "gen/1/004_charmander"
      },
      %{
        "name" => "Piplup",
        "number" => 393,
        "generation" => 4,
        "variant" => "normal",
        "shiny_of" => nil,
        "level" => 20,
        "tier" => nil,
        "role" => nil,
        "hp" => 400,
        "experience" => 600,
        "elements" => ["Water"],
        "habilidades" => [],
        "moves" => [],
        "evolves_to" => [],
        "evolves_from" => [],
        "sprite" => "images/pokedex/393.png",
        "path" => "gen/4/393_piplup"
      }
    ],
    "scraped_at" => "2026-08-25T10:00:00Z"
  }
```

Add these `describe` blocks (keep the existing setup that writes `@dataset` to a temp file and scopes `:pokedex_path`):

```elixir
  describe "effectiveness derived from the type chart" do
    test "a Grass and Poison species is weak to what the canonical chart says" do
      assert Pokedex.get("Bulbasaur").weak_to == ["Fire", "Flying", "Ice", "Psychic"]
    end

    test "the buckets come from the chart, not from the file on disk" do
      bulbasaur = Pokedex.get("Bulbasaur")

      assert "Water" in bulbasaur.resists
      assert bulbasaur.immune == []
      assert "Normal" in bulbasaur.neutral
      assert Enum.any?(bulbasaur.effectiveness, &(&1.label == "Muito Inefetivo"))
    end

    test "a shiny derives the same buckets as its base form, sharing its elements" do
      assert Pokedex.get("Shiny Bulbasaur").weak_to == Pokedex.get("Bulbasaur").weak_to
    end
  end

  describe "search/1 — the Poké Alliance axes" do
    test "filters by generation" do
      assert Pokedex.search(%{generations: [4]}) |> Enum.map(& &1.name) == ["Piplup"]
    end

    test "filters by tier, including the named ones" do
      assert Pokedex.search(%{tiers: ["ULTIMATE"]}) |> Enum.map(& &1.name) == ["Charmander"]
    end

    test "filters by role" do
      names = Pokedex.search(%{roles: ["PVE"]}) |> Enum.map(& &1.name)

      refute "Piplup" in names
      assert "Bulbasaur" in names
    end

    test "filters by variant" do
      assert Pokedex.search(%{variant: "shiny"}) |> Enum.map(& &1.name) == ["Shiny Bulbasaur"]
      refute "Shiny Bulbasaur" in (Pokedex.search(%{variant: "normal"}) |> Enum.map(& &1.name))
    end

    test "an entry with no tier survives a search that does not filter on tier" do
      assert "Piplup" in (Pokedex.search(%{}) |> Enum.map(& &1.name))
    end
  end

  describe "search/1 — sorting on the new axes" do
    test "sorting by tier puts ULTIMATE ahead of the numbered tiers" do
      assert Pokedex.search(%{sort: :tier}) |> Enum.map(& &1.name) |> hd() == "Charmander"
    end

    test "an entry with no tier sinks to the bottom in both directions" do
      assert Pokedex.search(%{sort: :tier}) |> List.last() |> Map.get(:name) == "Piplup"
      assert Pokedex.search(%{sort: :tier, desc: true}) |> List.last() |> Map.get(:name) == "Piplup"
    end

    test "sorting by generation orders ascending by default" do
      assert Pokedex.search(%{sort: :generation}) |> List.last() |> Map.get(:name) == "Piplup"
    end
  end

  describe "variant_of/2" do
    test "finds a species' shiny by the number they share" do
      assert Pokedex.variant_of(Pokedex.get("Bulbasaur"), "shiny").name == "Shiny Bulbasaur"
    end

    test "finds the base form from the shiny" do
      assert Pokedex.variant_of(Pokedex.get("Shiny Bulbasaur"), "normal").name == "Bulbasaur"
    end

    test "a species with no shiny answers nil" do
      assert Pokedex.variant_of(Pokedex.get("Charmander"), "shiny") == nil
    end
  end

  describe "the filter option lists" do
    test "generations, tiers and roles come from the dataset, sorted and deduped" do
      assert Pokedex.generations() == [1, 4]
      assert Pokedex.tiers() == ["ULTIMATE", "5", "6"]
      assert Pokedex.roles() == ["PVE"]
    end

    test "elements are the eighteen canonical ones, not just what the dataset holds" do
      assert length(Pokedex.elements()) == 18
    end
  end
```

Delete from the same file every `describe`/`test` that names `lures`, `shinies_for_lure`, `lures_for`, `novelty`, `wiki_age_days`, `edited_after`, `clans`, `materia`, `only_shiny` or the `:edited`/`:changed` sorts.

Run to find them: `cd /Users/tavano/projects/worktrees/pokedex-alliance && /usr/bin/grep -n "lure\|novelty\|wiki_age\|edited\|clan\|materia\|only_shiny" test/pokex/pokedex_test.exs`

- [ ] **Step 2: Run it to verify it fails**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix test test/pokex/pokedex_test.exs 2>&1 | tail -30`
Expected: FAIL — `Pokedex.variant_of/2 is undefined` e as buckets vindo vazias.

- [ ] **Step 3: Rewrite the loading half of Pokedex**

In `lib/pokex/pokedex.ex`:

Replace the `alias` line (`alias Pokex.Pokedex.Clans`) with:

```elixir
  alias Pokex.Pokedex.TypeChart
```

Replace `load/1` with:

```elixir
  defp load(path) do
    with {:ok, bin} <- File.read(path),
         {:ok, json} <- JSON.decode(bin) do
      %{
        species: Enum.map(json["species"] || [], &species_entry/1),
        synced_at: json["scraped_at"]
      }
    else
      _missing_or_corrupt -> %{species: [], synced_at: nil}
    end
  end
```

Replace `species_entry/1`, `move_entry/1` and delete `lure_entry/1`, `inherit_clans/1`, `normalize_elements/1`, `@element_separators` and `@element_aliases` — the PA serves one canonical spelling per element, so the five-spellings healer has nothing left to heal:

```elixir
  # The four effectiveness buckets are DERIVED here, not read: the PA wiki
  # publishes no effectiveness at all, so pokedex.json holds only what the
  # wiki said and `TypeChart` answers the rest. Correcting a chart cell is an
  # edit, not a re-sync of 910 pages.
  defp species_entry(map) do
    elements = map["elements"] || []

    %{
      name: map["name"],
      number: map["number"],
      generation: map["generation"],
      variant: map["variant"],
      shiny_of: map["shiny_of"],
      level: map["level"],
      tier: map["tier"],
      role: map["role"],
      hp: map["hp"],
      experience: map["experience"],
      elements: elements,
      habilidades: map["habilidades"] || [],
      description: map["description"],
      moves: map["moves"] && Enum.map(map["moves"], &move_entry/1),
      evolves_to: Enum.map(map["evolves_to"] || [], &evolution_entry/1),
      evolves_from: Enum.map(map["evolves_from"] || [], &evolution_entry/1),
      sprite: map["sprite"],
      path: map["path"],
      weak_to: TypeChart.weak_to(elements),
      resists: TypeChart.resists(elements),
      neutral: TypeChart.neutral(elements),
      immune: TypeChart.immune(elements),
      effectiveness: TypeChart.effectiveness(elements),
      scraped_at: map["scraped_at"],
      first_seen_at: map["first_seen_at"],
      changed_at: map["changed_at"]
    }
  end

  defp move_entry(map) do
    %{
      slot: map["slot"],
      name: map["name"],
      cooldown_s: map["cooldown_s"],
      element: map["element"]
    }
  end

  defp evolution_entry(map) do
    %{name: map["name"], level: map["level"], items: map["items"] || []}
  end
```

- [ ] **Step 4: Rewrite the query half of Pokedex**

Delete `lures/0`, `shinies_for_lure/1`, `lures_for/1`, `novelty_days/0`, `wiki_age_days/2`, `novelty/2` and the `@novelty_days` attribute.

Replace `wiki_url/1` — the PA route is the entry's own path:

```elixir
  @doc "The species' page on the wiki, or nil for an entry with no path."
  def wiki_url(%{path: path}) when is_binary(path) and path != "",
    do: Application.get_env(:pokex, :wiki_base) <> "/" <> path

  def wiki_url(_pathless), do: nil
```

Add, next to `get/1`:

```elixir
  @doc """
  The same species in the other skin: `variant_of(bulbasaur, "shiny")`.

  Asked by NUMBER and variant, which is the pairing the PA actually publishes
  — the old base carried a `shiny_name` string on the normal form, and the PA
  has no such field.
  """
  def variant_of(%{number: number}, variant) when is_integer(number) and is_binary(variant),
    do: Enum.find(species(), &(&1.number == number and &1.variant == variant))

  def variant_of(_numberless, _variant), do: nil

  @doc "Every generation in the dataset (for the filter chips)."
  def generations, do: species() |> Enum.map(& &1.generation) |> distinct_sorted()

  @doc "Every tier in the dataset, ordered the way the wiki's own filter orders them."
  def tiers,
    do: species() |> Enum.map(& &1.tier) |> distinct() |> Enum.sort_by(&tier_rank/1)

  @doc "Every role in the dataset (PVE/PVP)."
  def roles, do: species() |> Enum.map(& &1.role) |> distinct_sorted()

  defp distinct(values), do: values |> Enum.reject(&is_nil/1) |> Enum.uniq()
  defp distinct_sorted(values), do: values |> distinct() |> Enum.sort()

  # The wiki's own filter order: ULTIMATE, tiers 1-7, then the named ones.
  @tier_order ~w(ULTIMATE 1 2 3 4 5 6 7) ++ ["Super Rare", "Legendary", "Mythic", "Ultra Rare"]

  defp tier_rank(tier) do
    case Enum.find_index(@tier_order, &(&1 == tier)) do
      nil -> length(@tier_order)
      index -> index
    end
  end
```

Replace `elements/0`:

```elixir
  @doc "The eighteen elements, for the filter chips — the chart's list, not the dataset's."
  def elements, do: TypeChart.elements()
```

In the filtering section, delete the `{:clans, list}`, `{:edited_after, date}`, `{:only_novelty, true}` and `{:only_shiny, true}` clauses and add:

```elixir
  defp filter_matches?(entry, {:generations, list}) when is_list(list) and list != [] do
    entry.generation in list
  end

  defp filter_matches?(entry, {:tiers, list}) when is_list(list) and list != [] do
    entry.tier in list
  end

  defp filter_matches?(entry, {:roles, list}) when is_list(list) and list != [] do
    entry.role in list
  end

  defp filter_matches?(entry, {:variant, variant}) when is_binary(variant) and variant != "" do
    entry.variant == variant
  end
```

In `sort_key/2`, delete the `:edited` and `:changed` clauses and add, above the catch-all:

```elixir
  defp sort_key(entry, :tier), do: entry.tier && tier_rank(entry.tier)
  defp sort_key(entry, :generation), do: entry.generation
```

Update the `search/1` `@doc` to list the filters and sorts that actually exist now.

- [ ] **Step 5: Fix Team's shiny bonus**

In `lib/pokex/pokedex.ex`, inside `target_row/2`, replace:

```elixir
        lures = lures_for(target.name)
        shiny? = target.shiny_name != nil
```

with:

```elixir
        shiny? = variant_of(target, "shiny") != nil
```

and replace the score line:

```elixir
          score: base_score + if(shiny?, do: 1, else: 0) + if(lures != [], do: 1, else: 0)
```

with:

```elixir
          score: base_score + if(shiny?, do: 1, else: 0)
```

and delete `lures: lures,` from the row map. Update the `hunt_suggestions/2` `@doc` to drop "+1 when fishable".

Also change the candidate filter — `shiny_of == nil` still works, but `variant` is the field the PA publishes:

```elixir
      |> Enum.filter(&(&1.variant == "normal" and &1.name not in member_names))
```

- [ ] **Step 6: Delete Clans**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git rm -q lib/pokex/pokedex/clans.ex test/pokex/pokedex/clans_test.exs
```

- [ ] **Step 7: Run the Pokedex and Team tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex/pokedex_test.exs test/pokex/pokedex/team_test.exs`
Expected: PASS. Se `team_test.exs` quebrar, é porque a fixture dele ainda usa `shiny_name`/`materia` — atualize a fixture para o schema novo, não o código.

- [ ] **Step 8: Commit and push**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add -A && git commit -m "a efetividade passa a ser derivada, e o que era do PXG sai da consulta

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance
```

---

## Task 5: As telas

**Files:**
- Modify: `lib/pokex_web/live/pokedex_live.ex`
- Modify: `lib/pokex_web/live/pokedex_detail_live.ex`
- Modify: `lib/pokex_web/pokedex_style.ex`
- Modify: `test/pokex_web/live/pokedex_live_test.exs`, `test/pokex_web/live/pokedex_detail_live_test.exs`, `test/pokex_web/pokedex_style_test.exs`, `test/pokex_web/live/team_live_test.exs`, `test/pokex_web/live/character_switch_test.exs`

**Interfaces:**
- Consumes: tudo o que a Task 4 produziu.
- Produces: nenhuma API nova — só telas.

- [ ] **Step 1: Strip PokedexStyle**

In `lib/pokex_web/pokedex_style.ex`: delete the `"crystal" => {"#8ee8dc", "#0a2422"}` line from `@colors`, and delete `@clan_elements`, `clan_style/1` and `clan_colors/1` (everything below the `# Clan → the element…` comment). Update the `@moduledoc` to drop the clan sentence.

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && /usr/bin/grep -n "clan" lib/pokex_web/pokedex_style.ex test/pokex_web/pokedex_style_test.exs` and delete the matching tests.

- [ ] **Step 2: Strip pokedex_live of lures, clans and novelty**

In `lib/pokex_web/live/pokedex_live.ex`:

Delete `alias Pokex.Pokedex.Clans` and, from `mount/3`, the assigns `clans:` and `lures:`.

In `handle_params/3`: delete `clans: multi_param(params, "clans")`, `edited_after: params["edited_after"] || ""`, the `Map.put(:only_novelty, ...)` line, the `only_novelty?:` assign, the `novelty_count:` assign and the `selected_lure:` assign. Change `only_shiny: params["only_shiny"] == "true"` to `variant: params["variant"] || ""`. Change the `raw_filters` key list from

```elixir
          ~w(name elements weak_to clans min_level max_level only_shiny edited_after sort desc novidades)
```

to

```elixir
          ~w(name elements weak_to generations tiers roles variant min_level max_level sort desc)
```

and the merged map from `"clans" => filters.clans` to:

```elixir
           "generations" => filters.generations,
           "tiers" => filters.tiers,
           "roles" => filters.roles
```

Build the three new filters in `handle_params/3`, where the other filters are built:

```elixir
        generations: integer_param(params, "generations"),
        tiers: multi_param(params, "tiers"),
        roles: multi_param(params, "roles"),
```

`generations` arrive from the URL as strings and the filter compares integers. A hand-typed `?generations[]=abc` must narrow nothing, never raise — so parse, don't `String.to_integer/1`. Add next to `multi_param/3`:

```elixir
  defp integer_param(params, key) do
    params
    |> multi_param(key)
    |> Enum.flat_map(fn raw ->
      case Integer.parse(raw) do
        {number, _rest} -> [number]
        :error -> []
      end
    end)
  end
```

Delete `handle_event("toggle_novelty", ...)`, `handle_event("select_lure", ...)`, `current_lure_name/1`, and every `Map.put("isca", current_lure_name(socket))` call (in `patch_with/1`, the sort handler and the filter handler). Change the two `when key in ~w(elements weak_to clans)` guards to `when key in ~w(elements weak_to generations tiers roles)`, and the `Map.take` in the filter handler from

```elixir
      Map.take(socket.assigns.raw_filters, ~w(sort desc novidades elements weak_to clans))
```

to

```elixir
      Map.take(socket.assigns.raw_filters, ~w(sort desc elements weak_to generations tiers roles variant))
```

In `handle_info({:pokedex_sync, {:done, summary}}, socket)`, replace the `filled` branch:

```elixir
            if(summary.failed > 0, do: " · #{summary.failed} falharam", else: "")
```

and delete `lures: Pokedex.lures(),` from the same handler's re-assign.

In `filter_form/1`, delete the `"edited_after"` key.

In `@sorts`, delete `{:edited, "edição da wiki"}` and `{:changed, ...}`, and add `{:tier, "tier"}` and `{:generation, "geração"}`.

In `render/1`, delete: the `edited_after` input, the `filter-clans` chip group, the novelty button block, the `entry.clans` chips, the `@sort in [:edited, :changed]` stamp, the `Pokedex.novelty(entry, @today)` badge and its `title`, and the whole `🎣 Por isca` aside (`:if={@loaded? and @lures != []}` through the closing of `lure-tiers`).

Add, next to the elements and weak_to chip groups:

```heex
            <.filter_chips
              id="filter-generations"
              label="geração"
              param="generations"
              options={Enum.map(Pokedex.generations(), &Integer.to_string/1)}
              selected={Enum.map(@filters.generations, &Integer.to_string/1)}
              style_fun={fn _generation -> "" end}
            />
            <.filter_chips
              id="filter-tiers"
              label="tier"
              param="tiers"
              options={Pokedex.tiers()}
              selected={@filters.tiers}
              style_fun={fn _tier -> "" end}
            />
```

and, where the `only_shiny` checkbox was, a variant select:

```heex
              <select
                id="filter-variant"
                name="f[variant]"
                class="rounded bg-[#161b1f] px-2 py-1 text-xs"
              >
                <option value="" selected={@filters.variant == ""}>normais e shinies</option>
                <option value="normal" selected={@filters.variant == "normal"}>só normais</option>
                <option value="shiny" selected={@filters.variant == "shiny"}>só shinies</option>
              </select>
```

Add the new facts to each card, beside the level:

```heex
                    <span :if={entry.tier} class="rounded bg-[#1b2027] px-1.5 py-0.5">
                      tier {entry.tier}
                    </span>
                    <span class="rounded bg-[#1b2027] px-1.5 py-0.5">gen {entry.generation}</span>
```

Update the `@moduledoc` — it still describes the lure view.

- [ ] **Step 3: Strip pokedex_detail_live**

In `lib/pokex_web/live/pokedex_detail_live.ex`:

In `entry_assigns/2`, delete `lures: Pokedex.lures_for(entry.name)` (and the `lures: []` in the nil clause) and replace the shiny lookup:

```elixir
      shiny: Pokedex.variant_of(entry, "shiny"),
```

In `moves_table/1`, delete the whole `:for={tag <- Enum.reject(move.tags, ...)}` chip block and its surrounding `<td>` if the column exists only for tags.

In `render/1`, delete: the `entry-clans` span, the `@entry.boost` span, the `wiki editada em` span, the `entry-moves-pvp` details block, the `@entry.evolution_stones` paragraph, the `@entry.materia` paragraph and the `entry-lures` block. Change the `:if` on the abilities card from

```elixir
                :if={@entry.habilidades != [] or @entry.evolution_stones != [] or @entry.materia}
```

to

```elixir
                :if={@entry.habilidades != []}
```

Add a stats row beside the level:

```heex
                  <span :if={@entry.hp} class="rounded bg-[#1b2027] px-1.5 py-0.5">
                    ❤️ {@entry.hp}
                  </span>
                  <span :if={@entry.experience} class="rounded bg-[#1b2027] px-1.5 py-0.5">
                    ⭐ {@entry.experience}
                  </span>
                  <span :if={@entry.tier} class="rounded bg-[#1b2027] px-1.5 py-0.5">
                    🏅 tier {@entry.tier}
                  </span>
                  <span :if={@entry.role} class="rounded bg-[#1b2027] px-1.5 py-0.5">
                    🎯 {@entry.role}
                  </span>
                  <span class="rounded bg-[#1b2027] px-1.5 py-0.5">gen {@entry.generation}</span>
```

Replace the evolutions block with the two directions, each carrying its item:

```heex
              <section :if={@entry.evolves_from != [] or @entry.evolves_to != []} id="entry-evolution">
                <h2 class="text-sm font-semibold">✨ Evolução</h2>
                <p :for={evo <- @entry.evolves_from} class="text-xs">
                  evolui de
                  <.link navigate={~p"/pokedex/#{evo.name}"} class="underline">{evo.name}</.link>
                  <span :if={evo.level}>· lv {evo.level}</span>
                  <span :if={evo.items != []}>· {Enum.join(evo.items, ", ")}</span>
                </p>
                <p :for={evo <- @entry.evolves_to} class="text-xs">
                  evolui para
                  <.link navigate={~p"/pokedex/#{evo.name}"} class="underline">{evo.name}</.link>
                  <span :if={evo.level}>· lv {evo.level}</span>
                  <span :if={evo.items != []}>· {Enum.join(evo.items, ", ")}</span>
                </p>
              </section>
```

Update the `@moduledoc` — it names `lures_for/1`.

- [ ] **Step 4: Update the LiveView tests**

Every LiveView test builds a dataset fixture. Run:

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && /usr/bin/grep -rln "shiny_name\|materia\|lures\|edited_at\|only_shiny\|clans\|novidade" test/pokex_web/
```

For each file, replace the fixture entries with the Task 4 dataset shape (`generation`, `variant`, `tier`, `role`, `hp`, `experience`, `path`, `evolves_to`, no `weak_to`/`resists` — those derive), and delete every assertion about lures, clans, novelty, boost, matéria, PVP moves or move tags. Add assertions for the new chips:

```elixir
    test "the list filters by generation from the URL" do
      {:ok, view, _html} = live(conn, ~p"/pokedex?generations[]=4")

      assert render(view) =~ "Piplup"
      refute render(view) =~ "Bulbasaur"
    end

    test "the detail page shows the Poké Alliance stats" do
      {:ok, _view, html} = live(conn, ~p"/pokedex/Bulbasaur")

      assert html =~ "600"
      assert html =~ "tier 6"
      assert html =~ "PVE"
    end
```

- [ ] **Step 5: Run the web tests**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix format && mix test test/pokex_web/`
Expected: PASS.

- [ ] **Step 6: Verify in the browser**

O servidor tem que ser isolado — nunca subir um segundo servidor contra a configuração do dele.

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && cat .claude/launch.json 2>/dev/null || echo "sem launch.json — criar um com PORT próprio e POKEX_HOME apontando pra um diretório temporário"
```

Suba o preview pelo `preview_start` (nunca `mix phx.server` via Bash), abra `/pokedex`, e confira:
- os chips de geração e tier aparecem e filtram;
- nenhum painel de isca, nenhum chip de clã, nenhum botão de novidades;
- um card mostra sprite, tier e geração;
- `/pokedex/Bulbasaur` mostra HP, experiência, tier, role, as duas pontas da evolução com Leaf Stone, e a tabela de moves sem chips de tag;
- `read_console_messages` sem erro.

- [ ] **Step 7: Commit and push**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add -A && git commit -m "as telas passam a mostrar tier, geração e role, e param de mostrar isca e clã

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance
```

---

## Task 6: A varredura

O que sobrou nomeando o jogo antigo.

**Files:**
- Modify: `README.md`, `AGENTS.md`, `DESIGN.md`
- Modify: qualquer arquivo que a varredura acuse

**Interfaces:**
- Consumes: nada.
- Produces: nada.

- [ ] **Step 1: Find what still names the old game**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && /usr/bin/grep -rn -i "pokexgames\|poketibia\|pokedex.scrape\|Scraper\|Clans\|lures\|shiny_name\|materia" lib test config README.md AGENTS.md DESIGN.md 2>/dev/null | /usr/bin/grep -v "^docs/"
```

Expected: só `README.md`, `AGENTS.md`, `DESIGN.md` e talvez um comentário perdido. Se aparecer algo em `lib/` ou `test/`, conserte.

Cuidado com um falso positivo legítimo: `lib/pokex_web/live/sim_live.ex` menciona "pxg" como nome de PERFIL histórico — o simulador guarda o PXG como perfil, e isso é de propósito. Deixe.

- [ ] **Step 2: Update the docs**

Em `README.md`, `AGENTS.md` e `DESIGN.md`: trocar `mix pokedex.scrape` por `mix pokedex.sync`, trocar as menções ao wiki do PokeXGames pelo do Poké Alliance, e apagar as frases que descrevem iscas, clans ou novidades como capacidade da Pokédex.

**O README não nomeia o jogo de propósito** (o repo é público desde 14/08). Mantenha essa regra: fale de "a wiki do jogo", não do nome.

- [ ] **Step 3: Run the whole gate**

Run: `cd /Users/tavano/projects/worktrees/pokedex-alliance && mix precommit`
Expected: PASS, zero warnings.

- [ ] **Step 4: Confirm the base is whole**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && python3 -c "
import json
d = json.load(open('priv/pokedex/pokedex.json'))
s = d['species']
print('espécies:', len(s))
print('shinies:', sum(1 for x in s if x['variant'] == 'shiny'))
print('sem shiny_of ligado:', sum(1 for x in s if x['variant'] == 'shiny' and not x['shiny_of']))
print('sem moves:', sum(1 for x in s if not x['moves']))
print('sem sprite:', sum(1 for x in s if not x['sprite']))
print('nomes duplicados:', len(s) - len({x['name'] for x in s}))
"
```

Expected: 910 espécies, 384 shinies, 0 shinies sem `shiny_of`, 0 nomes duplicados, 0 sem sprite. "sem moves" pode ser algumas dezenas — é real (Groudon e companhia).

- [ ] **Step 5: Commit, push, and open the PR**

```bash
cd /Users/tavano/projects/worktrees/pokedex-alliance && git add -A && git commit -m "a documentação para de descrever a wiki de um jogo que ele não joga

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>" && git push origin pokedex/padrao-poke-alliance && gh pr create --base main --title "a Pokédex troca de jogo: a wiki do Poké Alliance no lugar da do PXG" --body "$(cat <<'BODY'
Desenho: `docs/superpowers/specs/2026-08-25-pokedex-poke-alliance-design.md`
Plano: `docs/superpowers/plans/2026-08-25-pokedex-poke-alliance.md`

A wiki nova é uma API JSON, não MediaWiki. As 416 linhas de regex do
`Scraper` viram cinco módulos puros — `Api`, `Index`, `PageParser`,
`Upsert`, `TypeChart` — e a base troca inteira: 910 espécies do Poké
Alliance no lugar de 866 do PXG, com 267 nomes que só o PA tem e 217 que
só o PXG tinha. O léxico que o `Interpret` fecha contra a battle list
melhora de graça.

Efetividade: o PA não publica nenhuma, em página nenhuma. Entra a matriz
canônica de 18 tipos como dado nosso, derivada no load em vez de gravada
no JSON — corrigir uma célula depois é uma edição, não um re-sync de 910
páginas. É uma aposta declarada, não uma medição.

Some: iscas, clans, matéria, boost por espécie, novidades, tags de move e
moveset PVP — nada disso existe no PA.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
BODY
)"
```

---

## Self-review

**Cobertura do spec:**

| seção do spec | task |
|---|---|
| §2 API do PA, índice e página | Task 2 (`Api`, `Index`, `PageParser`) |
| §3 matriz canônica | Task 1 |
| §3 apagar iscas/clans/matéria/boost | Tasks 4 e 5 |
| §3 cortar novidades | Tasks 4 e 5 |
| §4 forma da entrada | Task 3 (`to_entry/4`) e Task 4 (`species_entry/1`) |
| §4 `shiny_name` → `variant_of/2` | Task 4 Step 4, consumido na Task 5 Step 3 |
| §5 módulos que nascem/morrem/mudam | Tasks 2, 3, 4 |
| §6 sync e sprites | Task 3 Steps 5, 10, 11 |
| §7 telas | Task 5 |
| §8 testes e fixtures | Task 2 Step 1 (fixtures), Tasks 1–5 (testes) |
| §9 ordem dos PRs | as seis tasks, na ordem |

**Uma decisão que o spec não cobria e este plano fecha:** `Scraper.upsert/2` é a única parte do `Scraper` que não morre — a escrituração de `first_seen_at`/`changed_at` continua valendo, porque o upsert por nome é o que faz `--only` seguro. Ela vira `Pokex.Pokedex.Upsert` (Task 3), módulo próprio em vez de engordar o `Sync`.

**Uma segunda:** o gap pass (`Sync.incomplete/2` + `fill_gaps/5`) morre. Ele existia porque as regexes do MediaWiki perdiam cabeçalho; com um template só, seção ausente é a verdade sobre a espécie. O lugar dele no summary é ocupado por `failed`.
