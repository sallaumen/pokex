defmodule Pokex.Bots.PokemonTracker do
  @moduledoc """
  Where his pokémon actually IS on screen, and whether that is where the bot expected it.

  The bot has been assuming: it middle-clicks a spot, and from then on every rule that depends
  on the pokémon being there, above all the corpse sweep which centres on that spot, trusts a
  click nobody confirmed. Confirming that the pokémon reached the point was the open question;
  this answers it by looking.

  ## Cheap by construction

  The search is a `Pokex.Vision.Finder` sweep over a SMALL square around the point in question,
  not over the arena: asking "is it here?" costs a fraction of asking "where is it?".
  `look_around/2` takes the radius, so a caller that knows roughly where to look pays roughly
  nothing.

  Nothing here decides anything. It reports `%{point, score, off_by}` or a reason it could not
  tell, and the caller, which knows whether a missing pokémon means "wait", "click again" or
  "sweep anyway", decides. A tracker that guessed would be the assumption it exists to remove.
  """

  alias Pokex.Bots.{Capture, PokemonSprites}
  alias Pokex.Vision.Finder
  alias Pokex.{Calibration, Settings}

  @type sighting ::
          %{
            found?: true,
            name: String.t(),
            score: float,
            point: {integer, integer},
            off_by: non_neg_integer,
            windows: non_neg_integer
          }
          | %{found?: false, reason: atom, score: float | nil}

  @doc """
  Looks for the pokémon around `point` (screen coordinates).

  `radius_px` bounds the search box. Answers `found?: true` only above
  `pokemon_track_min_similarity` — and when it fails it still carries the best
  `score` it saw, because "missed by 0.03" and "nothing remotely like it" are
  different problems and the same `false` used to hide both.
  """
  @spec look_around({integer, integer}, pos_integer, keyword) :: sighting
  def look_around({px, py} = point, radius_px, opts \\ []) do
    capture = Keyword.get(opts, :capture, &Capture.frame/2)

    with :ok <- taught(),
         {:ok, calib} <- calibration(),
         region = box_around(point, radius_px, calib),
         {:ok, frame} <- capture.(region, "pokemon_track.raw") do
      PokemonSprites.library()
      |> Finder.find(frame,
        box: Settings.get(:pokemon_sprite_box_px),
        step: Settings.get(:pokemon_track_step_px),
        region: region
      )
      |> judge({px, py})
    else
      {:error, reason} -> %{found?: false, reason: reason, score: nil}
      _unreadable -> %{found?: false, reason: :no_frame, score: nil}
    end
  end

  defp taught do
    if PokemonSprites.empty?(), do: {:error, :no_library}, else: :ok
  end

  @doc """
  Did the pokémon get to the spot he clicked? `look_around/3` centred on the
  park point, with the tolerance the caller cares about already applied.

  `:ok` / `{:off, sighting}` / `{:unknown, sighting}` — three answers, not two:
  "it is elsewhere" is actionable (click again), "I cannot see" is not, and
  collapsing them would make the hunt act on ignorance.
  """
  @spec parked?({integer, integer}, keyword) :: :ok | {:off, sighting} | {:unknown, sighting}
  def parked?(point, opts \\ []) do
    tolerance = Keyword.get(opts, :tolerance_px, Settings.get(:pokemon_park_tolerance_px))
    radius = Keyword.get(opts, :radius_px, Settings.get(:pokemon_track_radius_px))

    case look_around(point, radius, opts) do
      %{found?: true, off_by: off} when off <= tolerance -> :ok
      %{found?: true} = seen -> {:off, seen}
      seen -> {:unknown, seen}
    end
  end

  defp judge(nil, _point), do: %{found?: false, reason: :nothing_scored, score: nil}

  defp judge(%{score: score} = hit, point) do
    if score >= Settings.get(:pokemon_track_min_similarity) do
      %{
        found?: true,
        name: hit.name,
        score: score,
        point: hit.point,
        off_by: distance(hit.point, point),
        windows: hit.windows
      }
    else
      %{found?: false, reason: :below_threshold, score: score}
    end
  end

  defp distance({ax, ay}, {bx, by}), do: round(:math.sqrt((ax - bx) ** 2 + (ay - by) ** 2))

  # Clamped to the SCREEN, never to the arena: the arena clip is what decapitated
  # the corpse ring (2026-07-30), and the pokémon stands further down than the
  # arena box reaches just as often.
  defp box_around({px, py}, radius, %Calibration{screen_w: sw, screen_h: sh}) do
    x = max(px - radius, 0)
    y = max(py - radius, 0)
    w = min(2 * radius, max(sw, 1) - x)
    h = min(2 * radius, max(sh, 1) - y)

    {x, y, max(w, 1), max(h, 1)}
  end

  defp calibration do
    case Calibration.load() do
      {:ok, %Calibration{screen_w: w, screen_h: h} = calib}
      when is_integer(w) and is_integer(h) ->
        {:ok, calib}

      _no_calibration ->
        {:not_calibrated, nil}
    end
  end
end
