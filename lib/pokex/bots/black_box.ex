defmodule Pokex.Bots.BlackBox do
  @moduledoc """
  A CAIXA-PRETA: fotos e fatos dos momentos em que um shiny costuma estar.

  "Quando ele precisar de mais de um revive, ou de um revive pra matar um
  grupo, ali provavelmente tem um shiny. Queria fotos ou vídeos desses
  momentos… pega os dados, tudo que tem aí no momento da foto, e salva tudo
  pra você poder analisar" (11/09). Até aqui cada leitor guardava as fotos
  DELE (o vigia as do avistamento, o olho as da abertura, a mira o último
  quadro) e nada juntava, no mesmo instante, a tela inteira com o que cada um
  estava lendo dela — e o shiny das 11:58 passou sem uma linha do vigia.

  Um EPISÓDIO abre quando: a corrente deixa um sobrevivente (o segundo revive
  da mesma pilha), o vigia vê a cor do shiny, ou a mira diz que uma barra
  caçada caiu. Enquanto dura, a cada 2 s um quadro do filme (a arena a meio
  tamanho) e, nas bordas — abertura, revive, hora da bola, queda, bola — um
  quadro inteiro; cada quadro vai com uma linha de manifesto: o que o cérebro
  via e decidia, a leitura do olho, o fato do vigia, a lista de batalha, o
  minimapa, o estado do capturador e as regras de cor armadas. Fecha quando a
  tela fica limpa por 6 s depois da hora da bola, ou aos 150 s.

  Guarda os últimos #{6} episódios em `captures/incidents/`; os quadros são
  PXRW comprimidos com zlib (`.raw.z`), a leitura é offline.
  """

  use GenServer

  alias Pokex.Bots.Capture
  alias Pokex.Bots.Catcher.SpotScan
  alias Pokex.Bots.Engine
  alias Pokex.Bots.ShinyGuard
  alias Pokex.Calibration
  alias Pokex.Home
  alias Pokex.Perception.WorldState
  alias Pokex.Vision.{ColorRules, Frame}

  @dir "incidents"
  @keep 6
  @film_every_ms 2_000
  @max_film 60
  @max_key 10
  @quiet_to_close_ms 6_000
  @max_episode_ms 150_000
  @catcher_topic "catcher"
  @shiny_topic "shiny"

  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)

    state = %{
      active?: Keyword.get(opts, :active, Application.get_env(:pokex, :black_box_active, true)),
      capture: Keyword.get(opts, :capture, &Capture.frame/2),
      quiet_to_close_ms: Keyword.get(opts, :quiet_to_close_ms, @quiet_to_close_ms),
      log: Keyword.get(opts, :log, &default_log/1),
      episode: nil
    }

    case name do
      nil -> GenServer.start_link(__MODULE__, state)
      name -> GenServer.start_link(__MODULE__, state, name: name)
    end
  end

  @doc "The episode being recorded, or nil."
  def status(server \\ __MODULE__), do: GenServer.call(server, :status)

  @impl true
  def init(state) do
    Phoenix.PubSub.subscribe(Pokex.PubSub, Engine.Worker.topic())
    Phoenix.PubSub.subscribe(Pokex.PubSub, @shiny_topic)
    Phoenix.PubSub.subscribe(Pokex.PubSub, @catcher_topic)
    {:ok, state}
  end

  @impl true
  def handle_call(:status, _from, state), do: {:reply, public(state.episode), state}

  @impl true
  def handle_info(_msg, %{active?: false} = state), do: {:noreply, state}

  # THE BRAIN'S TICK is the clock: it opens on the survivor, films, and closes.
  def handle_info({:engine, picture, orders}, state) do
    now = now()

    state =
      state
      |> maybe_open(trigger(orders), picture, orders, now)
      |> tick(picture, orders, now)

    {:noreply, state}
  end

  def handle_info({:shiny_on_screen, %{vistos: [_ | _]}}, state),
    do: {:noreply, maybe_open(state, :shiny, nil, nil, now())}

  def handle_info({:shiny_seen, _info}, state),
    do: {:noreply, maybe_open(state, :shiny, nil, nil, now())}

  def handle_info({:catcher_log, :macro, text}, state) do
    cond do
      String.contains?(text, "caiu em") ->
        {:noreply, state |> maybe_open(:queda, nil, nil, now()) |> key_frame("queda", now())}

      String.contains?(text, "bola") and state.episode != nil ->
        {:noreply, key_frame(state, "bola", now())}

      true ->
        {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # --- the episode --------------------------------------------------------------

  defp trigger(%{why: why}) when is_binary(why) do
    if String.contains?(why, "sobrevivente da corrente ("), do: :sobrevivente, else: nil
  end

  defp trigger(_orders), do: nil

  defp maybe_open(state, nil, _picture, _orders, _now), do: state
  defp maybe_open(%{episode: %{}} = state, _reason, _p, _o, _now), do: state

  defp maybe_open(state, reason, picture, orders, now) do
    stamp = DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601(:basic)
    name = "#{String.replace(stamp, ~r/[:+]/, "")}-#{reason}"
    dir = Path.join([Home.captures_dir(), @dir, name])
    File.mkdir_p!(dir)

    episode = %{
      dir: dir,
      name: name,
      reason: reason,
      since: now,
      film: 0,
      keys: 0,
      last_film_at: nil,
      cue_at: nil,
      clear_since: nil,
      revive_was: :hold,
      quiet_ms: state.quiet_to_close_ms
    }

    state.log.("📼 caixa-preta gravando (#{reason}) — captures/#{@dir}/#{name}")
    state = %{state | episode: episode}
    rotate(Path.join(Home.captures_dir(), @dir))
    key_frame(state, "abertura", now, picture, orders)
  end

  defp tick(%{episode: nil} = state, _picture, _orders, _now), do: state

  defp tick(state, picture, orders, now) do
    state
    |> frame_on_edge(picture, orders, now)
    |> note_tick(picture, orders, now)
    |> maybe_close(orders, now)
  end

  # The edges earn a whole frame; between them the film runs.
  defp frame_on_edge(%{episode: ep} = state, picture, orders, now) do
    cond do
      revive?(orders) and ep.revive_was == :hold ->
        key_frame(state, "revive", now, picture, orders)

      orders.phase == :capturing and ep.cue_at == nil ->
        key_frame(state, "hora-da-bola", now, picture, orders)

      due_film?(ep, now) ->
        film_frame(state, now, picture, orders)

      true ->
        state
    end
  end

  defp note_tick(%{episode: ep} = state, picture, orders, now) do
    clear? = Map.get(picture || %{}, :enemies) == 0

    episode = %{
      ep
      | clear_since: if(clear?, do: ep.clear_since || now, else: nil),
        cue_at: ep.cue_at || if(orders.phase == :capturing, do: now),
        revive_was: if(revive?(orders), do: :now, else: :hold)
    }

    %{state | episode: episode}
  end

  defp revive?(%{revive: revive}), do: revive in [:now, :prepare]

  defp maybe_close(%{episode: ep} = state, orders, now) do
    cond do
      now - ep.since >= @max_episode_ms ->
        close(state, "teto de #{div(@max_episode_ms, 1000)}s", now)

      orders.phase == :idle ->
        close(state, "caçada parada", now)

      quiet?(ep, now) ->
        close(state, "tela limpa", now)

      true ->
        state
    end
  end

  defp due_film?(%{last_film_at: nil}, _now), do: true

  defp due_film?(%{last_film_at: at, film: n}, now),
    do: n < @max_film and now - at >= @film_every_ms

  # Closed on a clean screen only AFTER the ball's moment (or with nothing
  # pending): the corpse and the ball are the whole point of the recording.
  defp quiet?(%{clear_since: nil}, _now), do: false

  defp quiet?(%{clear_since: since, cue_at: cue_at, quiet_ms: quiet_ms}, now),
    do: now - since >= quiet_ms and (cue_at != nil or now - since >= 2 * quiet_ms)

  defp close(state, why, now) do
    state = key_frame(state, "fim", now)
    ep = state.episode
    seconds = div(now - ep.since, 1000)

    state.log.(
      "📼 caixa-preta: #{ep.film} quadro(s) do filme + #{ep.keys} inteiro(s) em #{seconds}s (#{why}) — " <>
        "captures/#{@dir}/#{ep.name}"
    )

    %{state | episode: nil}
  end

  # --- the frames ----------------------------------------------------------------

  defp key_frame(state, tag, now, picture \\ nil, orders \\ nil)
  defp key_frame(%{episode: nil} = state, _tag, _now, _p, _o), do: state

  defp key_frame(%{episode: %{keys: keys}} = state, _tag, _now, _p, _o) when keys >= @max_key,
    do: state

  defp key_frame(state, tag, now, picture, orders) do
    ep = state.episode
    file = "#{pad(ep.keys + ep.film)}-#{tag}.raw.z"
    saved = save(state, ep.dir, file, 1)
    manifest(state, "key", tag, file, saved, now, picture, orders)
    %{state | episode: %{ep | keys: ep.keys + 1}}
  end

  defp film_frame(state, now, picture, orders) do
    ep = state.episode
    file = "#{pad(ep.keys + ep.film)}-filme.raw.z"
    saved = save(state, ep.dir, file, 2)
    manifest(state, "film", "filme", file, saved, now, picture, orders)
    %{state | episode: %{ep | film: ep.film + 1, last_film_at: now}}
  end

  defp save(state, dir, file, shrink) do
    with {:ok, calib} <- Calibration.load(),
         {:ok, {_x, _y, _w, _h} = region} <- SpotScan.region(calib),
         {:ok, %Frame{} = frame} <- state.capture.(region, "black_box.raw") do
      frame = if shrink > 1, do: shrink(frame, shrink), else: frame
      Home.write!(Path.join(dir, file), pack(Frame.to_raw(frame)))
      %{ok?: true, region: Tuple.to_list(region), shrink: shrink, w: frame.width, h: frame.height}
    else
      other -> %{ok?: false, reason: inspect(other)}
    end
  rescue
    error -> %{ok?: false, reason: Exception.message(error)}
  end

  # zlib at level 1: measured on his arena frame, 14,8 MB → 6,0 MB in 97 ms
  # (level 6 takes three times longer for 15 % less). `:zlib.uncompress/1` reads it.
  defp pack(bytes) do
    z = :zlib.open()
    :ok = :zlib.deflateInit(z, 1)
    packed = z |> :zlib.deflate(bytes, :finish) |> IO.iodata_to_binary()
    :ok = :zlib.deflateEnd(z)
    :ok = :zlib.close(z)
    packed
  end

  @doc false
  # Every other pixel of every other row: half the size, a quarter of the bytes.
  def shrink(%Frame{width: w, height: h, rgba: rgba} = frame, 2) do
    hw = div(w, 2)
    hh = div(h, 2)

    rows =
      for y <- 0..(hh - 1) do
        row = binary_part(rgba, y * 2 * w * 4, w * 4)
        for <<a::32, _skip::32 <- row>>, into: <<>>, do: <<a::32>>
      end

    %{frame | width: hw, height: hh, rgba: IO.iodata_to_binary(rows)}
  end

  def shrink(frame, _one), do: frame

  # --- the manifest ------------------------------------------------------------------

  defp manifest(state, kind, tag, file, saved, now, picture, orders) do
    line = %{
      at: DateTime.to_iso8601(DateTime.utc_now()),
      mono: now,
      t_ms: now - state.episode.since,
      kind: kind,
      tag: tag,
      file: file,
      frame: saved,
      picture:
        picture &&
          Map.take(picture, [
            :enemies,
            :rows,
            :own_hp,
            :heavy?,
            :special?,
            :boss?,
            :worth_fighting?,
            :named
          ]),
      orders: orders && Map.take(orders, [:phase, :route, :revive, :fire, :why, :capture]),
      crowd: fact(:crowd, 5_000),
      special: fact(:special, 5_000),
      battle: fact(:battle, 5_000) |> only([:enemies, :enemies_detail]),
      minimap: fact(:minimap, 5_000),
      capture: fact(:capture, 5_000),
      catcher: catcher(),
      guard: guard(),
      rules: rules()
    }

    File.write!(
      Path.join(state.episode.dir, "manifest.jsonl"),
      Jason.encode!(line, escape: :unicode_safe) <> "\n",
      [:append]
    )
  rescue
    _cannot_write -> :ok
  end

  defp fact(key, max_age) do
    case WorldState.get(key, max_age, now()) do
      {:ok, obs} -> plain(obs)
      {:stale, obs, age} -> %{stale_ms: age, was: plain(obs)}
      _missing -> nil
    end
  end

  defp only(nil, _keys), do: nil
  defp only(%{was: was} = stale, keys), do: %{stale | was: only(was, keys)}
  defp only(map, keys) when is_map(map), do: Map.take(map, keys)
  defp only(other, _keys), do: other

  defp catcher do
    Pokex.Bots.Catcher.Worker.status()
    |> Map.take([
      :state,
      :aim?,
      :shiny_pending?,
      :pending_corpses,
      :hold_reason,
      :last_action,
      :trail
    ])
    |> plain()
  catch
    _kind, _reason -> nil
  end

  defp guard do
    ShinyGuard.status() |> plain()
  catch
    _kind, _reason -> nil
  end

  defp rules do
    ColorRules.armed() |> Enum.map(&Map.take(&1, [:name, :slug, :min_px])) |> plain()
  catch
    _kind, _reason -> nil
  end

  # Tuples are not JSON: points become lists, everything else stays.
  defp plain(term) when is_tuple(term), do: term |> Tuple.to_list() |> plain()
  defp plain(term) when is_list(term), do: Enum.map(term, &plain/1)
  defp plain(%MapSet{} = set), do: set |> MapSet.to_list() |> plain()
  defp plain(%{__struct__: _} = struct), do: struct |> Map.from_struct() |> plain()
  defp plain(term) when is_map(term), do: Map.new(term, fn {k, v} -> {plain_key(k), plain(v)} end)
  defp plain(term) when is_function(term) or is_pid(term) or is_reference(term), do: inspect(term)
  defp plain(term), do: term

  defp plain_key(key) when is_binary(key) or is_atom(key) or is_number(key), do: key
  defp plain_key(key), do: inspect(key)

  # --- housekeeping -------------------------------------------------------------------

  defp rotate(root) do
    root
    |> File.ls!()
    |> Enum.sort(:desc)
    |> Enum.drop(@keep)
    |> Enum.each(&File.rm_rf(Path.join(root, &1)))
  rescue
    _no_dir -> :ok
  end

  defp pad(n), do: n |> Integer.to_string() |> String.pad_leading(3, "0")

  defp default_log(text),
    do:
      Phoenix.PubSub.broadcast(
        Pokex.PubSub,
        @catcher_topic,
        {:catcher_log, :macro, "captura: " <> text}
      )

  defp now, do: System.monotonic_time(:millisecond)

  @doc false
  def public(nil), do: nil
  def public(ep), do: Map.take(ep, [:name, :reason, :film, :keys, :since])
end
