defmodule Pokex.Bots.PokemonTrackerTest do
  @moduledoc """
  Finding HIS pokémon on screen instead of assuming where it is.

  The reason it exists: he parks it with a middle click and the corpse sweep
  centres on that spot — a click that never landed sends the sweep over empty
  ground and nobody notices.
  """
  # async: false — scopes the global :home_dir env per test.
  use ExUnit.Case, async: false

  alias Pokex.Bots.{PokemonSprites, PokemonTracker}
  alias Pokex.{Calibration, SettingsStash}
  alias Pokex.Vision.Frame

  @moduletag :tmp_dir

  setup %{tmp_dir: tmp} do
    Application.put_env(:pokex, :home_dir, tmp)
    on_exit(fn -> Application.delete_env(:pokex, :home_dir) end)

    SettingsStash.stash!(
      pokemon_sprite_box_px: 16,
      pokemon_track_step_px: 4,
      pokemon_track_radius_px: 48,
      pokemon_park_tolerance_px: 20,
      pokemon_track_min_similarity: 0.55
    )

    Calibration.save(%Calibration{scale: 1.0, screen_w: 400, screen_h: 400})
    :ok
  end

  # A frame of flat ground with a coloured square painted at {x, y}: the square
  # IS the pokémon as far as a colour histogram is concerned.
  defp scene(w, h, {sx, sy}, size, colour) do
    rgba =
      for y <- 0..(h - 1), x <- 0..(w - 1), into: <<>> do
        if x >= sx and x < sx + size and y >= sy and y < sy + size,
          do: colour,
          else: <<30, 90, 40, 255>>
      end

    %Frame{width: w, height: h, rgba: rgba, scale: 1.0}
  end

  defp teach!(name, size, colour) do
    crop =
      %Frame{
        width: size,
        height: size,
        rgba: :binary.copy(colour, size * size),
        scale: 1.0
      }

    {:ok, _} = PokemonSprites.add(name, crop)
  end

  # A capture stub: hands back the slice of the scene the region asks for.
  defp capture_of(scene) do
    fn {rx, ry, w, h}, _name ->
      {:ok, Frame.crop(scene, {rx, ry, min(w, scene.width - rx), min(h, scene.height - ry)})}
    end
  end

  describe "looking for it" do
    test "it finds the taught pokémon and says how far off the expected point it is" do
      teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)
      scene = scene(400, 400, {200, 200}, 16, <<220, 40, 200, 255>>)

      seen =
        PokemonTracker.look_around({208, 208}, 48, capture: capture_of(scene))

      assert seen.found?
      assert seen.name == "Shiny Vileplume"
      assert seen.score > 0.9

      {x, y} = seen.point
      assert_in_delta x, 208, 8
      assert_in_delta y, 208, 8
      assert seen.off_by <= 8
    end

    # The whole point of a small box: asking "is it here?" must not cost what
    # asking "where is it?" costs.
    test "a small radius scores few windows" do
      teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)
      scene = scene(400, 400, {200, 200}, 16, <<220, 40, 200, 255>>)

      near = PokemonTracker.look_around({208, 208}, 40, capture: capture_of(scene))
      far = PokemonTracker.look_around({208, 208}, 120, capture: capture_of(scene))

      assert near.windows < far.windows
    end
  end

  describe "when it cannot tell" do
    # Three answers, not two: "it is elsewhere" is actionable, "I cannot see" is
    # not, and collapsing them makes the hunt act on ignorance.
    test "nothing taught says so, instead of saying the pokémon is missing" do
      assert %{found?: false, reason: :no_library} =
               PokemonTracker.look_around({100, 100}, 48)
    end

    test "taught but not on screen: it reports the best score it DID see" do
      teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)
      empty = scene(400, 400, {0, 0}, 0, <<0, 0, 0, 255>>)

      seen = PokemonTracker.look_around({200, 200}, 48, capture: capture_of(empty))

      refute seen.found?
      assert seen.reason == :below_threshold
      assert is_float(seen.score)
      assert seen.score < 0.55
    end
  end

  describe "did it get to the spot he clicked" do
    test "on the spot answers :ok" do
      teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)
      scene = scene(400, 400, {200, 200}, 16, <<220, 40, 200, 255>>)

      assert :ok = PokemonTracker.parked?({208, 208}, capture: capture_of(scene))
    end

    test "found somewhere ELSE is a different answer from not found" do
      teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)
      scene = scene(400, 400, {230, 230}, 16, <<220, 40, 200, 255>>)

      assert {:off, %{found?: true, off_by: off}} =
               PokemonTracker.parked?({200, 200},
                 capture: capture_of(scene),
                 tolerance_px: 5,
                 radius_px: 80
               )

      assert off > 5
    end

    test "unable to see is neither :ok nor :off" do
      assert {:unknown, %{reason: :no_library}} = PokemonTracker.parked?({100, 100})
    end
  end

  # The safety line: a pokémon taught into the corpse library is something the
  # Catcher throws Pokéballs at.
  test "the pokémon library is a different file from the corpses'" do
    refute PokemonSprites.file() == Pokex.Bots.Catcher.CorpseLibrary.file()

    teach!("Shiny Vileplume", 16, <<220, 40, 200, 255>>)

    assert PokemonSprites.angles("Shiny Vileplume") == 1
    assert Pokex.Bots.Catcher.CorpseLibrary.list() == []
  end
end
