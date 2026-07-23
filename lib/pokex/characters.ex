defmodule Pokex.Characters do
  @moduledoc """
  Named characters, one folder each under `~/.pokex/chars/<slug>/`.

  A character folder holds that character's per-character files (team, routes…);
  `name.txt` inside it preserves the display name the slug was derived from.
  Which character is ACTIVE lives in Settings (`:active_character`, "" = none),
  so it survives restarts and follows the one-source-of-truth seed rule.

  Mirrors the Calibration profiles pattern (slug + dir + files as storage).
  """

  alias Pokex.Settings

  @name_file "name.txt"
  @topic "characters"

  def chars_dir, do: Path.join(Pokex.Home.dir(), "chars")

  @doc "Normalizes `name` to a slug (downcase, `[a-z0-9-]`). {:ok, slug} | {:error, :invalid_name}."
  def slugify(name) do
    slug =
      name
      |> to_string()
      |> String.trim()
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/u, "-")
      |> String.trim("-")

    if slug == "", do: {:error, :invalid_name}, else: {:ok, slug}
  end

  @doc "Every character, sorted by slug: %{slug, name} (name from name.txt, fallback: the slug)."
  def list do
    case File.ls(chars_dir()) do
      {:ok, entries} ->
        entries
        |> Enum.filter(&File.dir?(Path.join(chars_dir(), &1)))
        |> Enum.sort()
        |> Enum.map(&%{slug: &1, name: display_name(&1)})

      {:error, _no_dir_yet} ->
        []
    end
  end

  @doc "Creates `chars/<slug>/` keeping the original `name`. {:ok, slug} | {:error, reason}."
  def create(name) do
    with {:ok, slug} <- slugify(name) do
      if File.dir?(char_dir(slug)) do
        {:error, :already_exists}
      else
        File.mkdir_p!(char_dir(slug))
        File.write!(name_path(slug), String.trim(to_string(name)))
        {:ok, slug}
      end
    end
  end

  @doc "Renames the character (folder moves to the new slug). {:ok, new_slug} | {:error, reason}."
  def rename(slug, new_name) do
    with {:ok, new_slug} <- slugify(new_name) do
      cond do
        not File.dir?(char_dir(slug)) ->
          {:error, :not_found}

        new_slug == slug ->
          File.write!(name_path(slug), String.trim(to_string(new_name)))
          {:ok, slug}

        File.dir?(char_dir(new_slug)) ->
          {:error, :already_exists}

        true ->
          File.rename!(char_dir(slug), char_dir(new_slug))
          File.write!(name_path(new_slug), String.trim(to_string(new_name)))
          {:ok, new_slug}
      end
    end
  end

  @doc """
  Apaga o personagem — e larga o ponteiro se era ele que estava ativo.

  Sem a segunda parte, apagar o ativo deixava `:active_character` apontando pra
  uma pasta que não existe mais: o time some da tela (o arquivo dele sumiu) e as
  configurações do painel voltam pra base — sem nada dizendo por quê.
  """
  def delete(slug, server \\ Settings) do
    File.rm_rf!(char_dir(slug))
    if active(server) == slug, do: set_active("", server)
    :ok
  end

  @doc """
  Zera um ponteiro órfão: `:active_character` apontando pra pasta que não existe.

  Acontece de verdade — a pasta apagada por fora, um slug escrito à mão, uma
  build antiga. O estrago é silencioso e confuso: o `/time` mostra um time
  VAZIO em vez do seu (Lucas, 2026-07-23 — o `team.json` dele estava intacto o
  tempo todo), e o painel edita a configuração de um personagem que não existe.
  Rodado no boot, depois que o Settings sobe.
  """
  def heal_active(server \\ Settings) do
    slug = active(server)

    if slug != "" and not File.dir?(char_dir(slug)) do
      set_active("", server)
    end

    :ok
  end

  @doc "The active character's slug (\"\" = no character selected)."
  def active(server \\ Settings), do: Settings.get(:active_character, server)

  @doc "PubSub topic that announces `{:character, slug}` whenever the active one changes."
  def topic, do: @topic

  @doc """
  Switches the active character AND announces it on `topic/0`.

  The announcement lives HERE, not in the header that happens to own the picker:
  a page showing the wrong character's team is wrong no matter who flipped the
  switch. Whoever changes it, everyone hears.
  """
  def set_active(slug, server \\ Settings) do
    :ok = Settings.put(:active_character, slug, server)
    announce(slug)
    :ok
  end

  # The bot must keep running on a machine where PubSub is not up (early boot,
  # a tmp-scoped test instance): a failed announcement is not a failed switch.
  defp announce(slug) do
    Phoenix.PubSub.broadcast(Pokex.PubSub, @topic, {:character, slug})
    :ok
  catch
    _kind, _reason -> :ok
  end

  defp char_dir(slug), do: Path.join(chars_dir(), slug)
  defp name_path(slug), do: Path.join(char_dir(slug), @name_file)

  defp display_name(slug) do
    case File.read(name_path(slug)) do
      {:ok, name} ->
        case String.trim(name) do
          "" -> slug
          trimmed -> trimmed
        end

      {:error, _no_name_file} ->
        slug
    end
  end
end
