defmodule PokexWeb.Layouts do
  @moduledoc """
  This module holds layouts and related functionality
  used by your application.
  """
  use PokexWeb, :html

  # Embed all files in layouts/* within this module.
  # The default root.html.heex file contains the HTML
  # skeleton of your application, namely HTML headers
  # and other static content.
  embed_templates "layouts/*"

  @doc """
  Renders the Pokex app shell: a persistent top nav (Painel / Calibração /
  Diagnóstico / Laboratorio) that wraps every page so the app is navigable from
  anywhere.

  ## Examples

      <Layouts.app flash={@flash} current_page={:panel}>
        <h1>Content</h1>
      </Layouts.app>

  """
  attr :flash, :map, required: true, doc: "the map of flash messages"

  attr :current_page, :atom,
    default: nil,
    doc: "the active nav item: :panel | :calibration | :diagnostics | :fishing_lab"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <div class="min-h-dvh bg-base-300 text-base-content">
      <header class="sticky top-0 z-40 border-b border-base-content/10 bg-base-200/90 backdrop-blur">
        <nav class="mx-auto flex h-14 max-w-3xl items-center gap-2 px-3">
          <.link navigate={~p"/"} class="flex items-center gap-2 pr-1 font-bold tracking-tight">
            <span class="grid size-7 place-items-center rounded-lg bg-primary/20 text-primary">
              <.icon name="hero-cpu-chip" class="size-4" />
            </span>
            <span class="hidden sm:inline">Pokex</span>
          </.link>

          <div class="mx-auto flex items-center gap-1">
            <.nav_link navigate={~p"/"} active={@current_page == :panel} icon="hero-play-circle">
              Painel
            </.nav_link>
            <.nav_link
              navigate={~p"/calibration"}
              active={@current_page == :calibration}
              icon="hero-viewfinder-circle"
            >
              Calibração
            </.nav_link>
            <.nav_link
              navigate={~p"/diagnostics"}
              active={@current_page == :diagnostics}
              icon="hero-beaker"
            >
              Diagnóstico
            </.nav_link>
            <.nav_link
              navigate={~p"/fishing-lab"}
              active={@current_page == :fishing_lab}
              icon="hero-sparkles"
            >
              Laboratório
            </.nav_link>
          </div>

          <.theme_toggle />
        </nav>
      </header>

      <main class="mx-auto max-w-3xl px-3 py-6">
        {render_slot(@inner_block)}
      </main>

      <.flash_group flash={@flash} />
    </div>
    """
  end

  @doc """
  A single top-nav item. Highlights when `active`, and shrinks to an icon on
  narrow widths so the three items always fit.
  """
  attr :navigate, :string, required: true
  attr :active, :boolean, default: false
  attr :icon, :string, default: nil
  slot :inner_block, required: true

  def nav_link(assigns) do
    ~H"""
    <.link
      navigate={@navigate}
      aria-current={@active && "page"}
      class={[
        "flex items-center gap-1.5 rounded-lg px-2.5 py-1.5 text-sm font-medium transition-colors",
        if(@active,
          do: "bg-primary text-primary-content",
          else: "text-base-content/70 hover:bg-base-content/10 hover:text-base-content"
        )
      ]}
    >
      <.icon :if={@icon} name={@icon} class="size-4" />
      <span class="hidden sm:inline">{render_slot(@inner_block)}</span>
    </.link>
    """
  end

  @doc """
  Shows the flash group with standard titles and content.

  ## Examples

      <.flash_group flash={@flash} />
  """
  attr :flash, :map, required: true, doc: "the map of flash messages"
  attr :id, :string, default: "flash-group", doc: "the optional id of flash container"

  def flash_group(assigns) do
    ~H"""
    <div id={@id} aria-live="polite">
      <.flash kind={:info} flash={@flash} />
      <.flash kind={:error} flash={@flash} />

      <.flash
        id="client-error"
        kind={:error}
        title={gettext("We can't find the internet")}
        phx-disconnected={
          show(".phx-client-error #client-error")
          |> JS.remove_attribute("hidden", to: ".phx-client-error #client-error")
        }
        phx-connected={hide("#client-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>

      <.flash
        id="server-error"
        kind={:error}
        title={gettext("Something went wrong!")}
        phx-disconnected={
          show(".phx-server-error #server-error")
          |> JS.remove_attribute("hidden", to: ".phx-server-error #server-error")
        }
        phx-connected={hide("#server-error") |> JS.set_attribute({"hidden", ""})}
        hidden
      >
        {gettext("Attempting to reconnect")}
        <.icon name="hero-arrow-path" class="ml-1 size-3 motion-safe:animate-spin" />
      </.flash>
    </div>
    """
  end

  @doc """
  Provides dark vs light theme toggle based on themes defined in app.css.

  See <head> in root.html.heex which applies the theme before page load.
  """
  def theme_toggle(assigns) do
    ~H"""
    <div class="card relative flex flex-row items-center border-2 border-base-300 bg-base-300 rounded-full">
      <div class="absolute w-1/3 h-full rounded-full border-1 border-base-200 bg-base-100 brightness-200 left-0 [[data-theme=light]_&]:left-1/3 [[data-theme=dark]_&]:left-2/3 [[data-theme-source=system]_&]:!left-0 transition-[left]" />

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="system"
      >
        <.icon name="hero-computer-desktop-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="light"
      >
        <.icon name="hero-sun-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>

      <button
        class="flex p-2 cursor-pointer w-1/3"
        phx-click={JS.dispatch("phx:set-theme")}
        data-phx-theme="dark"
      >
        <.icon name="hero-moon-micro" class="size-4 opacity-75 hover:opacity-100" />
      </button>
    </div>
    """
  end
end
