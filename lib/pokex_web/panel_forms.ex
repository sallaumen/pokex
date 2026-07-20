defmodule PokexWeb.PanelForms do
  @moduledoc """
  Pure parsers for the panel's setting forms.

  The LiveView translates protocol (form params) into domain calls; the
  PARSING of Lucas's raw input — trimmed integers, allowed ranges, the
  seconds-vs-milliseconds convention, hotbar key lists — is pure logic that
  was buried inside a 1.5k-line LiveView. Here it is unit-testable and the
  LiveView keeps only the Settings.put/assign plumbing.
  """

  @doc "Strict bounded integer: the WHOLE trimmed string, inside `range`."
  @spec parse_int(String.t() | nil, Range.t()) :: {:ok, integer} | :error
  def parse_int(raw, range) do
    case Integer.parse(String.trim(raw || "")) do
      {value, ""} -> if value in range, do: {:ok, value}, else: :error
      _not_an_int -> :error
    end
  end

  @doc "Lenient non-negative integer: accepts trailing garbage (`\"25ms\"` -> 25)."
  @spec parse_non_neg(String.t() | nil) :: {:ok, non_neg_integer} | :error
  def parse_non_neg(nil), do: :error

  def parse_non_neg(raw) do
    case Integer.parse(String.trim(raw)) do
      {n, _rest} when n >= 0 -> {:ok, n}
      _negative_or_garbage -> :error
    end
  end

  @doc """
  A timing knob value. Keys in `positive_keys` are quantities where 0 makes no
  sense (e.g. taps per skill) — a submitted 0 clamps to 1 instead of
  persisting an inert combat setting.
  """
  @spec parse_timing(atom, String.t() | nil, [atom]) :: {:ok, non_neg_integer} | :error
  def parse_timing(key, raw, positive_keys) do
    case parse_non_neg(raw) do
      {:ok, 0} -> if key in positive_keys, do: {:ok, 1}, else: {:ok, 0}
      other -> other
    end
  end

  @doc """
  Hotbar key list from free text: split on spaces/commas, `10` means the `0`
  key, keep single digits only, dedupe preserving order.
  """
  @spec parse_skill_keys(String.t()) :: [String.t()]
  def parse_skill_keys(raw) do
    raw
    |> String.split(~r/[\s,]+/, trim: true)
    |> Enum.map(&if(&1 == "10", do: "0", else: &1))
    |> Enum.filter(&Regex.match?(~r/^[0-9]$/, &1))
    |> Enum.uniq()
  end
end
