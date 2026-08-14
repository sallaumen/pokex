defmodule Pokex.Home do
  @moduledoc "Filesystem locations under the Pokex home directory (default ~/.pokex)."

  def dir do
    case Application.get_env(:pokex, :home_dir) do
      nil -> Path.expand(default_dir())
      configured -> Path.expand(configured)
    end
  end

  # The suite sets :home_dir to a temp directory and dozens of tests clean up
  # with `Application.delete_env/2` — which does not restore what config/test.exs
  # put there, it ERASES the key. From the first such on_exit onward every read
  # fell through to this default, and the suite was reading Lucas's live
  # ~/.pokex: on 2026-08-14 a strip test failed because it found his real
  # 1512x982 calibration where the test env was supposed to have none. Only the
  # ORDER decided whether a test saw the temp home or his. In :test the fallback
  # is a bug by definition, so it raises there and names the fix.
  defp default_dir do
    if Application.get_env(:pokex, :home_dir_required, false) do
      raise """
      Pokex.Home.dir/0 was asked for the home while :home_dir is unset.

      In the test env that means a test erased it — `Application.delete_env(:pokex, :home_dir)`
      does not restore config/test.exs, it deletes the key, and the next reader
      gets the REAL ~/.pokex. Restore it instead: `Pokex.TestHome.restore()`.
      """
    end

    "~/.pokex"
  end

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

  def exports_dir do
    path = Path.join(dir(), "exports")
    File.mkdir_p!(path)
    path
  end

  def calibration_file, do: Path.join(dir(), "calibration.json")
  def settings_file, do: Path.join(dir(), "settings.json")
end
