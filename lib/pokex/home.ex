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
  def area_probe_file, do: Path.join(dir(), "area_probe.json")

  @doc """
  Writes a state file so a reader never catches it half-written.

  `File.write!/2` truncates and then fills: a reader landing inside that window
  gets a partial file. Every store here answers a decode error with "empty", so
  a torn read does not look like a failure — it looks exactly like *there is
  nothing here*. Measured 2026-08-14 with `routes.json` rewritten in a loop:
  6 concurrent reads came back with ZERO routes. The cavebot rewrites that same
  file about 8x/s while recording a fight, and a hunt reading it in that window
  would believe it had no route at all.

  Rename within a filesystem is atomic, so the reader sees either the whole old
  file or the whole new one, never the seam. The temp name carries a unique
  integer because two writers racing on one temp path would corrupt each other.
  """
  @spec write!(Path.t(), iodata) :: :ok
  def write!(path, contents) do
    tmp = "#{path}.#{System.unique_integer([:positive])}.tmp"

    try do
      File.write!(tmp, contents)
      File.rename!(tmp, path)
      :ok
    rescue
      error ->
        File.rm(tmp)
        reraise error, __STACKTRACE__
    end
  end
end
