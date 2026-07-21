defmodule PokexWeb.PokedexStyle do
  @moduledoc """
  The Pokédex's visual language: one colour per element, and the wiki's own
  type icon when the sync managed to download it.

  Lucas: "seria muito legal a gente ter alguns ícones… talvez até roubar da
  wiki, como por exemplo para falar sobre os elementos… usar algumas cores,
  algo para realmente deixar um pouco mais bonitinho". Colours are the
  guaranteed layer (pure data, always available); the icon is the bonus that
  appears once `priv/static/images/pokedex/elements/<element>.png` exists.
  """

  # {text, background} — tuned for the panel's near-black surface: saturated
  # enough to read as "the Fire one" at a glance, dark enough to sit in a
  # dense list without vibrating.
  @colors %{
    "fire" => {"#ffb37a", "#2a1408"},
    "water" => {"#7cc0e8", "#0b1d28"},
    "grass" => {"#7fd88f", "#0c2413"},
    "electric" => {"#f5d967", "#241f07"},
    "ice" => {"#96e0e6", "#0b2326"},
    "fighting" => {"#f09a86", "#280f0a"},
    "poison" => {"#c99ae8", "#1d0f28"},
    "ground" => {"#e0c58a", "#241c0b"},
    "flying" => {"#b9c8f0", "#131a2b"},
    "psychic" => {"#f79ac0", "#2a0f1d"},
    "bug" => {"#bfd86a", "#1b2409"},
    "rock" => {"#d6c08f", "#221b0d"},
    "ghost" => {"#a99ae0", "#171128"},
    "dragon" => {"#9aa8f0", "#111429"},
    "dark" => {"#a9a2ab", "#1a171c"},
    "steel" => {"#b8c6cf", "#141b21"},
    "fairy" => {"#f7a8d8", "#2a1122"},
    "crystal" => {"#8ee8dc", "#0a2422"},
    "neutral" => {"#c8cdd1", "#191c1f"},
    "normal" => {"#c8cdd1", "#191c1f"}
  }

  @fallback {"#aeb6bd", "#161b1f"}

  @doc "CSS `color`/`background` pair for an element name (case-insensitive)."
  def element_colors(nil), do: @fallback

  def element_colors(element),
    do: Map.get(@colors, String.downcase(element), @fallback)

  @doc "Inline style for an element chip."
  def element_style(element) do
    {text, background} = element_colors(element)
    "color: #{text}; background-color: #{background};"
  end

  @doc """
  Path to the wiki's own icon for this element, or nil when it was never
  downloaded (the chip then shows the coloured name alone).
  """
  def element_icon(nil), do: nil

  def element_icon(element) do
    file = "images/pokedex/elements/#{String.downcase(element)}.png"

    if File.exists?(Path.join(:code.priv_dir(:pokex), Path.join("static", file))),
      do: "/" <> file
  end
end
