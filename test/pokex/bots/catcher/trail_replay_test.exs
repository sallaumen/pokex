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
  # while the screen scrolled two tiles each way, and the shiny walked a tile
  # in its last second. Live (four looks a second) the same shiny became two
  # tracks two tiles apart and both fell — a ball on the sand each side of the
  # body; under the film's two-second cadence one track survives and its
  # anchor lands ONE TILE RIGHT of the body (the shells lay at ~1569,990; the
  # last sparkle put the name at x 1418 at t=20_192). THIS IS TODAY'S
  # BEHAVIOUR, pinned: the task that anchors on the freshest evidence in
  # screen space moves it within a tile of that last sparkle point.
  test "1950: a frozen minimap under a scrolling screen anchors beside the body (today)" do
    result = TrailReplay.run(fixture("2026-09-11-1950-gemeos.jsonl"))

    assert [%{screen: {1720, 918}}] = result.falls
    assert length(result.anchors) == 1
  end
end
