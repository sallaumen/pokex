defmodule Pokex.Bots.AlarmCategories do
  @moduledoc """
  Os SETORES de alarme sonoro que o Lucas pode silenciar um a um.

  Motivo (2026-07-30): todo `{:rule_alarm, texto}` — Shiny, estoque baixo,
  estagnação, canto de comando, logout, acervo de captura vazio, fila
  saturada, arremesso seco — soava pelo MESMO botão "som geral", e o único
  que ele quer sempre ligado é o Shiny ("tá sendo muito barulhento... talvez
  fosse muito legal poder configurar em vários setores de alertas").

  Esta lista fechada é a fonte única dos setores: o botão do header (rótulos)
  e os produtores de alarme (`ShinyGuard`, `Guardian`, `StockAlerts`,
  `Catcher.Worker`, `Fishing.Worker`, `Capture`, `PokexWeb.PanelLive`) leem
  DELA — nenhum atom de categoria nasce solto em outro lugar. `from_string/1`
  converte o `phx-value-category` de volta pro atom SÓ se for um setor
  conhecido (nunca `String.to_atom` num valor vindo do cliente).
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

  @doc "A lista inteira, na ordem de exibição: [{atom, rótulo}]."
  def all, do: @categories

  @doc "Só os atoms, na mesma ordem."
  def keys, do: Enum.map(@categories, &elem(&1, 0))

  @doc "O rótulo em português de um setor; o próprio atom (como texto) se for desconhecido."
  def label(key) do
    Enum.find_value(@categories, to_string(key), fn {k, l} -> k == key && l end)
  end

  @doc "Converte o texto de um phx-value-category pro atom — nil se não for um setor conhecido."
  def from_string(text) do
    Enum.find_value(@categories, fn {key, _label} -> to_string(key) == text && key end)
  end
end
