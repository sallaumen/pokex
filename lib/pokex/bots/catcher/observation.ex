defmodule Pokex.Bots.Catcher.Observation do
  @moduledoc """
  What the Catcher hands its `Logic` when the evidence is not a photo.

  The ordinary ball is judged on a fresh frame: `SpotScan` sweeps the ground
  around the character and scores every window against the taught corpses. The
  SHINY's ball has no such frame to offer — measured on his own frames of
  11/09 09:13, the Shiny Golem's corpse was on screen with ZERO pixels of the
  tone that found it alive, and every colour session of that day closed with
  "maior mancha do tom 0 px". What the bot does know is where the creature was
  standing when its health bar disappeared (`Catcher.Trail`): a CLAIM about the
  ground, not a picture of it. `anchors/3` dresses that claim in the Logic's
  contract so the same queue, the same one-ball-at-a-time and the same
  confirmation judge serve both lenses (`source` tells them apart).

  And the gate both lenses share: **nobody alive on the screen**. "Quando tá
  vivo temos que matar e quando tá morto temos que capturar" (09/09). While the
  brain still counts enemies, a ball is either wasted on a living creature or
  thrown instead of the fight that should be killing it, so `screen_clear/2`
  answers from the BRAIN's count (`:situation`, which already discounts his own
  pokémon's row) and never from the raw battle list. A stale or missing picture
  is "cannot tell", which here is "not a corpse": a ball is dearer than a scan.

  Points are SCREEN points; `in_frame` keeps the frame pixel for evidence.
  """

  alias Pokex.Perception.WorldState
  alias Pokex.Settings

  # o quadro do cérebro: ele tica a cada 200ms, e é ele que já desconta a linha
  # do PRÓPRIO pokémon da contagem (a lista crua inclui ela)
  @situation_max_age_ms 2_000

  @type candidate :: %{
          :name => String.t(),
          :px => non_neg_integer,
          :point => {integer, integer},
          :in_frame => {integer, integer},
          # quando a evidência é uma âncora do rastro: desde quando o corpo
          # está no chão (a narração conta a idade dele na linha da bola)
          optional(:fallen_at) => integer
        }

  @doc """
  Is the screen empty of the living? `:ok`, or `{:blocked, reason}`.

  A contagem é a do CÉREBRO (`:situation`), não a da lista crua: a lista inclui
  a linha do próprio pokémon dele, e cobrar zero dela seria nunca jogar bola
  nenhuma. Quadro velho ou ausente é "não sei", e não saber aqui é não jogar.
  Vale pra toda bola da caçada, não só pra do shiny: a varredura comum também
  confunde bicho de pé com corpo.
  """
  def screen_clear(:ask, now) do
    case WorldState.get(:situation, @situation_max_age_ms, now) do
      {:ok, %{enemies: 0}} -> :ok
      {:ok, %{enemies: n}} when is_integer(n) -> {:blocked, {:alive_on_screen, n}}
      _stale_or_missing -> {:blocked, :no_picture}
    end
  end

  def screen_clear(0, _now), do: :ok
  def screen_clear(n, _now) when is_integer(n), do: {:blocked, {:alive_on_screen, n}}

  @doc """
  The Logic's observation for the trail's anchors: not a photo, a claim.

  `at` is the instant the claim is made — and it must be NEWER than any photo
  the Logic has already judged (`Catcher.Worker.fresher_than/2`): the round's
  own scan stamps its frame in the very millisecond this call is born, and the
  Logic drops an observation whose `captured_at` is not past the last one
  (19:51:19 of 11/09: the corpse on the ground, him standing beside it, and "a
  lógica recusou 1 âncora").
  """
  @spec anchors([candidate], integer, map) :: map
  def anchors(candidates, at, diag \\ %{}) do
    %{
      scanning?: true,
      source: :anchor,
      diag: diag,
      corpses: Enum.map(candidates, & &1.point),
      # `score` É SEMELHANÇA, DE 0 A 1. Aqui não há semelhança nenhuma: o que
      # existe é a contagem de pixels do brilho. Postos no mesmo campo, os
      # 1,2 milhão de pixels da mancha dele viravam "reconhecido (120000000%)"
      # no registro da captura.
      known: Map.new(candidates, &{&1.point, %{name: &1.name, px: &1.px}}),
      candidates: candidates,
      region: {0, 0, 0, 0},
      captured_at: at
    }
  end

  @doc """
  Quem é o corpo naquele ponto, segundo ESTA leitura.

  A bola voa num ponto ADMITIDO numa observação anterior; o centro da mancha
  pode ter andado alguns px desde então — o vizinho mais próximo dentro da
  tolerância é o mesmo corpo. `nil` quando a leitura não conhece ninguém ali.
  """
  @spec known_at(map, {integer, integer}) :: map | nil
  def known_at(%{known: known}, {px, py}) when is_map(known) and map_size(known) > 0 do
    tolerance = Settings.get(:corpse_match_tolerance_px)

    known
    |> Enum.filter(fn {{x, y}, _info} ->
      abs(x - px) <= tolerance and abs(y - py) <= tolerance
    end)
    |> Enum.min_by(
      fn {{x, y}, _info} -> (x - px) * (x - px) + (y - py) * (y - py) end,
      fn -> nil end
    )
    |> case do
      {_point, info} -> info
      nil -> nil
    end
  end

  def known_at(_obs, _point), do: nil
end
