defmodule Pokex.Home do
  @moduledoc "Filesystem locations under the Pokex home directory (default ~/.pokex)."

  def dir, do: Path.expand(Application.get_env(:pokex, :home_dir, "~/.pokex"))

  def captures_dir do
    path = Path.join(dir(), "captures")
    File.mkdir_p!(path)
    path
  end

  def baselines_dir do
    path = Path.join(dir(), "baselines")
    File.mkdir_p!(path)
    path
  end

  def calibration_file, do: Path.join(dir(), "calibration.json")
  def settings_file, do: Path.join(dir(), "settings.json")
end
