defmodule Pokex.Vision.ColorRules do
  @moduledoc """
  The collection of SPECIAL COLOURS: the rules `ColorMark` scans for.

  **A shiny and a "boss" are the SAME creature in this game**, in his own words: what he
  had been calling a boss is what this game calls a shiny. A shiny is a recolour (his
  Electrode is green where the common one is red), it has far more health and attack, and
  it is at the same time the trophy he hunts. That is why there is ONE kind of rule and
  not two: each one holds the reference tone or tones, the tolerance and the sensitivity,
  taught in the calibration panel with an eyedropper
  (docs/shiny/plano-shiny-por-cor.md).

  Same discipline as `SpriteLibrary`: the JSON file is the truth
  (`~/.pokex/special_colors.json`), cached in `:persistent_term` stamped by mtime and size. An
  UNPROVEN rule (no `proven`) does not enter the watcher: the panel's noise proof is mandatory
  before arming, with the ordinary hunt floor measured and `min_px` given a 3x margin.
  """

  alias Pokex.Home
  alias Pokex.Vision.ColorMark

  def file, do: Path.join(Home.dir(), "special_colors.json")

  @doc "Todas as regras, mais novas primeiro."
  def list, do: cache().entries

  @doc """
  Creates a rule. `attrs` requires `name` and `colors`, each colour either a HUE cone
  (`%{"rgb" => [r, g, b], "tol_h" => degrees, "tol_sv" => pct}`) or a DARK band
  (`%{"dark" => v_max, "spread" => spread, "rgb" => [r, g, b]}` — the rgb is only the swatch;
  black has no hue to put a cone around). It accepts `min_px`, `min_cell_px` and `note`. It is
  born enabled and NOT proven.

  There is no `kind`: shiny and boss are the same thing here. Old files that stored the field
  still load, it simply no longer decides anything.
  """
  def add(%{"name" => name, "colors" => colors} = attrs)
      when is_binary(name) and is_list(colors) and colors != [] do
    entry = %{
      "slug" => unique_slug(slug(name), list()),
      "name" => name,
      "colors" => Enum.map(colors, &normalize_color/1),
      "min_px" => positive(attrs["min_px"], 25),
      "min_cell_px" => positive(attrs["min_cell_px"], 6),
      "enabled" => true,
      "proven" => nil,
      "note" => attrs["note"],
      "taught_at" => DateTime.utc_now() |> DateTime.to_iso8601()
    }

    persist([entry | list()])
    {:ok, entry}
  end

  def add(_incomplete), do: {:error, :invalid}

  @doc "Updates a rule's editable fields (tolerances, sensitivity, note)."
  def update(slug, attrs) do
    editable = ["min_px", "min_cell_px", "note", "colors", "name"]

    mutate(slug, fn entry ->
      attrs
      |> Map.take(editable)
      |> Enum.reduce(entry, fn
        {"colors", colors}, e when is_list(colors) and colors != [] ->
          # new tolerance = old proof no longer valid
          %{e | "colors" => Enum.map(colors, &normalize_color/1)} |> Map.put("proven", nil)

        {"min_px", v}, e ->
          Map.put(e, "min_px", positive(v, e["min_px"]))

        {"min_cell_px", v}, e ->
          Map.put(e, "min_cell_px", positive(v, e["min_cell_px"]))

        {k, v}, e ->
          Map.put(e, k, v)
      end)
    end)
  end

  @doc """
  Stamps the noise proof: the FLOOR's px peak (an ordinary hunt, with no special on screen),
  when it was measured, and the CHROME — the boxes that were dark in every single sample.

  The chrome only matters to a dark band, and to it, it is everything: the hotbar, the toolbar
  and the Tracker window are black, they never move, and in his own frame each of them was
  louder than the creature. What the hunt draws moves; what the client draws does not.
  """
  def mark_proven(slug, floor_px, chrome \\ [], region \\ nil, scale \\ nil)
      when is_integer(floor_px) and floor_px >= 0 do
    mutate(slug, fn entry ->
      Map.put(entry, "proven", %{
        "floor_px" => floor_px,
        "chrome" => Enum.map(chrome, fn {l, t, r, b} -> [l, t, r, b] end),
        # …E EM QUE AMPLIAÇÃO. `floor_px` é uma CONTAGEM e `chrome` são pixels do
        # QUADRO: os dois quadruplicam quando o backend de captura troca e serve
        # a mesma região com o dobro da largura. A região, que é em pontos de
        # tela, não vê essa troca — e a porteira abaixo deixava passar.
        "scale" => scale,
        # EM QUE QUADRO ela foi medida. As caixas do HUD são pixels DAQUELE
        # quadro, e o quadro sai de `corpse_scan_radius_tiles`, do tile da tela
        # e do ponto do personagem: mudar qualquer um desloca tudo, e as caixas
        # passariam a tapar chão vazio enquanto o HUD volta a disparar.
        "region" => region && Tuple.to_list(region),
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end

  # Um bicho ocupa da ordem de UM tile. O corpo do Charizard preto dele "passa
  # do tile", então quatro tiles de cor sólida já é generoso: acima disso o
  # gatilho não é alto, é inalcançável.
  @max_creature_tiles 4

  @doc """
  Um número de pixels casados medido em TILES de cor sólida.

  Pixel não diz nada a ele — ele mesmo escreveu isso ("não estou entendendo nem um pouco o
  que são os pixels"). Tile diz: é o quadrado que ele vê no jogo. Toda vez que uma dessas
  contas for pra tela, vai nesta unidade.
  """
  @spec tiles(number, pos_integer, number) :: float
  def tiles(px, tile_px, scale) when tile_px > 0 and scale > 0 do
    lado = tile_px * scale
    px / (lado * lado)
  end

  @doc """
  Um gatilho que nenhum bicho alcança.

  Acontece quando o tom ensinado é do CENÁRIO e não do bicho: o chão medido sobe junto, o
  método multiplica por três, e a regra fica provada, armada e muda — as duas do Charizard
  dele pediam 14,6 e 6,0 tiles de cor sólida na tela (09/09).
  """
  @spec unreachable?(number, pos_integer, number) :: boolean
  def unreachable?(px, tile_px, scale),
    do: tiles(px, tile_px, scale) > @max_creature_tiles

  @doc "O teto em tiles acima do qual um gatilho é inalcançável."
  @spec max_creature_tiles() :: pos_integer
  def max_creature_tiles, do: @max_creature_tiles

  @doc """
  Is this rule's proof still about the frame we are looking at now?

  A proof taken in another region is not a proof of anything here — and an OLD proof, from
  before this field existed, is trusted (it was measured on the region he had then).
  """
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

  @doc """
  Records the trigger the TOOL itself suggested, so the next measurement can tell its own
  number from one he typed — and lower its own without touching his.
  """
  def remember_suggested(slug, min_px) when is_integer(min_px) do
    mutate(slug, fn entry ->
      case entry["proven"] do
        %{} = proven -> Map.put(entry, "proven", Map.put(proven, "suggested", min_px))
        _no_proof -> entry
      end
    end)
  end

  def set_enabled(slug, on?) when is_boolean(on?),
    do: mutate(slug, &Map.put(&1, "enabled", on?))

  def delete(slug) do
    entries = Enum.reject(list(), &(&1["slug"] == slug))
    if length(entries) == length(list()), do: {:error, :not_found}, else: persist(entries)
  end

  @doc """
  The rules the WATCHER scans, enabled AND proven, already compiled:
  `[%{slug, name, min_px, min_cell_px, specs}]`.
  """
  def armed do
    cache().armed
  end

  @doc """
  The compiled specs of one STORED entry — what the teaching panel reads a photo with, so the
  ruler on screen is the watcher's own and not a copy of it.
  """
  def specs_for(%{"colors" => colors}), do: ColorMark.compile(Enum.map(colors, &spec_of/1))
  def specs_for(_no_colors), do: []

  # -- de dentro ---------------------------------------------------------------

  # O TOM SEM MATIZ (o shiny preto dele): o que se guarda é o teto de luz e o
  # espalhamento entre canais, e o rgb fica só pro quadradinho da tela.
  defp normalize_color(%{"dark" => v_max} = color) do
    [r, g, b] = Map.get(color, "rgb", [0, 0, 0])

    %{
      "dark" => v_max |> positive(30) |> min(255),
      # ZERO É UMA ESCOLHA. `positive/2` recusa o zero e devolvia 12, então o
      # tom preto que ele apertou até a banda mais justa — o corpo do bicho dele
      # mediu mediana 0 — era salvo TRÊS VEZES mais largo do que a prévia que
      # ele acabara de aprovar na tela.
      "spread" => color |> Map.get("spread") |> byte_or(12) |> min(255),
      "rgb" => [byte(r), byte(g), byte(b)]
    }
  end

  # A CAIXA RGB: a cor exata da sprite mais uma folga por canal. É a família certa
  # pra este jogo (sprites fixas, luz sempre igual) e a única que enxerga o eixo
  # que separa o shiny do comum, que é o BRILHO.
  defp normalize_color(%{"rgb" => [r, g, b], "tol" => tol}),
    do: %{"rgb" => [byte(r), byte(g), byte(b)], "tol" => tol |> byte_or(1) |> min(8)}

  # …e o cone de matiz, que regras gravadas antes usam.
  defp normalize_color(%{"rgb" => [r, g, b]} = color) do
    %{
      "rgb" => [byte(r), byte(g), byte(b)],
      "tol_h" => positive(color["tol_h"], 12),
      "tol_sv" => positive(color["tol_sv"], 30)
    }
  end

  defp byte(v) when is_integer(v), do: v |> max(0) |> min(255)
  defp byte(_bad), do: 0

  defp positive(v, _default) when is_integer(v) and v > 0, do: v
  defp positive(_bad, default), do: default

  # …e onde o zero é legítimo, só o que não é número vira o padrão.
  defp byte_or(v, _default) when is_integer(v) and v >= 0, do: v
  defp byte_or(_bad, default), do: default

  defp mutate(slug, fun) do
    case Enum.split_with(list(), &(&1["slug"] == slug)) do
      {[entry], rest} -> persist([fun.(entry) | rest])
      {[], _rest} -> {:error, :not_found}
    end
  end

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "cor"
      ok -> ok
    end
  end

  defp unique_slug(base, entries) do
    taken = MapSet.new(entries, & &1["slug"])

    if MapSet.member?(taken, base),
      do: unique_slug("#{base}-2", entries),
      else: base
  end

  @cache_key {__MODULE__, :cache}

  defp cache do
    stamp = file_stamp()

    case :persistent_term.get(@cache_key, nil) do
      %{stamp: ^stamp} = cache ->
        cache

      _stale_or_absent ->
        entries = raw_entries()

        cache = %{
          stamp: stamp,
          entries: entries,
          armed:
            entries
            |> Enum.filter(&(&1["enabled"] == true and is_map(&1["proven"])))
            |> Enum.map(fn e ->
              %{
                slug: e["slug"],
                name: e["name"],
                min_px: e["min_px"],
                min_cell_px: e["min_cell_px"],
                specs: ColorMark.compile(Enum.map(e["colors"], &spec_of/1)),
                # AS CAIXAS QUE NUNCA MEXERAM: o próprio HUD do jogo é preto, e
                # numa banda escura ele é mais alto que a criatura. A prova do
                # chão as aprendeu; o vigia as recusa.
                forbidden: chrome_boxes(e),
                proven_region: proven_region(e),
                proven_scale: proven_scale(e)
              }
            end)
        }

        :persistent_term.put(@cache_key, cache)
        cache
    end
  end

  defp spec_of(%{"dark" => v_max} = c),
    do: %{dark: v_max, spread: Map.get(c, "spread", 12)}

  defp spec_of(%{"tol" => tol} = c) do
    [r, g, b] = c["rgb"]
    %{rgb: {r, g, b}, tol: tol}
  end

  defp spec_of(c) do
    [r, g, b] = c["rgb"]
    %{rgb: {r, g, b}, tol_h: c["tol_h"], tol_sv: c["tol_sv"]}
  end

  defp chrome_boxes(%{"proven" => %{"chrome" => boxes}}) when is_list(boxes),
    do: for([l, t, r, b] <- boxes, do: {l, t, r, b})

  defp chrome_boxes(_no_proof), do: []

  defp proven_region(%{"proven" => %{"region" => [x, y, w, h]}}), do: {x, y, w, h}
  defp proven_region(_older_proof), do: nil

  defp proven_scale(%{"proven" => %{"scale" => scale}}) when is_number(scale), do: scale
  defp proven_scale(_older_proof), do: nil

  defp file_stamp do
    case File.stat(file(), time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _absent -> :absent
    end
  end

  # O ARQUIVO É DELE E ELE MEXE. `special_colors.json` é texto no `~/.pokex`:
  # um `"enabled": null` de uma versão velha, uma cor sem `rgb`, uma prova pela
  # metade — e `cache/0` levantava. Junto com ela levantava a guarda inteira e
  # as DUAS telas, ou seja, a página onde ele arrumaria o estrago não abria
  # mais. Uma entrada torta é DESCARTADA e o resto carrega.
  defp raw_entries do
    with {:ok, body} <- File.read(file()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      Enum.flat_map(entries, &sound/1)
    else
      _no_file -> []
    end
  end

  defp sound(%{"slug" => slug, "name" => name} = entry)
       when is_binary(slug) and is_binary(name) do
    case entry |> Map.get("colors") |> List.wrap() |> Enum.flat_map(&sane_color/1) do
      [] ->
        []

      colors ->
        [
          entry
          |> Map.merge(%{
            "colors" => colors,
            "enabled" => entry["enabled"] == true,
            "min_px" => positive(entry["min_px"], 25),
            "min_cell_px" => positive(entry["min_cell_px"], 6),
            "proven" => sane_proof(entry["proven"])
          })
        ]
    end
  end

  defp sound(_not_a_rule), do: []

  defp sane_color(%{"dark" => v} = color) when is_integer(v),
    do: [normalize_color(Map.put(color, "rgb", rgb_of(color)))]

  defp sane_color(%{"rgb" => [r, g, b], "tol" => tol} = color)
       when is_integer(r) and is_integer(g) and is_integer(b) and is_integer(tol),
       do: [normalize_color(color)]

  defp sane_color(%{"rgb" => [r, g, b]} = color)
       when is_integer(r) and is_integer(g) and is_integer(b),
       do: [normalize_color(color)]

  defp sane_color(_bad), do: []

  defp rgb_of(%{"rgb" => [r, g, b]}) when is_integer(r) and is_integer(g) and is_integer(b),
    do: [r, g, b]

  defp rgb_of(_no_swatch), do: [0, 0, 0]

  defp sane_proof(%{"floor_px" => px} = proven) when is_integer(px), do: proven
  defp sane_proof(_half_written), do: nil

  defp persist(entries) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
    :persistent_term.erase(@cache_key)
    :ok
  end
end
