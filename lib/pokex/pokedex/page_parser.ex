defmodule Pokex.Pokedex.PageParser do
  @moduledoc """
  The Poké Alliance species page (`/api/page/<path>` → `content`) → attributes.

  The markup is machine-generated from one template — `data-wiki-template="pokemon-v4"`
  on 40 of 40 pages sampled on 25/08 — with inline styles and no classes to
  anchor on. Targeted regexes beat a full HTML parser here: same reasoning the
  PokeXGames scraper used, plus real pages pinned in fixtures so a template
  change breaks in tests instead of in data.

  Sections are genuinely optional on the live wiki: 4 pages in 10 have no
  Habilidades, 1 in 10 has no moves table (Groudon), 1 in 10 has no
  description. An absent section is `nil`/`[]`, never an error. Only a page
  with no "Informações Básicas" is `{:error, :unrecognized}` — that is a wiki
  page that is not a species.
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
           tier: present(info["Tier"]),
           role: present(info["Função"]),
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
  #
  # /u is load-bearing: without it the label class is a BYTE range, and the
  # first capture came back as the emoji's trailing bytes glued to " HP"
  # instead of "HP". So the cell is captured whole and the decoration is
  # stripped by unicode letter class, not by guessing at ranges.
  defp basic_info(html) do
    rows =
      ~r{<td[^>]*>([^<]+)</td>\s*<td[^>]*><strong>\s*([^<]+?)\s*</strong>}u
      |> Regex.scan(html)
      |> Map.new(fn [_all, label, value] -> {label_of(label), value} end)

    if Map.has_key?(rows, "HP"), do: numeric_values(rows)
  end

  defp label_of(cell),
    do: cell |> String.replace(~r/^[^\p{L}]+/u, "") |> String.trim()

  # HP, experience and level are counts; tier and role are labels.
  defp numeric_values(rows) do
    Map.new(rows, fn
      {label, value} when label in ["HP", "Experiência", "Nível necessário"] ->
        {label, to_integer(value)}

      {label, value} ->
        {label, value}
    end)
  end

  defp present(value) when is_binary(value) and value not in ["", "None"], do: value
  defp present(_absent), do: nil

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
    pattern = ~r{#{Regex.escape(heading)}</h3>(.*?)(?:<h3|<!-- pokemon-evolution:end)}s

    case Regex.run(pattern, html) do
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
