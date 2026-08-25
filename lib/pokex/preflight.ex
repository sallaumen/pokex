defmodule Pokex.Preflight do
  @moduledoc "Sanity checks executed when the user hits Start. Messages in PT-BR."

  alias Pokex.Bots.Capture
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Pokedex.Team
  alias Pokex.Rig.Mac

  def run(rig \\ Pokex.Rig.impl()) do
    errors =
      []
      |> check_cliclick(rig)
      |> check_calibration()
      |> check_active_pokemon()
      |> check_screen(rig)

    case errors do
      [] -> :ok
      list -> {:error, Enum.reverse(list)}
    end
  end

  defp check_cliclick(errors, Mac) do
    if System.find_executable("cliclick"),
      do: errors,
      else: ["cliclick não encontrado — rode: brew install cliclick" | errors]
  end

  defp check_cliclick(errors, _rig), do: errors

  defp check_calibration(errors) do
    if Calibration.exists?(),
      do: errors,
      else: ["calibração não encontrada — rode o wizard em /calibration" | errors]
  end

  # The pokémon on the field owns its bar and its jobs, and nothing else does:
  # the shared bar is gone (see `Pokex.Bots.ActiveBar`). Starting without them
  # is starting blind — the cooldown reader would score against another
  # creature's icons, and the fight would rotate keys nobody classified.
  # "Temos que até bloquear de funcionar se não tiver corretamente configurado
  # para o pokémon ativo" (Lucas, 2026-08-24).
  defp check_active_pokemon(errors) do
    case Team.active() do
      nil ->
        ["nenhum pokémon escolhido — diga quem está em campo no /time" | errors]

      name ->
        errors
        |> check_bar(name)
        |> check_skills(name)
    end
  end

  defp check_bar(errors, name) do
    case Team.active_bar() do
      nil ->
        ["#{name} está sem barra de skills calibrada — calibre a dele em /calibration" | errors]

      _has_one ->
        errors
    end
  end

  # Every slot, not just some: a key without a job is a key the fight cannot
  # choose — nem área, nem controle, nem alvo único.
  #
  # A DÉCIMA TECLA É O ZERO, e este check contava 1..10. Uma barra de dez slots
  # tem as teclas 1–9 e 0, então ele procurava por uma tecla "10" que não existe
  # em barra nenhuma e recusava o arranque PARA SEMPRE — o Dugtrio dele, com os
  # dez slots todos classificados, nunca conseguiu ligar o combate, e a caçada
  # bloqueava sem sair do lugar (26/08). `SkillBar.keys/1` já sabia disso desde
  # sempre; era o único lugar que sabia.
  defp check_skills(errors, name) do
    skills = Team.skills(name)
    slots = bar_slots()
    missing = Enum.reject(SkillBar.keys(slots), &Map.has_key?(skills, &1))

    if slots == 0 or missing == [],
      do: errors,
      else: ["#{name}: falta dizer o que faz #{slot_list(missing)} no /time" | errors]
  end

  defp bar_slots do
    case Team.active_bar() do
      {_name, %{count: count}} when is_integer(count) and count > 0 -> count
      _no_bar -> 0
    end
  end

  defp slot_list([one]), do: "a tecla #{one}"
  defp slot_list(many), do: "as teclas #{Enum.join(many, ", ")}"

  defp check_screen(errors, Mac) do
    case Calibration.load() do
      {:ok, calib} -> screen_error(calib, Capture.display_points()) ++ errors
      _no_calibration -> errors
    end
  end

  defp check_screen(errors, _rig), do: errors

  @doc """
  The screen complaint, if any — pure, so the regression below is pinnable.

  This check compared APPLES WITH ORANGES and refused FOREVER on a Retina
  display: it took a CLI `screencapture` (which answers in PIXELS — 3024×1964)
  and measured it against `screen_w * scale`, where the calibration had been
  saved by ScreenCaptureKit (which answers in POINTS, so scale is 1.0 → 1512).
  3024 never equals 1512, so `start_all` refused every single time and the whole
  fleet sat stopped — "é como se ele não ligasse os supervisors nunca" (Lucas,
  2026-08-07). Same root as the frame-scale bug of #139; the preflight was
  simply never converted, and no test covered it because the only preflight test
  runs the Fake rig, which skips the Mac-only checks.

  `:unknown` is NO PROOF, never "the screen changed": a preflight that cannot
  measure must not block the bot.
  """
  def screen_error(calib, measured) do
    case Calibration.screen_check(calib, measured) do
      {:another_screen, {sw, sh}, {cw, ch}} ->
        [
          "a calibração é de uma tela #{sw}×#{sh} e esta é #{cw}×#{ch} — abra /calibration " <>
            "e use a última calibração desta tela (ou recalibre)"
        ]

      _same_rescalable_or_unknown ->
        []
    end
  end
end
