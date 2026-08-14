# Clãs na Pokédex + Filtros Não-Exclusivos — Plano de Implementação

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** todo Pokémon marcado com seu clã PokeTibia (derivado da matéria, zero marcação manual) e filtráveis em `/pokedex` por clã E por múltiplos valores ao mesmo tempo ("todos de planta e todos de veneno").

**Architecture:** o clã é DERIVADO do campo `materia` que o scraper já colhe ("Naturia Enhanced ou Malefic Enhanced" → clãs Naturia + Malefic) — um módulo puro novo (`Pokex.Pokedex.Clans`) parseia, o load do `Pokex.Pokedex` enriquece cada entrada com `clans: [...]` (shinies sem matéria herdam do base-form), e `matches?/2` ganha cláusulas de lista com semântica OR-dentro-do-grupo / AND-entre-grupos. Na UI, os dois `<select>` exclusivos viram fileiras de chips togglables (elemento, fraco contra, clã), com o estado nas URLs como sempre (`?elements[]=Grass&elements[]=Poison`).

**Tech Stack:** Elixir 1.19, Phoenix LiveView (streams + keyset cursor já existentes), sem dependência nova.

## Global Constraints

- Código e comentários em INGLÊS; textos de UI em pt-BR (padrão do repo).
- Os 10 clãs, exatos e canônicos: `Volcanic Seavell Orebound Wingeon Raibolt Gardestrike Naturia Malefic Psycraft Ironhard`.
- Semântica dos filtros: **OR dentro de um grupo** (elements/weak_to/clans), **AND entre grupos**. Grupo vazio = filtro desligado.
- Filtros SEMPRE na URL (links compartilháveis, back/forward) — regra existente da página, não regredir.
- Stream + paginação por cursor intocados: mudança de filtro continua `reset: true`; `Pokedex.page/3` não muda.
- URLs antigas continuam funcionando: `?element=Water` (singular) e `?weak_to=Fire` (string) são lidas como listas de um item.
- **Nenhuma sincronização nova é necessária**: a base do PR #46 já tem `materia` para 786/866 entradas; 18 shinies herdam do base-form; 62 ficam honestamente sem clã (sem invenção de dados).
- Derivação medida na base real (866 entradas, 178 strings distintas de matéria): decompõe em clã × tier (`Enhanced|Superior|Mastered`) unidos por "ou" — MAIS três sujeiras da wiki que o parser precisa absorver: `or` em inglês (4 páginas), um `e` ("Orebound Superior e Psycraft Superior"), e o typo `Oreboun`.
- `mix format` + suíte INTEIRA verde antes de cada commit.
- Branch: `pokedex/clas-e-filtros` (já criada a partir de `origin/main`, este plano commitado nela). Ao final: PR e merge (autorização em pé do Lucas: "pode mergir depois, vou validar aqui na main"). NUNCA `git add -A` — sempre paths explícitos (árvore compartilhada com outra sessão de IA).

---

### Task 1: `Pokex.Pokedex.Clans` — o parser puro de matéria → clãs

**Files:**
- Create: `lib/pokex/pokedex/clans.ex`
- Test: `test/pokex/pokedex/clans_test.exs`

**Interfaces:**
- Consumes: nada (módulo puro, sem deps).
- Produces: `Clans.all() :: [String.t()]` (os 10, ordem canônica) e `Clans.parse(String.t() | nil) :: [String.t()]` — usados pelas Tasks 2, 5.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule Pokex.Pokedex.ClansTest do
  use ExUnit.Case, async: true

  alias Pokex.Pokedex.Clans

  describe "parse/1 — matéria → clã(s), medido nas 178 strings da base real" do
    test "matéria simples é o próprio clã" do
      assert Clans.parse("Seavell") == ["Seavell"]
    end

    test "o tier (Enhanced/Superior/Mastered) é ruído" do
      assert Clans.parse("Malefic Superior") == ["Malefic"]
      assert Clans.parse("Naturia Enhanced") == ["Naturia"]
      assert Clans.parse("Gardestrike Mastered") == ["Gardestrike"]
    end

    test "'ou' divide em dois clãs, ordem da página" do
      assert Clans.parse("Naturia ou Malefic") == ["Naturia", "Malefic"]
      assert Clans.parse("Naturia Enhanced ou Wingeon Enhanced") == ["Naturia", "Wingeon"]
    end

    test "as três sujeiras da wiki: 'or' inglês, 'e', e o typo Oreboun" do
      assert Clans.parse("Seavell or Wingeon") == ["Seavell", "Wingeon"]
      assert Clans.parse("Orebound Superior e Psycraft Superior") == ["Orebound", "Psycraft"]
      assert Clans.parse("Oreboun") == ["Orebound"]
    end

    test "Ironhard é o décimo clã" do
      assert Clans.parse("Ironhard Superior") == ["Ironhard"]
    end

    test "sem matéria, sem clã — e palavra desconhecida NUNCA vira clã" do
      assert Clans.parse(nil) == []
      assert Clans.parse("") == []
      assert Clans.parse("Bazinga Superior") == []
    end

    test "clã repetido não duplica" do
      assert Clans.parse("Psycraft ou Psycraft Superior") == ["Psycraft"]
    end
  end

  test "all/0 lista os 10 clãs canônicos" do
    assert length(Clans.all()) == 10
    assert "Volcanic" in Clans.all()
    assert "Ironhard" in Clans.all()
  end
