defmodule Pokex.Layout do
  @moduledoc """
  Auto-calibration of the HUD. Kills the manual wizard for everything the game
  itself draws.

  In fullscreen the client's panels are docked, so every HUD region sits at a
  fixed offset from a piece of UI CHROME. This module locates three such
  anchors — the Battle panel header, the hotbar's "Sto" tab, the icon row
  beside the active pokémon — by exact pixel match against templates cut from
  a real capture, then derives every region from them. All three are unique on
  the whole 3440×1440 screen, so a match is never ambiguous.

  Anchoring the minimap to the BATTLE header (not to the screen corner) is
  deliberate: the minimap panel runs from the dock's top down to wherever the
  battle panel begins, so Lucas resizing his map moves one anchor and the
  minimap region follows for free.

  What stays manual: points of the WORLD (the fishing water, the pokémon's
  spot, the escape staircase). Those are map content, not interface — no
  anchor can find them.
  """

  alias Pokex.Bots.Capture
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Vision.Frame

  defmodule Fix do
    @moduledoc "A located layout: where the anchors are and every region derived from them."
    defstruct [:profile, :anchors, :regions, :region_opts, :located_at]
  end

  @profile_dir "priv/layouts"

  @doc "The layout profile for a resolution (only Lucas's ultrawide for now)."
  def profile(name \\ "ultrawide_3440x1440") do
    Application.app_dir(:pokex, Path.join(@profile_dir, "#{name}.json"))
    |> File.read!()
    |> Jason.decode!()
  end

  @doc """
  Locates the layout against the LIVE screen.

  Captures only the three anchor search windows — never the whole screen.
  Decoding a full 3440×1440 PNG costs ~7s, while the three windows together
  are under 1% of those pixels; the search itself is single-digit
  milliseconds either way.
  """
  def locate do
    profile = profile()

    with {:ok, anchors} <- capture_anchors(profile) do
      {:ok,
       %Fix{
         profile: profile["name"],
         anchors: anchors,
         regions: derive_regions(profile, anchors),
         region_opts: derive_opts(profile),
         located_at: DateTime.utc_now()
       }}
    end
  end

  defp capture_anchors(profile) do
    Enum.reduce_while(profile["anchors"], {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      key = String.to_atom(name)

      case capture_anchor(profile, spec) do
        {:ok, point} -> {:cont, {:ok, Map.put(acc, key, point)}}
        _not_found -> {:halt, {:error, {:anchor_not_found, key}}}
      end
    end)
  end

  defp capture_anchor(profile, spec) do
    template = template(spec)
    [pw, ph] = profile["resolution"]
    {wx, wy, ww, wh} = window(spec, template, pw, ph)

    with {:ok, frame} <- Capture.frame({wx, wy, ww, wh}, "layout_#{spec["template"]}"),
         {:ok, {x, y}} <-
           search(
             frame,
             template,
             0,
             0,
             frame.width - template.width,
             frame.height - template.height
           ) do
      {:ok, {wx + x, wy + y}}
    else
      _no_match -> :not_found
    end
  end

  # The search window: where the anchor was measured, widened by its tolerance,
  # clamped to the screen and to the template's size.
  defp window(spec, template, screen_w, screen_h) do
    [mx, my] = spec["measured_at"]
    [tol_x, tol_y] = spec["tolerance"]

    x0 = max(mx - tol_x, 0)
    y0 = max(my - tol_y, 0)
    x1 = min(mx + tol_x + template.width, screen_w)
    y1 = min(my + tol_y + template.height, screen_h)

    {x0, y0, x1 - x0, y1 - y0}
  end

  defp template(spec) do
    {:ok, template} =
      Frame.from_png_file(
        Application.app_dir(:pokex, Path.join([@profile_dir, "anchors", spec["template"]]))
      )

    template
  end

  @doc """
  Finds the anchors in `frame` and derives every region.

  Fails loudly rather than returning a plausible-but-wrong region: a missing
  anchor means the game moved, is windowed, or is on another display — and a
  bot that acts on guessed coordinates clicks blind.
  """
  def locate(%Frame{} = frame, profile \\ nil) do
    profile = profile || profile()
    [pw, ph] = profile["resolution"]

    cond do
      {frame.width, frame.height} != {pw, ph} ->
        {:error, {:resolution, {frame.width, frame.height}}}

      true ->
        with {:ok, anchors} <- find_anchors(frame, profile) do
          {:ok,
           %Fix{
             profile: profile["name"],
             anchors: anchors,
             regions: derive_regions(profile, anchors),
             region_opts: derive_opts(profile),
             located_at: DateTime.utc_now()
           }}
        end
    end
  end

  @doc """
  Locates and PUBLISHES: the fix becomes the `:layout` world fact and is
  persisted, so a restart starts calibrated instead of blind.
  """
  def apply! do
    case locate() do
      {:ok, fix} ->
        WorldState.put(:layout, to_fact(fix), System.monotonic_time(:millisecond))
        File.mkdir_p!(Home.dir())
        File.write!(path(), Jason.encode!(to_fact(fix), pretty: true))
        {:ok, fix}

      error ->
        error
    end
  end

  @doc "The layout in force: the live fact, else the persisted one, else nil."
  def current do
    case WorldState.get(:layout, :infinity, System.monotonic_time(:millisecond)) do
      {:ok, fact} -> from_fact(fact)
      _stale_or_missing -> load_persisted()
    end
  end

  defp path, do: Path.join(Home.dir(), "layout_fix.json")

  defp load_persisted, do: load_file(path())

  @doc false
  # O round-trip arquivo→Fix por caminho EXPLÍCITO. Existe como seam de teste:
  # o caminho padrão depende do env global :home_dir, que testes async mudam
  # concorrentemente — um teste de persistência que dependa dele testa a sorte
  # da corrida, não o código (flakou de verdade no CI, 2026-07-29).
  def load_file(path) do
    with {:ok, body} <- File.read(path),
         {:ok, fact} <- Jason.decode(body) do
      from_fact(fact)
    else
      _no_file -> nil
    end
  end

  # Regions travel as lists (JSON has no tuples) and come back as rects.
  defp to_fact(%Fix{} = fix) do
    %{
      "profile" => fix.profile,
      "anchors" => Map.new(fix.anchors, fn {k, {x, y}} -> {Atom.to_string(k), [x, y]} end),
      "regions" =>
        Map.new(fix.regions, fn {k, {x, y, w, h}} -> {Atom.to_string(k), [x, y, w, h]} end),
      "region_opts" =>
        Map.new(fix.region_opts, fn {k, opts} -> {Atom.to_string(k), Keyword.get(opts, :ink)} end),
      "located_at" => DateTime.to_iso8601(fix.located_at)
    }
  end

  defp from_fact(fact) do
    %Fix{
      profile: fact["profile"],
      anchors: Map.new(fact["anchors"], fn {k, [x, y]} -> {String.to_atom(k), {x, y}} end),
      regions:
        Map.new(fact["regions"], fn {k, [x, y, w, h]} -> {String.to_atom(k), {x, y, w, h}} end),
      region_opts:
        Map.new(fact["region_opts"] || %{}, fn {k, ink} -> {String.to_atom(k), [ink: ink]} end),
      located_at: fact["located_at"]
    }
  end

  @doc "A region rect from the layout in force, or nil when uncalibrated."
  def region(name, fix) do
    case fix do
      %Fix{regions: regions} -> Map.get(regions, name)
      nil -> nil
    end
  end

  @doc "Same, resolving the layout in force. Prefer `region/2` with the fix the caller already holds."
  def region(name), do: region(name, current())

  @doc """
  The battle list's per-row geometry, measured rather than configured.

  His `battle_row_height` setting says 52 — tuned when the panel sat 173px
  higher — while the rows actually repeat every 46px. Reading it from the
  profile means the row bands land on the rows even when the setting is stale.
  """
  def battle_rows(name \\ "ultrawide_3440x1440") do
    case profile(name)["battle_rows"] do
      nil ->
        nil

      spec ->
        %{
          pitch: spec["pitch"],
          max_rows: spec["max_rows"],
          band_top: spec["band_top"],
          name: {spec["name"]["offset"], spec["name"]["size"]},
          bar: {spec["bar"]["offset"], spec["bar"]["size"]}
        }
    end
  end

  @doc "Reading options a region declares (its ink floor), ready for Glyphs."
  def region_opts(%Fix{region_opts: opts}, region), do: Map.get(opts, region, [])

  defp find_anchors(frame, profile) do
    Enum.reduce_while(profile["anchors"], {:ok, %{}}, fn {name, spec}, {:ok, acc} ->
      case find_anchor(frame, spec) do
        {:ok, point} -> {:cont, {:ok, Map.put(acc, String.to_atom(name), point)}}
        :not_found -> {:halt, {:error, {:anchor_not_found, String.to_atom(name)}}}
      end
    end)
  end

  defp find_anchor(frame, spec) do
    template = template(spec)
    {wx, wy, ww, wh} = window(spec, template, frame.width, frame.height)

    search(
      frame,
      template,
      wx,
      wy,
      min(wx + ww - template.width, frame.width - template.width),
      min(wy + wh - template.height, frame.height - template.height)
    )
  end

  # Exact match. The first row is the prefilter: comparing one row-slice of
  # binary rejects nearly every candidate before the full compare runs.
  defp search(frame, template, x0, y0, x1, y1) do
    first_row = binary_part(template.rgba, 0, template.width * 4)

    Enum.reduce_while(y0..y1//1, :not_found, fn y, _acc ->
      case Enum.find(x0..x1//1, fn x ->
             row_at(frame, x, y, template.width) == first_row and
               full_match?(frame, template, x, y)
           end) do
        nil -> {:cont, :not_found}
        x -> {:halt, {:ok, {x, y}}}
      end
    end)
  end

  defp full_match?(frame, template, x, y) do
    Enum.all?(1..(template.height - 1)//1, fn j ->
      row_at(frame, x, y + j, template.width) ==
        binary_part(template.rgba, j * template.width * 4, template.width * 4)
    end)
  end

  defp row_at(%Frame{width: w, rgba: rgba}, x, y, len),
    do: binary_part(rgba, (y * w + x) * 4, len * 4)

  defp derive_regions(profile, anchors) do
    Map.new(profile["regions"], fn {name, spec} ->
      {String.to_atom(name), derive_region(spec, anchors)}
    end)
  end

  # A FIXED region is absolute: it belongs to the game viewport rather than to
  # a docked panel, so anchoring it would make it drift whenever that panel
  # moves. Proven by the mini-game strip: Lucas enlarged his minimap, which
  # pushed the battle panel 173px down, and the strip stayed exactly where it
  # was. The profile is per-resolution, so absolute is well-defined here.
  defp derive_region(%{"fixed" => [x, y, w, h]}, _anchors), do: {x, y, w, h}

  defp derive_region(spec, anchors) do
    {ax, ay} = Map.fetch!(anchors, String.to_atom(spec["anchor"]))
    [ox, oy] = spec["offset"]
    [w, h] = spec["size"]
    {ax + ox, ay + oy, w, h}
  end

  defp derive_opts(profile) do
    for {name, %{"ink" => ink}} <- profile["regions"], into: %{} do
      {String.to_atom(name), [ink: ink]}
    end
  end
end
