defmodule Pokex.Perception.Interpret.CorpsesTest do
  # async: false — o acervo (CorpseLibrary) mora no home global (:home_dir) com
  # cache em :persistent_term; cada teste usa um tmp próprio via put_env.
  use ExUnit.Case, async: false

  alias Pokex.Bots.Catcher.CorpseLibrary
  alias Pokex.Perception.Interpret.Corpses
  alias Pokex.{Calibration, Settings}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)
    :ok
  end

  # 64x64 frame = 4x4 grid of 16px cells at scale 1.0.
  defp calib do
    %Calibration{
      scale: 1.0,
      screen_w: 1000,
      screen_h: 700,
      water_point: {1, 1},
      glow_region: {0, 0, 8, 8},
      battle_region: {900, 0, 80, 400},
      arena_region: {100, 200, 64, 64},
      neutral_point: {500, 500}
    }
  end

  defp settings(overrides \\ %{}) do
    Map.merge(Settings.defaults(), Map.merge(%{corpse_warmup_frames: 3}, overrides))
  end

  defp frame(paint), do: Pokex.FrameFixtures.of(64, 64, paint)

  defp ground(_x, _y), do: {100, 90, 60}

  # Paint a 16x16 "corpse" whose top-left is the given cell (cx, cy).
  defp with_corpse(cx, cy) do
    fn x, y ->
      if div(x, 16) in [cx, cx + 1] and div(y, 16) == cy, do: {230, 40, 40}, else: ground(x, y)
    end
  end

  # O acervo É a mira (2026-07-30): sem corpo ensinado NADA vira alvo, então
  # os testes de detecção ensinam o vermelho-sobre-chão que os frames pintam —
  # o mesmo gesto do Lucas na calibração (fotografar o corpo real).
  defp teach_red!(name \\ "Corsola") do
    crop = Frame.crop(frame(with_corpse(1, 1)), {4, 0, 56, 56})
    {:ok, _n} = CorpseLibrary.add(name, crop)
    :ok
  end

  defp warm_up(settings) do
    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), settings, nil)

    Enum.reduce(1..2, st, fn _i, acc ->
      {obs, next} = Corpses.interpret(frame(&ground/2), calib(), settings, acc)
      refute obs.scanning? and obs.corpses != []
      next
    end)
  end

  test "warmup publishes scanning?: false, then flips to scanning" do
    s = settings()
    {obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, nil)
    assert obs == %{scanning?: false, corpses: [], known: %{}}

    {_obs, st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(&ground/2), calib(), s, st)
    assert obs.scanning?
  end

  test "a new static blob becomes a corpse only after the stationary frames, in screen points" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    # frame 1 with the blob: tracked but not yet confirmed (stationary_frames: 2)
    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []

    # frame 2, same place: confirmed. Blob spans cells {1,1},{2,1} → center ~x=32..48,y=24
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert [{sx, sy}] = obs.corpses
    # screen point = arena_region origin {100, 200} + frame px (scale 1.0)
    assert sx in 130..148
    assert sy in 220..232
  end

  test "o alvo confirmado chega com NOME e score no :known" do
    teach_red!("Corsola")
    s = settings()
    st = warm_up(s)

    {_obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)

    assert [point] = obs.corpses
    assert %{name: "Corsola", score: score} = obs.known[point]
    assert score >= Settings.get(:corpse_match_min_similarity)
  end

  test "um blob que NÃO casa com o acervo nunca vira alvo" do
    # acervo conhece o corpo VERMELHO; o blob parado é de outra paleta.
    # O blob precisa ser GRANDE no recorte: o chão compartilhado também pontua
    # no histograma (aqui ~84% de um recorte com blob de 2 células — acima do
    # limiar 0.72 sozinho!), então um sprite minúsculo sobre o chão ensinado
    # casaria com qualquer corpo. No jogo real o sprite ocupa a maior parte da
    # caixa de 56px; este blob de 48×32 reproduz isso (chão ≈ 51%).
    teach_red!()
    s = settings()
    st = warm_up(s)

    green = fn x, y ->
      if div(x, 16) in [1, 2, 3] and div(y, 16) in [1, 2], do: {40, 230, 40}, else: ground(x, y)
    end

    {obs, st} = Corpses.interpret(frame(green), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(green), calib(), s, st)
    assert obs.corpses == []
    assert obs.known == %{}
  end

  test "acervo VAZIO = nenhum alvo, por mais parado que o blob esteja" do
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(with_corpse(1, 1)), calib(), s, st)
    assert obs.corpses == []
  end

  test "a blob that moves every frame never becomes a corpse" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    {obs, st} = Corpses.interpret(frame(with_corpse(0, 0)), calib(), s, st)
    assert obs.corpses == []
    {obs, st} = Corpses.interpret(frame(with_corpse(2, 2)), calib(), s, st)
    assert obs.corpses == []
    {obs, _st} = Corpses.interpret(frame(with_corpse(0, 2)), calib(), s, st)
    assert obs.corpses == []
  end

  test "cells that flicker during warmup are masked and never produce corpses" do
    teach_red!()
    s = settings()

    # 'water' in the bottom row of cells flickers during warmup
    water = fn phase ->
      fn x, y ->
        if div(y, 16) == 3 and rem(x + phase, 2) == 0, do: {30, 60, 200}, else: ground(x, y)
      end
    end

    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, nil)
    {_obs, st} = Corpses.interpret(frame(water.(1)), calib(), s, st)
    {_obs, st} = Corpses.interpret(frame(water.(0)), calib(), s, st)

    # a "corpse" painted INSIDE the masked water row is invisible…
    still_water = fn x, y ->
      if div(y, 16) == 3 and div(x, 16) in [1, 2], do: {230, 40, 40}, else: water.(0).(x, y)
    end

    {obs, st} = Corpses.interpret(frame(still_water), calib(), s, st)
    {obs2, _st} = Corpses.interpret(frame(still_water), calib(), s, st)
    assert obs.corpses == []
    assert obs2.corpses == []
  end

  test "a new blob near a mature track does not inherit its maturity" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    # X: horizontal domino at cells {0,0}-{1,0} -> center {16,8} (screen {116,208}).
    x_only = with_corpse(0, 0)

    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == []

    # X mature (stationary_frames: 2).
    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == [{116, 208}]

    # Y: a DISTINCT (non-4-connected) vertical domino at cells {2,1}-{2,2} -> center {40,32}.
    # dx = |40-16| = 24, dy = |32-8| = 24: exactly at corpse_stationary_tolerance_px (24), so
    # Y is a brand-new blob within tolerance of X's mature track. X keeps growing (its own
    # position is nearer to its own prior track, distance 0); Y must start its own count at 1
    # and must NOT borrow X's maturity.
    x_and_y = fn x, y ->
      if div(x, 16) == 2 and div(y, 16) in [1, 2], do: {230, 40, 40}, else: x_only.(x, y)
    end

    {obs, _st} = Corpses.interpret(frame(x_and_y), calib(), s, st)
    assert obs.corpses == [{116, 208}]
  end

  test "two brand-new blobs competing for one vacated mature track: at most one inherits it" do
    teach_red!()
    s = settings()
    st = warm_up(s)

    # Establish a mature track T at center {16,8} via a domino at cells {0,0}-{1,0}.
    x_only = with_corpse(0, 0)
    {_obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    {obs, st} = Corpses.interpret(frame(x_only), calib(), s, st)
    assert obs.corpses == [{116, 208}]

    # Next frame: the original blob vanishes, replaced by TWO brand-new, mutually non-adjacent
    # blobs, both within tolerance (24px) of T's position {16,8}:
    #   C: vertical domino at cells {0,0}-{0,1} -> center {8,16} (dx=8, dy=8 from T).
    #   B: vertical domino at cells {2,1}-{2,2} -> center {40,32} (dx=24, dy=24 from T).
    # A correct 1:1 assignment lets only ONE of them consume T (so only one is confirmed this
    # frame); the buggy "max over all tracks within tolerance" implementation lets BOTH inherit
    # T's count and both would wrongly confirm immediately.
    two_new = fn x, y ->
      cond do
        div(x, 16) == 0 and div(y, 16) in [0, 1] -> {230, 40, 40}
        div(x, 16) == 2 and div(y, 16) in [1, 2] -> {230, 40, 40}
        true -> ground(x, y)
      end
    end

    {obs, _st} = Corpses.interpret(frame(two_new), calib(), s, st)
    assert length(obs.corpses) == 1
  end

  test "a blob smaller than corpse_min_cells is noise" do
    # min 2 cells; paint a single-cell blob
    teach_red!()
    s = settings()
    st = warm_up(s)

    one_cell = fn x, y ->
      if div(x, 16) == 1 and div(y, 16) == 1, do: {230, 40, 40}, else: ground(x, y)
    end

    {_obs, st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    {obs, _st} = Corpses.interpret(frame(one_cell), calib(), s, st)
    # a 16px cell has 16 samples all changed → hot, but 1 cell < corpse_min_cells 2
    assert obs.corpses == []
  end
end
