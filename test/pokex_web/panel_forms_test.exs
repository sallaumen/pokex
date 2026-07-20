defmodule PokexWeb.PanelFormsTest do
  use ExUnit.Case, async: true

  alias PokexWeb.PanelForms

  test "parse_int is strict: whole string, inside the range" do
    assert PanelForms.parse_int(" 30 ", 1..90) == {:ok, 30}
    assert PanelForms.parse_int("1", 1..90) == {:ok, 1}
    assert PanelForms.parse_int("0", 1..90) == :error
    assert PanelForms.parse_int("91", 1..90) == :error
    assert PanelForms.parse_int("30s", 1..90) == :error
    assert PanelForms.parse_int("", 1..90) == :error
    assert PanelForms.parse_int(nil, 1..90) == :error
  end

  test "parse_non_neg is lenient about trailing garbage but rejects negatives" do
    assert PanelForms.parse_non_neg("25") == {:ok, 25}
    assert PanelForms.parse_non_neg("25ms") == {:ok, 25}
    assert PanelForms.parse_non_neg("0") == {:ok, 0}
    assert PanelForms.parse_non_neg("-5") == :error
    assert PanelForms.parse_non_neg("abc") == :error
    assert PanelForms.parse_non_neg(nil) == :error
  end

  test "parse_timing clamps 0 to 1 only for positive-only keys" do
    assert PanelForms.parse_timing(:combat_skill_tap_count, "0", [:combat_skill_tap_count]) ==
             {:ok, 1}

    assert PanelForms.parse_timing(:combat_skill_gap_ms, "0", [:combat_skill_tap_count]) ==
             {:ok, 0}

    assert PanelForms.parse_timing(:combat_skill_gap_ms, "x", [:combat_skill_tap_count]) ==
             :error
  end

  test "parse_skill_keys: splits, maps 10 -> 0, keeps digits, dedupes in order" do
    assert PanelForms.parse_skill_keys("6, 4 3 6 10 f1 22") == ["6", "4", "3", "0"]
    assert PanelForms.parse_skill_keys("") == []
  end
end
