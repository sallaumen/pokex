defmodule Pokex.Pokedex.Team do
  @moduledoc """
  Lucas's OWN Pokémon (~/.pokex/team.json), now in two lists: the active
  TEAM he hunts with and the BANK (owned and stored, not hunting).
  Each entry carries an optional LEVEL, and the file
  also stores his character level + the hunt-window margin — what makes the
  /time suggestions match his real strength instead of recommending lv-5
  targets at lv 88.

  Names must exist in the scraped Pokédex (Shiny variants allowed — owning
  one is real). Same storage philosophy as Settings/Calibration profiles:
  a tiny JSON under the Pokex home, no process. Files written by the v1
  module (a bare list of names) load transparently as a level-less team.
  """

  alias Pokex.Pokedex.SkillProfile
  alias Pokex.{Home, Pokedex}

  # The in-game hotkey slots a team member can answer to: C+2..C+6 on screen.
  @slots 2..6//1 |> Enum.to_list()

  @default_margin 15

  @topic "team"

  @doc """
  Where a change to the team is announced.

  The fight resolves its key order from the active pokémon's profile and must
  not re-read a file every burst (the disk lesson from the recording audit), so
  it caches — and a cache with no invalidation would keep pressing yesterday's
  keys after he re-classified them.
  """
  def topic, do: @topic

  defp announce(data) do
    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:team_changed})
    data
  catch
    # a team edited with no PubSub running (scripts, tests) is still a saved team
    :exit, _no_pubsub -> data
  end

  @doc "The active team, in insertion order: [%{name, level}] (level nil = not set)."
  def members, do: read().members

  @doc "The bank (owned but not hunting): same shape as members/0."
  def bank, do: read().bank

  @doc "Just the team's names — what hunt_suggestions consumes."
  def member_names, do: Enum.map(members(), & &1.name)

  @doc "Lucas's character level (nil until he sets it on /time)."
  def player_level, do: read().player_level

  @doc "The hunt-window margin (±levels around player_level). Default #{@default_margin}."
  def level_margin, do: read().level_margin

  @doc """
  Adds a Pokédex-known name to `:team` or `:bank` (idempotent across BOTH
  lists — a name lives in one place). {:ok, data} | {:error, :unknown}.
  """
  def add(name, where \\ :team) when where in [:team, :bank] do
    case Pokedex.get(name) do
      nil ->
        {:error, :unknown}

      _entry ->
        data = read()
        target = if where == :team, do: data.members, else: data.bank

        if Enum.any?(target, &(&1.name == name)) do
          # already there — keep its position AND its level
          {:ok, data}
        else
          # relocating from the other list keeps the level too
          entry =
            Enum.find(
              data.members ++ data.bank,
              %{name: name, level: nil, slot: nil, skills: %{}, cooldowns: %{}, bar: nil},
              &(&1.name == name)
            )

          {:ok, data |> drop(name) |> append_to(where, entry) |> persist()}
        end
    end
  end

  defp append_to(data, :team, entry), do: %{data | members: data.members ++ [entry]}
  defp append_to(data, :bank, entry), do: %{data | bank: data.bank ++ [entry]}

  @doc "Removes a name from wherever it lives (idempotent)."
  def remove(name), do: persist(drop(read(), name))

  @doc "Moves a name to the OTHER list, keeping its level. No-op if absent."
  def move(name, where) when where in [:team, :bank] do
    data = read()

    case Enum.find(data.members ++ data.bank, &(&1.name == name)) do
      nil ->
        data

      entry ->
        data = drop(data, name)

        persist(
          case where do
            :team -> %{data | members: data.members ++ [entry]}
            :bank -> %{data | bank: data.bank ++ [entry]}
          end
        )
    end
  end

  @doc ~S'The key that swaps a slot in: C+2 on screen is "ctrl+2" to the Rig.'
  def swap_key(slot) when slot in @slots, do: "ctrl+#{slot}"

  @doc """
  Which slot best answers `enemy_name`, given the team as it is RIGHT NOW.

  `live_rows` comes from the `:team` feed — `[%{slot, name}]` — because the
  C+N order changes as Lucas plays and a configured slot would send out
  whoever happens to be sitting there now. nil when nobody on screen has an
  advantage: a combo that cannot pick a counter must not run.
  """
  def best_counter(enemy_name, live_rows) do
    case Pokedex.get(enemy_name) do
      %{} = enemy ->
        live_rows
        |> Enum.filter(
          &(is_map(&1) and is_binary(Map.get(&1, :name)) and is_integer(Map.get(&1, :slot)))
        )
        |> Enum.map(fn row -> {row.slot, advantage(row.name, enemy)} end)
        |> Enum.filter(fn {_slot, score} -> score > 0 end)
        |> Enum.max_by(fn {_slot, score} -> score end, fn -> nil end)
        |> case do
          nil -> nil
          {slot, _score} -> slot
        end

      _unknown ->
        nil
    end
  end

  # Same shape as the hunt scoring: hits are worth what resistances take away.
  defp advantage(member_name, enemy) do
    case Pokedex.get(member_name) do
      nil ->
        0

      member ->
        hits = Enum.count(member.elements, &(&1 in enemy.weak_to))
        resisted = Enum.count(member.elements, &(&1 in enemy.resists))
        2 * hits - 2 * resisted
    end
  end

  @doc "Sets an entry's level wherever it lives (nil clears). No-op if absent."
  def set_level(name, level) when is_integer(level) or is_nil(level) do
    data = read()

    update = fn list ->
      Enum.map(list, fn
        %{name: ^name} = entry -> %{entry | level: level}
        entry -> entry
      end)
    end

    persist(%{data | members: update.(data.members), bank: update.(data.bank)})
  end

  @doc """
  What each of this pokémon's skills is for (see `Pokex.Pokedex.SkillProfile`).

  Empty for a name nobody knows — a strategy asking an unknown pokémon for its
  area damage gets `[]` and skips that step, exactly as it does for a pokémon
  that genuinely has none.
  """
  def skills(name) do
    case Enum.find(members() ++ bank(), &(&1.name == name)) do
      %{skills: skills} -> skills
      _absent -> %{}
    end
  end

  @doc """
  Quanto cada skill deste pokémon leva pra voltar, em ms.

  Vazio para quem ele ainda não mediu — e vazio quer dizer "não sei", nunca
  "instantâneo": quem lê isto trata a tecla sem cooldown escrito como pronta,
  que é o comportamento que o bot já tinha antes de existir esta tabela.
  """
  def cooldowns(name) do
    case Enum.find(members() ++ bank(), &(&1.name == name)) do
      %{cooldowns: cooldowns} -> cooldowns
      _absent -> %{}
    end
  end

  @doc "Grava os cooldowns deste pokémon. No-op se ele não existe."
  def set_cooldowns(name, cooldowns) when is_map(cooldowns) do
    cooldowns = SkillProfile.decode_cooldowns(cooldowns)

    update = fn list ->
      Enum.map(list, fn
        %{name: ^name} = entry -> Map.put(entry, :cooldowns, cooldowns)
        entry -> entry
      end)
    end

    data = read()

    %{data | members: update.(data.members), bank: update.(data.bank)}
    |> persist()
    |> announce()
  end

  @doc """
  Replaces a pokémon's whole skill profile. No-op if absent.

  The whole map, not one key: the editor is a form that reports every select
  on every change, so rebuilding is both simpler and impossible to get out of
  step with what is on screen.
  """
  def set_skills(name, profile) when is_map(profile) do
    data = read()

    update = fn list ->
      Enum.map(list, fn
        %{name: ^name} = entry -> %{entry | skills: profile}
        entry -> entry
      end)
    end

    %{data | members: update.(data.members), bank: update.(data.bank)}
    |> persist()
    |> announce()
  end

  @doc """
  This pokémon's OWN skill bar: where it is on screen, how many slots it has,
  and the per-slot READY colour references.

  It used to be one global calibration, and that is wrong on two counts he ran
  into: different pokémon have different numbers of moves, and the READY
  references ARE the skill icons — so a set captured with Vespiquen out is a
  set of the wrong pictures the moment he swaps.

  `nil` when this one has never been calibrated, which is what makes the global
  calibration the fallback instead of a broken read.
  """
  @spec bar(String.t()) :: map | nil
  def bar(name) do
    case Enum.find(members() ++ bank(), &(&1.name == name)) do
      %{bar: %{} = bar} -> bar
      _absent_or_uncalibrated -> nil
    end
  end

  @doc """
  Stores a pokémon's bar. `nil` clears it, which drops that pokémon back to the
  global calibration.
  """
  @spec set_bar(String.t(), map | nil) :: map
  def set_bar(name, bar) do
    data = read()

    update = fn list ->
      Enum.map(list, fn
        %{name: ^name} = entry -> Map.put(entry, :bar, bar)
        entry -> entry
      end)
    end

    %{data | members: update.(data.members), bank: update.(data.bank)}
    |> persist()
    |> announce()
  end

  # Tuples do not survive JSON — and the bar carries TWO kinds of them: the
  # region, and one {r,g,b} READY reference per slot. The first cut only
  # translated the region, so the first real save (the page samples the refs
  # off the screenshot) died inside JSON.encode!, taking the calibration page
  # down with it. Both ride as lists and come back as tuples, because every
  # consumer pattern-matches {x, y, w, h} and Vision.slot_distance/2 answers
  # nil — silently dropping the reference — for anything that is not {r,g,b}.
  defp encode_bar(%{region: {x, y, w, h}} = bar),
    do: %{
      "region" => [x, y, w, h],
      "count" => bar[:count],
      "refs" => encode_refs(bar[:refs])
    }

  defp encode_bar(_none), do: nil

  defp encode_refs(refs) when is_list(refs), do: Enum.map(refs, &tuple_to_list/1)
  defp encode_refs(_none), do: nil

  defp tuple_to_list({_r, _g, _b} = ref), do: Tuple.to_list(ref)
  defp tuple_to_list([_r, _g, _b] = ref), do: ref
  defp tuple_to_list(_no_ref), do: nil

  defp decode_bar(%{"region" => [x, y, w, h], "count" => count} = map)
       when is_integer(count) and count in 1..10,
       do: %{region: {x, y, w, h}, count: count, refs: decode_refs(map["refs"])}

  defp decode_bar(_absent_or_corrupt), do: nil

  defp decode_refs(refs) when is_list(refs), do: Enum.map(refs, &list_to_tuple/1)
  defp decode_refs(_none), do: nil

  defp list_to_tuple([_r, _g, _b] = ref), do: List.to_tuple(ref)
  defp list_to_tuple(_no_ref), do: nil

  @doc "Sets Lucas's character level (nil clears)."
  def set_player_level(level) when is_integer(level) or is_nil(level),
    do: persist(%{read() | player_level: level})

  @doc "Sets the hunt-window margin."
  def set_level_margin(margin) when is_integer(margin) and margin > 0,
    do: persist(%{read() | level_margin: margin})

  @doc """
  The pokémon he says is on the field, or `nil`.

  Reading it off the screen is the honest way and does not exist yet; waiting
  for it would keep every rule that depends on knowing (open with area, hold
  the aura, never spend the control) unimplemented behind a calibration. So he
  chooses, and the choice is stored beside the team it belongs to.

  A name that has since left the team answers `nil`: the bar of a pokémon that
  is not his any more is not a bar to fight with.
  """
  @spec active() :: String.t() | nil
  def active do
    name = read().active
    if name && Enum.any?(members(), &(&1.name == name)), do: name, else: nil
  end

  @doc """
  The pokémon on the field together with its own skill bar, or `nil` when
  nobody is chosen or the chosen one has no bar of its own.

  One question, ONE read of the file. Asking `active/0` and then `bar/1` costs
  four — and the skill-bar feed asks this twice per tick, so the convenient
  spelling put a couple of hundred file reads a second into the perception
  loop for an answer that was already on the first page.
  """
  @spec active_bar() :: {String.t(), map} | nil
  def active_bar do
    data = read()

    with name when is_binary(name) <- data.active,
         %{bar: %{region: {_x, _y, _w, _h}} = bar} <-
           Enum.find(data.members, &(&1.name == name)) do
      {name, bar}
    else
      _no_choice_or_no_bar -> nil
    end
  end

  @doc """
  Chooses the pokémon on the field. `nil` (or a name outside the TEAM) clears
  it, which drops every consumer back to its pre-loadout behaviour.
  """
  @spec set_active(String.t() | nil) :: map
  def set_active(name) do
    data = read()
    known? = is_binary(name) and Enum.any?(data.members, &(&1.name == name))

    %{data | active: if(known?, do: name, else: nil)}
    |> persist()
    |> announce()
  end

  # -- storage -----------------------------------------------------------------

  defp read do
    with {:ok, bin} <- File.read(file()),
         {:ok, json} <- JSON.decode(bin) do
      %{
        members: entries(json["members"]),
        bank: entries(json["bank"]),
        player_level: int_or_nil(json["player_level"]),
        level_margin: int_or_nil(json["level_margin"]) || @default_margin,
        active: name_or_nil(json["active"])
      }
    else
      _missing_or_corrupt ->
        %{
          members: [],
          bank: [],
          player_level: nil,
          level_margin: @default_margin,
          active: nil
        }
    end
  end

  defp name_or_nil(value) when is_binary(value) and value != "", do: value
  defp name_or_nil(_other), do: nil

  # v1 stored bare name strings; v2 added "level"; v3 "slot"; v4 "skills";
  # v5 "cooldowns" — every one of them still loads, e um campo que falta é
  # simplesmente vazio.
  defp entries(list) when is_list(list) do
    list
    |> Enum.map(fn
      name when is_binary(name) ->
        %{name: name, level: nil, slot: nil, skills: %{}, cooldowns: %{}, bar: nil}

      %{"name" => name} = map when is_binary(name) ->
        %{
          name: name,
          level: int_or_nil(map["level"]),
          slot: slot_or_nil(map["slot"]),
          skills: SkillProfile.decode(map["skills"]),
          cooldowns: SkillProfile.decode_cooldowns(map["cooldowns"]),
          bar: decode_bar(map["bar"])
        }

      _corrupt ->
        nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp entries(_absent), do: []

  defp int_or_nil(value) when is_integer(value), do: value
  defp int_or_nil(_other), do: nil

  defp slot_or_nil(value) when value in 2..6, do: value
  defp slot_or_nil(_other), do: nil

  defp encode_entry(entry) do
    %{
      "name" => entry.name,
      "level" => entry.level,
      "slot" => entry.slot,
      "skills" => SkillProfile.encode(entry.skills),
      "cooldowns" => Map.get(entry, :cooldowns, %{}),
      "bar" => encode_bar(Map.get(entry, :bar))
    }
  end

  defp drop(data, name) do
    %{
      data
      | members: Enum.reject(data.members, &(&1.name == name)),
        bank: Enum.reject(data.bank, &(&1.name == name))
    }
  end

  defp persist(data) do
    File.mkdir_p!(Path.dirname(file()))

    Pokex.Home.write!(
      file(),
      JSON.encode!(%{
        members: Enum.map(data.members, &encode_entry/1),
        bank: Enum.map(data.bank, &encode_entry/1),
        player_level: data.player_level,
        level_margin: data.level_margin,
        active: data.active
      })
    )

    data
  end

  @doc """
  Where the team lives NOW: the legacy shared `team.json` when no character is
  selected, or the active character's own `chars/<slug>/team.json`.
  """
  def file do
    case Pokex.Characters.active() do
      "" -> Path.join(Home.dir(), "team.json")
      slug -> Path.join([Home.dir(), "chars", slug, "team.json"])
    end
  end
end
