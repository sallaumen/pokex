defmodule Pokex.Bots.Catcher.TrailReplayTest do
  @moduledoc """
  The capture bench: two real episodes of 11/09, replayed through the trail.
  When a rule of the trail changes, these say what it does to a real hunt.
  """
  use ExUnit.Case, async: true

  alias Pokex.TrailReplay

  @fixtures "test/fixtures/captura"

  defp fixture(name), do: Path.join(@fixtures, name)

  # 19:43 of 11/09 — the first capture that worked: the Shiny Feraligatr's bar
  # followed for seven seconds, the list emptied, the bar gone, ONE anchor on
  # the tile where it stood, and the ball went there ("capturado").
  test "1943: a clean death is one anchor where the bar last stood" do
    result = TrailReplay.run(fixture("2026-09-11-1943-queda-limpa.jsonl"))

    assert [%{t: t, screen: {1418, 918}}] = result.falls
    assert t > 6_000 and t < 8_000, "fell at #{t} ms"
    assert [%{name: "Shiny (brilho)"}] = result.anchors
  end

  # 19:50 of 11/09 — the minimap stood still at (309,1425) for fifteen seconds
  # while the screen scrolled two tiles each way, and the shiny walked two
  # tiles left in its last seconds. The eye lost its bar at 1720,918 and never
  # read it again; the guard kept seeing the STAR, last at 1418,842. The trail
  # anchored on the stale bar and the ball fell on the sand a tile right of the
  # body. The star is a sighting: the body is where it last shone.
  test "1950: the body is where the star last shone, not where the bar was lost" do
    result = TrailReplay.run(fixture("2026-09-11-1950-gemeos.jsonl"))

    # the last sparkle was at (1418, 842); the body centre is half a tile under
    assert [%{screen: {1418, 917}}] = result.falls
    assert length(result.anchors) == 1
  end
end
