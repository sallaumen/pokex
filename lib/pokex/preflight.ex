defmodule Pokex.Preflight do
  @moduledoc "Sanity checks executed when the user hits Start. Messages in PT-BR."

  alias Pokex.Calibration
  alias Pokex.Rig.Mac
  alias Pokex.Vision.Frame

  def run(rig \\ Pokex.Rig.impl()) do
    errors =
      []
      |> check_cliclick(rig)
      |> check_calibration()
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

  defp check_screen(errors, Mac) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, path} <- Mac.capture_screen(),
         {:ok, {w, h}} <- Frame.png_dimensions(path) do
      if w == round(calib.screen_w * calib.scale) and h == round(calib.screen_h * calib.scale) do
        errors
      else
        ["tamanho da tela mudou desde a calibração — recalibre em /calibration" | errors]
      end
    else
      _ ->
        [
          "não consegui capturar a tela — confira a permissão de Gravação de Tela do terminal"
          | errors
        ]
    end
  end

  defp check_screen(errors, _rig), do: errors
end
