defmodule Pokex.Bots.Catcher.Balls do
  @moduledoc """
  Which Pokéball to throw at the corpse we just recognised.

  Lucas keeps more than one kind on his hotbar — F1 the ordinary one, F2 one
  that is better at water types — and the aim already knows the NAME of the body
  it is throwing at. Spending the good ball on everything is waste; spending the
  ordinary one on the thing he is hunting is worse.

  A ESCOLHA MORA NO CORPO ENSINADO, não numa lista à parte.

  Ela vivia em `ball_rules`: uma lista de regras casadas por nome de espécie,
  editada num overlay do painel — um segundo lugar guardando o mesmo dado que o
  acervo de corpos da calibração já guarda, e que ele nem alcançava mais
  ("é coisa legada", 11/09). O acervo é quem IDENTIFICA o corpo, e o nome que
  ele devolve é exatamente o que chega aqui, então é lá que a bola pertence:
  um seletor por corpo, ao lado da foto que o reconhece.

  Sem escolha, a bola padrão (`ball_key`). Uma escolha apontando para uma tecla
  que não está no hotbar (`ball_types`) é ignorada — jogaria nada.
  """

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Settings

  @doc """
  The hotbar key for a corpse named `name` (nil = unrecognised → the default).

  Reads the configured balls and rules at call time: he flips these between
  hunts, and a ball chosen from a config frozen at boot is a ball he did not ask
  for.
  """
  @spec key_for(String.t() | nil) :: String.t()
  def key_for(name), do: key_for(name, CorpseLibrary.ball_for(name), Settings.get(:ball_types))

  @doc "Same, against an explicit choice and hotbar — the testable half."
  @spec key_for(String.t() | nil, String.t() | nil, list) :: String.t()
  def key_for(name, chosen, types) do
    if is_binary(name) and is_binary(chosen) and on_hotbar?(chosen, types),
      do: chosen,
      else: default_key()
  end

  @doc "How the panel names a key: the ball's label, or the bare key."
  @spec label(String.t()) :: String.t()
  def label(key), do: label(key, Settings.get(:ball_types))

  @spec label(String.t(), list) :: String.t()
  def label(key, types) do
    case Enum.find(List.wrap(types), &(&1["key"] == key)) do
      %{"name" => name} when is_binary(name) and name != "" -> name
      _unnamed -> key
    end
  end

  @doc "The default ball — what a corpse with no choice of its own gets."
  def default_key, do: Settings.get(:ball_key)

  defp on_hotbar?(key, types), do: Enum.any?(List.wrap(types), &(&1["key"] == key))
end
