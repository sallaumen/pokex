defmodule Pokex.Sim.Score do
  @moduledoc """
  The hunt as NUMBERS: what a night of this brain would produce per minute.

  A timeline answers "what did it decide". A scorecard answers the question he
  actually asks — *"is this brain better than that one"* — and it has to answer
  it in units a person can argue with: monsters per minute, deaths per minute,
  and how much of the minute was spent standing in front of monsters with
  nothing left to press.

  ## The six numbers, and why each exists

    * **`kills_per_min`** — the product. Everything else is a cost paid for it.
    * **`deaths_per_min`** — the price. A brain that kills 20% more while
      falling twice as often is not a better brain; it is a brain that has not
      been charged yet.
    * **`down_pct`** — the share of the run with NO pokemon on the field:
      fainted, or in the ball mid-revive. It is the only number that is pure
      loss — during it the hunt cannot kill, cannot defend, and he is the one
      being bitten.
    * **`stalled_pct`** — monsters on screen and every damage key on cooldown.
      This is the exact window his F4 idea targets: "0 cooldowns livres, muitos
      inimigos ainda na tela". If this is small, a revive-to-reset rule has
      nothing to win; if it is large, it has.
    * **`vanished_per_min`** — piles walked away from. R2's bill.
    * **`min_hp` / `yellow_pct` / `red_pct` / `player_hp`** — the RISK, for the
      runs that end with zero deaths and no way to tell luck from safety. The
      lowest the bar ever got, how much of the run the brain spent in each band,
      and what the character himself paid: he is only ever bitten while nothing
      of his is on the field, so `player_hp` is the price of every second spent
      down, in one number.
    * **`pile_ms`** (median / worst) — how long one pile takes from first
      monster on the list to empty list. Agility, in his words: "matar tudo e
      ser ágil".

  ## The revive, judged instead of counted

  A count of revives says nothing: the same six presses are excellent or
  reckless depending on WHEN. So every revive order is filed by the state of
  the world at the instant it was given:

    * **`proactive`** — the bar was spent AND the pile was still worth fighting
      (`enemies >= engage_from`). This is the press he is asking about: the
      fight had nothing left and the reset bought a whole bar back.
    * **`rescue`** — health was in the red or the round was being closed. The
      classic reason, and the only one the brain knows how to give today.
    * **`wasted`** — nothing was spent and nothing was on screen. A press that
      bought nothing and cost `revive_settle_ms` off the field.
    * **`refused`** — ORDERED and not accepted: still inside
      `revive_cooldown_ms`, already in flight, or the key is dead. An order the
      game never honoured must never be counted as a revive that happened, and
      keeping the two apart is what lets a run show a brain pressing F4 into a
      wall.

  ## What these numbers are worth (read this before tuning on them)

  Every number here is exact ARITHMETIC over a simulation whose damage model is
  invented. `mob_hp: 100`, `single_damage_pct: 22`, `aoe_damage_pct: 34`,
  `skill_cooldown_ms: 8_000`, `bite_dmg`, `bite_every_ms`, `revive_settle_ms` —
  none of these was measured in his game (`Pokex.Sim.World` names each guess as
  a guess, on purpose).

  So:

    * **Comparisons are trustworthy.** Same world, same seed, two brains: the
      difference between them is caused by the brains, and the sign of that
      difference is real.
    * **Absolute rates are not.** "14 monsters a minute" is a property of my
      damage numbers, not of Rattata. Do not carry an absolute into a
      conversation about the game; carry the delta.

  Closing that gap needs four measurements from a real hunt: how many presses
  kill one monster of the hunt, how long that takes, how fast the health falls
  under a pile of N, and how long F4 leaves the pokemon off the field.
  """

  alias Pokex.Sim.Knobs
  alias Pokex.Sim.Bench
  alias Pokex.Sim.Scenario

  @minute_ms 60_000

  @doc """
  The scorecard for a bench result.

  `config` is the decision config the run used — `engage_from` is needed to
  judge whether a pile was "worth fighting" at the moment a revive was ordered.
  """
  @spec card(map, map) :: map
  def card(%{metrics: metrics}, config \\ %{}) do
    minutes = max(metrics.ms, 1) / @minute_ms
    engage_from = Map.get(config, :engage_from, 3)
    revives = Enum.map(metrics.revives, &classify(&1, engage_from))
    accepted = Enum.filter(revives, & &1.accepted?)

    %{
      ms: metrics.ms,
      minutes: minutes,
      kills: metrics.kills,
      deaths: length(metrics.deaths),
      vanished: metrics.vanished,
      kills_per_min: per_min(metrics.kills, minutes),
      deaths_per_min: per_min(length(metrics.deaths), minutes),
      vanished_per_min: per_min(metrics.vanished, minutes),
      revives_per_min: per_min(length(accepted), minutes),
      stalled_pct: pct(metrics.ms_stalled, metrics.ms),
      down_pct: pct(metrics.ms_down, metrics.ms),
      fighting_pct: pct(metrics.ms_fighting, metrics.ms),
      enemies_pct: pct(metrics.ms_enemies, metrics.ms),
      piles_cleared: length(metrics.piles),
      by_phase: phase_shares(metrics),
      min_hp: metrics.min_hp,
      player_hp: metrics.player_hp,
      yellow_pct: pct(Map.get(metrics.by_band, :yellow, 0), metrics.ms),
      red_pct: pct(Map.get(metrics.by_band, :red, 0), metrics.ms),
      pile_ms: %{median: median(metrics.piles), worst: Enum.max(metrics.piles, fn -> nil end)},
      revives: %{
        ordered: length(revives),
        accepted: length(accepted),
        refused: length(revives) - length(accepted),
        proactive: count_kind(accepted, :proactive),
        rescue: count_kind(accepted, :rescue),
        wasted: count_kind(accepted, :wasted),
        events: revives
      }
    }
  end

  @doc """
  Runs `scenario` and scores it in one call.

  `opts` are `Bench.run/2`'s, plus nothing of its own — the config the run used
  is what the card is judged against, so the two can never disagree.
  """
  @spec run(Scenario.t(), keyword) :: map
  def run(%Scenario{} = scenario, opts \\ []) do
    # O que o CENÁRIO fixa entra por baixo do que o chamador pediu, exatamente
    # como no `Bench.run/2` — senão o placar julgaria a corrida por um ajuste
    # diferente do que ela rodou.
    config =
      Bench.default_config()
      |> Map.merge(scenario.config)
      |> Map.merge(Keyword.get(opts, :config, %{}))

    result = Bench.run(scenario, Keyword.put(opts, :config, config))

    Map.put(result, :card, card(result, config))
  end

  @doc """
  A HUNT rather than an experiment: the same route walked for `:minutes`
  (default 5) with the nests coming back.

  A scenario is one pile and one question, and a rate per minute measured on it
  is really a rate per fight. This runs long enough for the walking, the
  respawns and the bad luck to be in the average — which is the only shape in
  which "monstros por minuto" means what he means by it.
  """
  @spec hunt(Scenario.t(), keyword) :: map
  def hunt(%Scenario{} = scenario, opts \\ []) do
    minutes = Keyword.get(opts, :minutes, 5)
    # O RENASCIMENTO TEM DONO, e não é este arquivo: `Sim.Knobs.respawn_ms/1` é o número
    # que a tela mostra e que o `Sim.Runner` obedece. Inventados aqui, 45s
    # faziam o placar — a coisa com que dois cérebros são comparados — medir os
    # dois num mundo mais vazio do que o simulado. Só três dos doze cenários
    # trazem o seu; nos outros nove valia o número inventado.
    respawn_ms = Keyword.get(opts, :respawn_ms, Knobs.respawn_ms(:seeds))

    scenario = %{scenario | knobs: Map.put_new(scenario.knobs, :respawn_ms, respawn_ms)}

    run(scenario, Keyword.put(opts, :duration_ms, round(minutes * @minute_ms)))
  end

  # HIS definition, in his words: "0 cooldowns livres, muitos inimigos ainda na
  # tela". Spent + a pile still worth fighting is the press worth making; the
  # health reasons are the ones the brain already knows; everything else bought
  # nothing.
  defp classify(event, engage_from) do
    Map.put(event, :kind, kind_of(event, engage_from))
  end

  defp kind_of(%{phase: phase}, _engage_from) when phase in [:emergency, :closing, :recovering],
    do: :rescue

  defp kind_of(%{spent?: true, enemies: n}, engage_from)
       when is_integer(n) and n >= engage_from,
       do: :proactive

  defp kind_of(%{spent?: false, enemies: n}, _engage_from) when n in [0, nil], do: :wasted
  defp kind_of(_event, _engage_from), do: :other

  defp count_kind(events, kind), do: Enum.count(events, &(&1.kind == kind))

  # Sorted by how much of the run each phase ate, because that is the order the
  # question gets asked in: what took the time, then what took the rest.
  defp phase_shares(%{by_phase: by_phase, ms: ms}) do
    by_phase
    |> Enum.map(fn {phase, spent} -> %{phase: phase, ms: spent, pct: pct(spent, ms)} end)
    |> Enum.sort_by(& &1.ms, :desc)
  end

  defp phase_shares(_no_phases), do: []

  defp per_min(count, minutes), do: Float.round(count / minutes, 2)

  defp pct(_part, 0), do: 0.0
  defp pct(part, whole), do: Float.round(part * 100 / whole, 1)

  defp median([]), do: nil

  defp median(values) do
    sorted = Enum.sort(values)
    middle = div(length(sorted), 2)

    case rem(length(sorted), 2) do
      1 -> Enum.at(sorted, middle)
      0 -> div(Enum.at(sorted, middle - 1) + Enum.at(sorted, middle), 2)
    end
  end
end
