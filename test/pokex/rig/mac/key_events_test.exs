defmodule Pokex.Rig.Mac.KeyEventsTest do
  use ExUnit.Case, async: false

  alias Pokex.Rig.Mac.KeyEvents

  @tag :tmp_dir
  test "posts keys through a ready, trusted helper", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: true)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :ready)

    assert :ok = KeyEvents.key(:down, 49, "wine", pid)
    assert :ok = KeyEvents.key(:up, 49, nil, pid)
    assert :ok = KeyEvents.middle_click({1200, 640}, "wine", pid)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "middle_click degrades to an error when the helper isn't ready", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: false)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :untrusted)

    assert {:error, :untrusted} = KeyEvents.middle_click({10, 20}, nil, pid)
  end

  @tag :tmp_dir
  @tag :capture_log
  test "an untrusted helper degrades to an error so the Rig falls back", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: false)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :untrusted)

    assert {:error, :untrusted} = KeyEvents.key(:down, 49, nil, pid)
  end

  # A postura como UMA sequência nativa: o pedido leva os modificadores e o
  # respiro, e o helper faz shift-baixo → tecla → shift-cima sem ninguém no meio.
  @tag :tmp_dir
  test "a tecla com modificador vai num pedido só, com os modificadores e o respiro", %{
    tmp_dir: tmp
  } do
    log = Path.join(tmp, "requests.log")
    stub = write_stub!(tmp, trusted: true, log: log)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :ready)

    assert :ok = KeyEvents.press(20, ["shift"], "wine", 30, pid)

    assert {:ok, [request]} = wait_lines(log, 1)

    assert JSON.decode!(request) == %{
             "op" => "key",
             "action" => "press",
             "code" => 20,
             "modifiers" => ["shift"],
             "settle_ms" => 30,
             "app" => "wine"
           }
  end

  @tag :tmp_dir
  @tag :capture_log
  test "sem helper pronto, a tecla com modificador degrada pro osascript", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: false)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :untrusted)

    assert {:error, :untrusted} = KeyEvents.press(20, ["shift"], nil, 30, pid)
  end

  test "disabled (no executable, env off) never blocks callers" do
    pid = start_supervised!({KeyEvents, name: nil})

    assert KeyEvents.status(pid) == :disabled
    assert {:error, :disabled} = KeyEvents.key(:down, 49, nil, pid)
  end

  defp wait_status(pid, expected, tries \\ 100) do
    cond do
      KeyEvents.status(pid) == expected ->
        :ok

      tries == 0 ->
        flunk("helper never reached #{inspect(expected)}: #{inspect(KeyEvents.status(pid))}")

      true ->
        Process.sleep(10)
        wait_status(pid, expected, tries - 1)
    end
  end

  # A stand-in for the Swift helper speaking the same line protocol.
  defp wait_lines(log, n, tries \\ 100) do
    lines =
      if File.exists?(log), do: log |> File.read!() |> String.split("\n", trim: true), else: []

    cond do
      length(lines) >= n ->
        {:ok, lines}

      tries == 0 ->
        {:error, lines}

      true ->
        Process.sleep(10)
        wait_lines(log, n, tries - 1)
    end
  end

  # `log:` grava cada pedido recebido, um por linha — o teste lê o que o helper leu.
  defp write_stub!(dir, opts) do
    trusted? = Keyword.fetch!(opts, :trusted)
    log = Keyword.get(opts, :log)
    path = Path.join(dir, "key_events_stub.sh")
    record = if log, do: ~s(  echo "$_line" >> "#{log}"), else: ""

    File.write!(path, """
    #!/bin/bash
    echo '{"ready":true,"trusted":#{trusted?}}'
    while read -r _line; do
    #{record}
      echo '{"ok":true}'
    done
    """)

    File.chmod!(path, 0o755)
    path
  end
end
