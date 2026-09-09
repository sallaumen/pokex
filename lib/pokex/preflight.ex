defmodule Pokex.Preflight do
  @moduledoc "Sanity checks executed when the user hits Start. Messages in PT-BR."

  alias Pokex.Bots.Capture
  alias Pokex.Bots.SkillBar
  alias Pokex.Calibration
  alias Pokex.Characters
  alias Pokex.Pokedex.Team
  alias Pokex.Rig.Mac

  def run(rig \\ Pokex.Rig.impl()) do
    errors =
      []
      |> check_cliclick(rig)
      |> check_calibration()
      |> check_character()
      |> check_active_pokemon()
      |> check_bar_fits()
      |> check_tile()
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

  # NO CHARACTER, NO START. With the pointer empty the team is the legacy shared file — on
  # 2026-09-07 that was ANOTHER character's team (a level-127 Vespiquen), and the bot fought
  # a whole run "as Vespiquen" with a Torterra on the field, bar region and all. The pointer
  # had been cleared at a restart, and nothing said so. A machine with characters on it
  # refuses to hunt for nobody.
  defp check_character(errors) do
    if Characters.active() == "" and Characters.list() != [] do
      [
        "nenhum personagem ativo — o bot usaria o time legado, que pode ser de OUTRO " <>
          "personagem; escolha o seu no seletor do cabeçalho"
        | errors
      ]
    else
      errors
    end
  end

  # THE BAR MUST BE ON THIS SCREEN. The region travels with the pokémon in the team file and
  # carries no screen with it: calibrated on the ultrawide (x=1594), it is outside the
  # notebook's 1512 points, every capture answers "outside frame", and the bot hunts blind
  # of its own cooldowns — 2026-09-07, a whole run "pelo relógio". The message names the
  # pokémon and the screen, because the fix is his: recalibrate that bar here.
  defp check_bar_fits(errors) do
    with {:ok, %Calibration{screen_w: sw, screen_h: sh}} when is_integer(sw) and is_integer(sh) <-
           Calibration.load(),
         {name, %{region: {x, y, w, h}}} <- Team.active_bar(),
         false <- x + w <= sw and y + h <= sh do
      [
        "a barra de skills do #{name} está marcada em x=#{x}, y=#{y}, fora desta tela de " <>
          "#{sw}×#{sh} (foi calibrada noutra tela) — recalibre a barra dele em /calibration"
        | errors
      ]
    else
      _fits_or_nothing_to_measure -> errors
    end
  end

  # A SCREEN WITHOUT A MEASURED TILE HAS NO DISTANCES. The tile is the unit of everything
  # measured from the character; it used to be a number on the cavebot page, and the notebook
  # ran three days on the ultrawide's 151 (every creature "1 tile" away, park clicks off the
  # screen). "Isso deveria ser automático com o tamanho da tela, e numa tela que não tiver
  # sido reconhecida, dar erro" (Lucas, 2026-09-08).
  defp check_tile(errors) do
    with {:ok, calib} <- Calibration.load(),
         {:unknown, {w, h}} <- Calibration.tile(calib) do
      [
        "esta tela (#{w}×#{h}) não tem o tamanho do tile medido — o bot conhece " <>
          "#{Pokex.Screen.Tile.known_text()}; sem o tile nenhuma distância do personagem é " <>
          "de verdade. Meça o tile desta tela e cadastre em Pokex.Screen.Tile"
        | errors
      ]
    else
      _known_or_uncalibrated -> errors
    end
  end

  # The pokémon on the field owns its bar and its jobs, and nothing else does: the shared bar
  # is gone (see `Pokex.Bots.ActiveBar`). Starting without them is starting blind: the
  # cooldown reader would score against another creature's icons, and the fight would rotate
  # keys nobody classified. His rule: refuse to run when the active pokémon is not configured.
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
    case {Team.active_bar(), Team.bar_screens(name)} do
      {nil, []} ->
        ["#{name} está sem barra de skills calibrada — calibre a dele em /calibration" | errors]

      # THE BAR OF ANOTHER SCREEN (09/09): the notebook's Torterra bar (x=580)
      # does not exist on the ultrawide (x=2147), and the run hunted five
      # minutes blind of its cooldowns with alarms saying "recalibre" and
      # nothing saying why. Now it does not start, and says which screen has it.
      {nil, screens} ->
        [
          "#{name} tem barra de skills calibrada só #{screens_text(screens)} — nesta tela " <>
            "(#{this_screen()}) não; calibre a dele em /calibration antes de ligar"
          | errors
        ]

      _has_one_here ->
        errors
    end
  end

  defp screens_text(screens) do
    screens
    |> Enum.map(fn
      {w, h} -> "na tela #{w}×#{h}"
      nil -> "noutra tela"
    end)
    |> Enum.uniq()
    |> Enum.join(" e ")
  end

  defp this_screen do
    case Calibration.load() do
      {:ok, %Calibration{screen_w: w, screen_h: h}} -> "#{w}×#{h}"
      _no_calibration -> "?"
    end
  end

  # Every slot, not just some: a key without a job is a key the fight cannot choose, neither
  # area, nor control, nor single target.
  #
  # The tenth key is the ZERO, and this check used to count 1..10. A ten-slot bar has keys 1-9
  # and 0, so it looked for a key "10" that exists on no bar and refused the start FOREVER: a
  # pokémon with all ten slots classified never got combat on. `SkillBar.keys/1` always knew;
  # it was the only place that did.
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
