defmodule Pokex.Vision.ColorRules do
  @moduledoc """
  O acervo das CORES ESPECIAIS: as regras que o `ColorMark` varre.

  Um shiny no Poké Alliance é um recolor — o Electrode dele é verde onde o
  comum é vermelho — e um chefe costuma trair-se num detalhe de cor (cabelo,
  corpo). Cada regra guarda o(s) tom(s) de referência, a tolerância e a
  sensibilidade, ensinados no painel de calibração por conta-gotas
  (docs/shiny/plano-shiny-por-cor.md).

  Mesma disciplina do `SpriteLibrary`: o arquivo JSON é a verdade
  (`~/.pokex/special_colors.json`), cache em `:persistent_term` carimbado por
  mtime+tamanho. Regra NÃO PROVADA (sem `proven`) não entra no vigia: a prova de
  ruído do painel é obrigatória antes de armar (o chão de caçada normal é
  medido e o `min_px` ganha margem 3× — o método do grit/#461).
  """

  alias Pokex.Home
  alias Pokex.Vision.ColorMark

  def file, do: Path.join(Home.dir(), "special_colors.json")

  @doc "Todas as regras, mais novas primeiro."
  def list, do: cache().entries

  @doc """
  Cria uma regra. `attrs` pede `name`, `kind` (`"shiny"` | `"chefe"`) e
  `colors` (lista de `%{"rgb" => [r, g, b], "tol_h" => graus, "tol_sv" => pct}`);
  aceita `min_px`, `min_cell_px` e `note`. Nasce ligada e NÃO provada.
  """
  def add(%{"name" => name, "kind" => kind, "colors" => colors} = attrs)
      when is_binary(name) and kind in ["shiny", "chefe"] and is_list(colors) and colors != [] do
    entry = %{
      "slug" => unique_slug(slug(name), list()),
      "name" => name,
      "kind" => kind,
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

  @doc "Atualiza campos editáveis (tolerâncias, sensibilidade, nota) de uma regra."
  def update(slug, attrs) do
    editable = ["min_px", "min_cell_px", "note", "colors", "name", "kind"]

    mutate(slug, fn entry ->
      attrs
      |> Map.take(editable)
      |> Enum.reduce(entry, fn
        {"colors", colors}, e when is_list(colors) and colors != [] ->
          # tolerância nova = prova velha não vale mais
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
  Carimba a prova de ruído: o pico de px do CHÃO (caçada normal, sem o
  especial na tela) e quando foi medida. O vigia só varre regra provada.
  """
  def mark_proven(slug, floor_px) when is_integer(floor_px) and floor_px >= 0 do
    mutate(slug, fn entry ->
      Map.put(entry, "proven", %{
        "floor_px" => floor_px,
        "at" => DateTime.utc_now() |> DateTime.to_iso8601()
      })
    end)
  end

  def set_enabled(slug, on?) when is_boolean(on?),
    do: mutate(slug, &Map.put(&1, "enabled", on?))

  def delete(slug) do
    entries = Enum.reject(list(), &(&1["slug"] == slug))
    if length(entries) == length(list()), do: {:error, :not_found}, else: persist(entries)
  end

  @doc """
  As regras que o VIGIA varre — ligadas E provadas — já compiladas:
  `[%{slug, name, kind, min_px, min_cell_px, specs}]`.
  """
  def armed do
    cache().armed
  end

  # -- de dentro ---------------------------------------------------------------

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
            |> Enum.filter(&(&1["enabled"] and is_map(&1["proven"])))
            |> Enum.map(fn e ->
              %{
                slug: e["slug"],
                name: e["name"],
                kind: e["kind"],
                min_px: e["min_px"],
                min_cell_px: e["min_cell_px"],
                specs:
                  ColorMark.compile(
                    Enum.map(e["colors"], fn c ->
                      [r, g, b] = c["rgb"]
                      %{rgb: {r, g, b}, tol_h: c["tol_h"], tol_sv: c["tol_sv"]}
                    end)
                  )
              }
            end)
        }

        :persistent_term.put(@cache_key, cache)
        cache
    end
  end

  defp file_stamp do
    case File.stat(file(), time: :posix) do
      {:ok, %{mtime: mtime, size: size}} -> {mtime, size}
      _absent -> :absent
    end
  end

  defp raw_entries do
    with {:ok, body} <- File.read(file()),
         {:ok, entries} when is_list(entries) <- Jason.decode(body) do
      entries
    else
      _no_file -> []
    end
  end

  defp persist(entries) do
    File.mkdir_p!(Path.dirname(file()))
    File.write!(file(), Jason.encode!(entries, pretty: true))
    :persistent_term.erase(@cache_key)
    :ok
  end
end
