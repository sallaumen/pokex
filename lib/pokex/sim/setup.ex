defmodule Pokex.Sim.Setup do
  @moduledoc """
  The numbers he calibrates by hand, in `~/.pokex/sim_setup.json`.

  Every knob in `Sim.World` is labelled `measured`, `inherited` or `invented`,
  and the invented ones are the simulator's weak point: tuned by eye, they teach
  what I think rather than what the game does. This file is how they stop being
  mine. He plays a hunt, sees a monster survive a volley it should not have,
  and changes the number — once, not every time the app restarts.

  The whitelist is deliberate. A free merge of the whole file into the knobs
  would let a typo redefine physics the rest of the simulator leans on
  (`nest_size` pins a scenario, `own_row?` is an open measurement), and the
  failure would be silent: a scenario quietly answering about a different world.
  Anything not on this list is ignored and said so.
  """

  alias Pokex.Home

  require Logger

  @filename "sim_setup.json"

  @tunable [
    :mob_hp,
    :damage_spread_pct,
    :aoe_damage_pct,
    :single_damage_pct,
    :aoe_radius,
    :ms_per_tile,
    :pet_ms_per_tile,
    :mob_ms_per_tile,
    :pet_follow_tiles,
    :screen_w,
    :screen_h,
    :aggro_tiles,
    :leash_tiles,
    :bite_dmg,
    :bite_every_ms,
    # The price of a revive, measurable since 2026-08-25: how long F4 leaves the
    # pokemon in the ball, and the floor between two presses. Both are what
    # decides whether spending one for its cooldown reset pays.
    :revive_settle_ms,
    :revive_cooldown_ms,
    :stray_chance_pct
  ]

  @doc "The knobs the screen is allowed to set, in the order it shows them."
  @spec tunable() :: [atom]
  def tunable, do: @tunable

  @doc """
  What he last saved, as a knob map ready to merge over the defaults.

  An unreadable or absent file answers `%{}` — the simulator then runs on its
  own defaults, which is the right failure: a calibration nobody can read must
  not stop him from playing.
  """
  @spec read() :: map
  def read do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> %{}
    end
  rescue
    error ->
      Logger.warning(
        "sim_setup: #{path()} ilegível (#{Exception.message(error)}) — usando padrões"
      )

      %{}
  end

  @doc "Saves a knob map, keeping only what is his to set."
  @spec write(map) :: :ok
  def write(knobs) when is_map(knobs) do
    File.mkdir_p!(Home.dir())
    Home.write!(path(), JSON.encode!(encode(knobs)))
    :ok
  end

  @doc "Forgets the calibration, so the next read falls back to the defaults."
  @spec clear() :: :ok
  def clear do
    File.rm(path())
    :ok
  end

  @doc "Where the file lives."
  @spec path() :: String.t()
  def path, do: Path.join(Home.dir(), @filename)

  defp encode(knobs) do
    numbers =
      knobs
      |> Map.take(@tunable)
      |> Map.new(fn {key, value} -> {Atom.to_string(key), value} end)

    numbers
    |> Map.put("kill_combo", Map.get(knobs, :kill_combo, []))
    |> Map.put("skill_damage", encode_damage(Map.get(knobs, :skill_damage, %{})))
  end

  # A tuple has no JSON, so a band goes to disk as the two-element list it
  # already is in spirit.
  defp encode_damage(damage) do
    Map.new(damage, fn {key, {lo, hi}} -> {key, [lo, hi]} end)
  end

  defp decode(map) when is_map(map) do
    numbers =
      for key <- @tunable,
          value = map[Atom.to_string(key)],
          is_integer(value),
          into: %{},
          do: {key, value}

    numbers
    |> put_if(:kill_combo, decode_combo(map["kill_combo"]))
    |> put_if(:skill_damage, decode_damage(map["skill_damage"]))
  end

  defp decode(_shapeless), do: %{}

  defp put_if(knobs, _key, nil), do: knobs
  defp put_if(knobs, key, value), do: Map.put(knobs, key, value)

  defp decode_combo(list) when is_list(list), do: Enum.filter(list, &is_binary/1)
  defp decode_combo(_absent), do: nil

  defp decode_damage(map) when is_map(map) do
    for {key, [lo, hi]} <- map,
        is_binary(key),
        is_integer(lo),
        is_integer(hi),
        into: %{},
        do: {key, {lo, hi}}
  end

  defp decode_damage(_absent), do: nil
end
