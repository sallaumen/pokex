defmodule Mix.Tasks.Pokedex.Sync do
  @shortdoc "Syncs the Poké Alliance wiki into priv/pokedex/pokedex.json (+ sprites)"

  @moduledoc """
  Terminal wrapper around `Pokex.Pokedex.Sync` (the /pokedex "Sincronizar"
  button runs the same pipeline). Every run UPSERTS: freshly fetched entries
  replace their names in the existing pokedex.json, everything else stays.

  Deliberately does NOT boot the :pokex app (only :req) — running a sync
  from the terminal must never start the bot's workers against the real
  mouse/screen.

      mix pokedex.sync                        # full run (910 species, be nice to the wiki)
      mix pokedex.sync --only "Seadra,Horsea" # refresh just these
      mix pokedex.sync --fresh                # ignore the existing JSON (full rebuild)
      mix pokedex.sync --limit 20             # first N species (pipeline check)
      mix pokedex.sync --delay-ms 400         # slower pace
      mix pokedex.sync --skip-sprites         # JSON only
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
        if(summary.failed > 0, do: ", #{summary.failed} falharam", else: "") <>
        " — priv/pokedex/pokedex.json"
    )
  end
end
