# O olho do cerco — PR 1: marcas, leitura e cartão (sem cérebro)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** O bot passa a enxergar cada criatura na tela pela barra de vida (com caveira e caixa do número como assinaturas), publica as posições em tiles a partir do personagem, guarda fotos por decisão de revive, e a Central ganha o cartão do cerco. O cérebro NÃO lê nada disto ainda.

**Architecture:** Três funções puras em cadeia — `Vision.CreatureMarks.find/2` (pixels → marcas), `Bots.CrowdScan.place/3` (marcas → tiles de VOCÊ e do pokémon), e o vigia `Bots.CrowdWatch` que fotografa na cadência certa, publica o fato `:crowd` inteiro e avisa a Central por PubSub. O cartão `PokexWeb.SiegeComponents.siege_card/1` desenha o fato em SVG no espaço de tiles, centrado no personagem, o mesmo idioma do mapa da rota e do `/sim`.

**Tech Stack:** Elixir 1.19 / OTP 27, Phoenix LiveView, ExUnit. Frames RGBA crus (`Pokex.Vision.Frame`), PNG via `Pokex.Vision.Png`. Sem dependência nova.

**Spec:** `docs/superpowers/specs/2026-09-05-siege-eye-design.md` (seções 3, 4, 6, 8 e 9/PR 1).

## Global Constraints

- **Identificadores em inglês** (módulos, funções, variáveis, átomos, chaves de config, nomes de teste); **texto pro usuário em pt-BR** (feed, cartão, hints do /config). Comentários em inglês e raros.
- **Nunca compile, teste ou rode nada em `~/projects/pokex`.** Trabalhe no worktree desta branch (`worktree-olho-do-cerco`, em `.claude/worktrees/olho-do-cerco`). Nunca `mix run` (derruba o helper de captura do servidor vivo dele): sonda de comportamento vai em teste.
- **Nunca `git add -A`**: adicione só os arquivos que a tarefa tocou, por nome. `test/probe/` é sonda temporária e NUNCA entra em commit.
- **Toda chave nova do `Settings` tem UM destino**: linha no `/config` ou constante em `Settings.Locked` (teste "nenhuma chave escondida" em `test/pokex_web/live/config_live_test.exs:242`).
- **Design system**: só as três classes de texto (`text-pk-meta` / `text-pk-body` / `text-pk-title`), cores por token (`text-pk-*`, `bg-pk-*`, `var(--color-pk-*)`), números que mudam com `pk-num`. `test/pokex_web/design_drift_test.exs` é a cerca.
- **O cérebro não muda neste PR.** `Engine.Logic`, `Engine.Situation`, `Engine.Worker` ficam intocados. Os números da bancada (`Pokex.Sim.*`) não podem mudar: nada aqui é chamado por ela.
- Mensagens de commit em pt-BR, no estilo do repositório (uma frase que diz o que mudou e por quê). Termine cada commit com `Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>`.
- Antes do PR: `mix precommit` (format, compile --warnings-as-errors, deps.unlock --unused, test --warnings-as-errors) e `mix lint` (credo, dialyzer) verdes no worktree. O CI é o portão.

## Medidas de referência (foto real de 03/09 18:22, cliente 3440×1440, `tile_px` 151)

| coisa | medida |
|---|---|
| barra de vida | retângulo 27×4 px, borda preta (1 px), interior 25×2 px |
| preenchimento | `n` colunas de tinta saturada a partir da esquerda; 25 = 100% |
| tinta do preenchimento cheio | (0, 188, 0); amarelo/vermelho com a vida caindo |
| caveira | ~118 px quase brancos (`min > 150`, `max − min < 40`) num quadro de 24×26 centrado na barra, de 14 a 40 px acima da borda superior |
| caixa do número (pokémon dele) | a linha da borda inferior da barra faz parte de uma corrida preta ≥ 54 px (2 barras) |
| corpo da criatura | um tile (151 px) abaixo do centro da barra |
| custo | ~9 ms de captura + ~18 ms de leitura na caixa de 1812×1440 |

Fixtures reais (já cortados da foto, em `test/fixtures/crowd/`):

- `feraligatr_pile.png` — 600×440, origem na foto (600, 560). Barras esperadas (canto superior esquerdo, em px do recorte): Feraligatr com caveira em (142, 205), (444, 205) e (444, 356); Venusaur (caixa do número) em (293, 356). A barra do personagem está escondida por um balão de fala. Personagem em (306, 160).
- `feraligatr_far.png` — 240×220, origem (1540, 80). Um Feraligatr com caveira, barra em (108, 59).

## Mapa de arquivos

| arquivo | papel |
|---|---|
| `lib/pokex/vision/creature_marks.ex` (novo) | pixels → marcas: barra, vida, caveira, caixa; tamanhos como fração do `tile_px` |
| `test/pokex/vision/creature_marks_test.exs` (novo) | quadros sintéticos em duas réguas + os dois recortes reais |
| `test/fixtures/crowd/*.png` (novos) | os recortes reais |
| `lib/pokex/bots/crowd_scan.ex` (reescrito) | `place/3` pura (marcas → tiles) e `look/1` (captura + marcas + evidência) |
| `test/pokex/bots/crowd_scan_test.exs` (reescrito) | geometria, o personagem fora da lista, pokémon = caixa mais perto, evidência |
| `lib/pokex/settings.ex`, `lib/pokex/settings/locked.ex`, `lib/pokex_web/live/config_live.ex` | raio 8, `crowd_scan_every_ms`, `crowd_fact_max_age_ms`, hint novo |
| `lib/pokex/bots/crowd_watch.ex` (reescrito) | cadência por fase, fato `:crowd` inteiro, `{:crowd, reading}` no PubSub, fotos por decisão |
| `test/pokex/bots/crowd_watch_test.exs` (reescrito) | cadência, fato, difusão, fotos |
| `lib/pokex_web/components/siege_components.ex` (novo) | `siege_card/1` |
| `test/pokex_web/components/siege_components_test.exs` (novo) | renderização com leitura, sem leitura, com foto |
| `lib/pokex_web/live/cavebot_live.ex` | o cartão no modo assistir; `{:crowd, reading}`; "foto agora"; sai o bloco "onde eles estão" |
| `test/pokex_web/live/cavebot_live_test.exs` | o cartão na Central |

---

### Task 1: `Vision.CreatureMarks` — a barra, a vida, a caveira e a caixa

**Files:**
- Create: `lib/pokex/vision/creature_marks.ex`
- Create: `test/pokex/vision/creature_marks_test.exs`
- Add: `test/fixtures/crowd/feraligatr_pile.png`, `test/fixtures/crowd/feraligatr_far.png` (já estão no worktree, sem commit)

**Interfaces:**
- Consumes: `%Pokex.Vision.Frame{width, height, rgba, scale}` (RGBA8 row-major), `Pokex.FrameFixtures.of/3` nos testes.
- Produces: `CreatureMarks.find(frame, tile_px: pos_integer) :: [mark]` com `mark :: %{point: {x, y}, hp_pct: 0..100, skull?: boolean, pet?: boolean}` (`point` = centro da barra, em PIXELS do frame); `CreatureMarks.geometry(tile_px) :: %{bar_w, bar_h, skull_above: {min, max}, skull_half_w, skull_px, box_w}`.

- [ ] **Step 1: Escrever o teste do quadro sintético (barra cheia)**

Crie `test/pokex/vision/creature_marks_test.exs`:

```elixir
defmodule Pokex.Vision.CreatureMarksTest do
  use ExUnit.Case, async: true

  alias Pokex.FrameFixtures
  alias Pokex.Vision.{CreatureMarks, Frame}

  @tile 151
  @sand {224, 192, 128}
  @black {0, 0, 0}
  @green {0, 188, 0}
  @white {255, 255, 255}

  # Paints the game's health bar as measured on his client: a 27×4 black
  # rectangle whose 25×2 interior is `fill` columns of ink from the left and
  # black after. Optional skull above and number box below.
  defp scene(w, h, bars) do
    FrameFixtures.of(w, h, fn x, y -> Enum.find_value(bars, @sand, &paint(&1, x, y)) end)
  end

  defp paint(%{x: bx, y: by} = bar, x, y) do
    fill = Map.get(bar, :fill, 25)
    ink = Map.get(bar, :ink, @green)

    cond do
      x >= bx and x < bx + 27 and y >= by and y < by + 4 ->
        inside_x = x - bx - 1
        inside_y = y - by - 1
        if inside_x in 0..24 and inside_y in 0..1 and inside_x < fill, do: ink, else: @black

      Map.get(bar, :skull?) and x in (bx + 6)..(bx + 21) and y in (by - 30)..(by - 15) ->
        @white

      Map.get(bar, :box?) and x in (bx - 25)..(bx + 51) and y in (by + 3)..(by + 18) ->
        @black

      true ->
        nil
    end
  end

  describe "a full health bar on bare ground" do
    test "is one mark at the bar's centre with 100% health" do
      frame = scene(200, 120, [%{x: 60, y: 50}])

      assert [%{point: {73, 52}, hp_pct: 100, skull?: false, pet?: false}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end
end
```

- [ ] **Step 2: Rodar o teste e ver falhar**

Run: `mix test test/pokex/vision/creature_marks_test.exs`
Expected: FAIL — `module Pokex.Vision.CreatureMarks is not available`.

- [ ] **Step 3: Escrever o módulo, com o primitivo do retângulo**

Crie `lib/pokex/vision/creature_marks.ex`:

