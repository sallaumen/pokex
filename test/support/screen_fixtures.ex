defmodule Pokex.ScreenFixtures do
  @moduledoc """
  The REAL screen captures are this project's ground truth: every glyph, anchor
  template and HUD region is measured from them, never guessed. Captured
  2026-07-22 from Lucas's game at 3440×1440 fullscreen.
  """

  @dir "test/fixtures/screen"
  @labels "test/fixtures/glyphs/labels.json"

  @doc "A committed screen capture as a Frame (name without extension)."
  def frame!(name) do
    {:ok, frame} = Pokex.Vision.Frame.from_png_file(Path.join(@dir, "#{name}.png"))
    frame
  end

  @doc "The labeled text regions the atlas is learned from."
  def labels do
    @labels |> File.read!() |> Jason.decode!() |> Map.fetch!("labels")
  end

  @doc "Reading options for a label (its ink floor, when it declares one)."
  def opts(%{"ink" => ink}), do: [ink: ink]
  def opts(_label), do: []
end
