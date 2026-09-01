defmodule Pokex.Settings.Legacy do
  @moduledoc """
  Translates settings written by older installs into today's canonical values.

  Config values used to be Portuguese ("parado", "alarme", "deslogar") because
  they doubled as what the screen showed. They are code now — English, with the
  Portuguese kept as a label at the UI edge — so an existing `settings.json`
  would otherwise hold values this build no longer understands: the muted alarm
  sectors would come back ringing, the player mode would fall back to the
  default. Every read path runs values through here, and `Settings` rewrites the
  file on boot, so the translation happens once and then never again.

  An unknown value is returned untouched: a hand-edited file must degrade to
  "this setting looks odd", never to "your setting is gone".
  """

  @translations %{
    player_mode: %{"parado" => "still", "movimento" => "moving", "caçada" => "hunt"},
    stop_after_action: %{"parar" => "stop", "deslogar" => "logout"},
    stagnation_action: %{"alarme" => "alarm", "parar" => "stop", "deslogar" => "logout"},
    mini_game_mode: %{"automatico" => "auto", "diagnostico" => "diagnostic"},
    alarm_muted_categories: %{
      "vida" => "hp",
      "erro" => "error",
      "fuga" => "escape",
      "sessao" => "session",
      "comando" => "command",
      "captura" => "capture",
      "pesca" => "fishing",
      "estoque" => "stock"
    }
  }

  @doc "Today's value for what `key` holds — `value` itself when nothing changed."
  def value(key, value) do
    case Map.fetch(@translations, key) do
      {:ok, table} -> translate(table, value)
      :error -> value
    end
  end

  @doc "Runs `value/2` over a whole settings map."
  def map(settings) when is_map(settings) do
    Map.new(settings, fn {key, value} -> {key, value(key, value)} end)
  end

  @doc "The keys that have a legacy spelling at all — the panel uses it to explain itself."
  def translated_keys, do: Map.keys(@translations)

  defp translate(table, values) when is_list(values), do: Enum.map(values, &translate(table, &1))
  defp translate(table, value) when is_binary(value), do: Map.get(table, value, value)
  defp translate(_table, value), do: value
end
