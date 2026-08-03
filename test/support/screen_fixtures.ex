defmodule Pokex.ScreenFixtures do
  alias Pokex.Vision.Frame

  @moduledoc """
  The REAL screen captures are this project's ground truth: every glyph, anchor
  template and HUD region is measured from them, never guessed. Captured
  2026-07-22 from Lucas's game at 3440×1440 fullscreen.
  """

  @dir "test/fixtures/screen"
  @labels "test/fixtures/glyphs/labels.json"

  @doc """
  A committed screen capture as a Frame (name without extension).

  Cached: decoding the full 3440×1440 capture costs ~7s, so a test suite that
  re-decoded it per test would spend minutes doing nothing else.
  """
  def frame!(name) do
    key = {__MODULE__, name}

    case :persistent_term.get(key, nil) do
      nil ->
        {:ok, frame} = Frame.from_png_file(Path.join(@dir, "#{name}.png"))
        :persistent_term.put(key, frame)
        frame

      frame ->
        frame
    end
  end

  @doc "The labeled text regions the atlas is learned from."
  def labels do
    @labels |> File.read!() |> Jason.decode!() |> Map.fetch!("labels")
  end

  @doc "Reading options for a label (its ink floor, when it declares one)."
  def opts(%{"ink" => ink}), do: [ink: ink]
  def opts(_label), do: []
end
