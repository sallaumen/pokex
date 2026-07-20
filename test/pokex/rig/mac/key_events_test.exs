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
  test "middle_click degrades to an error when the helper isn't ready", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: false)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :untrusted)

    assert {:error, :untrusted} = KeyEvents.middle_click({10, 20}, nil, pid)
  end

  @tag :tmp_dir
  test "an untrusted helper degrades to an error so the Rig falls back", %{tmp_dir: tmp} do
    stub = write_stub!(tmp, trusted: false)
    pid = start_supervised!({KeyEvents, name: nil, executable: stub})

    wait_status(pid, :untrusted)

    assert {:error, :untrusted} = KeyEvents.key(:down, 49, nil, pid)
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
  defp write_stub!(dir, trusted: trusted?) do
    path = Path.join(dir, "key_events_stub.sh")

    File.write!(path, """
    #!/bin/bash
    echo '{"ready":true,"trusted":#{trusted?}}'
    while read -r _line; do
      echo '{"ok":true}'
    done
    """)

    File.chmod!(path, 0o755)
    path
  end
end
