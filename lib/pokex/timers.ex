defmodule Pokex.Timers do
  @moduledoc """
  Things the bot presses because a CLOCK said so, not because the screen did.

  Two shapes, both his: "usar 8 segundos depois de começar a mobar" and "algumas
  berries no jogo que terei que ter ele usando a cada 55 minutos" (2026-08-11).
  They look different and are the same machine — an action, a clock it watches,
  and how far into that clock it goes off:

    * `:every` — the clock is its own last firing (the session start, the first
      time round). A berry every 55 minutes.
    * `:after_mob` — the clock is the moment the hunt started gathering, and it
      fires ONCE per stretch. The aura, eight seconds in.

  ## What it presses

  Either literal keys, or a JOB from `Pokex.Pokedex.SkillProfile`. The job is
  the point of having classified them: "a aura" is `:buffs` on whatever pokémon
  is on the field, so the same timer survives a swap. A berry is a key, because
  a berry is not a skill.

  A job with nobody on the field, or a pokémon that has none of it, resolves to
  no keys — and a timer with nothing to press does not fire at all, rather than
  pressing something else.

  Nothing here touches the clock or the keyboard: `Pokex.Timers.Schedule`
  decides what is due and `Pokex.Bots.Timers.Worker` performs it, which is what
  makes "does this go off now?" answerable without a game running.
  """

  alias Pokex.Bots.Combat.Loadout
  alias Pokex.Pokedex.SkillProfile
  alias Pokex.Timers.Timer

  @triggers [:every, :after_mob]

  # The one he asked for by name. Seeded rather than documented, because a
  # feature whose first useful instance is homework is a feature he has to
  # build before he can judge it.
  @seed [
    %Timer{
      id: "aura-na-mobada",
      name: "aura na mobada",
      trigger: :after_mob,
      after_ms: 8_000,
      category: :buffs,
      enabled?: true
    }
  ]

  @doc "Every trigger there is, in the order the editor offers them."
  @spec triggers() :: [Timer.trigger()]
  def triggers, do: @triggers

  @doc "The timers a fresh install starts with."
  @spec seed() :: [Timer.t()]
  def seed, do: @seed

  @doc "What this trigger means, in one phrase."
  @spec trigger_label(Timer.trigger()) :: String.t()
  def trigger_label(:every), do: "a cada"
  def trigger_label(:after_mob), do: "depois de começar a mobar"

  @doc """
  The keys this timer would press right now — `[]` when it has nothing.

  A job resolves against the pokémon on the field; literal keys ignore it
  entirely.
  """
  @spec keys_for(Timer.t(), Loadout.t() | nil) :: [String.t()]
  def keys_for(%Timer{category: nil, keys: keys}, _loadout),
    do: Enum.filter(keys, &(&1 in SkillProfile.hotbar_keys()))

  def keys_for(%Timer{category: _category}, nil), do: []

  def keys_for(%Timer{category: category}, %Loadout{} = loadout),
    do: Map.get(loadout, category_field(category), [])

  defp category_field(:aoe), do: :aoe
  defp category_field(:single), do: :single
  defp category_field(:buffs), do: :buffs
  defp category_field(:heal), do: :heal
  defp category_field(:crowd), do: :crowd

  @doc """
  One line describing what a timer does: `"aura na mobada · 8s depois de
  começar a mobar · aura"`.
  """
  @spec describe(Timer.t()) :: String.t()
  def describe(%Timer{} = timer) do
    what =
      if timer.category,
        do: SkillProfile.label(timer.category),
        else: Enum.join(timer.keys, "+")

    "#{timer.name} · #{interval_text(timer)} · #{what}"
  end

  @doc "How often/how late, in words: `\"a cada 55min\"`, `\"8s depois de começar a mobar\"`."
  @spec interval_text(Timer.t()) :: String.t()
  def interval_text(%Timer{trigger: :every, after_ms: ms}), do: "a cada #{duration(ms)}"

  def interval_text(%Timer{trigger: :after_mob, after_ms: ms}),
    do: "#{duration(ms)} depois de começar a mobar"

  @doc """
  A duration a human reads: `"8s"`, `"55min"`, `"1h30min"`.

  Rounded DOWN to the unit, and never blank: a countdown that shows nothing
  reads as broken rather than as nearly there.
  """
  @spec duration(integer) :: String.t()
  def duration(ms) when ms < 0, do: "agora"
  def duration(ms) when ms < 60_000, do: "#{div(ms, 1000)}s"

  def duration(ms) when ms < 3_600_000 do
    minutes = div(ms, 60_000)
    seconds = div(rem(ms, 60_000), 1000)
    if seconds == 0, do: "#{minutes}min", else: "#{minutes}min#{seconds}s"
  end

  def duration(ms) do
    hours = div(ms, 3_600_000)
    minutes = div(rem(ms, 3_600_000), 60_000)
    if minutes == 0, do: "#{hours}h", else: "#{hours}h#{minutes}min"
  end

  @doc """
  Builds a timer from the editor's form data, or `:error`.

  Refuses rather than repairs: a timer with no id, no interval or nothing to
  press would sit on the page looking configured and never go off.
  """
  @spec from_form(map) :: {:ok, Timer.t()} | :error
  def from_form(params) when is_map(params) do
    with {:ok, name} <- non_empty(params["name"]),
         {:ok, trigger} <- decode_trigger(params["trigger"]),
         {:ok, after_ms} <- decode_after(params["after"], params["unit"], trigger),
         {:ok, category, keys} <- decode_what(params["category"], params["keys"]) do
      {:ok,
       %Timer{
         id: params["id"] || slug(name),
         name: name,
         trigger: trigger,
         after_ms: after_ms,
         category: category,
         keys: keys,
         enabled?: params["enabled"] != "false"
       }}
    end
  end

  def from_form(_not_a_form), do: :error

  defp non_empty(value) when is_binary(value) do
    case String.trim(value) do
      "" -> :error
      trimmed -> {:ok, trimmed}
    end
  end

  defp non_empty(_absent), do: :error

  defp decode_trigger(value) when is_binary(value) do
    case Enum.find(@triggers, &(Atom.to_string(&1) == value)) do
      nil -> :error
      trigger -> {:ok, trigger}
    end
  end

  defp decode_trigger(_absent), do: :error

  # Minutes are how he says the long ones ("a cada 55 minutos") and seconds how
  # he says the short ones ("8 segundos") — storing ms and editing in his unit
  # keeps both honest.
  defp decode_after(raw, unit, trigger) do
    factor = if unit == "min", do: 60_000, else: 1_000

    with {n, _rest} when n >= 0 <- Integer.parse(to_string(raw)),
         true <- valid_after?(n * factor, trigger) do
      {:ok, n * factor}
    else
      _refused -> :error
    end
  end

  @doc """
  Whether this interval makes sense for this trigger.

  Zero is fine for `:after_mob` — "the instant the stretch starts" — because
  that one fires ONCE per stretch. Zero for `:every` would be a key press on
  every tick, forever: that is not a schedule, it is a stuck button.
  """
  @spec valid_after?(integer, Timer.trigger()) :: boolean
  def valid_after?(after_ms, :after_mob), do: is_integer(after_ms) and after_ms >= 0
  def valid_after?(after_ms, :every), do: is_integer(after_ms) and after_ms > 0
  def valid_after?(_after_ms, _unknown), do: false

  # A job wins over typed keys when both arrive: choosing "a aura" is the more
  # specific answer, and it is the one that survives a swap.
  defp decode_what(category, _keys) when is_binary(category) and category != "" do
    case Enum.find(SkillProfile.categories(), &(Atom.to_string(&1) == category)) do
      nil -> :error
      found -> {:ok, found, []}
    end
  end

  defp decode_what(_no_category, keys) do
    case parse_keys(keys) do
      [] -> :error
      parsed -> {:ok, nil, parsed}
    end
  end

  @doc """
  Reads keys the way he types them: `"8 9"`, `"8,9"`, `"8"`. Anything that is
  not a hotbar key drops out.
  """
  @spec parse_keys(term) :: [String.t()]
  def parse_keys(raw) when is_binary(raw) do
    raw
    |> String.split([" ", ",", "+"], trim: true)
    |> Enum.filter(&(&1 in SkillProfile.hotbar_keys()))
    |> Enum.uniq()
  end

  def parse_keys(_absent), do: []

  defp slug(name) do
    name
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, "-")
    |> String.trim("-")
    |> case do
      "" -> "timer"
      slug -> slug
    end
  end

  @doc "The JSON-safe shape."
  @spec encode(Timer.t()) :: map
  def encode(%Timer{} = timer) do
    %{
      "id" => timer.id,
      "name" => timer.name,
      "trigger" => Atom.to_string(timer.trigger),
      "after_ms" => timer.after_ms,
      "category" => timer.category && Atom.to_string(timer.category),
      "keys" => timer.keys,
      "enabled" => timer.enabled?
    }
  end

  @doc """
  Reads a timer off disk. Triggers and jobs are WHITELISTED, never
  `String.to_atom/1` — `timers.json` is a file he can edit by hand, and a typo
  in it must not mint atoms.
  """
  @spec decode(term) :: Timer.t() | nil
  def decode(%{"id" => id, "name" => name} = map) when is_binary(id) and is_binary(name) do
    with {:ok, trigger} <- decode_trigger(map["trigger"]),
         after_ms when is_integer(after_ms) <- map["after_ms"],
         true <- valid_after?(after_ms, trigger) do
      %Timer{
        id: id,
        name: name,
        trigger: trigger,
        after_ms: after_ms,
        category: decode_category(map["category"]),
        keys: Enum.filter(List.wrap(map["keys"]), &(&1 in SkillProfile.hotbar_keys())),
        enabled?: map["enabled"] != false
      }
    else
      _invalid -> nil
    end
  end

  def decode(_corrupt), do: nil

  defp decode_category(value) when is_binary(value),
    do: Enum.find(SkillProfile.categories(), &(Atom.to_string(&1) == value))

  defp decode_category(_absent), do: nil
end
