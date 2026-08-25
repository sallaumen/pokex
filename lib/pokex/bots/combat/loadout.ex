defmodule Pokex.Bots.Combat.Loadout do
  @moduledoc """
  The keys of the pokémon currently on the field, already sorted by job.

  `Pokex.Pokedex.SkillProfile` says what each key of each pokémon does; this is
  that answer for ONE of them — whichever is out — in the shape the fight wants
  to read: four lists, never a lookup.

  ## Why he chooses it instead of us reading it

  Resolving the profile needs to know which pokémon is on the field, and the
  honest way to know is to read its portrait off the screen. That read does not
  exist yet, and waiting for it would keep every one of the rules he described
  (open with area, hold the aura for the huddle, never spend the control) sitting
  unimplemented behind a calibration.

  So the pokémon is a CHOICE he makes on `/time`, not a mystery we solve. When
  the portrait read arrives it becomes the source and the choice becomes the
  fallback — this module's shape does not change, and neither does anything
  reading it.

  ## Not a fact on the blackboard

  Deliberately: a blackboard fact carries an age and rots, which is right for
  something the screen is telling us and wrong for something he configured. A
  loadout that aged out mid-hunt would silently drop the fight back to the
  global key list. It is read once and re-read when the team file changes.
  """

  alias Pokex.Pokedex.{SkillProfile, Team}

  @enforce_keys [:name]
  defstruct name: nil, aoe: [], single: [], buffs: [], heal: [], crowd: []

  @type t :: %__MODULE__{
          name: String.t(),
          aoe: [String.t()],
          single: [String.t()],
          buffs: [String.t()],
          heal: [String.t()],
          crowd: [String.t()]
        }

  @doc """
  The loadout of the pokémon he chose, or `nil` when he chose none — or chose
  one whose skills are still unclassified.

  `nil` is not a failure: it is what makes every consumer fall back to the
  behaviour it had before this module existed.
  """
  @spec current() :: t | nil
  def current do
    real() || simulated()
  end

  defp real do
    case Team.active() do
      nil -> nil
      name -> resolve(name, Team.skills(name))
    end
  end

  # THE SIMULATOR'S STAND-IN, and only ever the simulator's: `Sim.Fence` puts a
  # bar here while it is armed and takes it away when it disarms, exactly like
  # it does with the rig and the eyes. Without it, arming with no team
  # configured gave the engine no hands, so it ordered nothing, so a whole
  # simulated hunt ran without a single key leaving the bar — silently (found
  # by him playing it, 2026-08-25).
  #
  # It can never leak into a real hunt: nothing else writes this key, and the
  # fence restores it in the same order it restores the hands.
  defp simulated, do: Application.get_env(:pokex, :simulated_loadout)

  @doc """
  Builds a loadout from a name and its profile. Pure — the whole reason the
  rules are testable without a team file.
  """
  @spec resolve(String.t(), SkillProfile.t()) :: t | nil
  def resolve(name, profile) when is_binary(name) and is_map(profile) do
    loadout = %__MODULE__{
      name: name,
      aoe: SkillProfile.keys(profile, :aoe),
      single: SkillProfile.keys(profile, :single),
      buffs: SkillProfile.keys(profile, :buffs),
      heal: SkillProfile.keys(profile, :heal),
      crowd: SkillProfile.keys(profile, :crowd)
    }

    # nil ONLY when he classified nothing at all. It used to mean "nothing to
    # attack with", and that conflated two different questions: the fight asks
    # "can I fight with this?" (`attacks?/1`) while a scheduled aura asks "what
    # is this pokémon's aura?" — and a pokémon with an aura and no area damage
    # classified has an honest answer to the second and not the first.
    if classified?(loadout), do: loadout, else: nil
  end

  def resolve(_no_name, _no_profile), do: nil

  @doc """
  Whether this loadout has anything to ATTACK with — the fight's question.

  False sends combat back to the configured key list, because a fight that
  presses nothing is the one idle the machine exists to prevent.
  """
  @spec attacks?(t | nil) :: boolean
  def attacks?(%__MODULE__{aoe: aoe, single: single}), do: aoe != [] or single != []
  def attacks?(nil), do: false

  @doc "Whether he classified ANY key of this pokémon, for any job."
  @spec classified?(t) :: boolean
  def classified?(%__MODULE__{} = loadout) do
    Enum.any?(
      [loadout.aoe, loadout.single, loadout.buffs, loadout.heal, loadout.crowd],
      &(&1 != [])
    )
  end

  @doc """
  The keys of this category on THIS pokémon — `[]` when there is no answer.

  The question a scheduled order asks ("what is his aura?"), separate from the
  one the fight asks (`attacks?/1`). With no pokémon on the field, or a category
  he never classified, the answer is empty and never an exception: whoever is
  asking is a worker in the middle of a tick.
  """
  @spec keys(t | nil, atom) :: [String.t()]
  def keys(%__MODULE__{} = loadout, category) do
    if category in SkillProfile.categories(), do: Map.get(loadout, category, []), else: []
  end

  def keys(nil, _no_pokemon), do: []

  @doc "One line for a log or a panel: `\"Shiny Vileplume · área 3+4 · alvo 7\"`."
  @spec describe(t | nil) :: String.t()
  def describe(nil), do: "sem pokémon escolhido"

  def describe(%__MODULE__{} = loadout) do
    parts =
      [{:aoe, loadout.aoe}, {:single, loadout.single}, {:buffs, loadout.buffs}]
      |> Enum.reject(fn {_job, keys} -> keys == [] end)
      |> Enum.map_join(" · ", fn {job, keys} ->
        "#{SkillProfile.label(job)} #{Enum.join(keys, "+")}"
      end)

    "#{loadout.name} · #{parts}"
  end
end
