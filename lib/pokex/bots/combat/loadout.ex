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
    case Team.active() do
      nil -> nil
      name -> resolve(name, Team.skills(name))
    end
  end

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

    # A pokémon he picked but never classified has nothing to say. Answering
    # with an empty loadout instead of nil would make the fight press nothing
    # at all, which is the one idle this machine exists to prevent.
    if attacks?(loadout), do: loadout, else: nil
  end

  def resolve(_no_name, _no_profile), do: nil

  @doc "Whether this loadout has anything to attack with at all."
  @spec attacks?(t) :: boolean
  def attacks?(%__MODULE__{aoe: aoe, single: single}), do: aoe != [] or single != []

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
