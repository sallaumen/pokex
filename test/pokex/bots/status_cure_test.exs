defmodule Pokex.Bots.StatusCureTest do
  @moduledoc """
  THE STATUS POTION IN FRONT OF THE ATTACK.

  A pokémon asleep, silenced or frozen turns the chain into a dead key: no
  skill leaves, the bar is not spent, and the bot keeps pressing at a mob that
  keeps hitting back. The E slot potion cures all of it and is a no-op when
  there is no status, so the prefix costs only time — which is why the rule
  here is generous by default.

  The `Combat.Worker` is what PRESSES (charged in `worker_test.exs`); this
  module only answers whether pressing is worth it.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.StatusCure
  alias Pokex.Rig.Fake
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash!(
      status_cure_enabled: true,
      status_cure_key: "e",
      status_cure_settle_ms: 100,
      tab_key: "tab",
      attack_mode_key: "shift+1",
      defense_mode_key: "shift+3"
    )

    :ok
  end

  describe "what it is" do
    test "the key and the breath come from the configuration" do
      assert StatusCure.key() == "e"
      assert StatusCure.settle_ms() == 100
      assert StatusCure.enabled?()
    end

    test "space around the key does not count" do
      SettingsStash.stash!(status_cure_key: "  e  ")
      assert StatusCure.key() == "e"
    end
  end

  describe "when cleaning is worth it" do
    # In Auto Combo the 4s window already caps the prefix at ~15 a minute, and
    # the status that kills is the one arriving in the MIDDLE of the mob —
    # between the first chain and the third.
    test "the chain always cleans, even having cleaned in this fight already" do
      assert StatusCure.due?(:always, ["r"], true)
    end

    test "in the other modes the fight's first offensive burst cleans" do
      assert StatusCure.due?(:opening, ["3", "4"], false)
    end

    test "…and the second does not" do
      refute StatusCure.due?(:opening, ["3", "4"], true)
    end

    # Targeting is not attacking: a burst that only switches target earns no
    # potion.
    test "Tab alone is not an opening" do
      refute StatusCure.due?(:opening, ["tab"], false)
    end

    test "Tab alongside a skill is" do
      assert StatusCure.due?(:opening, ["tab", "3"], false)
    end

    # Changing stance is not casting either, and the stance burst leaves on its
    # own: without this fence the fight's first potion was spent on `shift+3`
    # and the attack right behind it went out with no cleaning at all (measured
    # in the worker, 2026-09-05).
    test "changing stance is not attacking" do
      refute StatusCure.due?(:opening, ["shift+3"], false)
      refute StatusCure.due?(:always, ["shift+1"], false)
    end
  end

  describe "the press" do
    setup do
      {:ok, _} = Fake.start_link(%{})
      :ok
    end

    test "presses the configured key" do
      assert StatusCure.press() == :ok
      assert Fake.calls() == [press: "e"]
    end

    # With no key there is nothing to press, and a `press("")` would reach the
    # rig as an empty combination — a press the game does not understand and
    # that the keyboard watcher would still have to explain.
    test "with no key configured, it does not touch the keyboard" do
      SettingsStash.stash!(status_cure_key: "  ")
      assert StatusCure.press() == :ok
      assert Fake.calls() == []
    end

    test "switched off, it does not touch the keyboard" do
      SettingsStash.stash!(status_cure_enabled: false)
      assert StatusCure.press() == :ok
      assert Fake.calls() == []
    end
  end

  describe "when it is not worth it" do
    test "switched off, not even the chain cleans" do
      SettingsStash.stash!(status_cure_enabled: false)
      refute StatusCure.due?(:always, ["r"], false)
      refute StatusCure.due?(:opening, ["3"], false)
    end

    test "with no key configured there is nothing to press" do
      SettingsStash.stash!(status_cure_key: "   ")
      refute StatusCure.due?(:always, ["r"], false)
    end

    test "an empty burst does not clean" do
      refute StatusCure.due?(:always, [], false)
      refute StatusCure.due?(:opening, [], false)
    end
  end
end
