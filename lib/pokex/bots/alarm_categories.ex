defmodule Pokex.Bots.AlarmCategories do
  @moduledoc """
  Audible-alarm sectors that can be muted one by one (2026-07-30: every
  `{:rule_alarm, text}` shared one master toggle; only Shiny should stay always-on).
  This closed list is the single source of sector atoms — the header button and all
  alarm producers read from it; `from_string/1` never `String.to_atom`s client input.
  """

  @categories [
    {:shiny, "Shiny avistado"},
    {:vida, "Vida crítica do Pokémon"},
    {:erro, "Erro de um worker"},
    {:fuga, "Fuga de emergência"},
    {:sessao, "Sessão (estagnação, meta batida)"},
    {:cavebot, "Caçada bloqueada (cavebot)"},
    {:comando, "Canto de comando"},
    {:captura, "Captura (acervo, fila, região)"},
    {:pesca, "Arremesso seco (pesca)"},
    {:estoque, "Estoque baixo"},
    {:logout, "Logout automático"}
  ]

  @doc "Full list in display order: [{atom, label}]."
  def all, do: @categories

  @doc "Just the atoms, same order."
  def keys, do: Enum.map(@categories, &elem(&1, 0))

  @doc "Portuguese label of a sector; the atom as text if unknown."
  def label(key) do
    Enum.find_value(@categories, to_string(key), fn {k, l} -> k == key && l end)
  end

  @doc "Maps a phx-value-category string back to its atom — nil unless it is a known sector."
  def from_string(text) do
    Enum.find_value(@categories, fn {key, _label} -> to_string(key) == text && key end)
  end
end
