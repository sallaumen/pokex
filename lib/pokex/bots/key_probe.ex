defmodule Pokex.Bots.KeyProbe do
  @moduledoc """
  Did the key we pressed actually leave this machine, and did it leave WITH its
  modifier?

  `Pokex.Bots.SkillReceipt` reads the game's answer (the cooldown) to know a
  skill fired. That receipt cannot exist for the stance keys: shift+1 and
  shift+3 change a MODE, spend no cooldown, and leave nothing on the bar to
  compare. So they were the one thing the bot pressed with no way of knowing
  whether anything happened — "nunca até hoje funcionou isso de mudar para modo
  de ataque ou defesa com os comandos de shift" (Lucas, 2026-08-12).

  This is the receipt one layer lower: `Pokex.Rig.Mac.KeyEvents` polls the real
  keyboard state at 8ms, so the key events WE post show up there like his own
  hands would. Three outcomes, and the middle one is the one worth building
  this for:

    * `:posted` — the key was seen, with its modifier. It left macOS correctly;
      anything still wrong from here on is the game's side of the window.
    * `:naked` — the key was seen WITHOUT the modifier. shift+1 arriving as a
      bare "1" does not switch stance, it fires the skill bound to 1.
    * `:silent` — never seen at all: it did not leave this machine.
    * `:unmeasurable` — the key has no keycode to watch (a letter combo like
      shift+v), so nothing here is a statement about it.

  Nothing in this module says the GAME received anything. A window can be
  unfocused and Wine can drop a modifier macOS posted perfectly — that half is
  read with eyes, on the game.
  """

  alias Pokex.Rig.Mac.Commands

  @type sighting :: %{code: non_neg_integer, shift?: boolean, at: integer}
  @type verdict :: %{verdict: :posted | :naked | :silent | :unmeasurable, seen: non_neg_integer}

  @doc """
  What the watcher saw of `combo`, among the `sightings` it drained.

  The shift flag is SAMPLED (the helper reads the session's modifier state when
  it catches the key down), so one shifted sighting is enough to call it
  posted — a burst of taps that shows the flag on some of them did carry it.
  """
  @spec verdict(String.t(), [sighting]) :: verdict
  def verdict(combo, sightings) do
    {mods, key} = split(combo)

    case Commands.keycode(key) do
      :error ->
        %{verdict: :unmeasurable, seen: 0}

      {:ok, code} ->
        hits = Enum.filter(sightings, &(&1.code == code))
        %{verdict: verdict_for(hits, "shift" in mods), seen: length(hits)}
    end
  end

  defp verdict_for([], _shift?), do: :silent
  defp verdict_for(_hits, false), do: :posted

  defp verdict_for(hits, true),
    do: if(Enum.any?(hits, & &1.shift?), do: :posted, else: :naked)

  @doc "The keycodes `Pokex.Rig.key_watch/1` has to be armed with to measure `combos`."
  @spec codes([String.t()]) :: [non_neg_integer]
  def codes(combos) do
    combos
    |> Enum.flat_map(fn combo ->
      {_mods, key} = split(combo)

      case Commands.keycode(key) do
        {:ok, code} -> [code]
        :error -> []
      end
    end)
    |> Enum.uniq()
  end

  defp split(combo) do
    {mods, [key]} = combo |> String.split("+") |> Enum.split(-1)
    {mods, key}
  end
end
