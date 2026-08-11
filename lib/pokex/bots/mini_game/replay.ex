defmodule Pokex.Bots.MiniGame.Replay do
  @moduledoc """
  Re-runs a recorded mini-game bundle through the CURRENT vision code, offline.

  It reads PNGs from disk and runs exactly three things: `Detector`, `Track`
  and the diagnostic arithmetic (the fish plausibility gate and the velocity
  estimates). It starts no Worker, takes no capture, and touches no Rig — the
  default rig is `Pokex.Bots.MiniGame.Replay.NoRig`, whose every callback
  raises, and any other module must declare itself replay-safe or `run/2`
  refuses to start.

  What it is FOR: changing a threshold or a bounds rule and asking "would this
  have read the same frames the same way?" — a question that must never be
  answered by pressing a key in a live game.

  The bundle's kept frames are a deliberate SUBSET (see `Diag`), so a replay
  summary counts only those frames — it is comparable across code versions on
  the same bundle, not against the live summary of that game.
  """

  alias Pokex.Bots.MiniGame.{Detector, Diag}
  alias Pokex.Settings
  alias Pokex.Vision.Frame

  defmodule NoRig do
    @moduledoc """
    A Rig that cannot act. Every callback raises, so any actuation sneaking
    into a replay path fails loudly instead of moving a real character.
    """
    @behaviour Pokex.Rig

    # Every actuator raises on purpose (replay is offline), so "no local return"
    # is the design, not a defect.
    @dialyzer {:nowarn_function,
               press: 1,
               press_many: 2,
               key_down: 1,
               key_up: 1,
               click: 2,
               move: 1,
               middle_watch: 0,
               tap: 1,
               focus_click: 1,
               capture_sequence: 1,
               capture: 2,
               capture_screen: 0,
               cursor_position: 0}

    def replay_safe?, do: true

    @impl true
    def press(_combo), do: refuse(:press)
    @impl true
    def press_many(_combos, _opts), do: refuse(:press_many)
    @impl true
    def key_down(_key), do: refuse(:key_down)
    @impl true
    def key_up(_key), do: refuse(:key_up)
    @impl true
    def tap(_combo), do: refuse(:tap)
    @impl true
    def focus_click(_point), do: refuse(:focus_click)
    @impl true
    def hold_latency_ms, do: 0
    @impl true
    def click(_button, _point), do: refuse(:click)
    @impl true
    def move(_point), do: refuse(:move)
    @impl true
    def capture_sequence(_point), do: refuse(:capture_sequence)
    @impl true
    def capture(_region, _filename), do: refuse(:capture)
    @impl true
    def capture_screen, do: refuse(:capture_screen)
    @impl true
    def cursor_position, do: refuse(:cursor_position)
    @impl true
    def middle_watch, do: refuse(:middle_watch)

    defp refuse(action) do
      raise "mini-game replay is offline: #{action} is not allowed"
    end
  end

  @doc """
  Replay a bundle directory (or any directory holding `frames/*.png`).

  Options:

    * `:rig` — must be replay-safe; defaults to `NoRig`
    * `:track_bar` — override the bar geometry (defaults to the bundle's)
  """
  @spec run(String.t(), keyword) :: {:ok, map} | {:error, term}
  def run(source, opts \\ []) do
    ensure_offline!(Keyword.get(opts, :rig, NoRig))

    with {:ok, meta} <- read_summary(source),
         {:ok, track_bar} <- track_bar(meta, opts),
         {:ok, frames} <- frame_files(source) do
      recorded = recorded_samples(source)
      {diag, samples} = fold(frames, track_bar, recorded)

      {:ok,
       %{
         source: source,
         track_bar: track_bar,
         frames: length(frames),
         samples: samples,
         summary: diag |> Diag.finish(:replay) |> Diag.summary()
       }}
    end
  end

  @doc "Is this module allowed anywhere near a replay?"
  @spec replay_safe?(module) :: boolean
  def replay_safe?(NoRig), do: true

  def replay_safe?(module) when is_atom(module) do
    Code.ensure_loaded?(module) and function_exported?(module, :replay_safe?, 0) and
      module.replay_safe?()
  end

  def replay_safe?(_other), do: false

  defp ensure_offline!(rig) do
    unless replay_safe?(rig) do
      raise ArgumentError,
            "replay refuses #{inspect(rig)}: it is not declared replay-safe. " <>
              "A replay must never be able to actuate — omit :rig to use NoRig."
    end
  end

  # --- reading the bundle ----------------------------------------------------

  defp read_summary(source) do
    path = Path.join(source, "summary.json")

    case File.read(path) do
      {:ok, bin} -> JSON.decode(bin)
      # A bare directory of frames is a valid source too (hand-collected PNGs).
      {:error, :enoent} -> {:ok, %{}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp track_bar(meta, opts) do
    case Keyword.get(opts, :track_bar) || meta["track_bar"] || meta["bar"] do
      %{"x" => x, "width" => width} -> {:ok, %{x: round(x), width: round(width)}}
      %{x: x, width: width} -> {:ok, %{x: round(x), width: round(width)}}
      _missing -> {:error, :no_track_bar}
    end
  end

  defp frame_files(source) do
    case Path.wildcard(Path.join([source, "frames", "*.png"])) do
      [] -> {:error, :no_frames}
      files -> {:ok, Enum.sort(files)}
    end
  end

  # Recorded timings, keyed by the sample index the frame filename carries, so
  # a replayed sample can sit beside the one that was actually recorded.
  defp recorded_samples(source) do
    path = Path.join(source, "samples.jsonl")

    case File.read(path) do
      {:ok, bin} ->
        bin
        |> String.split("\n", trim: true)
        |> Enum.flat_map(&indexed_sample/1)
        |> Map.new()

      {:error, _absent} ->
        %{}
    end
  end

  defp indexed_sample(line) do
    case JSON.decode(line) do
      {:ok, %{"i" => i} = sample} -> [{i, sample}]
      _unreadable -> []
    end
  end

  # --- the replay itself -----------------------------------------------------

  defp fold(files, track_bar, recorded) do
    diag = Diag.new(started_at: 0, track_bar: track_bar, mode: :replay)

    Enum.reduce(files, {diag, []}, fn file, {diag, samples} ->
      case Frame.from_png_file(file) do
        {:ok, frame} ->
          {index, tag} = label(file)
          previous = Map.get(recorded, index, %{})
          diag = Diag.record(diag, sample(frame, track_bar, index, tag, previous))
          {diag, samples ++ [Diag.last_sample(diag)]}

        {:error, reason} ->
          {diag, samples ++ [%{file: file, error: inspect(reason)}]}
      end
    end)
  end

  defp sample(frame, track_bar, index, tag, recorded) do
    observation = Diag.observe(frame, track_bar)

    observation
    |> Map.merge(%{
      i: index,
      tag: tag,
      # Replay has no clock of its own: timings come from the recording, so a
      # replayed report never invents a cadence it did not observe.
      at: recorded["t_ms"] || index,
      cap_ms: recorded["cap_ms"],
      tick_ms: recorded["tick_ms"],
      recorded_fish_y: recorded["fish_y"],
      recorded_bar_y: recorded["bar_y"],
      recorded_source: recorded["bar_source"],
      detector: detector(frame)
    })
    |> put_drift()
  end

  # Does the CURRENT code still read this frame the way the recording did? This
  # single number is what a "did my change break anything?" comparison reads.
  defp put_drift(sample) do
    drift =
      case {sample[:fish_y], sample[:recorded_fish_y]} do
        {now, before} when is_number(now) and is_number(before) -> abs(now - before)
        _incomparable -> nil
      end

    Map.put(sample, :fish_drift, drift)
  end

  defp detector(frame) do
    reading =
      Detector.detect(frame,
        min_confidence: Settings.get(:mini_game_min_confidence),
        min_dark_ratio: Settings.get(:mini_game_min_dark_ratio),
        anchor_x: div(frame.width, 2),
        anchor_tolerance: div(frame.width, 2) + 1
      )

    %{
      present?: reading.present?,
      confidence: reading.confidence,
      via: reading.bar && reading.bar.via,
      bar_x: reading.bar && reading.bar.x,
      bar_width: reading.bar && reading.bar.width
    }
  end

  # "00042-source_flip.png" -> {42, :source_flip}
  defp label(file) do
    case file |> Path.basename(".png") |> String.split("-", parts: 2) do
      [index, tag] -> {String.to_integer(index), tag}
      [index] -> {String.to_integer(index), nil}
    end
  rescue
    ArgumentError -> {0, nil}
  end
end