```elixir
defmodule Pokex.Vision.CreatureMarks do
  @moduledoc """
  Where every creature on the field IS, read from the health bar the client
  draws over each one — the one picture that is the same for a Feraligatr, a
  Venusaur and the character.

  Measured on his own client (2026-09-05, a 1812×1440 capture around the
  character at `tile_px` 151): a 27×4 black rectangle with a 25×2 interior,
  filled from the left with saturated ink for as much health as the creature
  has. Name colour is NOT used — in this client the name is drawn in the
  health colour (green when full), so "red name = hostile" only held for
  creatures already bleeding.

  Two signatures ride with the bar:

    * a **skull** above it — ~118 near-white pixels in a 16×17 icon. In his
      game every level-150+ monster carries one, and an area either has
      skulls on everyone or on nobody.
    * a **number box** under it — a wide black box behind a number, drawn only
      under his own pokémon.

  Every size here is a fraction of the tile, so a client zoom that moves
  `tile_px` moves the whole ruler with it.
  """

  alias Pokex.Vision.Frame

  @reference_tile 151
  @bar_w 27
  @bar_h 4
  @skull_px 118
  @skull_above {14, 40}
  @skull_half_w 12
  @skull_share 0.6
  @box_bars 2

  @black_max 60
  @white_min 150
  @white_spread 40
  @ink_max_min 140
  @ink_min_max 60

  @type mark :: %{
          point: {integer, integer},
          hp_pct: 0..100,
          skull?: boolean,
          pet?: boolean
        }

  @type geometry :: %{
          bar_w: pos_integer,
          bar_h: pos_integer,
          skull_above: {pos_integer, pos_integer},
          skull_half_w: pos_integer,
          skull_px: pos_integer,
          box_w: pos_integer
        }

  @doc "The bar and signature sizes at this tile ruler, scaled from the measured reference."
  @spec geometry(pos_integer) :: geometry
  def geometry(tile_px) when is_integer(tile_px) and tile_px > 0 do
    ratio = tile_px / @reference_tile
    {above_min, above_max} = @skull_above

    %{
      bar_w: max(round(@bar_w * ratio), 5),
      bar_h: max(round(@bar_h * ratio), 4),
      skull_above: {max(round(above_min * ratio), 2), max(round(above_max * ratio), 4)},
      skull_half_w: max(round(@skull_half_w * ratio), 3),
      skull_px: max(round(@skull_px * ratio * ratio), 8),
      box_w: max(round(@bar_w * ratio) * @box_bars, 10)
    }
  end

  @doc """
  Every creature mark in `frame`, top to bottom. `point` is the centre of the
  bar in FRAME pixels; the body stands one tile below it.

  Options: `:tile_px` — the tile ruler in frame pixels (default the reference).
  """
  @spec find(Frame.t(), keyword) :: [mark]
  def find(%Frame{} = frame, opts \\ []) do
    geo = geometry(Keyword.get(opts, :tile_px, @reference_tile))

    frame
    |> candidates(geo)
    |> Enum.flat_map(&bars_at(frame, &1, geo))
    |> Enum.uniq_by(fn {x, y, _fill} -> {x, y} end)
    |> Enum.map(&mark(frame, &1, geo))
    |> Enum.sort_by(fn %{point: {x, y}} -> {y, x} end)
  end

  # --- candidates: runs of fill ink on sampled rows -------------------------
  #
  # The bar's two interior rows have different parity, so sampling every other
  # row meets exactly one of them. A run of ink narrower than the interior is
  # where a bar MAY start; the rectangle test decides.
  defp candidates(%Frame{height: h, width: w, rgba: rgba}, geo) do
    for y <- 0..(h - 1)//2, reduce: [] do
      acc -> row_runs(binary_part(rgba, y * w * 4, w * 4), 0, nil, y, geo, acc)
    end
  end

  defp row_runs(<<r, g, b, _a, rest::binary>>, x, run, y, geo, acc) do
    cond do
      ink?(r, g, b) -> row_runs(rest, x + 1, run || x, y, geo, acc)
      run == nil -> row_runs(rest, x + 1, nil, y, geo, acc)
      true -> row_runs(rest, x + 1, nil, y, geo, keep(acc, run, x - 1, y, geo))
    end
  end

  defp row_runs(<<>>, x, run, y, geo, acc) do
    if run, do: keep(acc, run, x - 1, y, geo), else: acc
  end

  defp keep(acc, start, last, y, geo) do
    if last - start + 1 <= geo.bar_w - 2, do: [{start, y} | acc], else: acc
  end

  # The run is one of the interior rows; the bar's top-left is one column to
  # the left and one to `bar_h - 2` rows up.
  defp bars_at(frame, {start, y}, geo) do
    for k <- 1..(geo.bar_h - 2),
        {:ok, fill} <- [rectangle(frame, start - 1, y - k, geo)],
        do: {start - 1, y - k, fill}
  end

  # --- the rectangle ------------------------------------------------------

  defp rectangle(frame, bx, by, %{bar_w: bw, bar_h: bh}) do
    inside? = bx >= 0 and by >= 0 and bx + bw <= frame.width and by + bh <= frame.height

    with true <- inside?,
         true <- Enum.all?(0..(bw - 1), &(black_at?(frame, bx + &1, by) and black_at?(frame, bx + &1, by + bh - 1))),
         true <- Enum.all?(0..(bh - 1), &(black_at?(frame, bx, by + &1) and black_at?(frame, bx + bw - 1, by + &1))),
         {:ok, fill} <- fill(frame, bx, by, bw, bh) do
      {:ok, fill}
    else
      _not_a_bar -> :no
    end
  end

  # Interior columns are ink from the left and black after — anything else is
  # not a health bar. Zero fill is refused: a plain black rectangle is not a
  # creature, and a creature at zero health is a corpse.
  defp fill(frame, bx, by, bw, bh) do
    rows = 1..(bh - 2)

    kinds =
      for i <- 1..(bw - 2) do
        column = Enum.map(rows, &kind_at(frame, bx + i, by + &1))

        cond do
          Enum.all?(column, &(&1 == :ink)) -> :ink
          Enum.all?(column, &(&1 == :black)) -> :black
          true -> :other
        end
      end

    fill = kinds |> Enum.take_while(&(&1 == :ink)) |> length()
    rest_black? = kinds |> Enum.drop(fill) |> Enum.all?(&(&1 == :black))

    if fill > 0 and rest_black?, do: {:ok, fill}, else: :no
  end

  # --- the mark and its signatures ----------------------------------------

  defp mark(frame, {bx, by, fill}, geo) do
    %{
      point: {bx + div(geo.bar_w, 2), by + div(geo.bar_h, 2)},
      hp_pct: round(100 * fill / (geo.bar_w - 2)),
      skull?: skull?(frame, bx, by, geo),
      pet?: box_below?(frame, bx, by, geo)
    }
  end

  defp skull?(frame, bx, by, geo) do
    cx = bx + div(geo.bar_w, 2)
    {above_min, above_max} = geo.skull_above

    count =
      for y <- (by - above_max)..(by - above_min),
          x <- (cx - geo.skull_half_w)..(cx + geo.skull_half_w),
          white_at?(frame, x, y),
          reduce: 0 do
        n -> n + 1
      end

    count >= round(geo.skull_px * @skull_share)
  end

  # The bottom border of his pokémon's bar is part of the number box's top
  # edge: one black run at least two bars wide. A hostile's bottom border is
  # the bar alone.
  defp box_below?(frame, bx, by, geo) do
    cx = bx + div(geo.bar_w, 2)
    row = by + geo.bar_h - 1

    left = cx |> Stream.iterate(&(&1 - 1)) |> Enum.take_while(&black_at?(frame, &1, row)) |> length()
    right = (cx + 1) |> Stream.iterate(&(&1 + 1)) |> Enum.take_while(&black_at?(frame, &1, row)) |> length()

    left + right >= geo.box_w
  end

  # --- pixels -------------------------------------------------------------

  defp kind_at(frame, x, y) do
    case pixel(frame, x, y) do
      {r, g, b} when r <= @black_max and g <= @black_max and b <= @black_max -> :black
      {r, g, b} -> if ink?(r, g, b), do: :ink, else: :other
      nil -> :other
    end
  end

  defp black_at?(frame, x, y), do: kind_at(frame, x, y) == :black

  defp white_at?(frame, x, y) do
    case pixel(frame, x, y) do
      {r, g, b} -> min(min(r, g), b) > @white_min and max(max(r, g), b) - min(min(r, g), b) < @white_spread
      nil -> false
    end
  end

  # Fill ink is one channel high and another near zero — sand (224,192,128)
  # and skin never qualify, green/yellow/red health always does.
  defp ink?(r, g, b), do: max(max(r, g), b) > @ink_max_min and min(min(r, g), b) < @ink_min_max

  defp pixel(%Frame{width: w, height: h, rgba: rgba}, x, y)
       when x >= 0 and y >= 0 and x < w and y < h do
    <<r, g, b, _a>> = binary_part(rgba, (y * w + x) * 4, 4)
    {r, g, b}
  end

  defp pixel(_frame, _x, _y), do: nil
end
```

- [ ] **Step 4: Rodar o teste e ver passar**

Run: `mix test test/pokex/vision/creature_marks_test.exs`
Expected: `1 test, 0 failures`.

- [ ] **Step 5: Testes de vida, caveira, caixa, régua dobrada e ruído**

Acrescente ao `describe` existente e crie os seguintes no mesmo arquivo:

```elixir
  describe "health" do
    test "the fill length is the health" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 12}])
      assert [%{hp_pct: 48}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "one column of red ink is a creature nearly dead, not nothing" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 1, ink: {200, 30, 30}}])
      assert [%{hp_pct: 4}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "a black rectangle with no ink is not a creature" do
      frame = scene(200, 120, [%{x: 60, y: 50, fill: 0}])
      assert CreatureMarks.find(frame, tile_px: @tile) == []
    end
  end

  describe "signatures" do
    test "a skull above the bar marks the heavy monster" do
      frame = scene(200, 120, [%{x: 60, y: 50, skull?: true}])
      assert [%{skull?: true, pet?: false}] = CreatureMarks.find(frame, tile_px: @tile)
    end

    test "a number box under the bar marks his own pokémon" do
      frame = scene(200, 120, [%{x: 60, y: 50, box?: true}])
      assert [%{pet?: true, skull?: false}] = CreatureMarks.find(frame, tile_px: @tile)
    end
  end

  describe "the ruler" do
    test "sizes scale with the tile" do
      assert %{bar_w: 27, bar_h: 4, box_w: 54, skull_px: 118} = CreatureMarks.geometry(151)
      assert %{bar_w: 54, bar_h: 8, box_w: 108, skull_px: 472} = CreatureMarks.geometry(302)
    end

    test "a bar drawn at a doubled tile is found with the doubled ruler and not with the reference" do
      # 54×8 rectangle, 52×6 interior, 30 of 52 columns filled
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          cond do
            x in 60..113 and y in 50..57 ->
              if x in 61..112 and y in 51..56 and x - 61 < 30, do: @green, else: @black

            true ->
              @sand
          end
        end)

      assert [%{point: {87, 54}, hp_pct: 58}] = CreatureMarks.find(frame, tile_px: 302)
      assert CreatureMarks.find(frame, tile_px: 151) == []
    end
  end

  describe "noise" do
    test "a red crest and sand are not bars" do
      frame =
        FrameFixtures.of(200, 120, fn x, y ->
          if x in 40..60 and y in 30..60, do: {150, 30, 50}, else: @sand
        end)

      assert CreatureMarks.find(frame, tile_px: @tile) == []
    end

    test "two bars on the same row are two marks" do
      frame = scene(300, 120, [%{x: 20, y: 50}, %{x: 200, y: 50, fill: 5}])
      assert [%{point: {33, 52}, hp_pct: 100}, %{point: {213, 52}, hp_pct: 20}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end

  describe "his own screen" do
    test "the pile: three skulls and his Venusaur" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_pile.png")

      marks = CreatureMarks.find(frame, tile_px: @tile)

      assert Enum.count(marks, & &1.skull?) == 3
      assert [%{point: {306, 358}, hp_pct: 100}] = Enum.filter(marks, & &1.pet?)
      assert Enum.map(marks, & &1.hp_pct) |> Enum.all?(&(&1 == 100))
      assert Enum.sort(Enum.map(marks, & &1.point)) ==
               Enum.sort([{155, 207}, {457, 207}, {306, 358}, {457, 358}])
    end

    test "one far Feraligatr alone" do
      {:ok, frame} = Frame.from_png_file("test/fixtures/crowd/feraligatr_far.png")

      assert [%{point: {121, 61}, hp_pct: 100, skull?: true, pet?: false}] =
               CreatureMarks.find(frame, tile_px: @tile)
    end
  end
```

- [ ] **Step 6: Rodar tudo e ajustar as coordenadas do recorte real se for o caso**

