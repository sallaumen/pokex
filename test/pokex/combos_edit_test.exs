defmodule Pokex.CombosEditTest do
  @moduledoc """
  Editing a combo's steps: the pure part. Dragging is a gesture in the browser,
  but WHERE a step lands is arithmetic — and it is the arithmetic that decides
  whether the rescue presses skill 1 before or after the wait.
  """
  use ExUnit.Case, async: true

  alias Pokex.Combos.Edit

  @steps [{:wait, 400}, {:skill, "1"}, {:wait, 500}, {:skill, "2"}]

  describe "move" do
    test "a step dragged down lands after the ones it passed" do
      assert Edit.move(@steps, 0, 2) == [{:skill, "1"}, {:wait, 500}, {:wait, 400}, {:skill, "2"}]
    end

    test "a step dragged up lands before them" do
      assert Edit.move(@steps, 3, 0) == [{:skill, "2"}, {:wait, 400}, {:skill, "1"}, {:wait, 500}]
    end

    test "dropping a step where it already was changes nothing" do
      assert Edit.move(@steps, 2, 2) == @steps
    end

    test "an index off either end is clamped instead of losing the step" do
      assert Edit.move(@steps, 0, 99) == [
               {:skill, "1"},
               {:wait, 500},
               {:skill, "2"},
               {:wait, 400}
             ]

      assert Edit.move(@steps, 3, -5) == [
               {:skill, "2"},
               {:wait, 400},
               {:skill, "1"},
               {:wait, 500}
             ]

      assert Edit.move(@steps, 99, 0) == @steps
    end
  end

  describe "delete" do
    test "drops only the step at that index" do
      assert Edit.delete(@steps, 1) == [{:wait, 400}, {:wait, 500}, {:skill, "2"}]
    end

    test "an index that is not there leaves the list alone" do
      assert Edit.delete(@steps, 9) == @steps
    end
  end

  describe "put_value" do
    test "a wait takes a new duration in ms" do
      assert Edit.put_value(@steps, 0, "2500") == [
               {:wait, 2500},
               {:skill, "1"},
               {:wait, 500},
               {:skill, "2"}
             ]
    end

    test "a skill takes a new hotbar key" do
      assert Edit.put_value(@steps, 1, "7") == [
               {:wait, 400},
               {:skill, "7"},
               {:wait, 500},
               {:skill, "2"}
             ]
    end

    test "a swap takes a new pokémon" do
      steps = [{:swap_member, "Jigglypuff"}, {:swap_counter}]

      assert Edit.put_value(steps, 0, "Xatu") == [{:swap_member, "Xatu"}, {:swap_counter}]
    end

    # He edits these while a hunt runs: a half-typed field must not corrupt the
    # combo, and a negative wait must never reach the runner.
    test "junk in a wait field is ignored rather than saved" do
      assert Edit.put_value(@steps, 0, "") == @steps
      assert Edit.put_value(@steps, 0, "abc") == @steps
      assert Edit.put_value(@steps, 0, "-300") == @steps
    end

    test "an empty skill key or pokémon is ignored" do
      assert Edit.put_value(@steps, 1, "  ") == @steps
      assert Edit.put_value([{:swap_member, "Xatu"}], 0, "") == [{:swap_member, "Xatu"}]
    end

    test "a step with nothing to type into is left as it is" do
      assert Edit.put_value([{:swap_counter}], 0, "seja o que for") == [{:swap_counter}]
    end
  end

  describe "editable_value" do
    test "tells the form what to show for each kind of step" do
      assert Edit.editable_value({:wait, 400}) == "400"
      assert Edit.editable_value({:skill, "1"}) == "1"
      assert Edit.editable_value({:swap_member, "Xatu"}) == "Xatu"
      assert Edit.editable_value({:swap_counter}) == nil
    end

    # An old combo can carry a SYMBOLIC wait ({:wait, :rescue_step_ms}); showing
    # the atom as text and saving it back would turn it into the string "rescue_step_ms".
    test "a symbolic wait is not offered as a number to overwrite" do
      assert Edit.editable_value({:wait, :rescue_step_ms}) == nil
      assert Edit.put_value([{:wait, :rescue_step_ms}], 0, "700") == [{:wait, :rescue_step_ms}]
    end
  end
end
