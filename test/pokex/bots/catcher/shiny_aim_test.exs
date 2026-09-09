defmodule Pokex.Bots.Catcher.ShinyAimTest do
  use ExUnit.Case, async: true

  alias Pokex.Bots.Catcher.ShinyAim
  alias Pokex.Vision.{ColorMark, Frame}

  # the green of the shiny Electrode from the 01/09 screenshot
  @verde {40, 160, 60}
  @region {100, 100, 300, 300}
  @tile 40

  defp frame(w, h, bg, patches) do
    pixels =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        {r, g, b} = pixel(x, y, bg, patches)
        <<r, g, b, 255>>
      end

    %Frame{width: w, height: h, rgba: pixels}
  end

  defp pixel(x, y, bg, patches) do
    Enum.find_value(patches, bg, fn {{px, py, pw, ph}, cor} ->
      if x >= px and x < px + pw and y >= py and y < py + ph, do: cor
    end)
  end

  # a 14x14 blob at (10,10) of the frame: centre of mass by 8px cells lands at (16,16),
  # screen {116, 116}
  defp frame_com_mancha, do: frame(300, 300, {40, 40, 40}, [{{10, 10, 14, 14}, @verde}])

  defp rules do
    [
      %{
        slug: "electrode-shiny",
        name: "Electrode shiny",
        min_px: 50,
        min_cell_px: 6,
        specs: ColorMark.compile([%{rgb: @verde, tol_h: 12, tol_sv: 30}])
      }
    ]
  end

  defp crowd(hostiles, pet \\ nil),
    do: %{read?: true, hostiles: Enum.map(hostiles, &%{point: &1}), pet: pet && %{point: pet}}

  test "a blob with no body near it is a corpse candidate in screen points" do
    assert [%{name: "Electrode shiny", px: px, point: {sx, sy}, in_frame: {fx, fy}}] =
             ShinyAim.judge(frame_com_mancha(), @region, rules(), [], crowd([{300, 300}]), @tile)

    assert px >= 50
    assert_in_delta sx, 117, 2
    assert_in_delta sy, 117, 2
    assert_in_delta fx, 17, 2
    assert_in_delta fy, 17, 2
  end

  test "a blob with a hostile body within a tile is a living creature, not a corpse" do
    assert [] =
             ShinyAim.judge(frame_com_mancha(), @region, rules(), [], crowd([{140, 130}]), @tile)
  end

  test "a blob with the pet's body within a tile is not a corpse" do
    assert [] =
             ShinyAim.judge(
               frame_com_mancha(),
               @region,
               rules(),
               [],
               crowd([], {110, 150}),
               @tile
             )
  end

  test "without an eye reading nothing is a corpse" do
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), [], nil, @tile)
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), [], %{read?: false}, @tile)
  end

  test "a blob inside a forbidden box is not seen" do
    forbidden = [{0, 0, 40, 40}]
    assert [] = ShinyAim.judge(frame_com_mancha(), @region, rules(), forbidden, crowd([]), @tile)
  end

  test "steady keeps only candidates seen on the previous scan" do
    now = %{name: "x", px: 60, point: {117, 117}, in_frame: {17, 17}}
    assert [] = ShinyAim.steady([now], [], 12)
    assert [^now] = ShinyAim.steady([now], [%{now | point: {120, 115}}], 12)
    assert [] = ShinyAim.steady([now], [%{now | point: {160, 115}}], 12)
  end

  test "obs speaks the Logic's contract" do
    cand = %{name: "Electrode shiny", px: 60, point: {117, 117}, in_frame: {17, 17}}

    assert %{
             scanning?: true,
             source: :shiny_aim,
             corpses: [{117, 117}],
             known: %{{117, 117} => %{name: "Electrode shiny", score: 60}},
             region: @region,
             captured_at: 5
           } = ShinyAim.obs([cand], @region, 5)
  end
end
