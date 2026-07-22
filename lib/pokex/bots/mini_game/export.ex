defmodule Pokex.Bots.MiniGame.Export do
  @moduledoc """
  Writes one mini-game's evidence bundle under `~/.pokex/exports` and keeps the
  directory from growing forever.

      exports/mini_game-1753200000000/
        summary.json     — the per-game verdict (timings, flips, errors, exit)
        samples.jsonl    — one JSON object per tick, in order
        frames/          — only the frames that explain something

  Samples are written in ONE pass at the end rather than appended per tick: the
  play loop already carries a capture, a decode and a decision inside an 80ms
  budget, and file IO there would show up as the very capture jitter the bundle
  exists to measure. The accumulator is capped, so nothing is lost that a
  per-tick write would have saved.

  Retention runs after every write, oldest first: at most `:keep` bundles and
  at most `:max_mb` total. The bundle just written is never pruned — a single
  game bigger than the whole budget still gets read once.
  """

  require Logger

  alias Pokex.Bots.MiniGame.Diag

  @prefix "mini_game-"

  @doc """
  Write `diag` as a bundle. Returns `{:ok, path, %{frames: n, samples: n}}`.

  Options: `:dir` (defaults to `~/.pokex/exports`), `:stamp` (bundle name
  suffix, defaults to the wall clock), `:keep`, `:max_mb`.
  """
  @spec write(Diag.t(), keyword) :: {:ok, String.t(), map} | {:error, term}
  def write(%Diag{} = diag, opts \\ []) do
    dir = Keyword.get(opts, :dir, Pokex.Home.exports_dir())
    stamp = Keyword.get(opts, :stamp, System.os_time(:millisecond))
    path = Path.join(dir, @prefix <> to_string(stamp))
    samples = Diag.samples(diag)
    frames = Diag.frames(diag)

    File.mkdir_p!(Path.join(path, "frames"))
    File.write!(Path.join(path, "summary.json"), encode(Diag.summary(diag)))
    File.write!(Path.join(path, "samples.jsonl"), Enum.map(samples, &[encode(&1), "\n"]))
    Enum.each(frames, &write_frame(path, &1))

    prune(Keyword.put(opts, :dir, dir))

    {:ok, path, %{samples: length(samples), frames: length(frames)}}
  rescue
    error -> {:error, error}
  end

  @doc """
  Enforce retention on the exports dir. Returns `{:ok, removed_paths}`.

  Deterministic and dull on purpose: sort bundles oldest-first by mtime, drop
  from the front while there are too many, then while there are too many bytes.
  """
  @spec prune(keyword) :: {:ok, [String.t()]}
  def prune(opts \\ []) do
    dir = Keyword.get(opts, :dir, Pokex.Home.exports_dir())
    keep = Keyword.get(opts, :keep) || Pokex.Settings.get(:mini_game_export_keep)
    max_mb = Keyword.get(opts, :max_mb) || Pokex.Settings.get(:mini_game_export_max_mb)
    bundles = bundles(dir)

    over_count = length(bundles) - max(keep, 1)
    {doomed, survivors} = Enum.split(bundles, max(over_count, 0))
    {doomed_by_size, _kept} = trim_to_budget(survivors, max_mb * 1_048_576)

    removed =
      (doomed ++ doomed_by_size)
      |> Enum.map(& &1.path)
      |> Enum.filter(&remove(&1))

    {:ok, removed}
  end

  @doc "Bundles present, newest first — for the diagnostics page's list."
  @spec list(keyword) :: [map]
  def list(opts \\ []) do
    opts
    |> Keyword.get(:dir, Pokex.Home.exports_dir())
    |> bundles()
    |> Enum.reverse()
  end

  # --- bundles ---------------------------------------------------------------

  defp bundles(dir) do
    case File.ls(dir) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&String.starts_with?(&1, @prefix))
        |> Enum.map(&Path.join(dir, &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.map(&%{path: &1, name: Path.basename(&1), mtime: mtime(&1), bytes: bytes(&1)})
        |> Enum.sort_by(&{&1.mtime, &1.name})

      {:error, _no_dir} ->
        []
    end
  end

  # The NEWEST bundle is never a candidate: pruning what was just written would
  # make a big game unreadable exactly when it matters most.
  defp trim_to_budget([], _budget), do: {[], []}

  defp trim_to_budget(bundles, budget) do
    {older, newest} = Enum.split(bundles, length(bundles) - 1)
    drop_oldest(older, newest, total_bytes(bundles), budget, [])
  end

  defp drop_oldest([], kept, _total, _budget, dropped), do: {Enum.reverse(dropped), kept}

  defp drop_oldest([oldest | rest], kept, total, budget, dropped) when total > budget,
    do: drop_oldest(rest, kept, total - oldest.bytes, budget, [oldest | dropped])

  defp drop_oldest(remaining, kept, _total, _budget, dropped),
    do: {Enum.reverse(dropped), remaining ++ kept}

  defp total_bytes(bundles), do: Enum.reduce(bundles, 0, &(&1.bytes + &2))

  defp remove(path) do
    case File.rm_rf(path) do
      {:ok, _removed} ->
        true

      {:error, reason, _file} ->
        Logger.warning("mini-game export prune failed for #{path}: #{inspect(reason)}")
        false
    end
  end

  defp mtime(path) do
    case File.stat(path, time: :posix) do
      {:ok, %{mtime: mtime}} -> mtime
      _gone -> 0
    end
  end

  defp bytes(path) do
    path
    |> Path.join("**")
    |> Path.wildcard()
    |> Enum.reduce(0, fn file, acc ->
      case File.stat(file) do
        {:ok, %{type: :regular, size: size}} -> acc + size
        _dir_or_gone -> acc
      end
    end)
  end

  defp write_frame(path, %{tag: tag, index: index, bytes: bytes}) do
    name = "#{String.pad_leading(to_string(index), 5, "0")}-#{tag}.png"
    File.write!(Path.join([path, "frames", name]), bytes)
  end

  # --- JSON ------------------------------------------------------------------

  @doc """
  JSON-encode a diagnostics term. Tuples (regions, row ranges) become lists and
  atoms become strings, so a sample survives the round-trip the replay makes.
  """
  @spec encode(term) :: iodata
  def encode(term), do: term |> jsonable() |> JSON.encode!()

  defp jsonable(%{__struct__: _struct} = value), do: inspect(value)

  defp jsonable(map) when is_map(map),
    do: Map.new(map, fn {key, value} -> {to_string(key), jsonable(value)} end)

  defp jsonable(tuple) when is_tuple(tuple), do: tuple |> Tuple.to_list() |> jsonable()
  defp jsonable(list) when is_list(list), do: Enum.map(list, &jsonable/1)
  defp jsonable(nil), do: nil
  defp jsonable(value) when is_boolean(value), do: value
  defp jsonable(value) when is_atom(value), do: Atom.to_string(value)
  defp jsonable(value), do: value
end
