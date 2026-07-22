defmodule Mix.Tasks.Glyphs.Learn do
  @shortdoc "Rebuilds priv/glyphs/atlas.json from the labeled screen fixtures"

  @moduledoc """
  Learns the client's bitmap font from the REAL captures: for every labeled
  region, segment it and zip the glyphs with the expected characters.

  A count mismatch is a hard error, never a silent skip — it means the label's
  rect is off (or the client changed), and learning past it would poison the
  atlas with wrong pixels.

      mix glyphs.learn
  """
  use Mix.Task

  alias Pokex.Vision.Glyphs

  @impl true
  def run(_argv) do
    Mix.Task.run("app.config")

    labels =
      "test/fixtures/glyphs/labels.json"
      |> File.read!()
      |> Jason.decode!()
      |> Map.fetch!("labels")

    atlas = Enum.reduce(labels, %{}, &learn/2)

    File.mkdir_p!("priv/glyphs")
    File.write!("priv/glyphs/atlas.json", Jason.encode!(%{glyphs: atlas}, pretty: true))
    Glyphs.clear()

    Mix.shell().info("atlas: #{map_size(atlas)} glifos de #{length(labels)} regiões")
  end

  defp learn(%{"fixture" => f, "region" => [x, y, w, h], "expected" => expected} = label, acc) do
    {:ok, frame} = Pokex.Vision.Frame.from_png_file("test/fixtures/screen/#{f}.png")
    opts = if ink = label["ink"], do: [ink: ink], else: []

    glyphs = Glyphs.segment(frame, {x, y, w, h}, opts)
    chars = expected |> String.replace(" ", "") |> String.graphemes()

    if length(glyphs) != length(chars) do
      Mix.raise(
        "#{f}/#{expected}: #{length(glyphs)} glifos para #{length(chars)} caracteres — " <>
          "o retângulo do label está errado"
      )
    end

    glyphs
    |> Enum.zip(chars)
    |> Enum.reduce(acc, fn {glyph, char}, atlas ->
      Map.put(atlas, Glyphs.signature(glyph.bitmap), char)
    end)
  end
end