end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex/pokedex/clans_test.exs`
Expected: FAIL — `module Pokex.Pokedex.Clans is not available`

- [ ] **Step 3: Write the module**

```elixir
defmodule Pokex.Pokedex.Clans do
  @moduledoc """
  The PokeTibia clan of a species, DERIVED from the wiki's "Materia" field — no new
  scraping and no hand-marking 866 entries: "Naturia Enhanced ou Malefic
  Enhanced" already names the clan(s); the tier suffix is noise here.

  Measured on the full 2026-07-22 base (866 entries, 178 distinct materia
  strings): every one decomposes into the 10 clans below × an optional tier
  (Enhanced/Superior/Mastered), joined by "ou" — plus three wiki quirks this
  module absorbs: the English "or" (4 pages), one "e", and the "Oreboun" typo.
  """

  @clans ~w(Volcanic Seavell Orebound Wingeon Raibolt Gardestrike Naturia Malefic Psycraft Ironhard)

  @typos %{"Oreboun" => "Orebound"}

  @doc "The 10 PokeTibia clans, canonical order — the filter UI's option list."
  def all, do: @clans

  @doc """
  Clan name(s) inside a materia string, deduped, page order kept. An unknown
  word is dropped, never invented; nil/"" parse to [].
  """
  def parse(nil), do: []

  def parse(materia) when is_binary(materia) do
    materia
    |> String.split(~r/\s+(?:ou|or|e)\s+/i)
    |> Enum.flat_map(fn part ->
      first = part |> String.trim() |> String.split() |> List.first()
      clan = Map.get(@typos, first, first)
      if clan in @clans, do: [clan], else: []
    end)
    |> Enum.uniq()
  end
end
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex/pokedex/clans_test.exs`
Expected: 9 tests, 0 failures

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex/pokedex/clans.ex test/pokex/pokedex/clans_test.exs
git commit -m "pokedex: Clans — clã derivado da matéria (10 clãs, 3 sujeiras da wiki absorvidas)"
```

---

### Task 2: enriquecer cada entrada com `clans` no load (+ herança dos shinies)

**Files:**
- Modify: `lib/pokex/pokedex.ex` (funções `load/1` e `species_entry/1`, ~linhas 425–470)
- Test: `test/pokex/pokedex_test.exs`

**Interfaces:**
- Consumes: `Clans.parse/1` da Task 1.
- Produces: todo mapa de espécie retornado por `Pokedex.species/0`, `get/1`, `search/1`, `page/3` carrega `clans :: [String.t()]` — a Task 3 filtra por ele, as Tasks 5–6 renderizam.

- [ ] **Step 1: Write the failing tests** — em `test/pokex/pokedex_test.exs`, adicionar `"materia"` a duas entradas do `@dataset` existente e um bloco novo. No `@dataset`, a entrada Seadra ganha `"materia" => "Seavell"`, a Charizard ganha `"materia" => "Volcanic Superior"` (a Shiny Seadra continua SEM materia — é o caso da herança). Depois o bloco:

```elixir
  describe "clãs derivados da matéria" do
    @tag :tmp_dir
    test "cada entrada nasce com seus clãs; shiny sem matéria herda do base-form" do
      assert %{clans: ["Seavell"]} = Pokedex.get("Seadra")
      assert %{clans: ["Volcanic"]} = Pokedex.get("Charizard")

      # Shiny Seadra não tem materia no JSON — herda do Seadra
      assert %{clans: ["Seavell"]} = Pokedex.get("Shiny Seadra")
    end

    @tag :tmp_dir
    test "entrada sem matéria e sem base-form fica honestamente sem clã" do
      assert %{clans: []} = Pokedex.get("Venusaur")
    end
  end
```

