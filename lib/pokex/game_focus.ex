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
    front_app(Settings.get(:game_app_name))
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

  @doc "Brings `app_name` forward. Never raises: a missing app is not a crash."
  @spec front_app(String.t() | nil) :: :ok
  def front_app(nil), do: :ok

  def front_app(app_name) do
    System.cmd(
      "osascript",
      [
        "-e",
        ~s(tell application "System Events" to set frontmost of application process "#{app_name}" to true)
      ],
      stderr_to_stdout: true
    )

    :ok
  rescue
    _no_osascript -> :ok
  end
end
