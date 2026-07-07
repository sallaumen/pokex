defmodule Pokex.Rig.FakeTest do
  use ExUnit.Case, async: false
  alias Pokex.Rig.Fake

  test "records calls in order and returns defaults" do
    {:ok, _} = Fake.start_link()
    assert :ok = Fake.press("shift+z")
    assert :ok = Fake.click(:left, {1, 2})
    assert {:ok, {500, 500}} = Fake.cursor_position()
    assert {:ok, path} = Fake.capture({0, 0, 10, 10}, "x.png")
    assert String.ends_with?(path, "x.png")

    # Filter out {:cursor_position} — the app-wide Guardian polls the panic
    # corner on its own timer against this same shared Rig.Fake, and its
    # reads may interleave with (or duplicate) the one this test issued
    # above. What this test actually asserts is the ORDER of the other calls.
    calls = Enum.reject(Fake.calls(), &match?({:cursor_position}, &1))

    assert calls == [
             {:press, "shift+z"},
             {:click, :left, {1, 2}},
             {:capture, {0, 0, 10, 10}, "x.png"}
           ]
  end

  test "scripted returns are consumed in order, last one sticks" do
    {:ok, _} = Fake.start_link(%{press: [{:error, :nope}, :ok]})
    assert {:error, :nope} = Fake.press("1")
    assert :ok = Fake.press("1")
    assert :ok = Fake.press("1")
  end
end
