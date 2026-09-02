defmodule Pokex.Rig.Mac.CommandsTest do
  use ExUnit.Case, async: true
  alias Pokex.Rig.Mac.Commands

  # O MODIFICADOR VAI SEGURADO, não pendurado na tecla. `using {shift down}`
  # marca a bandeira no PRÓPRIO evento da tecla, e o jogo dele roda sob Wine,
  # que traduz evento por evento: a tecla podia chegar antes de o estado do
  # shift virar, e aí saía a skill sozinha e a postura não mudava ("o pior dos
  # dois mundos", 02/09).
  test "press holds the modifier as its own event, before the key" do
    {"osascript", ["-e", script]} = Commands.press("shift+z")

    assert script =~ "key down shift"
    assert script =~ ~s(keystroke "z")
    assert script =~ "key up shift"
    refute script =~ "using {"

    assert :binary.match(script, "key down shift") < :binary.match(script, ~s(keystroke "z"))
    assert :binary.match(script, ~s(keystroke "z")) < :binary.match(script, "key up shift")
  end

  # Um modificador preso transforma TODA tecla seguinte em outra coisa, então
  # soltar não pode depender da prensa ter dado certo — a mesma regra do
  # `key_up` do rig, que é ungated pelo mesmo motivo.
  test "press releases the modifier even when the key itself fails" do
    {"osascript", ["-e", script]} = Commands.press("shift+z")

    assert :binary.match(script, "end try") < :binary.match(script, "key up shift")
  end

  test "press waits between holding the modifier and the key, and the wait is his" do
    {"osascript", ["-e", padrao]} = Commands.press("shift+z")
    {"osascript", ["-e", devagar]} = Commands.press("shift+z", modifier_settle_ms: 120)

    assert padrao =~ "delay 0.03"
    assert devagar =~ "delay 0.12"
  end

  test "press sends a digit as the TOP-ROW key code (not the numpad, which walks)" do
    assert Commands.press("2") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 19)]}
  end

  test "press keeps digits on the top row even with a modifier" do
    {"osascript", ["-e", script]} = Commands.press("ctrl+1")

    assert script =~ "key down control"
    assert script =~ "key code 18"
    assert script =~ "key up control"
  end

  test "press sends named keys (arrows/space) as key codes, not typed letters" do
    assert Commands.press("up") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 126)]}

    assert Commands.press("down") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 125)]}

    assert Commands.press("left") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 123)]}

    assert Commands.press("right") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 124)]}

    assert Commands.press("space") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 49)]}
  end

  test "keycode maps digits and named keys for the native CGEvent path" do
    assert Commands.keycode("space") == {:ok, 49}
    assert Commands.keycode("2") == {:ok, 19}
    assert Commands.keycode("TAB") == {:ok, 48}
    assert Commands.keycode("z") == :error
  end

  test "hold builds real key down/up events (mini-game Space hold)" do
    # NOT `key down (key code 49)`: nested `key code` executes as a full press
    # first (measured live 2026-07-10); System Events accepts the character form.
    assert Commands.hold("space", :down) ==
             {"osascript", ["-e", ~s(tell application "System Events" to key down " ")]}

    assert Commands.hold("space", :up) ==
             {"osascript", ["-e", ~s(tell application "System Events" to key up " ")]}
  end

  test "hold carries the focus guard inside the same script" do
    {"osascript", ["-e", script]} = Commands.hold("space", :down, focus_app: "wine")
    assert script =~ ~s(set frontmost of application process "wine" to true)
    assert script =~ ~s(key down " ")
  end

  test "hold accepts plain single characters and rejects unmapped named keys" do
    assert Commands.hold("w", :down) ==
             {"osascript", ["-e", ~s(tell application "System Events" to key down "w")]}

    assert_raise ArgumentError, fn -> Commands.hold("f1", :down) end
  end

  test "named keys compose with modifiers like digits do" do
    {"osascript", ["-e", script]} = Commands.press("shift+space")

    assert script =~ "key down shift"
    assert script =~ "key code 49"
    assert script =~ "key up shift"
  end

  # O intervalo entre teclas NUNCA viaja dentro de um script do barramento: o
  # `delay` do osascript roda dentro do `System.cmd` do `OsaBus.handle_call`, e
  # uma rajada de três teclas com o intervalo dele parava a fila global de
  # teclas por mais de um segundo — resgate, poção e setas de fallback atrás
  # dela. A rajada vira PASSOS, e quem paga a pausa é o chamador, entre
  # comandos curtos.
  test "burst devolve uma tecla por comando e a pausa como passo próprio" do
    assert Commands.burst(["1", "2", "shift+space"], tap_count: 1, gap_ms: 25) ==
             [
               {:press, "1"},
               {:pause, 25},
               {:press, "2"},
               {:pause, 25},
               {:press, "shift+space"}
             ]
  end

  test "burst repete cada tecla tap_count vezes, com pausa entre todas" do
    assert Commands.burst(["1", "2"], tap_count: 2, gap_ms: 10) ==
             [
               {:press, "1"},
               {:pause, 10},
               {:press, "1"},
               {:pause, 10},
               {:press, "2"},
               {:pause, 10},
               {:press, "2"}
             ]
  end

  test "burst sorteia o jitter por pausa, dentro da faixa" do
    pauses =
      for {:pause, ms} <- Commands.burst(["1", "2", "3"], tap_count: 1, gap_ms: 35, jitter_ms: 20),
          do: ms

    assert length(pauses) == 2
    assert Enum.all?(pauses, &(&1 >= 35 and &1 <= 55))
  end

  # O único `delay` que pode existir num script é o do guarda de foco (50ms
  # depois de re-frontar o jogo). O da CADÊNCIA não: um comando de rajada
  # carrega no máximo uma tecla, então não há entre-teclas para esperar dentro
  # do barramento.
  test "um comando de rajada carrega no máximo uma tecla" do
    steps = Commands.burst(["shift+1", "4", "5"], tap_count: 2, gap_ms: 300, jitter_ms: 40)

    for {:press, combo} <- steps do
      {"osascript", ["-e", script]} = Commands.press(combo, focus_app: "Jogo")

      key_lines =
        script
        |> String.split("\n")
        |> Enum.count(&(String.contains?(&1, "key code") or String.contains?(&1, "keystroke")))

      assert key_lines == 1, script
    end
  end

  test "tab is a key EVENT (code 48), never the typed letters t-a-b" do
    assert Commands.press("tab") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 48)]}
  end

  test "function keys send the real key code, not the typed letters (case-insensitive)" do
    # `keystroke "f1"` would TYPE f then 1 — F-keys need the key EVENT (F1 = 122).
    assert Commands.press("f1") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 122)]}

    assert Commands.press("F1") ==
             {"osascript", ["-e", ~s(tell application "System Events" to key code 122)]}
  end

  test "focus_app prepends the re-front guard inside the SAME keystroke script" do
    {"osascript", ["-e", script]} = Commands.press("shift+v", focus_app: "wine")

    assert script ==
             Enum.join(
               [
                 ~s(tell application "System Events"),
                 "  try",
                 ~s(    if name of first application process whose frontmost is true is not "wine" then),
                 ~s(      set frontmost of application process "wine" to true),
                 "      delay 0.05",
                 "    end if",
                 "  end try",
                 "  key down shift",
                 "  try",
                 "    delay 0.03",
                 ~s(    keystroke "v"),
                 "  end try",
                 "  key up shift",
                 "end tell"
               ],
               "\n"
             )
  end

  # Com a rajada em passos, cada tecla é um comando — logo cada uma carrega o
  # guarda, e não só a primeira da leva.
  test "focus_app guards every key of a burst, before the key event" do
    for {:press, combo} <- Commands.burst(["1", "2"], tap_count: 1, gap_ms: 0) do
      {"osascript", ["-e", script]} = Commands.press(combo, focus_app: "wine")

      assert script =~ ~s(set frontmost of application process "wine" to true)
      # the guard comes BEFORE the key event
      assert :binary.match(script, "frontmost") < :binary.match(script, "key code")
    end
  end

  test "left and right click" do
    assert Commands.click(:left, {812, 402}) == {"cliclick", ["c:812,402"]}
    assert Commands.click(:right, {10, 20}) == {"cliclick", ["rc:10,20"]}
  end

  test "cursor position command and parsing" do
    assert Commands.cursor_position() == {"cliclick", ["p"]}
    assert Commands.parse_point("428,259\n") == {:ok, {428, 259}}
    assert Commands.parse_point("Point: 428,259") == {:ok, {428, 259}}
    assert Commands.parse_point("garbage") == :error
  end

  test "screen region capture (main display only, for speed)" do
    assert Commands.capture({10, 20, 30, 40}, "/tmp/x.png") ==
             {"screencapture", ["-x", "-m", "-R", "10,20,30,40", "/tmp/x.png"]}

    assert Commands.capture_screen("/tmp/s.png") == {"screencapture", ["-x", "-m", "/tmp/s.png"]}
  end
end
