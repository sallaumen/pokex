defmodule Pokex.Combos do
  @moduledoc """
  Sequences the bot plays against a specific enemy — Lucas's ask: "colocar a
  Jigglypuff, usar a skill 4 (sing, que faz dormir) e depois colocar meu
  pokémon que tenha vantagem contra o pokémon inimigo".

  A combo is DATA: a trigger and a list of steps. Nothing here presses a key or
  looks at the screen — it decides, and the runner in the combat path performs.
  That split is what makes the interesting part (does this combo apply, and to
  whom does it swap?) testable without a game running.

  Steps:

    * `{:swap_member, name}` — send out a specific pokémon by name
    * `{:swap_counter}` — send out whoever best answers THIS enemy
    * `{:skill, key}` — press a hotbar key
    * `{:wait, ms}` or `{:wait, setting}` — let the previous step land

  Resolution turns a combo plus an enemy into concrete steps, or refuses:
  a combo whose pokémon has no slot, or whose counter cannot be chosen, does
  not run at all. Half a combo is worse than none — it would leave the wrong
  creature out mid-fight.
  """

  alias Pokex.Pokedex
  alias Pokex.Pokedex.Team
  alias Pokex.Settings

  defmodule Combo do
    @moduledoc """
    One named sequence and what sets it off.

    `dungeon: nil` means global — the combo applies anywhere. A named dungeon
    restricts it to fights inside that dungeon (the cavebot's route), which
    only exists while the cavebot publishes it.
    """
    defstruct [:name, :trigger, :steps, enabled?: true, dungeon: nil]
  end

  @doc """
  The combo that applies to `enemy_name` in `current_dungeon`, or nil.

  Specificity decides between rivals: naming the CREATURE beats naming what it
  is made of, and both beat "qualquer inimigo" — a catch-all is a floor, not a
  competitor.

  A combo with a dungeon only applies inside it; with none, it applies
  anywhere — including when no dungeon is published at all (`nil`).
  """
  def match(combos, enemy_name, current_dungeon \\ nil)

  def match(combos, enemy_name, current_dungeon) when is_binary(enemy_name) do
    applicable =
      Enum.filter(combos, fn combo ->
        combo.enabled? and triggered?(combo, enemy_name) and
          (combo.dungeon == nil or combo.dungeon == current_dungeon)
      end)

    Enum.find(applicable, &match?({:enemy_species, _}, &1.trigger)) ||
      Enum.find(applicable, &match?({:enemy_element, _}, &1.trigger)) ||
      List.first(applicable)
  end

  def match(_combos, _no_enemy, _dungeon), do: nil

  defp triggered?(%Combo{trigger: {:enemy_species, species}}, enemy_name),
    do: String.downcase(species) == String.downcase(enemy_name)

  defp triggered?(%Combo{trigger: {:enemy_element, element}}, enemy_name) do
    case Pokedex.get(enemy_name) do
      %{elements: elements} -> element in elements
      _unknown -> false
    end
  end

  # Vale contra qualquer coisa que engajar — o gatilho de quem quer uma abertura
  # padrão, não uma resposta a um bicho específico.
  defp triggered?(%Combo{trigger: {:any_enemy}}, _enemy_name), do: true

  # NUNCA em luta: existe só pra ser emprestado a outra coisa (hoje, o prefixo
  # de stun do auto-revive). É o gatilho que deixa as skills 1/2 ficarem
  # RESERVADAS — elas não podem ser gastas numa luta comum (Lucas, 2026-07-30).
  defp triggered?(%Combo{trigger: {:rescue_only}}, _enemy_name), do: false

  defp triggered?(_combo, _enemy), do: false

  @doc """
  Se o combo serve de PREFIXO do resgate (auto-revive com stun): só passos de
  skill e espera. Trocas de time (`swap_member`/`swap_counter`) dependem de
  leitura fresca do painel e do runner de lutas — o resgate é uma sequência
  atômica cega a `:critical`, e meio swap deixaria o bicho errado fora bem no
  momento mais vulnerável.
  """
  def rescue_eligible?(%Combo{steps: steps}),
    do: Enum.all?(steps, &(match?({:skill, _}, &1) or match?({:wait, _}, &1)))

  @doc """
  Checks a combo can run, and returns its steps with the DYNAMIC ones still
  symbolic.

  This is the subtle part. A swap is not just an action, it is what REORDERS
  the rows: the pokémon sent out leaves its C+N row and the one coming back
  drops into another. So resolving the whole sequence against a single reading
  computes the last key for a layout the first key destroys — and the sing
  combo waits ~3.4s between them, which is an eternity in that panel.

  Fixed steps (`{:skill, _}`, `{:wait, _}`) resolve now. Swaps stay symbolic
  and are turned into keys by `key_for/2` at the instant they are pressed,
  against a fresh reading. Validation still happens up front, so a combo that
  could never finish is never started.
  """
  def plan(%Combo{} = combo, enemy_name, live_rows) do
    with :ok <- validate(combo, enemy_name, live_rows) do
      {:ok, Enum.map(combo.steps, &plan_step/1)}
    end
  end

  defp plan_step({:swap_member, name}), do: {:swap_member, name}
  defp plan_step({:swap_counter}), do: {:swap_counter}
  defp plan_step({:skill, key}), do: {:press, key}
  defp plan_step({:wait, setting}) when is_atom(setting), do: {:wait, Settings.get(setting)}
  defp plan_step({:wait, ms}) when is_integer(ms) and ms >= 0, do: {:wait, ms}
  defp plan_step(unknown), do: {:bad, unknown}

  # Everything that could make the sequence unfinishable, checked BEFORE the
  # first key: a pokémon nowhere on screen, an enemy nobody answers, a step
  # nobody understands. Half a combo strands whoever it just sent out.
  defp validate(%Combo{steps: steps}, enemy_name, live_rows) do
    Enum.reduce_while(steps, :ok, fn step, :ok ->
      case check(step, enemy_name, live_rows) do
        :ok -> {:cont, :ok}
        {:skip, _reason} = skip -> {:halt, skip}
      end
    end)
  end

  defp check({:swap_member, name}, _enemy, live_rows) do
    if find_slot(live_rows, name), do: :ok, else: {:skip, {:not_on_screen, name}}
  end

  defp check({:swap_counter}, enemy_name, live_rows) do
    if Team.best_counter(enemy_name, live_rows), do: :ok, else: {:skip, {:no_counter, enemy_name}}
  end

  defp check({:skill, _key}, _enemy, _rows), do: :ok
  defp check({:wait, setting}, _enemy, _rows) when is_atom(setting), do: :ok
  defp check({:wait, ms}, _enemy, _rows) when is_integer(ms) and ms >= 0, do: :ok
  defp check(unknown, _enemy, _rows), do: {:skip, {:bad_step, unknown}}

  @doc """
  The key a step means RIGHT NOW, given the team as it is at this instant.

  Fixed steps pass through. A swap is looked up against `live_rows` — which
  the runner must re-read after every swap, because that is precisely what
  moves everyone around.
  """
  def key_for({:press, key}, _enemy, _live_rows), do: {:ok, key}

  def key_for({:swap_member, name}, _enemy, live_rows) do
    case find_slot(live_rows, name) do
      nil -> {:skip, {:not_on_screen, name}}
      slot -> {:ok, Team.swap_key(slot)}
    end
  end

  def key_for({:swap_counter}, enemy_name, live_rows) do
    case Team.best_counter(enemy_name, live_rows) do
      nil -> {:skip, {:no_counter, enemy_name}}
      slot -> {:ok, Team.swap_key(slot)}
    end
  end

  def key_for(step, _enemy, _live_rows), do: {:skip, {:bad_step, step}}

  # A row is only reachable when BOTH its portrait and its hotkey were read: a
  # nameless row could be anyone, and a row with no C+N label has no key to
  # press.
  defp find_slot(live_rows, name) do
    Enum.find_value(live_rows, fn row ->
      if is_map(row) and Map.get(row, :name) == name and is_integer(Map.get(row, :slot)),
        do: row.slot
    end)
  end

  @doc "How long the whole sequence will take, so a caller can budget for it."
  def duration(steps),
    do:
      Enum.reduce(steps, 0, fn
        {:wait, ms}, total -> total + ms
        _press, total -> total
      end)
end