Run: `mix test test/pokex/vision/creature_marks_test.exs`
Expected: `12 tests, 0 failures`. Se um ponto do recorte real falhar por ±1 px, imprima as marcas (`IO.inspect(marks)`), confira contra a tabela de referência (barras em (142,205), (444,205), (444,356), (293,356) no recorte da pilha; (108,59) no recorte solto) e corrija a asserção — nunca o detector — quando a diferença for só o arredondamento do centro.

- [ ] **Step 7: Commit**

```bash
git add lib/pokex/vision/creature_marks.ex test/pokex/vision/creature_marks_test.exs test/fixtures/crowd/feraligatr_pile.png test/fixtures/crowd/feraligatr_far.png
git commit -m "a criatura é a barra de vida: caveira em cima, caixa do número embaixo

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 2: `CrowdScan` v2 — marcas → tiles de VOCÊ e do pokémon

**Files:**
- Rewrite: `lib/pokex/bots/crowd_scan.ex`
- Rewrite: `test/pokex/bots/crowd_scan_test.exs`

**Interfaces:**
- Consumes: `CreatureMarks.find/2`; `Pokex.Calibration.load/0`, `player_point/1`, `tile_px/0`; `Pokex.Bots.Capture.frame/2` → `{:ok, %Frame{}}`; `Pokex.Vision.Evidence.data_url/2`.
- Produces:
  - `CrowdScan.place(marks, me, tile_px) :: placed` — pura. `me = {px, py}` em pontos de tela; `marks` já em pontos de TELA (centro da barra).
  - `CrowdScan.look(opts) :: reading`.
  - Tipos:

```elixir
@type hostile :: %{point: {integer, integer}, dx: integer, dy: integer,
                   from_me: non_neg_integer, from_pet: non_neg_integer | nil,
                   hp_pct: 0..100, skull?: boolean}
@type pet :: %{point: {integer, integer}, dx: integer, dy: integer,
               tiles: non_neg_integer, hp_pct: 0..100}
@type placed :: %{read?: true, me: {integer, integer}, pet: pet | nil, hostiles: [hostile]}
@type reading :: %{read?: true, at: integer, took_ms: non_neg_integer,
                   me: {integer, integer}, box: {integer, integer, integer, integer},
                   pet: pet | nil, hostiles: [hostile], listed: non_neg_integer | nil,
                   evidence: String.t() | nil}
                | %{read?: false, reason: atom}
```

  `at` é `System.monotonic_time(:millisecond)`; `box` é a região capturada em pontos de tela; `listed` vem do caller (`:listed` em `opts`), `nil` quando ninguém passou.

- [ ] **Step 1: Escrever os testes de `place/3` (puros, sem captura)**

Substitua `test/pokex/bots/crowd_scan_test.exs` por:

```elixir
defmodule Pokex.Bots.CrowdScanTest do
  @moduledoc """
  Marks on the screen become tiles from HIM and from his pokémon.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdScan
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  @tile 100
  @screen 1600
  @me {800, 800}

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)

    # radius 3: the painted capture is 600×600 instead of 1200×1200 — the
    # geometry under test is the same, the test runs in a blink.
    SettingsStash.stash!(tile_px: @tile, crowd_scan_radius_tiles: 3)

    Calibration.save(%Calibration{
      scale: 1.0,
      screen_w: @screen,
      screen_h: @screen,
      player_point: @me
    })

    :ok
  end

  # A mark whose BODY stands `{dx, dy}` tiles from him: the bar is one tile up.
  defp mark({dx, dy}, opts \\ []) do
    {px, py} = @me

    %{
      point: {px + dx * @tile, py + dy * @tile - @tile},
      hp_pct: Keyword.get(opts, :hp, 100),
      skull?: Keyword.get(opts, :skull?, false),
      pet?: Keyword.get(opts, :pet?, false)
    }
  end

  describe "placing marks" do
    test "a creature two right and two down is two tiles from him" do
      placed = CrowdScan.place([mark({2, 2})], @me, @tile)

      assert placed.read?
      assert placed.pet == nil
      assert [%{dx: 2, dy: 2, from_me: 2, from_pet: nil, hp_pct: 100, skull?: false}] = placed.hostiles
    end

    test "distance is Chebyshev in whole tiles" do
      assert [%{from_me: 3, dx: 0, dy: 3}] = CrowdScan.place([mark({0, 3})], @me, @tile).hostiles
      assert [%{from_me: 3, dx: -3, dy: 1}] = CrowdScan.place([mark({-3, 1})], @me, @tile).hostiles
    end

    test "hostiles come nearest to him first" do
      placed = CrowdScan.place([mark({5, 0}), mark({1, 1}), mark({-3, 0})], @me, @tile)
      assert Enum.map(placed.hostiles, & &1.from_me) == [1, 3, 5]
    end

    test "the mark standing on his own tile is him, not a hostile" do
      placed = CrowdScan.place([mark({0, 0}), mark({2, 0})], @me, @tile)
      assert length(placed.hostiles) == 1
    end
  end

  describe "his pokémon" do
    test "is the number-boxed mark nearest to him, and every hostile is also measured from it" do
      placed = CrowdScan.place([mark({0, 2}, pet?: true), mark({1, 3}), mark({-4, 2})], @me, @tile)

      assert %{dx: 0, dy: 2, tiles: 2, hp_pct: 100} = placed.pet
      assert [%{from_me: 3, from_pet: 1}, %{from_me: 4, from_pet: 4}] = placed.hostiles
    end

    test "another boxed creature farther away is a hostile, not a second pet" do
      placed = CrowdScan.place([mark({0, 2}, pet?: true), mark({5, 5}, pet?: true)], @me, @tile)

      assert placed.pet.dx == 0
      assert [%{dx: 5, dy: 5}] = placed.hostiles
    end

    test "without a boxed mark there is no pet and from_pet is nil" do
      placed = CrowdScan.place([mark({1, 1})], @me, @tile)
      assert placed.pet == nil
      assert [%{from_pet: nil}] = placed.hostiles
    end
  end

  describe "looking at the screen" do
    test "a capture that fails says so instead of reporting an empty field" do
      reading = CrowdScan.look(capture: fn _region, _name -> {:error, :no_display} end)
      assert reading == %{read?: false, reason: :no_display}
    end

    test "no calibration is a reason, not a zero" do
      File.rm!(Pokex.Home.calibration_file())

      assert %{read?: false, reason: :not_calibrated} =
               CrowdScan.look(capture: fn _r, _n -> {:error, :never_called} end)
    end

    test "a bar painted on the captured box comes back placed, with the box and the clock" do
      # one creature two tiles right of him: its bar sits one tile above its body
      reading = look_at([{2, 2}], listed: 3)

      assert reading.read?
      assert reading.listed == 3
      assert is_integer(reading.at)
      assert {500, 500, 600, 600} = reading.box
      assert [%{dx: 2, dy: 2, from_me: 2, hp_pct: 100}] = reading.hostiles
      assert reading.evidence == nil
    end

    test "asked for, the evidence is a picture a browser can draw" do
      reading = look_at([{2, 2}], evidence: true)

      assert "data:image/bmp;base64," <> b64 = reading.evidence
      assert {:ok, <<"BM", _rest::binary>>} = Base.decode64(b64)
    end
  end

  # Paints a 27×4 health bar (full, green) one tile above each body point,
  # inside the box the scan asks for, and hands it to `look/1` as the capture.
  defp look_at(bodies, opts) do
    {px, py} = @me

    capture = fn {rx, ry, w, h}, _name ->
      bars =
        Enum.map(bodies, fn {dx, dy} ->
          {px + dx * @tile - 13 - rx, py + dy * @tile - @tile - 2 - ry}
        end)

      rgba =
        for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
          case Enum.find(bars, fn {bx, by} -> x >= bx and x < bx + 27 and y >= by and y < by + 4 end) do
            {bx, by} -> if x > bx and x < bx + 26 and y > by and y < by + 3, do: <<0, 188, 0, 255>>, else: <<0, 0, 0, 255>>
            nil -> <<224, 192, 128, 255>>
          end
        end

      {:ok, %Frame{width: w, height: h, rgba: rgba, scale: 1.0}}
    end

    CrowdScan.look(Keyword.put(opts, :capture, capture))
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/pokex/bots/crowd_scan_test.exs`
Expected: FAIL — `CrowdScan.place/3 is undefined`.

- [ ] **Step 3: Reescrever o módulo**

Substitua `lib/pokex/bots/crowd_scan.ex` por:

```elixir
defmodule Pokex.Bots.CrowdScan do
  @moduledoc """
  Where every creature around the character stands, in tiles from HIM and
  from his pokémon.

  ## Measured from the character, always

  The calibrated character point never disappears and is never mistaken for
  a monster. His pokémon is one more mark — the one with the number box under
  its bar, nearest to him — and it is optional: without it `from_pet` is
  `nil`, and a consumer knows it only has distances from the character.

  ## Marks in, tiles out

  `Pokex.Vision.CreatureMarks` turns pixels into bar marks; `place/3` turns
  marks into tiles and is pure, so the simulator can feed it the marks its
  own world would draw. `look/1` is the only function here that touches the
  screen.

  ## It shows its work

  With `evidence: true` the reading carries the captured box with the marks
  drawn on it: bars boxed (blue hostile, green pet), skulls tagged, a magenta
  cross where the character is. A number cannot say whether the detector, the
  anchor or the ruler was wrong; a picture can.

  ## Cost

  Measured on the live server log (2026-09-05): ~9 ms for the capture of a
  1812×1440 box and ~18 ms for the read. A per-tick cost, not a per-decision
  one.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Calibration
  alias Pokex.Vision.{CreatureMarks, Evidence, Frame}

  @hostile_box {0, 220, 255}
  @pet_box {0, 255, 120}
  @skull_box {255, 255, 255}
  @me_cross {255, 0, 255}

  # A mark whose body stands within this many tiles of the character IS the
  # character (his own bar floats over his head).
  @me_tiles 0.6

  @type hostile :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          from_me: non_neg_integer,
          from_pet: non_neg_integer | nil,
          hp_pct: 0..100,
          skull?: boolean
        }
  @type pet :: %{
          point: {integer, integer},
          dx: integer,
          dy: integer,
          tiles: non_neg_integer,
          hp_pct: 0..100
        }
  @type placed :: %{read?: true, me: {integer, integer}, pet: pet | nil, hostiles: [hostile]}
  @type reading ::
          %{
            read?: true,
            at: integer,
            took_ms: non_neg_integer,
            me: {integer, integer},
            box: {integer, integer, integer, integer},
            pet: pet | nil,
            hostiles: [hostile],
            listed: non_neg_integer | nil,
            evidence: String.t() | nil
          }
          | %{read?: false, reason: atom}

  @doc """
  Captures the box around the character and places every creature in it.

  Options:

    * `:radius_tiles` — how far out to look (default `crowd_scan_radius_tiles`)
    * `:listed` — the battle-list count to carry alongside, when the caller has one
    * `:evidence` — also return the picture it read, with the marks drawn on
    * `:capture` — injected for tests
  """
  @spec look(keyword) :: reading
  def look(opts \\ []) do
    started = System.monotonic_time(:millisecond)
    radius = Keyword.get(opts, :radius_tiles, Pokex.Settings.get(:crowd_scan_radius_tiles))
    capture = Keyword.get(opts, :capture, &Capture.frame/2)

    with {:ok, calib} <- calibration(),
         {px, py} when is_integer(px) <- Calibration.player_point(calib),
         box = box_around({px, py}, radius, calib),
         {:ok, frame} <- capture.(box, "crowd_scan.raw") do
      scale = frame_scale(frame)
      tile = Calibration.tile_px()
      found = CreatureMarks.find(frame, tile_px: round(tile * scale))
      marks = Enum.map(found, &to_screen(&1, box, scale))

      marks
      |> place({px, py}, tile)
      |> Map.merge(%{
        at: started,
        took_ms: System.monotonic_time(:millisecond) - started,
        box: box,
        listed: Keyword.get(opts, :listed),
        evidence: evidence(opts, frame, found, box, {px, py}, scale)
      })
    else
      {:error, reason} -> %{read?: false, reason: reason}
      :not_calibrated -> %{read?: false, reason: :not_calibrated}
      _no_anchor -> %{read?: false, reason: :no_player_point}
    end
  end

  @doc """
  Marks (bar centres, in screen points) placed in tiles from `me` and from
  his pokémon. Pure: the simulator calls it with the marks its world draws.
  """
  @spec place([CreatureMarks.mark()], {integer, integer}, pos_integer) :: placed
  def place(marks, {px, py} = me, tile) do
    bodies =
      marks
      |> Enum.map(fn %{point: {x, y}} = mark -> %{mark | point: {x, y + tile}} end)
      |> Enum.reject(&(chebyshev(&1.point, me) <= @me_tiles * tile))

    pet =
      bodies
      |> Enum.filter(& &1.pet?)
      |> Enum.min_by(&chebyshev(&1.point, me), fn -> nil end)

    hostiles =
      bodies
      |> Enum.reject(&(&1 == pet))
      |> Enum.map(&hostile(&1, me, pet, tile))
      |> Enum.sort_by(&{&1.from_me, &1.dx, &1.dy})

    %{read?: true, me: {px, py}, pet: pet && pet_of(pet, me, tile), hostiles: hostiles}
  end

  # --- geometry ------------------------------------------------------------

  defp hostile(%{point: point, hp_pct: hp, skull?: skull?}, me, pet, tile) do
    {dx, dy} = offset(point, me, tile)

    %{
      point: point,
      dx: dx,
      dy: dy,
      from_me: max(abs(dx), abs(dy)),
      from_pet: pet && tiles_between(point, pet.point, tile),
      hp_pct: hp,
      skull?: skull?
    }
  end

  defp pet_of(%{point: point, hp_pct: hp}, me, tile) do
    {dx, dy} = offset(point, me, tile)
    %{point: point, dx: dx, dy: dy, tiles: max(abs(dx), abs(dy)), hp_pct: hp}
  end

  defp offset({x, y}, {px, py}, tile), do: {round((x - px) / tile), round((y - py) / tile)}

  defp tiles_between(a, b, tile) do
    {dx, dy} = offset(a, b, tile)
    max(abs(dx), abs(dy))
  end

  defp chebyshev({ax, ay}, {bx, by}), do: max(abs(ax - bx), abs(ay - by))

  # Frame pixels → screen points: the box's origin plus the pixel over the
  # backend's scale.
  defp to_screen(%{point: {x, y}} = mark, {rx, ry, _w, _h}, scale),
    do: %{mark | point: {rx + round(x / scale), ry + round(y / scale)}}

  defp evidence(opts, frame, marks, {rx, ry, _w, _h}, {px, py}, scale) do
    if Keyword.get(opts, :evidence, false) do
      %{bar_w: bw, bar_h: bh} = CreatureMarks.geometry(round(Calibration.tile_px() * scale))

      boxes =
        Enum.flat_map(marks, fn %{point: {x, y}} = mark ->
          bar = %{x: x - div(bw, 2), y: y - div(bh, 2), w: bw, h: bh, colour: if(mark.pet?, do: @pet_box, else: @hostile_box)}

          if mark.skull?,
            do: [bar, %{x: x - 8, y: y - 34, w: 16, h: 17, colour: @skull_box}],
            else: [bar]
        end)

      Evidence.data_url(frame,
        shrink: Pokex.Settings.get(:crowd_scan_evidence_shrink),
        boxes: boxes,
        marks: [{round((px - rx) * scale), round((py - ry) * scale), @me_cross}]
      )
    end
  end

  defp frame_scale(%Frame{scale: scale}) when is_number(scale) and scale > 0, do: scale
  defp frame_scale(_frame), do: 1.0

  defp box_around({px, py}, radius_tiles, %Calibration{screen_w: sw, screen_h: sh}) do
    radius = radius_tiles * Calibration.tile_px()
    x = max(px - radius, 0)
    y = max(py - radius, 0)
    w = min(2 * radius, max(sw, 1) - x)
    h = min(2 * radius, max(sh, 1) - y)

    {x, y, max(w, 1), max(h, 1)}
  end

  defp calibration do
    case Calibration.load() do
      {:ok, %Calibration{screen_w: w, screen_h: h} = calib} when is_integer(w) and is_integer(h) ->
        {:ok, calib}

      _no_calibration ->
        :not_calibrated
    end
  end
