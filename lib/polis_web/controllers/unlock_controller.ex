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

  @doc """
  The address the throttle counts. Without `POLIS_BEHIND_PROXY=1` it is the
  socket's peer, headers ignored. Behind a proxy every peer is the proxy, so
  the last `X-Forwarded-For` entry (the one the proxy itself appended) is used,
  then `X-Real-IP`, then the peer when neither parses.
  """
  def peer(conn) do
    if Application.get_env(:polis, :behind_proxy, false) do
      forwarded_for(conn) || real_ip(conn) || conn.remote_ip
    else
      conn.remote_ip
    end
  end

  defp forwarded_for(conn) do
    case conn |> get_req_header("x-forwarded-for") |> List.last() do
      nil -> nil
      value -> value |> String.split(",") |> List.last() |> parse_ip()
    end
  end

  defp real_ip(conn) do
    case get_req_header(conn, "x-real-ip") do
      [value | _] -> parse_ip(value)
      [] -> nil
    end
  end

  defp parse_ip(value) do
    case :inet.parse_address(String.to_charlist(String.trim(value))) do
      {:ok, ip} -> ip
      {:error, _} -> nil
    end
  end
end
