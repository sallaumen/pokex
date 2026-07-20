defmodule Pokex.Bots.Capture.ScreenCaptureKit do
  @moduledoc """
  Persistent macOS ScreenCaptureKit helper.

  The helper keeps an `SCStream` alive and serves crop requests over a line-based
  JSON protocol. The Elixir capture broker remains the serializer; this module
  only replaces the expensive per-request `screencapture` process with a warm
  stream when macOS permits it.
  """
  require Logger

  defstruct [:port, :executable, :command_timeout_ms, :metadata]

  @default_ready_timeout_ms 20_000
  @default_command_timeout_ms 10_000
  @source_rel "priv/native/screen_capture_kit.swift"

  def start(opts \\ []) do
    with :ok <- enabled?(),
         :ok <- macos?(),
         {:ok, executable} <- ensure_executable(opts),
         {:ok, port} <- open_helper(executable) do
      ready_timeout_ms =
        timeout_ms(opts, :ready_timeout_ms, :sck_ready_timeout_ms, @default_ready_timeout_ms)

      command_timeout_ms =
        timeout_ms(
          opts,
          :command_timeout_ms,
          :sck_command_timeout_ms,
          @default_command_timeout_ms
        )

      case wait_ready(port, ready_timeout_ms) do
        {:ok, metadata} ->
          Logger.info("ScreenCaptureKit capture backend ready: #{inspect(metadata)}")

          {:ok,
           %__MODULE__{
             port: port,
             executable: executable,
             command_timeout_ms: command_timeout_ms,
             metadata: metadata
           }}

        {:error, reason} ->
          close_port(port)
          {:error, reason}
      end
    end
  end

  def capture(%__MODULE__{port: port, command_timeout_ms: timeout_ms}, {x, y, w, h}, path) do
    request =
      JSON.encode!(%{
        op: "capture",
        x: round(x),
        y: round(y),
        w: round(w),
        h: round(h),
        path: path
      })

    with true <- safe_port_command(port, request <> "\n"),
         {:ok, response} <- read_line(port, timeout_ms) do
      case response do
        %{"ok" => true, "path" => path} -> {:ok, path}
        %{"ok" => false, "error" => reason} -> {:error, {:screen_capture_kit, reason}}
        other -> {:error, {:screen_capture_kit, {:bad_response, other}}}
      end
    else
      false -> {:error, {:screen_capture_kit, :port_closed}}
      error -> error
    end
  end

  # Port.command/2 RAISES ArgumentError on a closed/dead port (it does not return false), so a
  # crashed helper would blow up the caller instead of falling back. Catch it into `false` so the
  # `with` above degrades to {:error, :port_closed} and the broker can fall back to screencapture.
  defp safe_port_command(port, data) do
    Port.command(port, data)
  rescue
    ArgumentError -> false
  end

  def stop(%__MODULE__{port: port}) when is_port(port), do: close_port(port)
  def stop(_backend), do: :ok

  @doc """
  The filmed display's full area as a screen-points region, from the helper's
  ready metadata. This names the GAME's display (the helper films the main
  display, `CGMainDisplayID`) — full-screen captures must use it, because the
  CLI's `screencapture -m` can film the wrong monitor on a 2-display setup.
  """
  def display_region(%__MODULE__{
        metadata: %{"display_width" => pw, "display_height" => ph, "scale" => scale}
      })
      when is_number(pw) and is_number(ph) and is_number(scale) and scale > 0,
      do: {:ok, {0, 0, round(pw / scale), round(ph / scale)}}

  def display_region(_backend), do: :unknown

  defp enabled? do
    case Application.get_env(:pokex, :capture_backend, :auto) do
      :auto -> :ok
      :screen_capture_kit -> :ok
      "auto" -> :ok
      "screen_capture_kit" -> :ok
      other -> {:error, {:disabled, other}}
    end
  end

  defp macos? do
    case :os.type() do
      {:unix, :darwin} -> :ok
      other -> {:error, {:unsupported_os, other}}
    end
  end

  defp ensure_executable(opts) do
    case Keyword.get(opts, :executable) ||
           Application.get_env(:pokex, :screen_capture_kit_executable) do
      nil -> compile_if_needed()
      executable -> if File.exists?(executable), do: {:ok, executable}, else: {:error, :enoent}
    end
  end

  defp compile_if_needed do
    source = source_path()
    executable = Path.join([Pokex.Home.dir(), "bin", "screen_capture_kit"])

    cond do
      not File.exists?(source) ->
        {:error, {:missing_source, source}}

      fresh?(source, executable) ->
        {:ok, executable}

      true ->
        compile(source, executable)
    end
  end

  defp source_path do
    case :code.priv_dir(:pokex) do
      path when is_list(path) ->
        Path.join(List.to_string(path), "native/screen_capture_kit.swift")

      {:error, _} ->
        Path.expand(Path.join(["..", "..", "..", "..", @source_rel]), __DIR__)
    end
  end

  # Rebuild ONLY when the source CONTENT changed — never on mtime. macOS TCC identifies this
  # ad-hoc binary by its code hash, so every recompile produces a "new app" and silently voids
  # the Screen Recording permission the user already granted (the System Settings toggle keeps
  # pointing at the old binary → -3801 "user declined" / re-prompt on the next boot). mtime is
  # the wrong freshness signal here: git touches it on every checkout/pull even when the file
  # is byte-identical, which is exactly what kept breaking the permission. The compiled
  # source's SHA-256 is stored next to the executable and compared against the current source.
  @doc false
  def fresh?(source, executable) do
    with true <- File.exists?(executable),
         {:ok, compiled_sha} <- File.read(hash_path(executable)),
         {:ok, current} <- source_sha256(source) do
      String.trim(compiled_sha) == current
    else
      _ -> false
    end
  end

  defp hash_path(executable), do: executable <> ".source_sha256"

  defp source_sha256(source) do
    with {:ok, content} <- File.read(source) do
      {:ok, Base.encode16(:crypto.hash(:sha256, content), case: :lower)}
    end
  end

  defp compile(source, executable) do
    File.mkdir_p!(Path.dirname(executable))

    Logger.warning(
      "recompiling the ScreenCaptureKit helper — macOS will treat it as a NEW app and " <>
        "ask for the Screen Recording permission again (grant it once and it sticks " <>
        "until the helper source actually changes)"
    )

    args = [
      "swiftc",
      "-parse-as-library",
      "-O",
      "-framework",
      "ScreenCaptureKit",
      "-framework",
      "CoreMedia",
      "-framework",
      "CoreVideo",
      "-framework",
      "CoreImage",
      "-framework",
      "ImageIO",
      "-framework",
      "UniformTypeIdentifiers",
      "-framework",
      "AppKit",
      "-o",
      executable,
      source
    ]

    case System.cmd("xcrun", args, stderr_to_stdout: true) do
      {_out, 0} ->
        with {:ok, sha} <- source_sha256(source), do: File.write(hash_path(executable), sha)
        {:ok, executable}

      {out, code} ->
        {:error, {:compile_failed, code, String.trim(out)}}
    end
  rescue
    e in ErlangError -> {:error, {:compile_failed, e.original}}
  end

  defp open_helper(executable) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 65_536}
      ])

    {:ok, port}
  rescue
    e in ErlangError -> {:error, {:open_failed, e.original}}
  end

  defp wait_ready(port, timeout_ms) do
    with {:ok, response} <- read_line(port, timeout_ms) do
      case response do
        %{"ready" => true} -> {:ok, Map.delete(response, "ready")}
        %{"ready" => false, "error" => reason} -> {:error, {:not_ready, reason}}
        other -> {:error, {:bad_ready_response, other}}
      end
    else
      {:error, reason} -> {:error, reason}
    end
  end

  defp read_line(port, timeout_ms) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        case JSON.decode(line) do
          {:ok, map} -> {:ok, map}
          {:error, reason} -> {:error, {:bad_json, line, reason}}
        end

      {^port, {:data, {:noeol, line}}} ->
        {:error, {:partial_line, line}}

      {^port, {:exit_status, status}} ->
        {:error, {:exit_status, status}}
    after
      timeout_ms -> {:error, :timeout}
    end
  end

  defp timeout_ms(opts, opt_key, env_key, default) do
    opts
    |> Keyword.get(opt_key, Application.get_env(:pokex, env_key, default))
    |> pos_int(default)
  end

  defp pos_int(value, _default) when is_integer(value) and value > 0, do: value
  defp pos_int(_value, default), do: default

  # Closing the port closes the helper's stdin, which its lifeline thread turns into exit(0) —
  # but belt-and-suspenders: an OLD compiled helper (pre-lifeline) or a wedged one ignores EOF
  # and lives forever holding an open SCStream (measured: dozens of zombies starving the SCK
  # daemon until every start timed out). So grab the OS pid first and SIGKILL it after closing;
  # the process has no cleanup needs — its death releases the daemon connection.
  defp close_port(port) do
    os_pid =
      case Port.info(port, :os_pid) do
        {:os_pid, pid} -> pid
        _closed -> nil
      end

    try do
      Port.close(port)
    catch
      :error, _reason -> :ok
    end

    if os_pid, do: System.cmd("kill", ["-9", Integer.to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  @doc """
  SIGKILL every helper left over from a previous run. Each orphan holds a live SCStream that
  loads the ScreenCaptureKit daemon; enough of them and every new stream start times out — the
  exact death spiral debugged on 2026-07-10 (~64 zombies). Called once at Capture boot, BEFORE
  starting our own helper. Assumes one pokex instance per machine (a second running instance
  would lose its helper and recover through its normal fallback+retry path).
  """
  def kill_orphans(executable \\ nil) do
    # Only when this process would actually USE the SCK backend — a `mix test` run
    # (capture_backend :screencapture) must never sweep a live dev server's helper.
    with :ok <- enabled?(), :ok <- macos?() do
      do_kill_orphans(executable)
    else
      _disabled_or_not_macos -> :ok
    end
  end

  defp do_kill_orphans(executable) do
    path = executable || Path.join([Pokex.Home.dir(), "bin", "screen_capture_kit"])

    case System.cmd("pkill", ["-9", "-f", path], stderr_to_stdout: true) do
      {_out, 0} ->
        Logger.warning("killed orphaned ScreenCaptureKit helper(s) from a previous run: #{path}")
        :ok

      # 1 = no matching processes — the common, healthy case.
      {_out, _code} ->
        :ok
    end
  rescue
    e in ErlangError -> {:error, {:pkill_failed, e.original}}
  end
end
