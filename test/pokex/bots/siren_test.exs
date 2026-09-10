defmodule Pokex.Bots.SirenTest do
  @moduledoc """
  The Mac's own speaker for the sectors with no mute button. It listens where
  the journal listens, plays one file per sector, and rings a sector at most
  once every few seconds.
  """
  use ExUnit.Case, async: false

  alias Pokex.Bots.Siren
  alias Pokex.SettingsStash

  setup do
    SettingsStash.stash!(native_alarm_sound: true)
    test = self()
    {:ok, clock} = Agent.start_link(fn -> 10_000 end)

    siren =
      start_supervised!(
        {Siren,
         name: nil,
         play: fn file -> send(test, {:played, file}) end,
         clock: fn -> Agent.get(clock, & &1) end}
      )

    %{siren: siren, clock: clock}
  end

  defp alarm(topic, category, text \\ "teste"),
    do: Phoenix.PubSub.broadcast(Pokex.PubSub, topic, {:rule_alarm, category, text})

  # Every alarm broadcast is asynchronous: a call to the siren orders the mailbox.
  defp settle(siren), do: :sys.get_state(siren)

  test "his life rings Basso and a setup problem rings Submarine", %{siren: siren} do
    alarm("game", :mortal, "VOCÊ está com 14%")
    settle(siren)
    assert_receive {:played, "/System/Library/Sounds/Basso.aiff"}

    alarm("combat", :setup, "o bot NÃO ligou")
    settle(siren)
    assert_receive {:played, "/System/Library/Sounds/Submarine.aiff"}
  end

  # O SHINY SAIU DAQUI. Ele é o único setor que nasce sem botão de mudo
  # (`AlarmCategories`, 30/07) e o único cujo aviso ele quer ouvir de longe:
  # "quando eu tiver um Shiny na tela, de repente ser um alerta" (10/09).
  test "an announced shiny rings the native sound", %{siren: siren} do
    alarm("combat", :shiny)
    settle(siren)
    assert_receive {:played, "/System/Library/Sounds/Hero.aiff"}
  end

  test "a shiny sector he silenced on the panel does not ring here either", %{siren: siren} do
    Pokex.SettingsStash.stash!(alarm_muted_categories: ["shiny"])

    alarm("combat", :shiny)
    settle(siren)
    refute_receive {:played, _}, 100
  end

  test "the sectors the panel plays stay silent here", %{siren: siren} do
    for category <- [:hp, :command, :capture, :error] do
      alarm("combat", category)
    end

    settle(siren)
    refute_receive {:played, _}, 100
  end

  test "a burst in one sector is one ring, and the gap is per sector", %{
    siren: siren,
    clock: clock
  } do
    alarm("combat", :mortal)
    alarm("combat", :mortal)
    alarm("combat", :setup)
    settle(siren)

    assert_receive {:played, "/System/Library/Sounds/Basso.aiff"}
    assert_receive {:played, "/System/Library/Sounds/Submarine.aiff"}
    refute_receive {:played, _}, 50

    Agent.update(clock, fn _ -> 13_000 end)
    alarm("combat", :mortal)
    settle(siren)
    assert_receive {:played, "/System/Library/Sounds/Basso.aiff"}
  end

  test "ring/2 rings without an alarm on the wire", %{siren: siren} do
    Siren.ring(:setup, siren)
    settle(siren)
    assert_receive {:played, "/System/Library/Sounds/Submarine.aiff"}
  end

  test "the switch turns it off", %{siren: siren} do
    SettingsStash.stash!(native_alarm_sound: false)
    alarm("combat", :mortal)
    settle(siren)
    refute_receive {:played, _}, 100
  end

  test "a player that raises does not take the siren down", %{clock: clock} do
    siren =
      start_supervised!(
        {Siren,
         name: nil,
         play: fn _file -> raise "sem alto-falante" end,
         clock: fn -> Agent.get(clock, & &1) end},
        id: :broken_siren
      )

    alarm("combat", :mortal)
    settle(siren)
    assert Process.alive?(siren)
  end

  test "the sectors with a sound are the ones without a mute button" do
    assert Enum.sort(Siren.sectors()) == [:mortal, :setup, :shiny]
    assert Siren.sound(:hp) == nil
  end
end
