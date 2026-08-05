defmodule Pokex.Combos.Edit do
  @moduledoc """
  Rewriting a combo's step list: move, delete, retype.

  Pure on purpose. Dragging is a browser gesture, but WHERE a step lands is
  arithmetic, and the arithmetic is what decides whether the rescue presses its
  skill before or after the wait. Keeping it here means the drag hook only has
  to report two indices, and the part that can be wrong is covered by tests.

  Every function takes bad input rather than raising: he edits these while a
  hunt is running, and a half-typed field must not be able to corrupt a combo.
  """

  @doc "The step at `from` lands at `to`, pushing the rest aside. Indices are clamped."
  def move(steps, from, to) when is_list(steps) and is_integer(from) and is_integer(to) do
    case Enum.at(steps, from) do
      nil ->
        steps

      step ->
        rest = List.delete_at(steps, from)
        List.insert_at(rest, clamp(to, length(rest)), step)
    end
  end

  defp clamp(to, max), do: to |> max(0) |> min(max)

  @doc "Drops the step at `index`; an index that is not there is a no-op."
  def delete(steps, index) when is_list(steps) and is_integer(index) do
    if index >= 0 and index < length(steps), do: List.delete_at(steps, index), else: steps
  end

  @doc """
  Retypes the step at `index` from what he typed. Anything the step cannot
  hold — a blank field, letters in a duration, a negative wait — leaves the
  step exactly as it was.
  """
  def put_value(steps, index, raw) when is_list(steps) and is_integer(index) do
    case Enum.at(steps, index) do
      nil -> steps
      step -> List.replace_at(steps, index, retyped(step, raw))
    end
  end

  defp retyped({:wait, ms}, raw) when is_integer(ms) do
    case Integer.parse(String.trim(to_string(raw))) do
      {new_ms, ""} when new_ms >= 0 -> {:wait, new_ms}
      _not_a_duration -> {:wait, ms}
    end
  end

  defp retyped({:skill, key}, raw), do: {:skill, non_empty(raw) || key}
  defp retyped({:swap_member, name}, raw), do: {:swap_member, non_empty(raw) || name}
  defp retyped(step, _raw), do: step

  defp non_empty(raw) do
    case String.trim(to_string(raw)) do
      "" -> nil
      text -> text
    end
  end

  @doc """
  What the form shows for a step, or nil when there is nothing to type.

  A SYMBOLIC wait (`{:wait, :rescue_step_ms}`, resolved from settings at rescue
  time) is deliberately not editable here: rendering the atom as text and saving
  it back would turn the setting into the literal string "rescue_step_ms".
  """
  def editable_value({:wait, ms}) when is_integer(ms), do: Integer.to_string(ms)
  def editable_value({:skill, key}), do: to_string(key)
  def editable_value({:swap_member, name}), do: to_string(name)
  def editable_value(_nothing_to_type), do: nil
end
