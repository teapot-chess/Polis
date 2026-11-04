defmodule PolisWeb.UnlockController do
  @moduledoc """
  `/unlock`: where a browser that is not on this machine gives the access PIN.

  Wrong guesses are counted before the PIN is compared
  (`Polis.AccessPin.Throttle`), per address; while an address has to wait,
  even the right PIN is refused and the page says for how long. The right PIN
  puts a stamp of it in the session; changing the PIN voids the stamp.
  """

  use PolisWeb, :controller

  alias Polis.AccessPin
  alias Polis.AccessPin.Throttle

  def show(conn, _params) do
    if PolisWeb.PinGate.local_request?(conn) or AccessPin.granted?(get_session(conn, "pin_grant")) do
      redirect(conn, to: "/")
    else
      render_form(conn, nil, Throttle.peek(peer(conn)))
    end
  end

  def create(conn, params) do
    ip = peer(conn)

    case Throttle.claim(ip) do
      {:wait, seconds} ->
        conn |> put_status(429) |> render_form(nil, seconds)

      :ok ->
        if AccessPin.correct?(params["pin"]) do
          Throttle.succeeded(ip)
          let_in(conn)
        else
          conn |> put_status(403) |> render_form(gettext("That is not the PIN."), 0)
        end
    end
  end

  defp let_in(conn) do
    back = get_session(conn, "pin_return_to")

    conn
    |> configure_session(renew: true)
    |> put_session("pin_grant", AccessPin.stamp())
    # So that a change of the PIN can drop this browser's open socket.
    |> put_session("live_socket_id", AccessPin.socket_id())
    |> delete_session("pin_return_to")
    |> redirect(to: safe(back))
  end

  # Only a path of ours, never a way to somewhere else.
  defp safe("/" <> rest = path) do
    if String.starts_with?(rest, ["/", "\\"]) or path == "/unlock", do: "/", else: path
  end

  defp safe(_other), do: "/"

  defp render_form(conn, error, wait) do
    render(conn, :show, error: error, wait: wait, locale: conn.assigns.locale)
  end

  defp peer(conn), do: conn.remote_ip
end
