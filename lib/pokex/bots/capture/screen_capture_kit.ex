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
  ready metadata — LOCAL to that display, so its top-left is `{0, 0}`.

  Local because every region in this house is: the helper crops inside the
  filmed display's own frame, and the one translation to desktop coordinates
  happens at the edge, in `Pokex.Rig.Mac`. A global rectangle handed to the crop
  would fall outside the frame; handed to the CLI it would cross the border
  twice. `display_origin/1` is where the display actually sits.
  """
  def display_region(%__MODULE__{
        metadata: %{"display_width" => pw, "display_height" => ph, "scale" => scale}
      })
      when is_number(pw) and is_number(ph) and is_number(scale) and scale > 0,
      do: {:ok, {0, 0, round(pw / scale), round(ph / scale)}}

  def display_region(_backend), do: :unknown

  @doc """
  The filmed display's top-left in GLOBAL screen points — `{:ok, {x, y}}`, or
  `:unknown` when the helper did not say (an older binary, or no helper at all).

  This is the vector between what the eye reads and what the mouse moves; see
  `Pokex.Screen.Display`.
  """
  def display_origin(%__MODULE__{metadata: %{"display_x" => x, "display_y" => y}})
      when is_number(x) and is_number(y),
      do: {:ok, {round(x), round(y)}}

  def display_origin(%__MODULE__{}), do: :unknown
  def display_origin(_backend), do: :unknown

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

  # The helper films the display holding a window of THIS app. Passed as an
  # argument rather than read on the other side because the name is a setting of
  # his, and a helper that reads no configuration stays a pure camera.
  defp open_helper(executable) do
    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        {:line, 65_536},
        {:args, [setting(:game_window_owner), setting(:game_display)]}
      ])

    {:ok, port}
  rescue
    e in ErlangError -> {:error, {:open_failed, e.original}}
  end

  # Settings may be down (a bare unit test, a boot race): no answer means the
  # main display, which is what the house did before there was an answer at all.
  defp setting(key) do
    case Pokex.Settings.get(key) do
      value when is_binary(value) -> value
      _absent -> ""
    end
  catch
    :exit, _no_settings -> ""
  end

  @doc """
  Every display macOS can film, from the helper's ready metadata:
  `[%{id:, w:, h:, x:, y:, scale:, main?:}]` in SCREEN POINTS, or `[]` when the
  helper did not say (an older binary, or no helper at all).
  """
  def displays(%__MODULE__{metadata: %{"displays" => roll}}) when is_list(roll) do
    Enum.flat_map(roll, fn
      %{"id" => id, "w" => w, "h" => h, "x" => x, "y" => y} = display ->
        [
          %{
            id: id,
            w: round(w),
            h: round(h),
            x: round(x),
            y: round(y),
            scale: Map.get(display, "scale", 1.0),
            main?: Map.get(display, "main", false) == true
          }
        ]

      _malformed ->
        []
    end)
  end

  def displays(_backend), do: []

  @doc """
  How the filmed display was chosen: `:pinned` (he said so), `:window` (the
  game's window was there) or `:main` (nothing else answered).
  """
  def display_found_by(%__MODULE__{metadata: %{"display_found_by" => "pinned"}}), do: :pinned
  def display_found_by(%__MODULE__{metadata: %{"display_found_by" => "window"}}), do: :window
  def display_found_by(_backend), do: :main

  defp wait_ready(port, timeout_ms) do
    case read_line(port, timeout_ms) do
      {:ok, %{"ready" => true} = response} -> {:ok, Map.delete(response, "ready")}
      {:ok, %{"ready" => false, "error" => reason}} -> {:error, {:not_ready, reason}}
      {:ok, other} -> {:error, {:bad_ready_response, other}}
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
