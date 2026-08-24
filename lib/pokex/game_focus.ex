defmodule Pokex.GameFocus do
  @moduledoc """
  Runs something with the GAME in front, and gives it back afterwards.

  Every human-initiated action that touches the game from the browser needs
  this: the page has focus while the button is clicked, so a screenshot would
  photograph the browser and a key would type into it. It lived inside the
  calibration LiveView until the hunt's rehearsal needed exactly the same
  recipe — two copies of "bring the game forward" would drift, and the one
  that drifted would be the one nobody was looking at.

  Fronting is not the whole story: macOS hands the KEYBOARD on a click, not on
  `set frontmost` (measured 2026-08-10 — arrows landed in the browser). Callers
  that press keys click a safe point inside the game first; see
  `Pokex.Bots.Body`'s `{:focus_click, point}`.
  """

  alias Pokex.Settings

  @doc """
  Fronts the game, runs `fun`, and restores whatever was in front before.

  Disabled by `ensure_game_focus: false` (or the `:calibration_front_game`
  app env, which tests set) — then `fun` simply runs where it stands.
  """
  @spec with_game_front((-> result)) :: result when result: term
  def with_game_front(fun) do
    if Application.get_env(:pokex, :calibration_front_game, true) and
         Settings.get(:ensure_game_focus) do
      fronted(fun)
    else
      fun.()
    end
  end

  defp fronted(fun) do
    previous = frontmost_app()
    front_game()
    Process.sleep(Settings.get(:calibration_front_delay_ms))

    try do
      fun.()
    after
      if previous, do: front_app(previous)
    end
  end

  @doc "The app that is frontmost right now, or nil when it cannot be read."
  @spec frontmost_app() :: String.t() | nil
  def frontmost_app do
    case System.cmd(
           "osascript",
           [
             "-e",
             ~s(tell application "System Events" to name of first application process whose frontmost is true)
           ],
           stderr_to_stdout: true
         ) do
      {out, 0} -> String.trim(out)
      _unreadable -> nil
    end
  rescue
    _no_osascript -> nil
  end

  @doc """
  Brings the GAME forward by whichever handle actually moves it.

  Fronting by PROCESS is how this always worked, and `game_app_name` must stay
  the process name: that is what `frontmost` reports and what `Pokex.Bots.Focus`
  compares against. But the client Lucas moved to on 2026-08-21 runs inside an
  app bundle whose window System Events cannot see — two processes answer to
  "wine", both report zero windows, `set frontmost` returns success and nothing
  moves (measured 2026-08-24, a whole calibration session fronted by hand). The
  BUNDLE around that process activates by name, and the process's own executable
  path carries the name, so nothing has to be configured.

  The bundle is only tried when fronting the process did not take: on the old
  client `activate` is refused by its bundle and the process handle is the one
  that works, so neither client depends on the other's.
  """
  @spec front_game() :: :ok
  def front_game do
    app = Settings.get(:game_app_name)
    front_app(app)

    if same_app?(frontmost_app(), app), do: :ok, else: activate_bundle(app)
  end

  @doc "Brings `app_name` forward by PROCESS. Never raises: a missing app is not a crash."
  @spec front_app(String.t() | nil) :: :ok
  def front_app(nil), do: :ok

  def front_app(app_name) do
    osascript(
      ~s(tell application "System Events" to set frontmost of application process "#{app_name}" to true)
    )
  end

  defp same_app?(frontmost, app) when is_binary(frontmost) and is_binary(app),
    do: String.downcase(frontmost) == String.downcase(app)

  defp same_app?(_frontmost, _app), do: false

  defp activate_bundle(app) do
    case bundle_name(app) do
      nil -> :ok
      name -> osascript(~s(tell application "#{name}" to activate))
    end
  end

  # Derived once per process name and remembered: the derivation costs its own
  # round trip, and the emergency escape must not pay it on every flee.
  defp bundle_name(app) do
    key = {__MODULE__, :bundle, app}

    case :persistent_term.get(key, :undiscovered) do
      :undiscovered ->
        name = app |> executable_path() |> bundle_from_path()
        :persistent_term.put(key, name)
        name

      name ->
        name
    end
  end

  defp executable_path(app) do
    script =
      ~s(tell application "System Events" to get POSIX path of application file of ) <>
        ~s(first process whose name is "#{app}")

    case System.cmd("osascript", ["-e", script], stderr_to_stdout: true) do
      {out, 0} -> String.trim(out)
      _unreadable -> nil
    end
  rescue
    _no_osascript -> nil
  end

  @doc false
  # The OUTERMOST ".app" the executable sits inside — the name macOS activates
  # by. A helper nested deeper carries its own bundle, and activating that one
  # would front the helper instead of the game.
  def bundle_from_path(nil), do: nil

  def bundle_from_path(path) do
    path
    |> Path.split()
    |> Enum.find(&String.ends_with?(&1, ".app"))
    |> case do
      nil -> nil
      component -> Path.basename(component, ".app")
    end
  end

  defp osascript(script) do
    System.cmd("osascript", ["-e", script], stderr_to_stdout: true)
    :ok
  rescue
    _no_osascript -> :ok
  end
end
