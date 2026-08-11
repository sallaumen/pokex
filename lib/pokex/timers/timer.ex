defmodule Pokex.Timers.Timer do
  @moduledoc """
  One scheduled action: what to press, which clock it watches, and how far into
  that clock it goes off.

  See `Pokex.Timers` for the vocabulary and `Pokex.Timers.Schedule` for the
  rules that read it.
  """

  alias Pokex.Pokedex.SkillProfile

  defstruct id: nil,
            name: "",
            trigger: :every,
            after_ms: 60_000,
            # a JOB (`:buffs`) resolved against whoever is on the field, so the
            # timer survives a swap; nil means the literal `keys` below
            category: nil,
            keys: [],
            enabled?: true

  @type trigger :: :every | :after_mob

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          trigger: trigger,
          after_ms: pos_integer,
          category: SkillProfile.category() | nil,
          keys: [String.t()],
          enabled?: boolean
        }
end
