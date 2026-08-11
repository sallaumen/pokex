defmodule Pokex.Rig.Mac.KeyEvents do
  @moduledoc """
  Persistent native key-event helper (CGEvents): ~1-2ms per hold/release
  versus ~60-100ms per osascript spawn — the mini-game actuation hot path.

  Mirrors the ScreenCaptureKit helper's lifecycle: the Swift source at
  `priv/native/key_events.swift` is compiled to `~/.pokex/bin/key_events`
  ONLY when its content SHA changes (macOS TCC keys the Accessibility grant
  to the binary's code hash — a gratuitous rebuild silently voids it), talks
  line-based JSON over stdio, and dies on stdin EOF so it can never orphan.

  Degrades, never blocks: while the helper is missing, still compiling,
  untrusted (Accessibility not granted) or crashed, `key/3` returns an error
  and `Pokex.Rig.Mac` falls back to the osascript path transparently.
  """
  use GenServer
  require Logger

  @source_rel "priv/native/key_events.swift"
  @ready_timeout_ms 8_000
  @command_timeout_ms 1_000
  @restart_backoff_ms 30_000

  def start_link(opts \\ []) do
    case Keyword.get(opts, :name, __MODULE__) do
      nil -> GenServer.start_link(__MODULE__, opts)
      name -> GenServer.start_link(__MODULE__, opts, name: name)
    end
  end

  @type status ::
          :ready | :starting | :untrusted | :disabled | :unavailable | {:error, term}

  @doc "Post a key event through the helper. `{:error, _}` means: use the fallback."
  @spec key(:down | :up | :press, non_neg_integer, String.t() | nil, GenServer.server()) ::
          :ok | {:error, term}
  def key(action, code, app \\ nil, server \\ __MODULE__)
      when action in [:down, :up, :press] and is_integer(code) do
    GenServer.call(server, {:key, action, code, app}, @command_timeout_ms + 500)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @spec status(GenServer.server()) :: status
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status, 500)
  catch
    :exit, _reason -> :unavailable
  end

  @doc """
  Middle click at a screen point (the game's "step here" command for the active
  Pokémon). There is NO fallback path: cliclick and osascript can't post a
  middle button, so `{:error, _}` here means the click did not happen.
  """
  @spec middle_click({number, number}, String.t() | nil, GenServer.server()) ::
          :ok | {:error, term}
  def middle_click({x, y}, app \\ nil, server \\ __MODULE__) do
    GenServer.call(server, {:middle_click, x, y, app}, @command_timeout_ms + 500)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @doc """
  How many middle clicks the SESSION has seen, and where the cursor is now:
  `{:ok, %{count: n, point: {x, y}}}`.

  A counter, not an event tap — no extra permission, nothing intercepted, and
  a fast click cannot be missed the way polling the button STATE would miss
  it. The recorder watches the count for a jump; the point is the marker he
  makes with his own hand ("eu geralmente clico com o botão do meio do mouse
  em um ponto da minha tela", 2026-08-11).
  """
  @spec middle_watch(GenServer.server()) ::
          {:ok, %{count: integer, point: {integer, integer}}} | {:error, term}
  def middle_watch(server \\ __MODULE__) do
    GenServer.call(server, :middle_watch, @command_timeout_ms + 500)
  catch
    :exit, _reason -> {:error, :unavailable}
  end

  @impl true
  def init(opts) do
    # An explicit :executable (tests, power users) always runs; otherwise the
    # app env gate + macOS check decide (test env disables to never compile).
    if Keyword.has_key?(opts, :executable) or (enabled?() and macos?()) do
      {:ok, %{port: nil, status: :starting, opts: opts}, {:continue, :start_helper}}
    else
      {:ok, %{port: nil, status: :disabled, opts: opts}}
    end
  end

  @impl true
  def handle_continue(:start_helper, state) do
    case start_helper(state.opts) do
      {:ok, port, trusted?} ->
        if trusted? do
          Logger.info("native key-event helper ready (CGEvents)")
          {:noreply, %{state | port: port, status: :ready}}
        else
          Logger.warning(
            "key-event helper compiled but NOT trusted — grant Accessibility to " <>
              "~/.pokex/bin/key_events in System Settings > Privacy & Security > " <>
              "Accessibility (a prompt was shown); keys fall back to osascript until then"
          )

          # Retry SLOWLY: every helper launch while untrusted can re-show the
          # Accessibility prompt — once every 5min is a reminder, not spam.
          close_helper_port(port)
          schedule_restart(:timer.minutes(5))
          {:noreply, %{state | port: nil, status: :untrusted}}
        end

      {:error, reason} ->
        Logger.warning("key-event helper unavailable (#{inspect(reason)}); using osascript")
        schedule_restart(@restart_backoff_ms)
        {:noreply, %{state | port: nil, status: {:error, reason}}}
    end
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call({:key, _action, _code, _app}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, status}, state}
  end

  def handle_call({:key, action, code, app}, _from, state) do
    request =
      %{op: "key", action: to_string(action), code: code}
      |> maybe_put_app(app)
      |> JSON.encode!()

    send_command(request, state)
  end

  def handle_call({:middle_click, _x, _y, _app}, _from, %{status: status} = state)
      when status != :ready do
    {:reply, {:error, status}, state}
  end

  def handle_call(:middle_watch, _from, %{status: status} = state) when status != :ready,
    do: {:reply, {:error, status}, state}

  def handle_call(:middle_watch, _from, state) do
    with true <- safe_port_command(state.port, JSON.encode!(%{op: "middle_watch"}) <> "\n"),
         {:ok, %{"ok" => true, "count" => count, "x" => x, "y" => y}} <-
           read_line(state.port, @command_timeout_ms) do
      {:reply, {:ok, %{count: count, point: {x, y}}}, state}
    else
      failure -> {:reply, {:error, {:helper_failed, failure}}, state}
    end
  end

  def handle_call({:middle_click, x, y, app}, _from, state) do
    request =
      %{op: "middle_click", x: x, y: y}
      |> maybe_put_app(app)
      |> JSON.encode!()

    send_command(request, state)
  end

  defp send_command(request, state) do
    with true <- safe_port_command(state.port, request <> "\n"),
         {:ok, %{"ok" => true}} <- read_line(state.port, @command_timeout_ms) do
      {:reply, :ok, state}
    else
      failure ->
        Logger.warning("key-event helper failed (#{inspect(failure)}); restarting")
        close_helper_port(state.port)
        schedule_restart(@restart_backoff_ms)
        {:reply, {:error, :helper_failed}, %{state | port: nil, status: {:error, :command}}}
    end
  end

  @impl true
  def handle_info(:restart_helper, %{status: :ready} = state), do: {:noreply, state}

  def handle_info(:restart_helper, state) do
    {:noreply, state, {:continue, :start_helper}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("key-event helper exited (#{status}); restarting")
    schedule_restart(@restart_backoff_ms)
    {:noreply, %{state | port: nil, status: {:error, {:exit_status, status}}}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port), do: close_helper_port(port)
  def terminate(_reason, _state), do: :ok

  # --- helper lifecycle --------------------------------------------------------

  defp start_helper(opts) do
    with {:ok, executable} <- ensure_executable(opts),
         {:ok, port} <- open_helper(executable),
         {:ok, trusted?} <- wait_ready(port) do
      {:ok, port, trusted?}
    end
  end

  defp enabled? do
    Application.get_env(:pokex, :native_key_events, true)
  end

  defp macos? do
    match?({:unix, :darwin}, :os.type())
  end

  defp ensure_executable(opts) do
    case Keyword.get(opts, :executable) do
      nil -> compile_if_needed()
      executable -> if File.exists?(executable), do: {:ok, executable}, else: {:error, :enoent}
    end
  end

  defp compile_if_needed do
    source = source_path()
    executable = Path.join([Pokex.Home.dir(), "bin", "key_events"])

    cond do
      not File.exists?(source) -> {:error, {:missing_source, source}}
      fresh?(source, executable) -> {:ok, executable}
      true -> compile(source, executable)
    end
  end

  defp source_path do
    case :code.priv_dir(:pokex) do
      path when is_list(path) -> Path.join(List.to_string(path), "native/key_events.swift")
      {:error, _} -> Path.expand(Path.join(["..", "..", "..", "..", @source_rel]), __DIR__)
    end
  end

  # Same SHA-freshness rule as the SCK helper: TCC keys the Accessibility
  # grant to the binary hash, so rebuild only on real source changes.
  defp fresh?(source, executable) do
    with true <- File.exists?(executable),
         {:ok, compiled_sha} <- File.read(executable <> ".source_sha256"),
         {:ok, current} <- source_sha256(source) do
      String.trim(compiled_sha) == current
    else
      _stale -> false
    end
  end

  defp source_sha256(source) do
    with {:ok, content} <- File.read(source) do
      {:ok, Base.encode16(:crypto.hash(:sha256, content), case: :lower)}
    end
  end

  defp compile(source, executable) do
    File.mkdir_p!(Path.dirname(executable))

    Logger.warning(
      "recompiling the key-event helper — macOS treats it as a NEW app and will ask " <>
        "for the Accessibility permission again (grant once; it sticks until the " <>
        "helper source actually changes)"
    )

    args = [
      "swiftc",
      "-parse-as-library",
      "-O",
      "-framework",
      "AppKit",
      "-framework",
      "ApplicationServices",
      "-framework",
      "CoreGraphics",
      "-o",
      executable,
      source
    ]

    case System.cmd("xcrun", args, stderr_to_stdout: true) do
      {_out, 0} ->
        with {:ok, sha} <- source_sha256(source),
             do: File.write(executable <> ".source_sha256", sha)

        {:ok, executable}

      {out, code} ->
        {:error, {:compile_failed, code, String.trim(out)}}
    end
  rescue
    e in ErlangError -> {:error, {:compile_failed, e.original}}
  end

  defp open_helper(executable) do
    {:ok, Port.open({:spawn_executable, executable}, [:binary, :exit_status, {:line, 4096}])}
  rescue
    e in ErlangError -> {:error, {:open_failed, e.original}}
  end

  defp wait_ready(port) do
    case read_line(port, @ready_timeout_ms) do
      {:ok, %{"ready" => true} = ready} -> {:ok, ready["trusted"] == true}
      {:ok, other} -> {:error, {:bad_ready, other}}
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

  defp safe_port_command(port, data) when is_port(port) do
    Port.command(port, data)
  rescue
    ArgumentError -> false
  end

  defp safe_port_command(_port, _data), do: false

  # stdin EOF is the helper's lifeline (it exits on close), but SIGKILL the OS
  # pid too — the SCK zombies taught us not to trust EOF alone.
  defp close_helper_port(port) when is_port(port) do
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

  defp close_helper_port(_port), do: :ok

  defp maybe_put_app(request, nil), do: request
  defp maybe_put_app(request, app), do: Map.put(request, :app, app)

  defp schedule_restart(delay_ms) do
    Process.send_after(self(), :restart_helper, delay_ms)
  end
end
