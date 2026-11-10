defmodule PolisWeb.UnlockHTML do
  @moduledoc "The page of `PolisWeb.UnlockController`."

  use PolisWeb, :html

  attr :error, :string, default: nil
  attr :wait, :integer, default: 0
  attr :locale, :string, required: true

  def show(assigns) do
    ~H"""
    <Layouts.app flash={%{}} locale={@locale} page={:unlock}>
      <section id="unlock">
        <h2>{gettext("PIN")}</h2>
        <p class="note">
          {gettext("This station asks for its PIN. It is shown on the station's own screen.")}
        </p>

        <p id="unlock-headless" class="note">
          {gettext(
            "On a box without a screen it is in the file access-pin in Polis's data folder (on Linux: sudo cat /var/lib/polis/access-pin)."
          )}
        </p>

        <p :if={@error} id="unlock-error" class="error" role="alert">{@error}</p>
        <p :if={@wait > 0} id="unlock-wait" class="error" role="alert">
          {ngettext("Wait %{count} second.", "Wait %{count} seconds.", @wait)}
        </p>

        <.form for={%{}} action="/unlock" method="post" id="unlock-form">
          <input
            id="unlock-pin"
            name="pin"
            type="password"
            maxlength="64"
            autocomplete="off"
            autocapitalize="off"
            autocorrect="off"
            spellcheck="false"
            aria-label={gettext("PIN")}
            required
            autofocus
          />
          <button
            id="unlock-show"
            type="button"
            class="quiet"
            phx-click={
              Phoenix.LiveView.JS.toggle_attribute({"type", "password", "text"}, to: "#unlock-pin")
            }
          >
            {gettext("Show")}
          </button>
          <button id="unlock-submit" type="submit">{gettext("Unlock")}</button>
        </.form>
      </section>
    </Layouts.app>
    """
  end
end
