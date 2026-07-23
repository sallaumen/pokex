defmodule Pokex.Combos.Store do
  @moduledoc """
  Where the combos live: `~/.pokex/combos.json`, seeded on first read with the
  one Lucas described.

  A combo list is not a settings scalar — it is a small user-authored program —
  so it gets its own file, like the team and the shiny log. Seeding rather than
  shipping an empty list means the feature has something to demonstrate itself
  with the first time he switches it on.
  """

  alias Pokex.Combos.Combo
  alias Pokex.Home

  @filename "combos.json"

  @doc """
  The seeded combo: Jigglypuff sings the enemy to sleep, then the counter comes
  in while it cannot answer.

  The trigger is deliberately broad (any Water enemy — his fishing spots are
  full of them) because a combo nobody ever sees fire teaches him nothing. He
  narrows it once he has watched it work.
  """
  def seed do
    [
      %Combo{
        name: "sing",
        trigger: {:enemy_element, "Water"},
        steps: [
          {:swap_member, "Jigglypuff"},
          {:wait, :combo_swap_wait_ms},
          {:skill, "4"},
          {:wait, :combo_sing_wait_ms},
          {:swap_counter}
        ],
        enabled?: true
      }
    ]
  end

  @doc "Every combo, seeded on first read."
  def all do
    case File.read(path()) do
      {:ok, body} -> body |> JSON.decode!() |> decode()
      _no_file -> seed()
    end
  rescue
    # a corrupt file must not take the combat path down with it
    _error -> seed()
  end

  @doc "Replaces the whole list."
  def put(combos) when is_list(combos) do
    File.mkdir_p!(Home.dir())
    File.write!(path(), JSON.encode!(%{combos: Enum.map(combos, &encode/1)}))
    :ok
  end

  @doc """
  Adds a combo, replacing any existing one of the same name.

  The name is the identity `set_enabled/2` and `delete/1` work by, so two combos
  sharing one would make both unreachable. Replacing is the honest reading of
  "salvar" onto a name already in the list.
  """
  def add(%Combo{name: name} = combo) when is_binary(name) and name != "" do
    all()
    |> Enum.reject(&(&1.name == name))
    |> Kernel.++([combo])
    |> put()
  end

  def add(_nameless), do: {:error, :invalid_name}

  @doc "Removes one combo by name."
  def delete(name) do
    all()
    |> Enum.reject(&(&1.name == name))
    |> put()
  end

  @doc "Flips one combo on or off by name."
  def set_enabled(name, enabled?) when is_boolean(enabled?) do
    all()
    |> Enum.map(fn
      %Combo{name: ^name} = combo -> %Combo{combo | enabled?: enabled?}
      combo -> combo
    end)
    |> put()
  end

  defp path, do: Path.join(Home.dir(), @filename)

  defp decode(%{"combos" => list}) when is_list(list), do: Enum.map(list, &decode_combo/1)
  defp decode(_corrupt), do: seed()

  defp decode_combo(map) do
    %Combo{
      name: map["name"],
      trigger: decode_trigger(map["trigger"]),
      steps: Enum.map(map["steps"] || [], &decode_step/1),
      enabled?: map["enabled"] != false,
      # absent or null (every file written before the field existed) = global
      dungeon: map["dungeon"]
    }
  end

  defp decode_trigger(%{"kind" => "species", "value" => value}), do: {:enemy_species, value}
  defp decode_trigger(%{"kind" => "element", "value" => value}), do: {:enemy_element, value}
  defp decode_trigger(_unknown), do: nil

  defp decode_step(%{"do" => "swap_member", "value" => name}), do: {:swap_member, name}
  defp decode_step(%{"do" => "swap_counter"}), do: {:swap_counter}
  defp decode_step(%{"do" => "skill", "value" => key}), do: {:skill, key}
  defp decode_step(%{"do" => "wait", "value" => value}) when is_integer(value), do: {:wait, value}

  defp decode_step(%{"do" => "wait", "value" => setting}) when is_binary(setting),
    do: {:wait, String.to_existing_atom(setting)}

  defp decode_step(unknown), do: {:unknown, unknown}

  defp encode(%Combo{} = combo) do
    %{
      "name" => combo.name,
      "trigger" => encode_trigger(combo.trigger),
      "steps" => Enum.map(combo.steps, &encode_step/1),
      "enabled" => combo.enabled?,
      "dungeon" => combo.dungeon
    }
  end

  defp encode_trigger({:enemy_species, value}), do: %{"kind" => "species", "value" => value}
  defp encode_trigger({:enemy_element, value}), do: %{"kind" => "element", "value" => value}
  defp encode_trigger(_none), do: nil

  defp encode_step({:swap_member, name}), do: %{"do" => "swap_member", "value" => name}
  defp encode_step({:swap_counter}), do: %{"do" => "swap_counter"}
  defp encode_step({:skill, key}), do: %{"do" => "skill", "value" => key}

  defp encode_step({:wait, setting}) when is_atom(setting),
    do: %{"do" => "wait", "value" => Atom.to_string(setting)}

  defp encode_step({:wait, ms}), do: %{"do" => "wait", "value" => ms}
end
