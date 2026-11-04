defmodule PolisWeb.Router do
  use PolisWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_live_flash
    plug :put_root_layout, html: {PolisWeb.Layouts, :root}
    plug PolisWeb.Locale
    plug :protect_from_forgery
    plug :put_secure_browser_headers
    plug PolisWeb.PinGate
  end

  # No accounts: the access PIN is the only door (`PolisWeb.PinGate`). The
  # machine itself is never asked; other machines are, and only when
  # POLIS_LISTEN=lan lets them reach the page at all (config/runtime.exs).
  # So one browser pipeline, with the gate in it, and one live_session, with
  # the gate on mount.
  scope "/", PolisWeb do
    pipe_through :browser
    get "/unlock", UnlockController, :show
    post "/unlock", UnlockController, :create
    get "/lang/:code", LangController, :set
    get "/jobs/:id/pdf", JobController, :pdf

    live_session :default,
      on_mount: [{PolisWeb.PinGate, :default}, {PolisWeb.Locale, :default}] do
      live "/", StationLive, :index
      live "/help", HelpLive, :index
    end
  end
end
