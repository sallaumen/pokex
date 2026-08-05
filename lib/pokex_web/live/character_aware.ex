defmodule PokexWeb.CharacterAware do
  @moduledoc """
  Pages showing data that BELONGS to a character reload themselves when it changes.

  Switching character in the header does not reload the page — it is the same
  LiveView and the same socket. Without this callback `/time` kept listing the
  previous character's team until an F5 (Lucas, 2026-07-23): the disk was right
  and the screen was lying.

  Implementing it is only this:

      @behaviour PokexWeb.CharacterAware

      @impl PokexWeb.CharacterAware
      def on_character_change(socket), do: assign_team(socket)

  `PokexWeb.HeaderState` calls it when it hears `{:character, slug}` on
  `Pokex.Characters.topic/0`. A page that does not implement it simply does not
  reload — Calibration has no character data to reload.
  """
  @callback on_character_change(Phoenix.LiveView.Socket.t()) :: Phoenix.LiveView.Socket.t()
end
