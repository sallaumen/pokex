defmodule Pokex.TestHome do
  @moduledoc """
  The home the suite is allowed to touch, and how to give it back.

  A test that needs its own home writes `Application.put_env(:pokex, :home_dir, tmp)`.
  Cleaning that up with `Application.delete_env/2` looks symmetric and is not:
  `config/test.exs` set that same key, so deleting it does not restore the test
  home — it uncovers `Pokex.Home`'s default, the REAL `~/.pokex`. Every reader
  after the first such on_exit was pointed at Lucas's live directory, and which
  test saw it was decided by the run order alone (measured 2026-08-14).

  `restore/0` puts back what the config asked for, read once at boot — before any
  test has had the chance to erase it.
  """

  @key {__MODULE__, :configured}

  @doc false
  def remember do
    :persistent_term.put(@key, Application.fetch_env!(:pokex, :home_dir))
  end

  @doc "The home config/test.exs declared."
  def path, do: :persistent_term.get(@key)

  @doc "Gives the suite's home back. The counterpart to put_env, never delete_env."
  def restore, do: Application.put_env(:pokex, :home_dir, path())
end
