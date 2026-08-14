defmodule Mix.Tasks.Pokedex.Scrape do
  @shortdoc "Scrapes the PokeTibia wiki into priv/pokedex/pokedex.json (+ sprites)"

  @moduledoc """
  Terminal wrapper around `Pokex.Pokedex.Sync` (the /pokedex "Sincronizar"
  button runs the same pipeline). Every run UPSERTS: freshly scraped entries
  replace their names in the existing pokedex.json, everything else stays.
  Each entry carries the wiki's last-edit date (edited_at) and this run's
  scraped_at.

  Deliberately does NOT boot the :pokex app (only :req) — running a scrape
  from the terminal must never start the bot's workers against the real
  mouse/screen.

      mix pokedex.scrape                        # full run (~10-20min, be nice to the wiki)
      mix pokedex.scrape --only "Seadra,Horsea" # refresh just these (+ their shinies)
      mix pokedex.scrape --fresh                # ignore the existing JSON (full rebuild)
      mix pokedex.scrape --limit 20             # first N species (pipeline check)
      mix pokedex.scrape --delay-ms 400         # slower pace
      mix pokedex.scrape --skip-sprites         # JSON only
  """

  use Mix.Task

  alias Pokex.Pokedex.Sync

  @requirements ["app.config"]

  @impl true
  def run(args) do
    {opts, _argv, _errors} =
      OptionParser.parse(args,
        strict: [
          limit: :integer,
          delay_ms: :integer,
          skip_sprites: :boolean,
          only: :string,
          fresh: :boolean
        ]
      )

    {:ok, _apps} = Application.ensure_all_started(:req)

    {:ok, summary} = Sync.run(opts, fn text -> Mix.shell().info(text) end)

    Mix.shell().info(
      "pronto: #{summary.updated} atualizadas nesta rodada, " <>
        "#{summary.base} na base (#{summary.shinies} shinies)" <>
        if(Map.get(summary, :filled, 0) > 0, do: ", #{summary.filled} completadas", else: "") <>
        " — priv/pokedex/pokedex.json"
    )
  end
end
