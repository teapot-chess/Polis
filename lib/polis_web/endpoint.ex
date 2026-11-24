defmodule PolisWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :polis

  @session_options [store: :cookie, key: "_polis_key", signing_salt: "c4Vn8sPq", same_site: "Lax"]

  # Before everything: a request that names a host this station does not
  # answer to (DNS rebinding) gets a 403 and nothing else. See the plug.
  plug PolisWeb.HostGuard

  socket "/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]]

  # Phoenix's and LiveView's own scripts, as their packages ship them: no
  # build step for a page this size.
  plug Plug.Static, at: "/vendor", from: {:phoenix, "priv/static"}, only: ~w(phoenix.min.js)

  plug Plug.Static,
    at: "/vendor",
    from: {:phoenix_live_view, "priv/static"},
    only: ~w(phoenix_live_view.min.js)

  # The favicon is the mark (`PolisWeb.Logo`), made from priv/logo/mark.svg,
  # so it is answered here and not read from priv/static.
  plug :favicon

  plug Plug.Static, at: "/", from: :polis, only: PolisWeb.static_paths()

  # The launcher's Details panel - this machine, a secret, no proxy header, or
  # a 404. Before anything that logs, so a panel left open does not fill the
  # log it shows. See the plug.
  plug PolisWeb.Plugs.LauncherStats

  if code_reloading? do
    socket "/phoenix/live_reload/socket", Phoenix.LiveReloader.Socket
    plug Phoenix.LiveReloader
    plug Phoenix.CodeReloader
  end

  plug Plug.RequestId
  plug Plug.Parsers, parsers: [:urlencoded], pass: ["*/*"]
  plug Plug.Head
  plug Plug.Session, @session_options
  plug PolisWeb.Router

  @doc false
  # sobelow_skip ["XSS.SendResp"]
  def favicon(%Plug.Conn{request_path: "/favicon.svg"} = conn, _opts) do
    conn
    |> Plug.Conn.put_resp_content_type("image/svg+xml")
    |> Plug.Conn.put_resp_header("cache-control", "public, max-age=3600")
    |> Plug.Conn.send_resp(200, PolisWeb.Logo.favicon())
    |> Plug.Conn.halt()
  end

  def favicon(conn, _opts), do: conn
end
