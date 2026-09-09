defmodule Pokex.Bots.Catcher.ShinyAim do
  @moduledoc """
  The aim for a SHINY's corpse, by the same colour that found it alive.

  `SpotScan` aims at taught corpses from the ground around a STANDING character; in a hunt
  nothing is taught for the cave and the character walks. The shiny is the exception that
  pays: the guard (`ShinyGuard`) already knows its palette, and the corpse is the same sprite
  lying down. So the aim is one fresh frame of the guard's square, the proven colour rules on
  it, and one question per blob — is there a living body on it?

  The eye's `:crowd` reading answers that: a creature body (hostile or his pet) within one tile
  of the blob means the shiny is still standing (or his Torterra is), and a ball would be
  wasted. No eye reading at all means "cannot tell", which here is "not a corpse" — a ball
  is dearer than a scan. The worker also asks for TWO consecutive sightings (`steady/3`),
  the same discipline the guard uses to confirm the living shiny.

  The observation speaks `Catcher.Logic`'s contract (`corpses`, `known`, `captured_at`) plus
  `source: :shiny_aim`, the tag that lets the worker open the mode and fight gates for it.
  Points are SCREEN points; `in_frame` keeps the frame pixel for evidence.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Perception.WorldState
  alias Pokex.Vision.{ColorMark, ColorRules, Frame}

  # the eye walks at 1 s; its own `crowd_fact_max_age_ms` (600) is a fight cadence
  @crowd_max_age_ms 1_500

  @type candidate :: %{
          name: String.t(),
          px: non_neg_integer,
          point: {integer, integer},
          in_frame: {integer, integer}
        }

  @doc """
  One fresh look: the guard's square, the armed rules, the eye's latest reading.
  `opts[:capture]` and `opts[:crowd]` are the test seams; nil obs means nothing to say.
  """
  @spec scan(keyword) :: map | nil
  def scan(opts \\ []) do
    capture = Keyword.get(opts, :capture, &Capture.frame/2)
    now = System.monotonic_time(:millisecond)

    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- capture.(region, "shiny_aim.raw") do
      forbidden = ShinyGuard.forbidden_boxes(calib, frame, region)
      crowd = Keyword.get_lazy(opts, :crowd, fn -> crowd(now) end)
      tile = Calibration.tile_px(calib)

      frame
      |> judge(region, ColorRules.armed(), forbidden, crowd, tile)
      |> obs(region, now)
    else
      {:error, reason} -> %{scanning?: false, source: :shiny_aim, reason: reason}
      _blind -> %{scanning?: false, source: :shiny_aim, reason: :capture_failed}
    end
  end

  @doc """
  The largest blob of each rule, at or above the rule's floor, with NO body within `tile_px`
  of it. `crowd` is the eye's reading (`%{read?: true, hostiles: [%{point}], pet: %{point} | nil}`);
  nil or unread → nothing is a corpse.
  """
  @spec judge(Frame.t(), tuple, list, list, map | nil, pos_integer) :: [candidate]
  def judge(%Frame{} = frame, region, rules, forbidden, crowd, tile_px) do
    case bodies(crowd) do
      :unknown ->
        []

      bodies ->
        rules
        |> Enum.flat_map(fn rule ->
          result =
            ColorMark.scan(frame, rule.specs,
              min_cell_px: rule.min_cell_px,
              # …mais o HUD que a prova do chão aprendeu (uma banda escura vê o
              # próprio cliente, e ele é mais alto que qualquer criatura)
              forbidden: forbidden ++ Map.get(rule, :forbidden, [])
            )

          case List.first(result.manchas) do
            %{px: px} = mancha when px >= rule.min_px ->
              [on_screen(mancha, rule, region, frame.scale)]

            _small_or_none ->
              []
          end
        end)
        |> Enum.reject(fn cand -> Enum.any?(bodies, &within?(&1, cand.point, tile_px)) end)
    end
  end

  @doc "Candidates already seen on the previous scan, within `tolerance` px: two photos, not one."
  @spec steady([candidate], [candidate], non_neg_integer) :: [candidate]
  def steady(candidates, prev, tolerance),
    do:
      Enum.filter(candidates, fn c -> Enum.any?(prev, &within?(&1.point, c.point, tolerance)) end)

  @doc "The Logic's observation for these candidates."
  def obs(candidates, region, at) do
    %{
      scanning?: true,
      source: :shiny_aim,
      corpses: Enum.map(candidates, & &1.point),
      known: Map.new(candidates, &{&1.point, %{name: &1.name, score: &1.px}}),
      candidates: candidates,
      region: region,
      captured_at: at
    }
  end

  defp bodies(%{read?: true} = crowd) do
    hostiles = Map.get(crowd, :hostiles, []) |> Enum.map(& &1.point)

    case Map.get(crowd, :pet) do
      %{point: point} -> [point | hostiles]
      _no_pet -> hostiles
    end
  end

  defp bodies(_nil_or_unread), do: :unknown

  defp within?({ax, ay}, {bx, by}, tolerance),
    do: abs(ax - bx) <= tolerance and abs(ay - by) <= tolerance

  defp on_screen(%{point: {fx, fy}, px: px}, rule, {rx, ry, _w, _h}, scale) do
    %{
      name: rule.name,
      px: px,
      point: {rx + round(fx / scale), ry + round(fy / scale)},
      in_frame: {fx, fy}
    }
  end

  defp crowd(now) do
    case WorldState.get(:crowd, @crowd_max_age_ms, now) do
      {:ok, reading} -> reading
      _stale_or_missing -> nil
    end
  end
end
