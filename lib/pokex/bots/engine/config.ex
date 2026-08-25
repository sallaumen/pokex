defmodule Pokex.Bots.Engine.Config do
  @moduledoc """
  The knobs the decision runs on, declared once.

  They used to be declared three times: `Engine.Worker` built a map key by key,
  `Sim.Bench` kept its own list, and `Engine.Logic` carried a literal fallback
  inside each `Map.get(config, :knob, 6_000)`. Three copies of one list is three
  chances to disagree, and they took it — on 2026-08-25 the bench's copy still
  said `recover_timeout_ms: 20_000` and `closing_timeout_ms: 15_000` while the
  seeds had been 30_000 and 8_000 for weeks, so every verdict it gave was about
  a bot that does not exist.

  So: one list, two readings of it.

    * `in_force/0` — what the bot is running right now, his overrides included.
    * `defaults/0` — the SEEDS, which is what keeps a bench run reproducible
      across machines and across whatever he tuned today.

  ## A config is COMPLETE or it is not a config

  `Logic` reads `config.knob` and nothing else — no `Map.get`, no fallback, no
  literal. A key missing from the map is a crash naming the key, which is the
  cheapest possible way to find out that a caller forgot one. The alternative
  (a fallback per read site) is how a knob comes to have two values: the one in
  Settings and the one written next to the read.

  `merge/1` is how a caller asks a question — "the same hunt, but engaging from
  one" — without having to know the other sixteen.
  """

  alias Pokex.Settings

  # knob (what the decision calls it) => setting (what Settings stores it under)
  @knobs %{
    engage_from: :engine_engage_from,
    gather_piles: :engine_gather_piles,
    pile_settle_ms: :engine_pile_settle_ms,
    gather_tiles: :engine_gather_tiles,
    patience_tiles: :engine_patience_tiles,
    size_ceiling_ms: :engine_size_ceiling_ms,
    skip_fire: :engine_skip_fire,
    kite_when_spent: :engine_kite_when_spent,
    band_yellow_pct: :engine_band_yellow_pct,
    band_red_pct: :engine_band_red_pct,
    resume_pct: :engine_resume_pct,
    recover_timeout_ms: :engine_recover_timeout_ms,
    closing_timeout_ms: :engine_closing_timeout_ms,
    revive_confirm_ms: :engine_revive_confirm_ms,
    reset_revive: :engine_reset_revive,
    reset_revive_cooldown_ms: :engine_reset_revive_cooldown_ms,
    reset_revive_min_hp: :engine_reset_revive_min_hp,
    # NOT the engine's own numbers: the two floors `PlayerSupport` keeps between
    # two presses — one for a pokémon still standing, a much shorter one for a
    # pokémon already on the floor. A brain planning around a press the hands
    # cannot make is how a hunt froze for thirty seconds at a time (R5), and a
    # brain asking four times faster than the hands can answer is the same
    # mistake pointed the other way.
    rescue_cooldown_ms: :rescue_cooldown_ms,
    fainted_revive_cooldown_ms: :fainted_revive_cooldown_ms
  }

  @type t :: %{required(atom) => term}

  @doc "Every knob, by the name the decision calls it, and the setting behind it."
  @spec knobs() :: %{atom => atom}
  def knobs, do: @knobs

  @doc "The knobs as the bot is running them right now."
  @spec in_force() :: t
  def in_force, do: Map.new(@knobs, fn {knob, setting} -> {knob, Settings.get(setting)} end)

  @doc "The knobs at their SEEDED values — reproducible, and his tuning aside."
  @spec defaults() :: t
  def defaults do
    seeds = Settings.defaults()
    Map.new(@knobs, fn {knob, setting} -> {knob, Map.fetch!(seeds, setting)} end)
  end

  @doc "The seeds with `overrides` on top: the shape a question is asked in."
  @spec merge(map) :: t
  def merge(overrides \\ %{}), do: Map.merge(defaults(), overrides)
end