end
```

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/pokex/bots/crowd_scan_test.exs test/pokex/vision/creature_marks_test.exs`
Expected: todos verdes. Se `look_at/2` falhar no `box` esperado `{500, 500, 600, 600}`: raio 3 × tile 100 = 300 em volta de (800, 800) numa tela de 1600 — confira que o `SettingsStash` está sendo aplicado antes do `look`.

- [ ] **Step 5: Compilar sem avisos (o `cavebot_live.ex` ainda chama `CrowdScan.look` com a forma antiga — isso é tarefa 6; aqui só o compilador precisa passar)**

Run: `mix compile --warnings-as-errors`
Expected: sem avisos. `within/2` e `nearest/1` saíram e não tinham chamador fora dos testes antigos.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/crowd_scan.ex test/pokex/bots/crowd_scan_test.exs
git commit -m "o olho mede de VOCÊ: marcas viram tiles do personagem e do pokémon

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 3: as chaves — raio 8, cadência e validade da foto

**Files:**
- Modify: `lib/pokex/settings.ex` (bloco `crowd_*` em ~`:705-716` e `@ranges` em ~`:900`)
- Modify: `lib/pokex/settings/locked.ex` (`:232-234`)
- Modify: `lib/pokex_web/live/config_live.ex` (`:353-360`, o hint de `crowd_watch_enabled`)

**Interfaces:**
- Produces: `Settings.get(:crowd_scan_radius_tiles) == 8`, `Settings.get(:crowd_scan_every_ms) == 250`, `Settings.get(:crowd_fact_max_age_ms) == 600`.

- [ ] **Step 1: Teste de valor das chaves novas**

Acrescente ao final de `test/pokex/bots/crowd_watch_test.exs` (o arquivo será reescrito na tarefa 4; este teste sobrevive):

```elixir
  describe "the eye's keys" do
    test "the box covers the game viewport and the clock is a fight clock" do
      assert Pokex.Settings.defaults()[:crowd_scan_radius_tiles] == 8
      assert Pokex.Settings.defaults()[:crowd_scan_every_ms] == 250
      assert Pokex.Settings.defaults()[:crowd_fact_max_age_ms] == 600
    end
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/pokex/bots/crowd_watch_test.exs --only describe:"the eye's keys"`
Expected: FAIL — `8 != 6` (e as outras chaves `nil`).

- [ ] **Step 3: Declarar as chaves**

Em `lib/pokex/settings.ex`, substitua o bloco atual:

```elixir
    # --- Onde estão os monstros (leitura, não regra) ----------------------------------------------
    # How far out `Pokex.Bots.CrowdScan` looks when asked. The box it captures is
    # this many tiles in EVERY direction, so raising it costs area quadratically —
    # 6 already covers more than any area skill in the game reaches.
    # O OLHO DA ESPERA (fase 1, 02/09): fotografa ao redor do pokémon enquanto o cérebro
    # espera o bolo e escreve no feed quantos estão a 1 tile. Só mede.
    crowd_watch_enabled: true,
    crowd_scan_radius_tiles: 6,
    # How much the evidence picture is shrunk before it is drawn.
    crowd_scan_evidence_shrink: 4,
```

por:

```elixir
    # --- Onde estão os monstros (leitura, não regra) ----------------------------------------------
    # The eye: `Pokex.Bots.CrowdWatch` photographs the box around the character
    # and publishes every creature's tiles. Nothing decides on it yet (PR 1).
    crowd_watch_enabled: true,
    # The box is this many tiles in EVERY direction. 8 covers the whole game
    # viewport (15×11): a creature the battle list counts but the box cannot
    # see would read as hidden, and hold a revive from something far away.
    crowd_scan_radius_tiles: 8,
    # How often the eye looks during a fight; walking with an empty list it
    # looks once a second. Measured ~30 ms a look (2026-09-05).
    crowd_scan_every_ms: 250,
    # A `:crowd` fact older than this is no eye at all.
    crowd_fact_max_age_ms: 600,
    # How much the evidence picture is shrunk before it is drawn.
    crowd_scan_evidence_shrink: 4,
```

No mapa `@ranges`, logo abaixo de `crowd_scan_radius_tiles: 1..20,`, acrescente:

```elixir
    crowd_scan_every_ms: 100..5_000,
    crowd_fact_max_age_ms: 200..5_000,
```

Em `lib/pokex/settings/locked.ex`, substitua a entrada de `crowd_scan_radius_tiles` e acrescente as duas novas:

```elixir
    crowd_scan_radius_tiles: {"Onde estão os monstros (visão)", "a foto ao redor cobre a tela do jogo inteira (8 tiles)"},
    crowd_scan_every_ms: {"Onde estão os monstros (visão)", "em luta olha 4× por segundo (~30 ms cada)"},
    crowd_fact_max_age_ms: {"Onde estão os monstros (visão)", "foto mais velha que 0,6 s não vale"},
```

Em `lib/pokex_web/live/config_live.ex`, na linha de `crowd_watch_enabled`, troque `label` e `hint`:

```elixir
          label: "O olho do cerco (só mede)",
          hint:
            "Em luta, fotografa a tela em volta do personagem 4× por segundo e desenha na Central " <>
              "onde cada bicho está, a vida, a caveira e o seu pokémon. Ainda não decide nada por isso.",
```

- [ ] **Step 4: Rodar os testes das chaves e do /config**

Run: `mix test test/pokex/bots/crowd_watch_test.exs test/pokex_web/live/config_live_test.exs`
Expected: verdes, inclusive "nenhuma chave escondida".

- [ ] **Step 5: Commit**