(Venusaur já existe no `@dataset` sem materia — não adicionar materia nele.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex/pokedex_test.exs`
Expected: FAIL — `key :clans not found`

- [ ] **Step 3: Implement** — em `lib/pokex/pokedex.ex`:

(a) no topo do módulo, junto dos aliases (se não houver bloco de alias, criar após o `@moduledoc`):

```elixir
  alias Pokex.Pokedex.Clans
```

(b) em `species_entry/1`, adicionar o campo logo após `materia: map["materia"],`:

```elixir
      # PokeTibia clan(s), derived from materia at load time — filterable, no manual
      # marking; a shiny without materia inherits from its base form (below)
      clans: Clans.parse(map["materia"]),
```

(c) em `load/1`, passar a lista pelo passo de herança — trocar:

```elixir
        species: Enum.map(json["species"] || [], &species_entry/1),
```

por:

```elixir
        species: (json["species"] || []) |> Enum.map(&species_entry/1) |> inherit_clans(),
```

(d) a função privada, junto de `species_entry/1`:

```elixir
  # 62 of the 80 materia-less entries are Shiny variants whose base form HAS
  # one — the clan is the same, so inherit it instead of showing "no clan".
  defp inherit_clans(species) do
    by_name = Map.new(species, &{&1.name, &1})

    Enum.map(species, fn
      %{clans: [], shiny_of: base_name} = entry when is_binary(base_name) ->
        case by_name[base_name] do
          %{clans: clans} -> %{entry | clans: clans}
          nil -> entry
        end

      entry ->
        entry
    end)
  end
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex/pokedex_test.exs`
Expected: PASS (todos, incluindo os pré-existentes)

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex/pokedex.ex test/pokex/pokedex_test.exs
git commit -m "pokedex: entradas carregam clans no load; shiny herda do base-form"
```

---

### Task 3: filtros multi-valor em `matches?/2` (OR no grupo, AND entre grupos)

**Files:**
- Modify: `lib/pokex/pokedex.ex` (`matches?/2`, ~linha 360; docstring de `search/1`, ~linha 60)
- Test: `test/pokex/pokedex_test.exs`

**Interfaces:**
- Consumes: `entry.clans` da Task 2.
- Produces: chaves de filtro `:elements`, `:weak_to`, `:clans` aceitando LISTAS — a Task 5 monta esses filtros a partir da URL. As cláusulas antigas `{:element, binário}` / `{:weak_to, binário}` PERMANECEM (URLs antigas).

- [ ] **Step 1: Write the failing tests** — em `test/pokex/pokedex_test.exs` (o `@dataset` tem Seadra=Water, Charizard=Fire/Flying, Venusaur=Grass/Poison…):

```elixir
  describe "filtros multi-valor — OR dentro do grupo, AND entre grupos" do
    @tag :tmp_dir
    test "elements: [Grass, Water] é a UNIÃO (planta E veneno do pedido do Lucas)" do
      names = Pokedex.search(%{elements: ["Grass", "Water"]}) |> Enum.map(& &1.name)

      assert "Venusaur" in names
      assert "Seadra" in names
      refute "Charizard" in names
    end

    test "lista vazia é filtro desligado" do
      assert length(Pokedex.search(%{elements: []})) == length(Pokedex.search(%{}))
    end

    @tag :tmp_dir
    test "grupos diferentes continuam compondo com AND" do
      names =
        Pokedex.search(%{elements: ["Grass", "Water"], min_level: 55})
        |> Enum.map(& &1.name)

      assert "Venusaur" in names
      refute "Seadra" in names
    end

    @tag :tmp_dir
    test "weak_to como lista: fraco a QUALQUER um dos elementos" do
      names = Pokedex.search(%{weak_to: ["Rock", "Electric"]}) |> Enum.map(& &1.name)

      assert "Charizard" in names
      assert "Seadra" in names
    end

    @tag :tmp_dir
    test "clans filtra pelo clã derivado" do
      names = Pokedex.search(%{clans: ["Seavell"]}) |> Enum.map(& &1.name)

      assert "Seadra" in names
      assert "Shiny Seadra" in names
      refute "Charizard" in names
    end

    @tag :tmp_dir
    test "as chaves singulares antigas continuam valendo (URLs marcadas)" do
      assert Pokedex.search(%{element: "Water"}) |> Enum.map(& &1.name) |> Enum.member?("Seadra")
      assert Pokedex.search(%{weak_to: "Rock"}) |> Enum.map(& &1.name) == ["Charizard"]
    end
  end
```

(Nos testes sem `@tag :tmp_dir` acima, ajustar: TODOS precisam da tag — o setup do arquivo injeta o dataset via `:tmp_dir`. Colocar `@tag :tmp_dir` em cada um.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex/pokedex_test.exs`
Expected: FAIL nos testes de lista (a cláusula `_off -> true` engole a chave e devolve tudo — o assert `refute "Charizard"` quebra)

- [ ] **Step 3: Implement** — em `matches?/2`, logo APÓS a cláusula `{:weak_to, element} when is_binary(element)...`, adicionar:

```elixir
      # Multi-value groups (the non-exclusive filters): the entry matches when
      # it has ANY of the selected values — "todos de planta E todos de
      # veneno" is one group with two values, not two exclusive searches.
      {:elements, list} when is_list(list) and list != [] ->
        Enum.any?(list, &(&1 in entry.elements))

      {:weak_to, list} when is_list(list) and list != [] ->
        Enum.any?(list, &(&1 in entry.weak_to))

      {:clans, list} when is_list(list) and list != [] ->
        Enum.any?(list, &(&1 in entry.clans))
```

E na docstring de `search/1`, trocar as linhas dos dois filtros por:

```elixir
    * `:elements` — species has ANY of these elements (list; the old singular
      `:element` binary still works)
    * `:weak_to` — ANY of these elements hits the species hard (list or the
      old singular binary)
    * `:clans` — species belongs to ANY of these PokeTibia clans (derived from materia)
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex/pokedex_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex/pokedex.ex test/pokex/pokedex_test.exs
git commit -m "pokedex: filtros multi-valor (elements/weak_to/clans) — OR no grupo, AND entre grupos"
```

---

### Task 4: `PokedexStyle.clan_style/1` — o clã veste a paleta do seu elemento

**Files:**
- Modify: `lib/pokex_web/pokedex_style.ex`
- Test: `test/pokex_web/pokedex_style_test.exs` (criar se não existir; se existir, adicionar o describe)

**Interfaces:**
- Consumes: `element_style/1` existente.
- Produces: `PokedexStyle.clan_style(clan) :: String.t()` (inline CSS) — Tasks 5 e 6 usam nos chips.

- [ ] **Step 1: Write the failing tests**

```elixir
defmodule PokexWeb.PokedexStyleTest do
  use ExUnit.Case, async: true

  alias PokexWeb.PokedexStyle

  describe "clan_style/1" do
    test "cada clã veste a paleta do elemento que representa" do
      assert PokedexStyle.clan_style("Volcanic") == PokedexStyle.element_style("fire")
      assert PokedexStyle.clan_style("Seavell") == PokedexStyle.element_style("water")
      assert PokedexStyle.clan_style("Ironhard") == PokedexStyle.element_style("steel")
      assert PokedexStyle.clan_style("psycraft") == PokedexStyle.element_style("psychic")
    end

    test "clã desconhecido cai no fallback neutro, nunca quebra" do
      assert PokedexStyle.clan_style("Bazinga") == PokedexStyle.element_style(nil)
    end
  end
end
```

(Se o arquivo já existir com outro conteúdo, só acrescentar o `describe` e o alias.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex_web/pokedex_style_test.exs`
Expected: FAIL — `clan_style/1 is undefined`

- [ ] **Step 3: Implement** — em `lib/pokex_web/pokedex_style.ex`, após `element_style/1`:

```elixir
  # Clan → the element whose palette it wears (PokeTibia's own pairing: Volcanic is
  # the Fire clan, Seavell the Water one…). Reusing the element colours means
  # the eye learns ONE palette, not two.
  @clan_elements %{
    "volcanic" => "fire",
    "seavell" => "water",
    "orebound" => "rock",
    "wingeon" => "flying",
    "raibolt" => "electric",
    "gardestrike" => "fighting",
    "naturia" => "grass",
    "malefic" => "ghost",
    "psycraft" => "psychic",
    "ironhard" => "steel"
  }

  @doc "Inline style for a clan chip — wears its element's palette."
  def clan_style(clan) do
    @clan_elements
    |> Map.get(String.downcase(to_string(clan)))
    |> element_style()
  end
```

(`element_style(nil)` já funciona: delega para `element_colors/1`, que tem cláusula para nil e devolve o fallback — clã desconhecido fica neutro de graça.)

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex_web/pokedex_style_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex_web/pokedex_style.ex test/pokex_web/pokedex_style_test.exs
git commit -m "pokedex: clan_style — clãs vestem a paleta dos seus elementos"
```

---

### Task 5: a página `/pokedex` — chips togglables no lugar dos selects exclusivos

**Files:**
- Modify: `lib/pokex_web/live/pokedex_live.ex`
- Test: `test/pokex_web/live/pokedex_live_test.exs`

**Interfaces:**
- Consumes: filtros de lista da Task 3, `Clans.all()` da Task 1, `clan_style/1` da Task 4, `entry.clans` da Task 2.
- Produces: URL canônica `?elements[]=X&weak_to[]=Y&clans[]=Z`; eventos `toggle_filter`/`clear_filter`.

- [ ] **Step 1: Write the failing tests** — em `test/pokex_web/live/pokedex_live_test.exs`. O `@dataset` do arquivo precisa de `"materia"` em pelo menos duas entradas (ex.: na Seadra `"materia" => "Seavell"`, na Charizard `"materia" => "Volcanic Superior"` — espelhando a Task 2). Adicionar:

```elixir
  describe "filtros não-exclusivos por chips" do
    @tag :tmp_dir
    test "dois elementos ligados = união (planta E veneno), na URL como lista", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex")

      view |> element(~s(#filter-elements button[phx-value-value="Water"])) |> render_click()
      assert_patch(view)
      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      refute results =~ "Charizard"

      view |> element(~s(#filter-elements button[phx-value-value="Fire"])) |> render_click()
      path = assert_patch(view)
      assert path =~ "elements[]=Water"
      assert path =~ "elements[]=Fire"

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      assert results =~ "Charizard"
    end

    @tag :tmp_dir
    test "clicar de novo desliga o chip; 'limpar ×' zera o grupo", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water"]}}")

      view |> element(~s(#filter-elements button[phx-value-value="Water"])) |> render_click()
      path = assert_patch(view)
      refute path =~ "elements"

      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water", "Fire"]}}")
      view |> element(~s(#filter-elements button), "limpar ×") |> render_click()
      path = assert_patch(view)
      refute path =~ "elements"
    end

    @tag :tmp_dir
    test "filtro por clã acha os membros (shiny herdeiro incluso)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"clans" => ["Seavell"]}}")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      assert results =~ "Shiny Seadra"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "URL antiga com ?element= singular continua filtrando", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?element=Water")

      results = view |> element("#pokedex-results") |> render()
      assert results =~ "Seadra"
      refute results =~ "Charizard"
    end

    @tag :tmp_dir
    test "o card mostra o clã do Pokémon", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"name" => "Charizard"}}")

      assert view |> element("#pokedex-results") |> render() =~ "Volcanic"
    end

    @tag :tmp_dir
    test "trocar chips reseta a lista (convive com o scroll infinito)", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex")

      view |> element(~s(#filter-clans button[phx-value-value="Seavell"])) |> render_click()
      assert_patch(view)
      results = view |> element("#pokedex-results") |> render()
      refute results =~ "Charizard"
    end
  end
```

(Adaptar nomes/valores ao `@dataset` real do arquivo — os asserts acima assumem Seadra=Water/Seavell e Charizard=Fire/Volcanic. Se os testes existentes usavam o select `f[element]`, atualizá-los para o chip OU deixá-los cobrindo a URL singular legada.)

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex_web/live/pokedex_live_test.exs`
Expected: FAIL — não existe `#filter-elements`

- [ ] **Step 3: Implement** — em `lib/pokex_web/live/pokedex_live.ex`:

(a) alias no topo, junto dos existentes:

```elixir
  alias Pokex.Pokedex.Clans
```

(b) `mount/3`: adicionar ao assign `clans: Clans.all(),` (junto de `elements:`).

(c) `handle_params/3`: trocar a montagem de `filters` por:

```elixir
    filters =
      %{
        name: params["name"] || "",
        elements: multi_param(params, "elements", "element"),
        weak_to: multi_param(params, "weak_to"),
        clans: multi_param(params, "clans"),
        only_shiny: params["only_shiny"] == "true",
        edited_after: params["edited_after"] || ""
      }
      |> put_level(:min_level, params["min_level"])
      |> put_level(:max_level, params["max_level"])
```

e trocar o assign de `raw_filters` por (normaliza o legado — a URL singular vira lista canônica na próxima navegação):

```elixir
       raw_filters:
         params
         |> Map.take(
           ~w(name elements weak_to clans min_level max_level only_shiny edited_after sort desc novidades)
         )
         |> Map.put("elements", filters.elements)
         |> Map.put("weak_to", filters.weak_to)
         |> Map.put("clans", filters.clans)
         |> clean_query(),
```

(d) `clean_query/1` passa a descartar listas vazias — trocar o reject por:

```elixir
    |> Enum.reject(fn {_k, v} -> v in [nil, "", "false", []] end)
```

(e) novo helper privado, junto de `put_level/3`:

```elixir
  # Multi-value filters ride the URL as lists (?elements[]=Grass&elements[]=
  # Poison). `legacy` reads the pre-chips singular param so old bookmarks
  # keep working; a binary under the plural key (hand-typed URL) counts too.
  defp multi_param(params, key, legacy \\ nil) do
    case params[key] || (legacy && params[legacy]) do
      list when is_list(list) -> Enum.reject(list, &(&1 in [nil, ""]))
      value when is_binary(value) and value != "" -> [value]
      _absent -> []
    end
  end
```

(f) eventos novos, junto de `handle_event("filter", ...)`:

```elixir
  # A chip toggles its value in or out of the group — "todos de planta E
  # todos de veneno" is two chips on. OR inside the group, AND across groups.
  def handle_event("toggle_filter", %{"key" => key, "value" => value}, socket)
      when key in ~w(elements weak_to clans) do
    current = socket.assigns.raw_filters[key] || []
    updated = if value in current, do: List.delete(current, value), else: current ++ [value]

    query =
      socket.assigns.raw_filters
      |> Map.put(key, updated)
      |> Map.put("isca", current_lure_name(socket))
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end

  def handle_event("clear_filter", %{"key" => key}, socket)
      when key in ~w(elements weak_to clans) do
    query =
      socket.assigns.raw_filters
      |> Map.delete(key)
      |> Map.put("isca", current_lure_name(socket))
      |> clean_query()

    {:noreply, push_patch(socket, to: ~p"/pokedex?#{query}")}
  end
```

(g) `filter_form/1`: remover as chaves `"element"` e `"weak_to"` do mapa (os campos saem do form).

(g2) **CRÍTICO** — em `handle_event("filter", ...)` (o evento do form de nome/level/data), o `keep` precisa preservar os chips, senão digitar um nome APAGA os filtros de chip ligados. Trocar:

```elixir
    keep = Map.take(socket.assigns.raw_filters, ~w(sort desc novidades))
```

por:

```elixir
    # sort/novelty AND the chip groups survive a form change — typing a name
    # must never wipe the elements/clans the user just toggled on
    keep = Map.take(socket.assigns.raw_filters, ~w(sort desc novidades elements weak_to clans))
```

E cobrir com teste (adicionar ao describe da Task 5):

```elixir
    @tag :tmp_dir
    test "digitar um nome NÃO apaga os chips ligados", %{conn: conn} do
      {:ok, view, _} = live(conn, ~p"/pokedex?#{%{"elements" => ["Water"]}}")

      view |> form("#pokedex-filter-form", %{"f" => %{"name" => "sea"}}) |> render_change()
      path = assert_patch(view)
      assert path =~ "elements[]=Water"
      assert path =~ "name=sea"
    end
```

(h) componente novo, junto de `element_chip/1`:

```elixir
  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :hint, :string, default: nil
  attr :param, :string, required: true
  attr :options, :list, required: true
  attr :selected, :list, required: true
  attr :style_fun, :any, required: true

  # One row of toggle chips = one NON-exclusive filter: any number on at
  # once, matching entries that have ANY of them. Empty selection = "todos".
  defp filter_chips(assigns) do
    ~H"""
    <div id={@id} class="flex flex-wrap items-center gap-1" title={@hint}>
      <span class="mr-0.5 w-24 shrink-0">
        {@label}<span :if={@selected != []} class="text-[#3de083]"> ({length(@selected)})</span>
      </span>
      <button
        :for={option <- @options}
        type="button"
        phx-click="toggle_filter"
        phx-value-key={@param}
        phx-value-value={option}
        style={@style_fun.(option)}
        class={[
          "rounded px-1.5 py-0.5 font-mono text-[10px] transition",
          if(option in @selected,
            do: "ring-1 ring-[#37d07d]/70",
            else: "opacity-40 hover:opacity-90"
          )
        ]}
      >
        {option}
      </button>
      <button
        :if={@selected != []}
        type="button"
        phx-click="clear_filter"
        phx-value-key={@param}
        class="rounded px-1 py-0.5 text-[#89939a] hover:bg-[#161b1f] hover:text-white"
      >
        limpar ×
      </button>
    </div>
    """
  end
```

(i) no template: REMOVER os dois `<label>` com `<select name="f[element]">` e `<select name="f[weak_to]">` de dentro do `.form`, e logo APÓS o `</.form>` inserir:

```heex
          <div class="mt-2 space-y-1.5 border-t border-[#1d2429] pt-2 font-mono text-[10px] text-[#77828a]">
            <.filter_chips
              id="filter-elements"
              label="elemento"
              param="elements"
              options={@elements}
              selected={@filters.elements}
              style_fun={&PokedexStyle.element_style/1}
            />
            <.filter_chips
              id="filter-weak-to"
              label="fraco contra"
              hint="ataques de QUALQUER um destes elementos batem forte nele"
              param="weak_to"
              options={@elements}
              selected={@filters.weak_to}
              style_fun={&PokedexStyle.element_style/1}
            />
            <.filter_chips
              id="filter-clans"
              label="clã"
              hint="derivado da matéria do Pokémon na wiki"
              param="clans"
              options={@clans}
              selected={@filters.clans}
              style_fun={&PokedexStyle.clan_style/1}
            />
          </div>
```

(j) no card da lista, na linha de meta (`<p class="flex flex-wrap items-center gap-1 font-mono text-[9px]...">`, a que tem `lv {entry.level}` e os `element_chip`), adicionar após os element_chips:

```heex
                      <span
                        :for={clan <- entry.clans}
                        class="rounded px-1 py-0.5"
                        style={PokedexStyle.clan_style(clan)}
                      >
                        ⚑ {clan}
                      </span>
```

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex_web/live/pokedex_live_test.exs`
Expected: PASS (novos E pré-existentes — os que usavam o select precisam ter sido adaptados no Step 1)

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex_web/live/pokedex_live.ex test/pokex_web/live/pokedex_live_test.exs
git commit -m "pokedex: chips não-exclusivos (elemento/fraqueza/clã) no lugar dos selects"
```

---

### Task 6: página do Pokémon — chip de clã linkando pra lista filtrada

**Files:**
- Modify: `lib/pokex_web/live/pokedex_detail_live.ex` (cabeçalho do `#entry-card`, junto dos `element_chip`)
- Test: `test/pokex_web/live/pokedex_detail_live_test.exs`

**Interfaces:**
- Consumes: `entry.clans` (Task 2), `clan_style/1` (Task 4), URL `?clans[]=` (Task 5).
- Produces: nada novo — só UI.

- [ ] **Step 1: Write the failing tests** — no `@dataset` do arquivo, adicionar `"materia" => "Seavell"` à entrada Seadra (a Shiny Seadra fica sem — herda). Adicionar:

```elixir
  @tag :tmp_dir
  test "o clã aparece no cabeçalho e clica pra lista filtrada", %{conn: conn} do
    {:ok, view, _} = live(conn, ~p"/pokedex/Seadra")

    chip = view |> element("#entry-clans") |> render()
    assert chip =~ "Seavell"
    assert chip =~ "clans[]=Seavell"

    # o shiny herdeiro também mostra
    {:ok, shiny, _} = live(conn, ~p"/pokedex/#{"Shiny Seadra"}")
    assert shiny |> element("#entry-clans") |> render() =~ "Seavell"
  end
```

- [ ] **Step 2: Run to verify it fails**

Run: `mix test test/pokex_web/live/pokedex_detail_live_test.exs`
Expected: FAIL — não existe `#entry-clans`

- [ ] **Step 3: Implement** — no cabeçalho do card (a `<p class="mt-1 flex flex-wrap gap-1.5 font-mono text-[11px]">` que tem número, level, `element_chip` e boost), adicionar após os `element_chip`:

```heex
                  <span :if={@entry.clans != []} id="entry-clans" class="contents">
                    <.link
                      :for={clan <- @entry.clans}
                      navigate={~p"/pokedex?#{%{"clans" => [clan]}}"}
                      title={"ver todos do clã #{clan}"}
                      class="rounded px-1.5 py-0.5 transition hover:ring-1 hover:ring-[#37d07d]/60"
                      style={PokedexStyle.clan_style(clan)}
                    >
                      ⚑ {clan}
                    </.link>
                  </span>
```

- [ ] **Step 4: Run to verify it passes**

Run: `mix test test/pokex_web/live/pokedex_detail_live_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex_web/live/pokedex_detail_live.ex test/pokex_web/live/pokedex_detail_live_test.exs
git commit -m "pokedex: chip de clã na página do Pokémon, linkando pra lista filtrada"
```

---

### Task 7: `--skip-sprites` preserva sprites já baixados (o bug que anulou 866 sprites)

**Files:**
- Modify: `lib/pokex/pokedex/sync.ex` (`download_sprite/3` e `sprites_dir/0`, ~linhas 354–375 e ~395)
- Modify: `config/test.exs` (dir de sprites por env)
- Test: `test/pokex/pokedex/sync_test.exs`

**Interfaces:**
- Consumes: nada das tasks anteriores (independente).
- Produces: `Sync.download_sprite/3` vira pública (`@doc false`) para o teste; `sprites_dir` lê `Application.get_env(:pokex, :pokedex_sprites_dir, "priv/static/images/pokedex")`.

**Contexto:** na sincronização de 2026-07-22, `--fresh --skip-sprites` devolveu `nil` para TODO campo `sprite` — o PR #46 teve que restaurar 824 paths na mão a partir do JSON antigo. Pular sprites tem que significar "não baixar", nunca "esquecer o que já existe no disco".

- [ ] **Step 1: Write the failing tests** — em `test/pokex/pokedex/sync_test.exs`:

```elixir
  describe "download_sprite/3 — skip_sprites preserva, nunca esquece" do
    @tag :tmp_dir
    test "com skip_sprites, sprite já no disco mantém o path", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      File.write!(Path.join(tmp, "seadra.gif"), "gif")

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               "images/pokedex/seadra.gif"
    end

    @tag :tmp_dir
    test "com skip_sprites e NADA no disco, aí sim nil", %{tmp_dir: tmp} do
      Application.put_env(:pokex, :pokedex_sprites_dir, tmp)
      on_exit(fn -> Application.delete_env(:pokex, :pokedex_sprites_dir) end)

      assert Sync.download_sprite("/images/f/f0/117_-_Seadra.gif", "Seadra", skip_sprites: true) ==
               nil
    end

    test "sem URL não há sprite, com ou sem skip" do
      assert Sync.download_sprite(nil, "Seadra", skip_sprites: true) == nil
    end
  end
```

- [ ] **Step 2: Run to verify they fail**

Run: `mix test test/pokex/pokedex/sync_test.exs`
Expected: FAIL — `download_sprite/3 is undefined or private`

- [ ] **Step 3: Implement** — em `lib/pokex/pokedex/sync.ex`, substituir as duas cláusulas de `defp download_sprite` por:

```elixir
  # Public only for the test: skip_sprites must mean "don't FETCH", never
  # "forget" — a --fresh --skip-sprites run once nulled every sprite in the
  # base (PR #46 had to restore 824 paths by hand from the previous JSON).
  @doc false
  def download_sprite(nil, _name, _opts), do: nil

  def download_sprite(url, name, opts) do
    file = slug(name) <> Path.extname(url)
    dest = Path.join(sprites_dir(), file)

    if opts[:skip_sprites] do
      if File.exists?(dest), do: "images/pokedex/" <> file
    else
      File.mkdir_p!(sprites_dir())

      unless File.exists?(dest) do
        case Req.get(@base <> url, retry: :transient, max_retries: 2) do
          {:ok, %{status: 200, body: body}} when is_binary(body) -> File.write!(dest, body)
          _error -> :skip
        end
      end

      if File.exists?(dest), do: "images/pokedex/" <> file
    end
  end
```

e trocar `defp sprites_dir, do: "priv/static/images/pokedex"` por:

```elixir
  defp sprites_dir,
    do: Application.get_env(:pokex, :pokedex_sprites_dir, "priv/static/images/pokedex")
```

(As chamadas internas `download_sprite(...)` continuam funcionando — só mudou a visibilidade. `opts` nas chamadas internas é Keyword/map dos opts do run: conferir que `opts[:skip_sprites]` segue funcionando para ambos os formatos — no pipeline os opts são Keyword, ok.)

- [ ] **Step 4: Run to verify they pass**

Run: `mix test test/pokex/pokedex/sync_test.exs`
Expected: PASS

- [ ] **Step 5: Format and commit**

```bash
mix format
git add lib/pokex/pokedex/sync.ex test/pokex/pokedex/sync_test.exs
git commit -m "pokedex: --skip-sprites preserva sprites do disco (nunca mais anular a base)"
```

---

### Task 8: suíte inteira, PR e merge

- [ ] **Step 1: Full suite, twice** (flake guard do repo)

Run: `mix test` (2×)
Expected: 0 failures nas duas rodadas (baseline atual: 615 testes; este plano adiciona ~20)

- [ ] **Step 2: Format check**

Run: `mix format --check-formatted`
Expected: sem saída

- [ ] **Step 3: Push + PR**

```bash
git push -u origin pokedex/clas-e-filtros
gh pr create --title "pokedex: clãs derivados da matéria + filtros não-exclusivos por chips" --body "..."
```

Corpo do PR: os dois pedidos do Lucas (clã visível/filtrável; "todos de planta E todos de veneno"), a decisão de DERIVAR o clã da matéria (zero marcação manual; 786 diretos + 18 shinies por herança + 62 honestamente sem), a semântica OR-no-grupo/AND-entre-grupos, a compat com URLs antigas, e o fix do `--skip-sprites`. Rodapé: `🤖 Generated with [Claude Code](https://claude.com/claude-code)`.

- [ ] **Step 4: Merge** (autorização em pé do Lucas) e confirmar `origin/main`:

```bash
gh pr merge --merge --delete-branch=false
git fetch origin && git log --oneline origin/main -1
```

---

## Decisões registradas (por quê)

1. **Derivar > marcar na mão**: a matéria já nomeia o clã para 786/866 entradas; marcar 866 na mão seria trabalho do Lucas e envelheceria a cada sync. Herança shiny→base cobre +18. Os 62 restantes (Chikorita, Krabby… páginas antigas sem o campo) ficam sem clã — mostrar nada é mais honesto que adivinhar por elemento.
2. **Chips > multi-select nativo**: `<select multiple>` é péssimo de usar e esconde o estado; chips mostram TUDO que está ligado, com a cor do elemento que o olho já conhece, e cada clique é um `push_patch` — o padrão da página (URL = verdade) fica intacto.
3. **`weak_to` também vira multi**: o pedido citou elementos, mas "fraco a Fire OU Ice" é exatamente a pergunta de caçada, e deixar UM filtro exclusivo quando os vizinhos não são seria inconsistência boba.
4. **Task 7 pegou carona**: bug real encontrado ao rodar a sincronização desta entrega; consertar aqui evita a próxima base anulada.

## Fora de escopo (deferido, consciente)

- Fallback elemento→clã para os 62 sem matéria (dado inventado; esperar a wiki preencher).
- Ordenar por clã (ninguém pediu; os chips já agrupam visualmente).
- Tier do clã (Enhanced/Superior/Mastered) como dado estruturado — a matéria crua já aparece na página de detalhe.
