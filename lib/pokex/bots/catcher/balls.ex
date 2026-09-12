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

  ## E O SHINY NÃO TEM CORPO ENSINADO

  O corpo comum é reconhecido pelo acervo de sprites, e é lá que a escolha dele
  mora. O shiny não passa por aí: ele é seguido pela barra até a queda, e o que
  sobra é uma ÂNCORA — um ponto de tela e o nome que o cliente desenhava em
  cima do bicho. Não há foto a ensinar, então não há onde pendurar um seletor.

  Por isso a bola do shiny é UMA chave só, `shiny_ball_key`: a tecla que vale
  pra todo corpo que veio do brilho. É a bola cara, a que ele não quer gastar
  no que a varredura acha no chão — e é a única em que faz diferença, porque
  um shiny perdido não volta.
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
  def key_for(name), do: key_for(name, :corpse)

  @doc """
  The hotbar key for `name` lying there as a `kind` of target.

  `:corpse` is the ordinary body the sweep recognised (the choice rides on the
  taught corpse); `:anchor` is where the shiny's bar fell (the choice is
  `shiny_ball_key`, one for all of them).
  """
  @spec key_for(String.t() | nil, :corpse | :anchor) :: String.t()
  def key_for(name, kind) do
    key_for(
      name,
      kind,
      CorpseLibrary.ball_for(name),
      Settings.get(:shiny_ball_key),
      Settings.get(:ball_types)
    )
  end

  @doc "Same, against an explicit choice and hotbar — the testable half."
  @spec key_for(String.t() | nil, String.t() | nil, list) :: String.t()
  def key_for(name, chosen, types), do: key_for(name, :corpse, chosen, nil, types)

  @doc "Same, against both explicit choices and the hotbar — the testable half."
  @spec key_for(String.t() | nil, :corpse | :anchor, String.t() | nil, String.t() | nil, list) ::
          String.t()
  def key_for(_name, :anchor, _chosen, shiny_choice, types),
    do: on_hotbar_or_default(shiny_choice, types)

  def key_for(name, :corpse, chosen, _shiny_choice, types) do
    if is_binary(name), do: on_hotbar_or_default(chosen, types), else: default_key()
  end

  defp on_hotbar_or_default(key, types) do
    if is_binary(key) and on_hotbar?(key, types), do: key, else: default_key()
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