```bash
git add lib/pokex/settings.ex lib/pokex/settings/locked.ex lib/pokex_web/live/config_live.ex test/pokex/bots/crowd_watch_test.exs
git commit -m "o olho cobre a tela inteira, olha 4x por segundo em luta e uma foto de 0,6s não vale

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 4: `CrowdWatch` v2 — cadência, o fato inteiro, a difusão e as fotos por decisão

**Files:**
- Rewrite: `lib/pokex/bots/crowd_watch.ex`
- Rewrite: `test/pokex/bots/crowd_watch_test.exs` (mantendo o `describe "the eye's keys"` da tarefa 3)

**Interfaces:**
- Consumes: `CrowdScan.look/1` (injetável por `:look`); `WorldState.get(:orders, …)` (`%{phase, why, revive}`), `WorldState.get(:battle, …)` (`%{enemies: [rows]}`); PubSub `"engine"` recebendo `{:engine, picture, orders}` do `Engine.Worker`.
- Produces:
  - fato `:crowd` = o `reading` do `CrowdScan` **sem** `:evidence` (a foto não entra no quadro);
  - difusão `{:crowd, reading}` no tópico `"engine"` a cada leitura;
  - `CrowdWatch.look_now(server \\ __MODULE__) :: CrowdScan.reading()` — uma leitura agora, COM evidência, publicada e difundida;
  - fotos em `captures/crowd/<ts>-<tag>.png`, `tag ∈ open | revive | held`, trinta guardadas;
  - linha do feed `olho: 👀 …` a cada leitura que mudou.

- [ ] **Step 1: Escrever os testes**

Substitua `test/pokex/bots/crowd_watch_test.exs` por (mantendo o `describe "the eye's keys"` no fim):

```elixir
defmodule Pokex.Bots.CrowdWatchTest do
  @moduledoc """
  The eye: looks on a fight clock, publishes the whole reading, tells the
  page, and keeps a photo of every revive decision. Decides nothing.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.CrowdWatch
  alias Pokex.Perception.WorldState
  alias Pokex.SettingsStash

  @bmp "data:image/bmp;base64," <> Base.encode64("bmp-de-mentira")

  setup %{tmp_dir: tmp} do
    WorldState.clear()
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Pokex.TestHome.restore() end)
    SettingsStash.stash!(crowd_watch_enabled: true)
    Phoenix.PubSub.subscribe(Pokex.PubSub, "engine")

    test = self()

    look = fn opts ->
      send(test, {:looked, opts})

      %{
        read?: true,
        at: now(),
        took_ms: 12,
        me: {800, 800},
        box: {200, 200, 1200, 1200},
        pet: %{point: {800, 1000}, dx: 0, dy: 2, tiles: 2, hp_pct: 96},
        hostiles: [
          %{point: {900, 1000}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: true},
          %{point: {1300, 500}, dx: 5, dy: -3, from_me: 5, from_pet: 5, hp_pct: 100, skull?: true}
        ],
        listed: opts[:listed],
        evidence: if(opts[:evidence], do: @bmp)
      }
    end

    pid = start_supervised!({CrowdWatch, name: nil, active: true, look: look})
    %{watch: pid}
  end

  defp orders!(phase, opts \\ []) do
    WorldState.put(
      :orders,
      %{phase: phase, why: Keyword.get(opts, :why, "teste"), revive: Keyword.get(opts, :revive, :hold)},
      now()
    )
  end

  defp battle!(n), do: WorldState.put(:battle, %{enemies: Enum.to_list(1..n//1), captured_at: now()}, now())

  defp now, do: System.monotonic_time(:millisecond)

  @tag :tmp_dir
  test "in a fight it looks, publishes the whole reading without the picture, and tells the page", %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    reading = CrowdWatch.look_now(watch)

    assert_receive {:looked, opts}
    assert opts[:listed] == 3
    assert reading.evidence == @bmp
    assert {:ok, crowd} = WorldState.get(:crowd, 5_000, now())
    assert crowd.listed == 3
    assert length(crowd.hostiles) == 2
    assert crowd.pet.tiles == 2
    refute Map.has_key?(crowd, :evidence)
    assert_receive {:crowd, %{hostiles: [_, _]}}
  end

  @tag :tmp_dir
  test "the feed line says what it saw, once per change", %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    CrowdWatch.look_now(watch)
    CrowdWatch.look_now(watch)

    assert_receive {:engine_log, :macro, "olho: 👀 vi 2 (lista 3) · pokémon a 2 tiles · mais perto a 2 tiles · caveira · 12ms"}
    refute_receive {:engine_log, :macro, "olho: 👀" <> _}, 100
  end

  @tag :tmp_dir
  test "the clock is a fight clock: 250ms with enemies or a revive pending, 1s walking clear, idle without a hunt", %{watch: watch} do
    battle!(0)
    orders!(:travelling)
    assert CrowdWatch.next_look_ms(watch) == 1_000

    battle!(2)
    assert CrowdWatch.next_look_ms(watch) == 250

    battle!(0)
    orders!(:travelling, revive: :prepare)
    assert CrowdWatch.next_look_ms(watch) == 250

    orders!(:engaged)
    assert CrowdWatch.next_look_ms(watch) == 250

    WorldState.forget(:orders)
    assert CrowdWatch.next_look_ms(watch) == :idle
  end

  @tag :tmp_dir
  test "without a hunt or switched off it does not look", %{watch: watch} do
    battle!(3)
    assert CrowdWatch.look_now(watch) == %{read?: false, reason: :no_hunt}
    refute_receive {:looked, _}, 50

    orders!(:engaged)
    SettingsStash.stash!(crowd_watch_enabled: false)
    assert CrowdWatch.look_now(watch) == %{read?: false, reason: :disabled}
    refute_receive {:looked, _}, 50
  end

  @tag :tmp_dir
  test "the fight opening keeps a photo", %{watch: watch} do
    orders!(:bunching)
    battle!(3)
    CrowdWatch.look_now(watch)

    send(watch, {:engine, %{}, %{phase: :engaged, why: "matando", revive: :hold}})
    :sys.get_state(watch)

    dir = Path.join(Pokex.Home.captures_dir(), "crowd")
    assert [photo] = File.ls!(dir)
    assert photo =~ "-open.png"
    assert File.read!(Path.join(dir, photo)) == "bmp-de-mentira"
  end

  @tag :tmp_dir
  test "every revive decision keeps a photo named by the verdict, once per sentence", %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    send(watch, {:engine, %{}, %{phase: :engaged, why: "revive agora", revive: :now}})
    send(watch, {:engine, %{}, %{phase: :engaged, why: "revive agora", revive: :now}})
    send(watch, {:engine, %{}, %{phase: :engaged, why: "parado — segurando o revive: 2 na tela", revive: :hold}})
    send(watch, {:engine, %{}, %{phase: :travelling, why: "andando", revive: :prepare}})
    :sys.get_state(watch)

    dir = Path.join(Pokex.Home.captures_dir(), "crowd")
    tags = dir |> File.ls!() |> Enum.map(&(&1 |> String.split("-") |> List.last())) |> Enum.sort()
    assert tags == ["held.png", "revive.png", "revive.png"]
  end

  @tag :tmp_dir
  test "only thirty photos stay", %{watch: watch} do
    orders!(:engaged)
    battle!(3)

    for i <- 1..33 do
      send(watch, {:engine, %{}, %{phase: :engaged, why: "revive #{i}", revive: :now}})
    end

    :sys.get_state(watch)
    assert Path.join(Pokex.Home.captures_dir(), "crowd") |> File.ls!() |> length() == 30
  end

  describe "the eye's keys" do
    test "the box covers the game viewport and the clock is a fight clock" do
      assert Pokex.Settings.defaults()[:crowd_scan_radius_tiles] == 8
      assert Pokex.Settings.defaults()[:crowd_scan_every_ms] == 250
      assert Pokex.Settings.defaults()[:crowd_fact_max_age_ms] == 600
    end
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/pokex/bots/crowd_watch_test.exs`
Expected: FAIL nos testes novos (`next_look_ms/1` indefinido, `look_now` devolvendo `:ok`, etc.).

- [ ] **Step 3: Reescrever o vigia**

Substitua `lib/pokex/bots/crowd_watch.ex` por:

```elixir
defmodule Pokex.Bots.CrowdWatch do
  @moduledoc """
  THE EYE — it measures, publishes and photographs. It decides nothing (PR 1).

  Every `crowd_scan_every_ms` during a fight (enemies listed, or a revive
  pending), once a second walking with an empty list, it captures the box
  around the character, places every creature (`Pokex.Bots.CrowdScan`) and
  writes the whole reading to the `:crowd` fact — positions included, which
  the first eye threw away. The page learns of every reading by PubSub.

  ## Photos as proof

  Two moments keep a picture with the marks drawn on: the fight opening
  (`open`) and every revive decision the brain makes — fired (`revive`) or
  held by the sleep fence (`held`). The file name carries the verdict. Thirty
  stay. A death is investigated from these.

  ## Cost

  ~9 ms capture + ~18 ms read, measured 2026-09-05. Four looks a second is
  under 12% of the helper's time; `crowd_watch.battle_age_ms` in `Perf` says
  whether the battle feed ever waited behind it.
  """
  use GenServer

  alias Pokex.Bots.CrowdScan
  alias Pokex.Bots.Perf
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  @topic "engine"
  @walk_ms 1_000
  @idle_ms 1_000
  @keep_photos 30
  @waiting [:bunching, :sizing]
  @no_hunt [nil, :idle, :guarding]

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :crowd_watch_active, true)),
      look: Keyword.get(opts, :look, &CrowdScan.look/1),
      last: nil,
      last_phase: nil,
      last_line: nil,
      last_why: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "One reading now, WITH the picture — the page's button. Published and broadcast like any other."
  @spec look_now(GenServer.server()) :: CrowdScan.reading()
  def look_now(server \\ __MODULE__), do: GenServer.call(server, :look_now)

  @doc "How long until the next look on the clock, for the current picture (tests)."
  @spec next_look_ms(GenServer.server()) :: pos_integer | :idle
  def next_look_ms(server \\ __MODULE__), do: GenServer.call(server, :next_look_ms)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, @topic)
    schedule(@idle_ms)
    {:ok, state}
  end

  @impl true
  def handle_call(:look_now, _from, state) do
    case allowed(state, now()) do
      :ok ->
        {reading, state} = look(state, now(), evidence: true)
        {:reply, reading, state}

      {:error, reason} ->
        {:reply, %{read?: false, reason: reason}, state}
    end
  end

  def handle_call(:next_look_ms, _from, state), do: {:reply, cadence(now()), state}

  @impl true
  def handle_info(:look, state) do
    now = now()

    state =
      case {allowed(state, now), cadence(now)} do
        {:ok, ms} when is_integer(ms) -> state |> look(now, evidence: false) |> elem(1)
        _idle_or_off -> state
      end

    schedule(
      case cadence(now) do
        :idle -> @idle_ms
        ms -> ms
      end
    )

    {:noreply, state}
  end

  # The brain spoke: the opening and every revive decision keep a photo.
  def handle_info({:engine, _picture, orders}, state) do
    {:noreply, state |> photo_on_opening(orders) |> photo_on_decision(orders)}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # -- the clock ---------------------------------------------------------------

  defp cadence(now) do
    orders = orders(now)

    cond do
      orders == nil or orders.phase in @no_hunt -> :idle
      listed(now) > 0 or orders.revive != :hold -> Settings.get(:crowd_scan_every_ms)
      orders.phase not in [:travelling, :post_fight] -> Settings.get(:crowd_scan_every_ms)
      true -> @walk_ms
    end
  end

  defp allowed(state, now) do
    cond do
      not state.active? or Settings.get(:crowd_watch_enabled) != true -> {:error, :disabled}
      cadence(now) == :idle -> {:error, :no_hunt}
      true -> :ok
    end
  end

  # -- a look ------------------------------------------------------------------

  defp look(state, now, opts) do
    listed = listed(now)
    reading = state.look.(Keyword.merge([listed: listed, evidence: false], opts))

    publish(reading, now)
    measure(reading, now)
    broadcast({:crowd, Map.delete(reading, :evidence)})

    {reading, %{narrate(state, reading) | last: reading, last_phase: phase(now)}}
  end

  defp publish(%{read?: true} = reading, now), do: WorldState.put(:crowd, Map.delete(reading, :evidence), now)
  defp publish(unread, now), do: WorldState.put(:crowd, unread, now)

  defp measure(%{read?: true, took_ms: took}, now) do
    Perf.record("crowd_watch.look_ms", took)

    case WorldState.get(:battle, 60_000, now) do
      {:ok, %{captured_at: at}} when is_integer(at) -> Perf.record("crowd_watch.battle_age_ms", max(now() - at, 0))
      _no_battle -> :ok
    end
  end

  defp measure(_unread, _now), do: Perf.count("crowd_watch.unread")

  defp narrate(state, reading) do
    line = line(reading)

    if line == state.last_line do
      state
    else
      broadcast({:engine_log, :macro, "olho: " <> line})
      %{state | last_line: line}
    end
  end

  defp line(%{read?: true} = r) do
    "👀 vi #{length(r.hostiles)} (lista #{r.listed || "?"}) · #{pet_words(r.pet)} · " <>
      "#{nearest_words(r.hostiles)} · #{skull_words(r.hostiles)} · #{r.took_ms}ms"
  end

  defp line(unread), do: "👀 sem leitura ao redor (#{inspect(Map.get(unread, :reason))})"

  defp pet_words(nil), do: "pokémon não visto"
  defp pet_words(%{tiles: t}), do: "pokémon a #{t} #{tiles(t)}"

  defp nearest_words([]), do: "ninguém perto"
  defp nearest_words([%{from_me: t} | _]), do: "mais perto a #{t} #{tiles(t)}"

  defp skull_words(hostiles), do: if(Enum.any?(hostiles, & &1.skull?), do: "caveira", else: "sem caveira")

  defp tiles(1), do: "tile"
  defp tiles(_n), do: "tiles"

  # -- the photos ----------------------------------------------------------------

  # The wait ended in a fight: the last reading of the wait is the opening.
  defp photo_on_opening(%{last: %{read?: true}, last_phase: before} = state, %{phase: :engaged})
       when before in @waiting do
    {reading, state} = look(state, now(), evidence: true)
    save_photo(reading, "open")
    state
  end

  defp photo_on_opening(state, _orders), do: state

  # One photo per revive SENTENCE: the brain repeats its order every tick.
  defp photo_on_decision(%{last_why: why} = state, %{why: why}), do: state

  defp photo_on_decision(state, %{why: why} = orders) do
    state = %{state | last_why: why}

    case tag(orders) do
      nil ->
        state

      tag ->
        if allowed(state, now()) == :ok do
          {reading, state} = look(state, now(), evidence: true)
          save_photo(reading, tag)
          state
        else
          state
        end
    end
  end

  defp tag(%{revive: revive}) when revive in [:now, :prepare], do: "revive"
  defp tag(%{why: why}), do: if(String.contains?(why, "segurando o revive"), do: "held")

  defp save_photo(%{read?: true, evidence: "data:" <> _ = url}, tag) do
    case decode(url) do
      {:ok, bytes} ->
        dir = Path.join(Home.captures_dir(), "crowd")
        File.mkdir_p!(dir)
        # Millisecond stamp first (so the rotation's sort is chronological), a
        # unique integer second (two decisions in one millisecond are two files).
        name = "#{System.system_time(:millisecond)}-#{System.unique_integer([:positive, :monotonic])}-#{tag}.png"
        Home.write!(Path.join(dir, name), bytes)
        rotate(dir)

      :error ->
        :ok
    end
  rescue
    _no_photo -> :ok
  end

  defp save_photo(_unread, _tag), do: :ok

  defp decode(url) do
    case String.split(url, ",", parts: 2) do
      [_head, body] -> Base.decode64(body)
      _no_body -> :error
    end
  end

  defp rotate(dir) do
    dir
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@keep_photos)
    |> Enum.each(&File.rm(Path.join(dir, &1)))
  end

  # -- the blackboard --------------------------------------------------------------

  defp orders(now) do
    case WorldState.get(:orders, Settings.get(:engine_orders_max_age_ms), now) do
      {:ok, %{phase: _} = orders} -> Map.put_new(orders, :revive, :hold)
      _no_brain -> nil
    end
  end

  defp phase(now), do: orders(now) && orders(now).phase

  defp listed(now) do
    case WorldState.get(:battle, Settings.get(:combat_world_max_age_ms), now) do
      {:ok, %{enemies: enemies}} when is_list(enemies) -> length(enemies)
      _no_list -> 0
    end
  end

  defp broadcast(message), do: Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, message)
  defp schedule(ms), do: Process.send_after(self(), :look, ms)
  defp now, do: System.monotonic_time(:millisecond)
end
```

Observações para quem executa:
- `listed/1` devolve `0` (não `nil`) quando a lista não é lida, porque a cadência precisa de um número; o `reading.listed` continua sendo o que o `look` recebeu (`0`), e o cartão diz "lista 0". Se preferir distinguir "lista ilegível" no cartão, passe `nil` no `look` e `0` na cadência — mas mantenha o teste do feed (`lista 3`) verde.
- O `photo_on_decision` chama `look` de novo (uma captura extra por decisão, ~30 ms) porque a leitura do relógio não carrega a foto.
- O `tag/1` de "segurando o revive" é PROVISÓRIO: quando o `Siege` nascer (PR 2/3) a ordem ganha um campo próprio e esta string sai.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/pokex/bots/crowd_watch_test.exs`
Expected: `8 tests, 0 failures`. O teste "the clock is a fight clock" depende de `WorldState.forget/1` existir (existe: `cavebot_live_test.exs:18` usa).

- [ ] **Step 5: Rodar a suíte inteira dos bots pra garantir que ninguém mais dependia do fato antigo**

Run: `mix test test/pokex/bots --max-cases 6`
Expected: verde. Se algum teste esperava `crowd.near` ou `reach_tiles`, ele era do vigia antigo e já foi reescrito.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex/bots/crowd_watch.ex test/pokex/bots/crowd_watch_test.exs
git commit -m "o olho olha em luta, publica onde cada bicho está e guarda a foto de cada decisão de revive

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 5: `SiegeComponents.siege_card/1` — o cartão do cerco

**Files:**
- Create: `lib/pokex_web/components/siege_components.ex`
- Create: `test/pokex_web/components/siege_components_test.exs`

**Interfaces:**
- Consumes: o `reading` do `CrowdScan` (fato `:crowd`), `photo` (data URL) opcional, `radius` (tiles), `max_age_ms`, `now_ms`.
- Produces: `siege_card(assigns)` com attrs `reading :: map | nil`, `photo :: String.t() | nil`, `radius :: pos_integer`, `max_age_ms :: pos_integer`, `now_ms :: integer`. Renderiza `<section id="siege-card">` com um `<svg>` em tiles; cada inimigo é `<rect data-hostile data-dx data-dy data-from-me>`; o pokémon `<rect data-pet>`; o personagem `<rect data-me>`; o cabeçalho em `<p id="siege-headline">`; o botão `phx-click="crowd_scan"` (o LiveView que hospeda trata o evento).

- [ ] **Step 1: Escrever os testes de renderização**

Crie `test/pokex_web/components/siege_components_test.exs`:

```elixir
defmodule PokexWeb.SiegeComponentsTest do
  use ExUnit.Case, async: true
  import Phoenix.LiveViewTest

  import PokexWeb.SiegeComponents

  @now 100_000

  defp reading(opts \\ []) do
    %{
      read?: true,
      at: @now - Keyword.get(opts, :age_ms, 200),
      took_ms: 27,
      me: {906, 720},
      box: {0, 0, 1812, 1440},
      pet: Keyword.get(opts, :pet, %{point: {906, 1022}, dx: 0, dy: 2, tiles: 2, hp_pct: 96}),
      hostiles:
        Keyword.get(opts, :hostiles, [
          %{point: {1057, 1022}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: true},
          %{point: {1661, 268}, dx: 5, dy: -3, from_me: 5, from_pet: 5, hp_pct: 40, skull?: true}
        ]),
      listed: Keyword.get(opts, :listed, 3)
    }
  end

  defp card(assigns) do
    assigns =
      Map.merge(%{reading: nil, photo: nil, radius: 8, max_age_ms: 600, now_ms: @now}, assigns)

    render_component(&siege_card/1, assigns)
  end

  test "with a reading it draws him, the pet and every hostile in tiles" do
    html = card(%{reading: reading()})

    assert html =~ ~s(id="siege-card")
    assert html =~ ~s(data-me)
    assert html =~ ~s(data-pet)
    assert html =~ ~s(data-hostile data-dx="1" data-dy="2" data-from-me="2")
    assert html =~ ~s(data-hostile data-dx="5" data-dy="-3" data-from-me="5")
    assert html =~ "vi 2 · lista 3 · 1 sem ver"
    assert html =~ "pokémon a 2 tiles"
    assert html =~ "área com caveira"
    assert html =~ "lido há 200 ms"
  end

  test "an old reading is no eye, and it says so" do
    html = card(%{reading: reading(age_ms: 900)})

    assert html =~ "sem olho (foto de 900 ms)"
    refute html =~ ~s(data-hostile)
  end

  test "no reading yet is an empty field with words" do
    html = card(%{reading: nil})

    assert html =~ "sem olho — nenhuma leitura ainda"
    assert html =~ ~s(phx-click="crowd_scan")
  end

  test "an unreadable screen shows the reason" do
    html = card(%{reading: %{read?: false, reason: :not_calibrated}})
    assert html =~ "não deu pra olhar: o /calibrar nunca rodou nesta tela"
  end

  test "without the pet it says so and draws no pet" do
    html = card(%{reading: reading(pet: nil)})

    assert html =~ "pokémon não visto"
    refute html =~ ~s(data-pet)
  end

  test "the photo goes behind the tiles when there is one" do
    html = card(%{reading: reading(), photo: "data:image/bmp;base64,QUJD"})
    assert html =~ ~s(<image href="data:image/bmp;base64,QUJD")
  end

  test "a skull-less area says so" do
    hostiles = [%{point: {1057, 1022}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: false}]
    html = card(%{reading: reading(hostiles: hostiles, listed: 1)})
    assert html =~ "sem caveira"
  end
end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/pokex_web/components/siege_components_test.exs`
Expected: FAIL — módulo indefinido.

- [ ] **Step 3: Escrever o componente**

Crie `lib/pokex_web/components/siege_components.ex`:

```elixir
defmodule PokexWeb.SiegeComponents do
  @moduledoc """
  The siege, drawn the way the game frames it: the character in the centre,
  everything else in tiles from him.

  Game tiles ARE the drawing's coordinates (x east, y south), the same idiom as
  the route map and the simulator's board, so nothing is transformed twice and
  the evidence photo — which IS the captured box — lines up tile for tile
  underneath.

  State is never colour alone: the headline says in words what the tiles show.
  """
  use PokexWeb, :html

  attr :reading, :map, default: nil, doc: "the :crowd fact — a CrowdScan reading without the picture"
  attr :photo, :string, default: nil, doc: "evidence data URL, when he asked for one"
  attr :radius, :integer, required: true, doc: "the eye's box, in tiles each way"
  attr :max_age_ms, :integer, required: true
  attr :now_ms, :integer, required: true

  def siege_card(assigns) do
    assigns =
      assigns
      |> assign(:state, state(assigns.reading, assigns.now_ms, assigns.max_age_ms))
      |> assign(:span, 2 * assigns.radius + 1)

    ~H"""
    <section id="siege-card" class="rounded-lg border border-pk-line bg-pk-surface p-3">
      <div class="flex flex-wrap items-center gap-x-3 gap-y-1">
        <h2 class="shrink-0 font-mono text-pk-meta font-bold uppercase tracking-[0.12em] text-pk-text-3">
          👁 o cerco
        </h2>
        <p id="siege-headline" class="min-w-0 flex-1 text-pk-body text-pk-text-2">
          {headline(@state, @reading, @now_ms)}
        </p>
        <button
          type="button"
          phx-click="crowd_scan"
          class="shrink-0 rounded border border-pk-line px-2 py-0.5 font-mono text-pk-meta text-pk-text-2 hover:bg-pk-raised"
        >
          foto agora
        </button>
      </div>

      <div class="relative mt-2 aspect-[4/3] w-full overflow-hidden rounded border border-pk-line bg-pk-bg">
        <svg viewBox={"#{-@radius - 0.5} #{-@radius - 0.5} #{@span} #{@span}"} class="size-full" role="img" aria-label={headline(@state, @reading, @now_ms)}>
          <defs>
            <pattern id="siege-ground" width="1" height="1" patternUnits="userSpaceOnUse">
              <rect width="1" height="1" fill="var(--color-pk-bg)" />
              <path d="M 1 0 L 0 0 0 1" fill="none" stroke="var(--color-pk-line)" stroke-width="0.04" />
            </pattern>
          </defs>

          <image
            :if={@photo && @state == :fresh}
            href={@photo}
            x={photo_x(@reading)}
            y={photo_y(@reading)}
            width={photo_w(@reading)}
            height={photo_h(@reading)}
            preserveAspectRatio="none"
            opacity="0.55"
          />
          <rect x={-@radius - 0.5} y={-@radius - 0.5} width={@span} height={@span} fill="url(#siege-ground)" fill-opacity={if @photo, do: "0.35", else: "1"} />

          <%= if @state == :fresh do %>
            <%!-- the bite ring around the pet: the eight tiles a pile can fill --%>
            <rect
              :if={@reading.pet}
              x={@reading.pet.dx - 1.5}
              y={@reading.pet.dy - 1.5}
              width="3"
              height="3"
              fill="none"
              stroke="var(--color-pk-ok)"
              stroke-width="0.08"
              stroke-dasharray="0.4 0.3"
              opacity="0.7"
            />
            <rect
              :for={h <- @reading.hostiles}
              data-hostile
              data-dx={h.dx}
              data-dy={h.dy}
              data-from-me={h.from_me}
              x={h.dx - 0.5}
              y={h.dy - 0.5}
              width="1"
              height="1"
              fill={hp_fill(h.hp_pct)}
              stroke="var(--color-pk-bg)"
              stroke-width="0.08"
            >
              <title>{hostile_title(h)}</title>
            </rect>
            <rect
              :if={@reading.pet}
              data-pet
              x={@reading.pet.dx - 0.5}
              y={@reading.pet.dy - 0.5}
              width="1"
              height="1"
              fill="var(--color-pk-ok)"
              stroke="var(--color-pk-bg)"
              stroke-width="0.12"
            >
              <title>seu pokémon a {@reading.pet.tiles} tiles · {@reading.pet.hp_pct}% de vida</title>
            </rect>
          <% end %>

          <rect data-me x="-0.5" y="-0.5" width="1" height="1" fill="var(--color-pk-info)" stroke="var(--color-pk-text)" stroke-width="0.18">
            <title>você</title>
          </rect>
        </svg>
      </div>

      <ul class="mt-2 flex flex-wrap gap-x-4 gap-y-1 text-pk-meta text-pk-text-2">
        <li class="flex items-center gap-1.5"><span class="inline-block size-3 bg-pk-info ring-1 ring-pk-text"></span> você</li>
        <li class="flex items-center gap-1.5"><span class="inline-block size-3 bg-pk-ok"></span> seu pokémon</li>
        <li class="flex items-center gap-1.5"><span class="inline-block size-3 border border-dashed border-pk-ok"></span> as oito bocas</li>
        <li class="flex items-center gap-1.5"><span class="inline-block size-3 bg-pk-danger"></span> monstro (cor = vida)</li>
      </ul>
    </section>
    """
  end

  # --- words ---------------------------------------------------------------

  defp state(nil, _now, _max), do: :none
  defp state(%{read?: false}, _now, _max), do: :unread

  defp state(%{at: at}, now, max) do
    if now - at <= max, do: :fresh, else: {:stale, now - at}
  end

  defp headline(:none, _reading, _now), do: "sem olho — nenhuma leitura ainda"
  defp headline({:stale, age}, _reading, _now), do: "sem olho (foto de #{age} ms)"
  defp headline(:unread, %{reason: reason}, _now), do: "não deu pra olhar: #{reason(reason)}"

  defp headline(:fresh, r, now) do
    seen = length(r.hostiles)
    unseen = max((r.listed || 0) - seen, 0)

    Enum.join(
      [
        "vi #{seen} · lista #{r.listed || "?"} · #{unseen} sem ver",
        pet_words(r.pet),
        nearest_words(r.hostiles),
        skull_words(r.hostiles),
        "lido há #{max(now - r.at, 0)} ms"
      ],
      " · "
    )
  end

  defp pet_words(nil), do: "pokémon não visto"
  defp pet_words(%{tiles: t}), do: "pokémon a #{t} #{tiles(t)}"

  defp nearest_words([]), do: "ninguém perto"
  defp nearest_words([%{from_me: t} | _]), do: "mais perto a #{t} #{tiles(t)}"

  defp skull_words(hostiles),
    do: if(Enum.any?(hostiles, & &1.skull?), do: "área com caveira", else: "sem caveira")

  defp tiles(1), do: "tile"
  defp tiles(_n), do: "tiles"

  defp hostile_title(h) do
    "#{h.dx}, #{h.dy} · a #{h.from_me} #{tiles(h.from_me)} de você" <>
      if(h.from_pet, do: " · a #{h.from_pet} do pokémon", else: "") <>
      " · #{h.hp_pct}% de vida" <> if(h.skull?, do: " · caveira", else: "")
  end

  defp reason(:not_calibrated), do: "o /calibrar nunca rodou nesta tela"
  defp reason(:no_player_point), do: "a calibração não marcou onde o personagem fica"
  defp reason(:disabled), do: "o olho está desligado no /config"
  defp reason(:no_hunt), do: "sem caçada rodando"
  defp reason(other), do: to_string(other)

  # --- the palette, the simulator's --------------------------------------------

  defp hp_fill(hp) when hp > 66, do: "var(--color-pk-danger)"
  defp hp_fill(hp) when hp > 33, do: "var(--color-pk-warn)"
  defp hp_fill(_low), do: "var(--color-pk-warn-line)"

  # --- the photo, mapped tile for tile ------------------------------------------

  defp photo_x(%{box: {bx, _by, _w, _h}, me: {px, _py}}), do: (bx - px) / tile() - 0.5
  defp photo_y(%{box: {_bx, by, _w, _h}, me: {_px, py}}), do: (by - py) / tile() - 0.5
  defp photo_w(%{box: {_bx, _by, w, _h}}), do: w / tile()
  defp photo_h(%{box: {_bx, _by, _w, h}}), do: h / tile()

  defp tile, do: Pokex.Calibration.tile_px()
end
```

Anéis do stun, quadrado da guarda, contorno tracejado de "dormindo", contorno vermelho de "acordado dentro da guarda" e o selo "N sem ver" na pilha (spec, seção 6) chegam com o `Siege` nos PRs 2 e 3: neste PR o cartão só tem o que o olho já sabe.

- [ ] **Step 4: Rodar e ver passar**

Run: `mix test test/pokex_web/components/siege_components_test.exs test/pokex_web/design_drift_test.exs`
Expected: verdes. Se o `design_drift_test` reclamar de cor, só tokens `var(--color-pk-*)` e classes `pk-*` são permitidos — não há hex neste componente. Se o HEEx renderizar os atributos numa ordem diferente da escrita (`data-hostile data-dx=… data-dy=… data-from-me=…`), troque a asserção do teste por uma asserção por atributo (`html =~ ~s(data-dx="1")` etc.), nunca o componente.

- [ ] **Step 5: Commit**

```bash
git add lib/pokex_web/components/siege_components.ex test/pokex_web/components/siege_components_test.exs
git commit -m "o cartão do cerco: você no centro, o pokémon e cada bicho em tiles, a foto por trás

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 6: a Central — o cartão no lugar do bloco "onde eles estão"

**Files:**
- Modify: `lib/pokex_web/live/cavebot_live.ex` — mount (`:128`, `crowd: nil`), `handle_event("crowd_scan")` (`:961-963`), novo `handle_info({:crowd, reading})` ao lado de `handle_info({:engine, …})` (`:243`), o bloco do modo assistir (`:3746-3760`, logo abaixo de `<.engine_brain>`), remoção do `<section id="cavebot-crowd">` dentro de "Instrumentos" (`:3770-3815`) e dos helpers `crowd_headline/1`, `crowd_spread/1`, `crowd_gap/1`, `crowd_anchor/1`, `crowd_reason/1` (`:1373-1420`). `enemy_count/1` fica se outro lugar usa; senão sai.
- Modify: `test/pokex_web/live/cavebot_live_test.exs`

**Interfaces:**
- Consumes: `PokexWeb.SiegeComponents.siege_card/1`; `Pokex.Bots.CrowdWatch.look_now/0`; PubSub `"engine"` com `{:crowd, reading}`; `WorldState.get(:crowd, 60_000, now)` na montagem.
- Produces: assigns `crowd` (reading sem foto), `crowd_photo` (data URL ou nil).

- [ ] **Step 1: Escrever os testes da Central**

Acrescente a `test/pokex_web/live/cavebot_live_test.exs` (dentro do módulo, após o `setup`; o helper fica FORA do `describe`, ao lado de `put_pos/1`):

```elixir
  defp crowd_fact do
    %{
      read?: true,
      at: System.monotonic_time(:millisecond),
      took_ms: 27,
      me: {906, 720},
      box: {0, 0, 1812, 1440},
      pet: %{point: {906, 1022}, dx: 0, dy: 2, tiles: 2, hp_pct: 100},
      hostiles: [%{point: {1057, 1022}, dx: 1, dy: 2, from_me: 2, from_pet: 1, hp_pct: 100, skull?: true}],
      listed: 1
    }
  end

  describe "the siege card" do
    test "opens on the fact already on the blackboard", %{conn: conn} do
      WorldState.put(:crowd, crowd_fact(), System.monotonic_time(:millisecond))

      {:ok, _view, html} = live(conn, ~p"/cavebot")

      assert html =~ ~s(id="siege-card")
      assert html =~ ~s(data-hostile data-dx="1" data-dy="2" data-from-me="2")
      refute html =~ "onde eles estão"
    end

    test "without a reading it says so", %{conn: conn} do
      {:ok, _view, html} = live(conn, ~p"/cavebot")
      assert html =~ "sem olho — nenhuma leitura ainda"
    end

    test "every reading the eye broadcasts redraws it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/cavebot")

      send(view.pid, {:crowd, crowd_fact()})

      assert render(view) =~ ~s(data-hostile data-dx="1")
    end
  end
```

- [ ] **Step 2: Rodar e ver falhar**

Run: `mix test test/pokex_web/live/cavebot_live_test.exs --only describe:"the siege card"`
Expected: FAIL (o cartão não existe na página; `{:crowd, _}` cai no `handle_info` genérico ou crasha).

- [ ] **Step 3: Ligar o cartão**

Em `lib/pokex_web/live/cavebot_live.ex`:

1. No `mount`, troque
```elixir
       # What the last look at the SCREEN found, and nothing until he asks: the
       # scan costs a capture, so it never runs on the poll (see the button).
       crowd: nil,
```
por
```elixir
       # The eye's last reading (the :crowd fact), and the photo only when he
       # asks for one — the picture never rides the blackboard.
       crowd: crowd_fact(),
       crowd_photo: nil,
```
e acrescente, perto de `engine_fact/1`:
```elixir
  defp crowd_fact do
    case WorldState.get(:crowd, 60_000, System.monotonic_time(:millisecond)) do
      {:ok, reading} -> reading
      _none_or_stale -> nil
    end
  end
```

2. Ao lado de `handle_info({:engine, situation, orders}, socket)`, acrescente:
```elixir
  def handle_info({:crowd, reading}, socket), do: {:noreply, assign(socket, crowd: reading)}
```

3. Substitua o `handle_event("crowd_scan", …)` por:
```elixir
  def handle_event("crowd_scan", _params, socket) do
    reading = Pokex.Bots.CrowdWatch.look_now()
    {:noreply, assign(socket, crowd: Map.delete(reading, :evidence), crowd_photo: Map.get(reading, :evidence))}
  end
```
e remova o `alias Pokex.Bots.CrowdScan` se ficou sem uso.

4. No modo assistir, logo abaixo de `<.engine_brain … />` (linha ~3752), acrescente:
```elixir
        <PokexWeb.SiegeComponents.siege_card
          reading={@crowd}
          photo={@crowd_photo}
          radius={Settings.get(:crowd_scan_radius_tiles)}
          max_age_ms={Settings.get(:crowd_fact_max_age_ms)}
          now_ms={System.monotonic_time(:millisecond)}
        />
```

5. Apague o `<section id="cavebot-crowd">` inteiro dentro de "Instrumentos" (do comentário `ONDE ELES ESTÃO` até o `</section>` que fecha antes do comentário `QUANTO A ÁREA ALCANÇA`), e os helpers `crowd_headline/1`, `crowd_spread/1`, `crowd_gap/1`, `crowd_anchor/1`, `crowd_reason/1`. Confira `enemy_count/1` com `grep -n enemy_count lib/pokex_web/live/cavebot_live.ex`: se só o handler antigo usava, apague também.

6. `now_ms` na montagem: o cartão mostra "lido há N ms" com o relógio da RENDERIZAÇÃO. A página já re-renderiza a cada `{:engine, …}` (5×/s) e a cada `{:crowd, …}` (4×/s em luta), então a idade acompanha sem timer novo.

- [ ] **Step 4: Rodar os testes da Central e o drift**

Run: `mix test test/pokex_web/live/cavebot_live_test.exs test/pokex_web/design_drift_test.exs`
Expected: verdes. Se um teste antigo procurava "onde eles estão" ou `#cavebot-crowd`, apague-o: o bloco foi substituído pelo cartão.

- [ ] **Step 5: Ver no navegador (sem subir servidor no checkout dele)**

Siga `visual-check-safe-server` da memória (servidor isolado, porta própria, `home_dir` de teste) OU confie nos testes de renderização: o cartão é SVG puro e os testes cobrem os três estados. Não use `preview_start` com o `launch.json` de outro worktree.

- [ ] **Step 6: Commit**

```bash
git add lib/pokex_web/live/cavebot_live.ex test/pokex_web/live/cavebot_live_test.exs
git commit -m "a Central mostra o cerco ao lado do cérebro, e o botão pede a foto ao olho

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
```

---

### Task 7: o portão e o PR

**Files:** nenhum novo.

- [ ] **Step 1: A suíte inteira e o lint**

Run: `mix precommit && mix lint`
Expected: `0 failures`, credo 0, dialyzer 0. Se o dialyzer reclamar do `@type reading` do `CrowdScan` (união com `%{read?: false}`), declare os campos opcionais com `optional(...)` em vez de dois mapas.

- [ ] **Step 2: A bancada não mudou**

Run: `mix test test/pokex/sim --max-cases 4`
Expected: verde, sem nenhum número alterado (nada da bancada chama o olho neste PR). Se algum teste do `sim` falhar, o motivo é flake de semente e não este PR — repita uma vez antes de investigar.

- [ ] **Step 3: Confirmar que a sonda ficou fora**

Run: `git status --short`
Expected: só `?? test/probe/`. Nunca adicione essa pasta.

- [ ] **Step 4: Abrir o PR**

```bash
git push
gh pr create --title "o olho do cerco, parte 1: a criatura é a barra de vida, e a Central mostra o cerco" --body "$(cat <<'EOF'
## O que muda

- `Vision.CreatureMarks`: cada criatura na tela é a barra de vida (27×4, borda preta, preenchimento = vida), com a caveira acima (peso) e a caixa do número embaixo (o pokémon dele). Cor de nome não entra em nada — no cliente do PA o nome é da cor da vida.
- `CrowdScan` v2 mede de VOCÊ (o centro calibrado), acha o pokémon como a caixa mais perto, e devolve cada inimigo com `dx/dy`, tiles de você e do pokémon, vida e caveira. `place/3` é pura (a bancada vai usar no PR 2).
- `CrowdWatch` v2 olha 4×/s em luta e 1×/s andando, publica o fato `:crowd` INTEIRO, avisa a Central por PubSub e guarda a foto de cada decisão de revive com o veredito no nome.
- A Central ganha o cartão do cerco (SVG em tiles, centrado em você, foto real por trás quando você pede).
- Chaves: raio 6 → 8 (a caixa cobre a tela do jogo), `crowd_scan_every_ms` 250, `crowd_fact_max_age_ms` 600 (travadas).

## O que NÃO muda

O cérebro. `Engine.Logic`/`Situation`/`Worker` intocados; a bancada não chama o olho.

## Prova

Foto real de 03/09 18:22 como fixture: 5 caveiras, o Venusaur, vidas 100/100/100/100/100/96 — e o olho antigo, na mesma foto, ancorava num Feraligatr e contava a crista como inimigo (12.104 de 21.436 leituras "viram menos que a lista" em 03/09).

Spec: `docs/superpowers/specs/2026-09-05-siege-eye-design.md`. Plano: `docs/superpowers/plans/2026-09-05-siege-eye-pr1-marks-and-card.md`.

## Checagem de campo (antes do PR 2)

- a barra escala com o `tile_px` na tela do notebook;
- quantas marcas sobrevivem numa pilha de 9;
- a caixa preta do número aparece só no pokémon dele;
- balão de fala esconde barra;
- as fotos `-revive.png` / `-held.png` em `~/.pokex/captures/crowd/`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
EOF
)"
```

- [ ] **Step 5: CI verde → merge → push da main**

Ordem permanente dele: PR verde, mergeie você mesmo (`gh pr merge --squash --delete-branch`), e deixe a `main` local dele em dia com o origin (`git -C ~/projects/pokex pull --ff-only` só se o checkout dele estiver limpo — confira `git -C ~/projects/pokex status --short` antes e NÃO toque em arquivo modificado dele).

---

## Depois do PR 1 (planos próprios)

Os PRs 2 e 3 do spec ganham cada um o seu plano DEPOIS da checagem de campo do PR 1, porque a cegueira do simulador (`mark_miss_pct`, `stacked_hide?`) é calibrada com as fotos reais que este PR produz. Esqueleto, pra ninguém se perder:

**PR 2 — bancada e sombra** (`docs/superpowers/plans/2026-09-05-siege-eye-pr2-bench-and-shadow.md`):
1. `Sim.World.marks/1` (verdade → marcas; knobs `stacked_hide?`, `effect_hide_ms`, `mark_miss_pct`) e `siege_truth/1`.
2. `Engine.Siege.build/5` + `summary/1` + `siege_test.exs` (tabela).
3. `Situation` carrega `crowd`; `Logic.tick` calcula `t.siege`; `Engine.Worker.inputs` lê o fato com `crowd_fact_max_age_ms`; `stun_cover` em todo `mark(:stunned)` e no fim da corrente; a frase "o olho diria: …" no `why` SEM mudar decisão.
4. Bancada entrega `inputs.crowd` via `CrowdScan.place/3`; `contrato_test` cobra.
5. Física: `stragglers`, `player_bite_pct`, e o estacionar em `Sim.Hands` (`{:park, {dx, dy}}`).
6. Cenários `straggler-at-recall`, `asleep-pile-plus-loner`, `nine-on-top` (renomeado), `skull-less-easy`, `blind-eye`; promessas `:no_recall_with_awake_in_guard`, `:recall_flows`, `:eye_agrees`.
7. `/sim`: dois cartões (verdade × leitura) e a linha de divergência; `Runner` publica `:crowd`.
8. O estacionar no jogo: `Cavebot.Logic` devolve `{:park, {dx, dy}}` na primeira parada com bicho (`@park_gap_tiles 2`, do lado da pilha), atrás de `cavebot_park_on_stop`; **apagar** o estacionar antigo (`Route.park_spot/2`, `set_park_tiles/3`, `set_park_point/3`, campos `park_point`/`park_tiles`, `Recording.mark_park/4`, `on_arrival` do `lure_end`, `default_park/1`, chaves `cavebot_park_tiles_x/_y`, UI).

**PR 3 — o cérebro obedece** (`…-pr3-brain-obeys.md`):
1. `recall_safe?` v2, `held_by_recall?` com `stun_cover`, o vermelho com gap fechado (controle → parado → `revive_desperate_pct`), `boss_tiles` do olho.
2. Chaves `engine_recall_guard_tiles` (4), `engine_recall_guard_light_tiles` (2), `engine_revive_desperate_pct` (15) no `/config`.
3. `Siege.summary/1` vira a frase do `why` e o campo `siege` do registro `:decision`; o `tag/1` provisório do `CrowdWatch` lê o campo em vez da string.
4. Bancada antes × depois (enxame, 4 sementes, 1 h, config dele) no PR.
