defmodule PolisWeb.Layouts do
  @moduledoc """
  The frame of both pages: the root document, and `app/1` - the header with
  the mark, the flash, the content, and the foot with the help link and the
  language.
  """

  use PolisWeb, :html

  def root(assigns) do
    ~H"""
    <!DOCTYPE html>
    <html lang={assigns[:locale] || "en"}>
      <head>
        <meta charset="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <meta name="csrf-token" content={Phoenix.Controller.get_csrf_token()} />
        <title>Polis</title>
        <link rel="icon" type="image/svg+xml" href="/favicon.svg" />
        <link rel="stylesheet" href="/app.css" />
        <script defer src="/vendor/phoenix.min.js">
        </script>
        <script defer src="/vendor/phoenix_live_view.min.js">
        </script>
        <script defer src="/app.js">
        </script>
      </head>
      <body>
        {@inner_content}
      </body>
    </html>
    """
  end

  attr :flash, :map, required: true
  attr :locale, :string, required: true
  attr :page, :atom, values: [:station, :help, :unlock], required: true
  attr :subtitle, :string, default: nil

  attr :notice, :map,
    default: nil,
    doc: "`Polis.Updates.notice/0`; the station page has its own, larger section"

  slot :inner_block, required: true

  def app(assigns) do
    ~H"""
    <main id={"page-#{@page}"}>
      <header id="head">
        <h1>
          <.logo /> Polis <span :if={@subtitle} class="name">{@subtitle}</span>
        </h1>
        <p class="note">{gettext("Prints the pairings and the place cards of every new round.")}</p>
      </header>
      <p :if={@notice && @page != :station} id="update-banner" class="banner" role="status">
        {gettext("Polis %{version} is out.", version: @notice.version)}
        <a id="update-banner-station" href="/#update">{gettext("Install it on the station page")}</a>
      </p>
      <.flash_group flash={@flash} />
      {render_slot(@inner_block)}
      <footer id="foot" class="foot">
        <a :if={@page == :station} id="help-link" href="/help">{gettext("Help")}</a>
        <a :if={@page == :help} id="back-link" href="/">{gettext("Back to the station")}</a>
        <span class="note">{gettext("Language")}:</span>
        <a id="lang-en" href="/lang/en" aria-current={to_string(@locale == "en")}>EN</a>
        <a id="lang-nl" href="/lang/nl" aria-current={to_string(@locale == "nl")}>NL</a>
      </footer>
    </main>
    """
  end

  attr :flash, :map, required: true

  def flash_group(assigns) do
    ~H"""
    <div id="flash-group" aria-live="polite">
      <p
        :for={kind <- [:info, :error]}
        :if={msg = Phoenix.Flash.get(@flash, kind)}
        id={"flash-#{kind}"}
        class={["flash", if(kind == :info, do: "ok", else: "error")]}
        phx-click={Phoenix.LiveView.JS.push("lv:clear-flash", value: %{key: kind})}
      >
        {msg}
      </p>
    </div>
    """
  end
end
