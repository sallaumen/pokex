defmodule Pokex.Bots.MiniGame.Diag do
  @moduledoc """
  Everything one mini-game tells us about itself, accumulated in memory with
  hard caps and dumped as an evidence bundle when the game ends.

  Two rules shape this module:

    * **It never changes what the game does.** It records the readings, the
      gate verdict and the decision the Player already made. Nothing here can
      re-aim the capsule.
    * **It is bounded.** Samples stop at `samples_max` (the counters keep
      counting), and frames are kept in three fixed slots (first, worst error,
      last) plus a small ring of EVENT frames — never one PNG per tick.

  `observe/2` is the single image -> reading step, shared by live play and by
  the offline replay, so a report can never describe a different read than the
  one that flew (or, in manual assist, failed to fly) the capsule.
  """

  alias Pokex.Bots.MiniGame.Track
  alias Pokex.Vision.Frame

  defstruct mode: :manual_assist,
            started_at: nil,
            ended_at: nil,
            exit_reason: nil,
            strip: nil,
            bar: nil,
            track_bar: nil,
            samples_max: 3_000,
            frames_max: 8,
            index: 0,
            samples: [],
            dropped_samples: 0,
            capture_ms: [],
            tick_ms: [],
            gap_ms: [],
            flips: 0,
            rejected: 0,
            blind: 0,
            no_track: 0,
            no_fish: 0,
            key_down: 0,
            key_up: 0,
            safety_key_ups: [],
            # One statistic, one field: three top-level counters for the same
            # measurement pushed the struct past 31 fields for no gain.
            error: %{sum: 0.0, n: 0, max: 0.0},
            no_capsule_streak: 0,
            no_capsule_streak_max: 0,
            last_capture_at: nil,
            last_source: nil,
            frames: %{},
            frame_ring: []

  @type t :: %__MODULE__{}

  @doc """
  Start a recording. `:strip`/`:bar`/`:track_bar` are the geometry the game was
  armed with — the replay needs them to read the saved frames the same way.
  """
  @spec new(keyword) :: t
  def new(opts \\ []) do
    %__MODULE__{
      mode: Keyword.get(opts, :mode, :manual_assist),
      started_at: Keyword.get(opts, :started_at),
      strip: Keyword.get(opts, :strip),
      bar: Keyword.get(opts, :bar),
      track_bar: Keyword.get(opts, :track_bar),
      samples_max: Keyword.get(opts, :samples_max, 3_000),
      frames_max: Keyword.get(opts, :frames_max, 8)
    }
  end

  @doc """
  The image -> reading step: `Track.read_diag/2` flattened into the shape a
  sample carries. Pure, and the ONLY place either the live player or the replay
  turns pixels into numbers.
  """
  @spec observe(Frame.t(), %{x: integer, width: integer}) :: map
  def observe(%Frame{} = frame, track_bar) do
    {result, stats} = Track.read_diag(frame, track_bar)

    base = %{
      frame_w: frame.width,
      frame_h: frame.height,
      top: stats.top,
      bottom: stats.bottom,
      fish_rows: stats.fish_rows,
      dark_px: stats.dark_px,
      blue_px: stats.blue_px,
      dark_rows: stats.dark_rows,
      blue_rows: stats.blue_rows,
      other_rows: stats.other_rows,
      track_at_edge?: stats.track_at_edge?
    }

    case result do
      {:ok, reading} ->
        Map.merge(base, %{
          read: :ok,
          fish_y: reading.fish_y,
          bar_y: reading.bar_y,
          bar_source: reading.bar_source
        })

      {:error, reason} ->
        Map.merge(base, %{read: reason, fish_y: nil, bar_y: nil, bar_source: nil})
    end
  end

  @doc """
  Record one tick.

  `sample` carries the observation plus what the caller alone knows (timings,
  gate verdict, hold state, decision). `png` is a ZERO-ARITY function returning
  `{:ok, binary}` for the analysed PNG — it is called ONLY when this tick earns
  a frame slot, so an uneventful tick costs no IO at all.
  """
  @spec record(t, map, (-> {:ok, binary} | {:error, term}) | nil) :: t
  def record(%__MODULE__{} = diag, sample, png \\ nil) do
    sample = derive(diag, sample)

    diag
    |> count(sample)
    |> keep_sample(sample)
    |> keep_frames(sample, png)
    |> Map.put(:index, diag.index + 1)
    |> Map.put(:last_capture_at, sample.at)
    |> Map.put(:last_source, sample[:bar_source] || diag.last_source)
  end

  @doc """
  Remember the track geometry the reads are using. It depends on the captured
  frame's width, so it is only known once the first frame arrives — and the
  replay CANNOT read the saved frames without it.
  """
  @spec remember_track_bar(t | nil, map) :: t | nil
  def remember_track_bar(nil, _bar), do: nil
  def remember_track_bar(%__MODULE__{track_bar: nil} = diag, bar), do: %{diag | track_bar: bar}
  def remember_track_bar(diag, _bar), do: diag

  @doc "Record the result of a safety Space release (entry guard, exit paths)."
  @spec record_key_up(t, term) :: t
  def record_key_up(%__MODULE__{} = diag, result),
    do: %{diag | safety_key_ups: diag.safety_key_ups ++ [inspect(result)]}

  @doc "Count an actuation the Player performed (`:auto` only)."
  @spec record_actuation(t, boolean) :: t
  def record_actuation(%__MODULE__{} = diag, true), do: %{diag | key_down: diag.key_down + 1}
  def record_actuation(%__MODULE__{} = diag, false), do: %{diag | key_up: diag.key_up + 1}

  @doc """
  Close the recording: stamp the exit and take the LAST frame. The last capture
  file is still on disk untouched (only the mini-game writes it), so the final
  frame costs one read at the end instead of one per tick.
  """
  @spec finish(t, atom, (-> {:ok, binary} | {:error, term}) | nil) :: t
  def finish(%__MODULE__{} = diag, exit_reason, png \\ nil) do
    %{diag | ended_at: System.monotonic_time(:millisecond), exit_reason: exit_reason}
    |> put_slot(:last, diag.index - 1, png)
  end

  @doc "Samples in chronological order."
  @spec samples(t) :: [map]
  def samples(%__MODULE__{samples: samples}), do: Enum.reverse(samples)

  @doc "Kept frames, chronological: `[%{tag:, index:, bytes:}]`."
  @spec frames(t) :: [map]
  def frames(%__MODULE__{} = diag) do
    (Map.values(diag.frames) ++ diag.frame_ring)
    |> Enum.reject(&is_nil/1)
    |> Enum.sort_by(& &1.index)
  end

  @doc "The tick a diagnostics page shows: the newest sample, or nil."
  @spec last_sample(t) :: map | nil
  def last_sample(%__MODULE__{samples: []}), do: nil
  def last_sample(%__MODULE__{samples: [newest | _older]}), do: newest

  @doc """
  The per-game verdict: duration, cadence, how often the reading flipped
  source, how often the gate refused a reading, how far the capsule sat from
  the fish, and how the game ended.
  """
  @spec summary(t) :: map
  def summary(%__MODULE__{} = diag) do
    duration_ms = duration_ms(diag)
    ticks = diag.index

    %{
      mode: diag.mode,
      duration_ms: duration_ms,
      ticks: ticks,
      fps: rounded(fps(ticks, duration_ms), 2),
      capture_ms: percentiles(diag.capture_ms),
      tick_ms: percentiles(diag.tick_ms),
      gap_ms: percentiles(diag.gap_ms),
      source_flips: diag.flips,
      rejected_readings: diag.rejected,
      blind_ticks: diag.blind,
      no_track: diag.no_track,
      no_fish: diag.no_fish,
      max_no_capsule_streak: diag.no_capsule_streak_max,
      error_mean: rounded(mean(diag.error.sum, diag.error.n), 4),
      error_max: rounded(diag.error.max, 4),
      key_down: diag.key_down,
      key_up: diag.key_up,
      safety_key_ups: diag.safety_key_ups,
      exit_reason: diag.exit_reason,
      samples_recorded: length(diag.samples),
      samples_dropped: diag.dropped_samples,
      frames_kept: length(frames(diag)),
      strip: diag.strip,
      bar: diag.bar,
      track_bar: diag.track_bar
    }
  end

  # --- derivation ------------------------------------------------------------

  defp derive(diag, sample) do
    flip? =
      sample[:bar_source] != nil and diag.last_source != nil and
        sample[:bar_source] != diag.last_source

    error =
      case {sample[:fish_aim], sample[:bar_y]} do
        {aim, bar} when is_number(aim) and is_number(bar) -> abs(aim - bar)
        _incomplete -> nil
      end

    sample
    |> Map.put(:i, diag.index)
    |> Map.put(:t_ms, elapsed_ms(diag, sample[:at]))
    |> Map.put(:gap_ms, gap_ms(diag, sample[:at]))
    |> Map.put(:flip, flip?)
    |> Map.put(:error, error)
  end

  defp elapsed_ms(%{started_at: nil}, _at), do: nil
  defp elapsed_ms(_diag, nil), do: nil
  defp elapsed_ms(%{started_at: started_at}, at), do: at - started_at

  defp gap_ms(%{last_capture_at: nil}, _at), do: nil
  defp gap_ms(_diag, nil), do: nil
  defp gap_ms(%{last_capture_at: last}, at), do: at - last

  defp bump(counter, true), do: counter + 1
  defp bump(counter, _false), do: counter

  defp count(diag, sample) do
    blind? = sample[:read] != :ok
    no_capsule? = sample[:bar_source] == :fish
    streak = if no_capsule?, do: diag.no_capsule_streak + 1, else: 0
    # `index` counts ticks, so the cap check is O(1). Measuring a 3000-element
    # list four times per tick would make the diagnostics a source of the very
    # tick latency they exist to measure.
    full? = full?(diag)

    %{
      diag
      | capture_ms: push_capped(diag.capture_ms, sample[:cap_ms], full?),
        tick_ms: push_capped(diag.tick_ms, sample[:tick_ms], full?),
        gap_ms: push_capped(diag.gap_ms, sample[:gap_ms], full?),
        flips: bump(diag.flips, sample.flip),
        rejected: bump(diag.rejected, sample[:accepted] == false),
        blind: bump(diag.blind, blind?),
        no_track: bump(diag.no_track, sample[:read] == :no_track),
        no_fish: bump(diag.no_fish, sample[:read] == :no_fish),
        no_capsule_streak: streak,
        no_capsule_streak_max: max(diag.no_capsule_streak_max, streak),
        error: %{
          sum: diag.error.sum + (sample.error || 0.0),
          n: diag.error.n + if(sample.error, do: 1, else: 0),
          max: max(diag.error.max, sample.error || 0.0)
        }
    }
  end

  defp full?(%{index: index, samples_max: samples_max}), do: index >= samples_max

  defp push_capped(list, nil, _full?), do: list
  defp push_capped(list, _value, true), do: list
  defp push_capped(list, value, false), do: [value | list]

  defp keep_sample(diag, sample) do
    if full?(diag),
      do: %{diag | dropped_samples: diag.dropped_samples + 1},
      else: %{diag | samples: [sample | diag.samples]}
  end

  # Frame policy: three fixed slots that must survive the whole game (the first
  # frame, the worst error, the last frame) plus a ring of EVENT frames — a
  # source flip, a refused reading, a lost track, a lost fish. Everything else
  # is thrown away, which is the difference between an evidence bundle and a
  # screen recording.
  defp keep_frames(diag, _sample, nil), do: diag

  defp keep_frames(diag, sample, png) do
    diag
    |> maybe_first(sample, png)
    |> maybe_worst(sample, png)
    |> maybe_event(sample, png)
  end

  defp maybe_first(%{index: 0} = diag, _sample, png), do: put_slot(diag, :first, 0, png)
  defp maybe_first(diag, _sample, _png), do: diag

  defp maybe_worst(diag, %{error: error} = sample, png)
       when is_number(error) do
    worst = diag.frames[:max_error]

    if worst == nil or error > worst.error,
      do: put_slot(diag, :max_error, sample.i, png, %{error: error}),
      else: diag
  end

  defp maybe_worst(diag, _sample, _png), do: diag

  defp maybe_event(diag, sample, png) do
    case event_tag(sample) do
      nil -> diag
      tag -> push_ring(diag, tag, sample.i, png)
    end
  end

  defp event_tag(%{read: :no_track}), do: :no_track
  defp event_tag(%{read: :no_fish}), do: :no_fish
  defp event_tag(%{accepted: false}), do: :rejected
  defp event_tag(%{flip: true}), do: :source_flip
  defp event_tag(_uneventful), do: nil

  defp put_slot(diag, tag, index, png, extra \\ %{})
  defp put_slot(diag, _tag, _index, nil, _extra), do: diag

  defp put_slot(diag, tag, index, png, extra) do
    case png.() do
      {:ok, bytes} ->
        entry = Map.merge(%{tag: tag, index: index, bytes: bytes, error: 0.0}, extra)
        %{diag | frames: Map.put(diag.frames, tag, entry)}

      _unreadable ->
        diag
    end
  end

  defp push_ring(diag, tag, index, png) do
    case png.() do
      {:ok, bytes} ->
        ring =
          [%{tag: tag, index: index, bytes: bytes} | diag.frame_ring]
          |> Enum.take(diag.frames_max)

        %{diag | frame_ring: ring}

      _unreadable ->
        diag
    end
  end

  # --- summary maths ---------------------------------------------------------

  defp duration_ms(%{started_at: nil}), do: nil

  defp duration_ms(%{ended_at: nil, started_at: started_at}),
    do: System.monotonic_time(:millisecond) - started_at

  defp duration_ms(%{ended_at: ended_at, started_at: started_at}), do: ended_at - started_at

  defp fps(_ticks, nil), do: nil
  defp fps(_ticks, duration) when duration <= 0, do: nil
  defp fps(ticks, duration), do: ticks * 1000 / duration

  defp mean(_sum, 0), do: nil
  defp mean(sum, n), do: sum / n

  defp percentiles([]), do: %{p50: nil, p95: nil, max: nil}

  defp percentiles(values) do
    sorted = Enum.sort(values)
    %{p50: percentile(sorted, 0.5), p95: percentile(sorted, 0.95), max: List.last(sorted)}
  end

  # Nearest-rank (the plain textbook definition): the p50 of [10, 30] is 10, not
  # 30 — a latency percentile must never round UP into the tail it is measuring.
  defp percentile(sorted, fraction) do
    index = (length(sorted) * fraction) |> Float.ceil() |> trunc() |> Kernel.-(1) |> max(0)
    Enum.at(sorted, index)
  end

  defp rounded(nil, _digits), do: nil
  defp rounded(value, digits) when is_float(value), do: Float.round(value, digits)
  defp rounded(value, _digits), do: value
end
