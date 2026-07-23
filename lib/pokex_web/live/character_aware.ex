defmodule PokexWeb.CharacterAware do
  @moduledoc """
  Páginas que mostram dados DO personagem recarregam sozinhas quando ele muda.

  Trocar de personagem no header não recarrega a página — é o mesmo LiveView, o
  mesmo socket. Sem este callback o `/time` continuava listando o time do
  personagem anterior até um F5 (Lucas, 2026-07-23): a página estava certa no
  disco e mentindo na tela.

  Implementar é só isto:

      @behaviour PokexWeb.CharacterAware

      @impl PokexWeb.CharacterAware
      def on_character_change(socket), do: assign_team(socket)

  O `PokexWeb.HeaderState` chama isto ao ouvir `{:character, slug}` em
  `Pokex.Characters.topic/0`. Quem não implementa simplesmente não recarrega —
  páginas como a Calibração não têm nada de personagem pra recarregar.
  """
  @callback on_character_change(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
end
