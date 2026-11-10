defmodule PolisWeb.PinGate do
  @moduledoc """
  The door. Every page, the PDF of a job included, is behind the access PIN
  (`Polis.AccessPin`) for a browser that is not on this machine. Static files
  are served before the router and are not behind it.

  A request is *local* when it comes from the loopback address, to a name only
  this machine answers to, with no forwarding header on it (a proxy or tunnel
  on the box also connects from loopback, and most say so). A proxy that says
  nothing cannot be told from the machine's own browser, so `POLIS_BEHIND_PROXY=1`
  switches "local" off altogether: everybody is asked, the machine included. The machine's own
  browser is never asked, and is the only one that sees the PIN, on the
  station page. When the station listens on loopback only, which is the
  default, every request is local and nobody is ever asked.

  Two doors with one key, because there are two ways in:

    * `call/2`, a plug in the browser pipeline, for the page itself;
    * `on_mount/4`, for the LiveView socket. It sees the session the page was
      made with, so a PIN that changed after the page was made turns the
      socket away, and `Polis.AccessPin.change/1` also tells open sockets to
      go.

  The language links (`/lang/:code`) and `/unlock` itself are open: neither
  shows anything of the station.
  """

  import Plug.Conn

  @forwarding ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host)

  def init(opts), do: opts

  def call(conn, _opts) do
    local? = local_request?(conn)
    conn = put_session(conn, "pin_local", local?)

    cond do
      local? -> conn
      open_path?(conn.path_info) -> conn
      Polis.AccessPin.granted?(get_session(conn, "pin_grant")) -> conn
      true -> ask(conn)
    end
  end

  defp open_path?(["unlock"]), do: true
  defp open_path?(["lang", _code]), do: true
  defp open_path?(_other), do: false

  defp ask(conn) do
    conn =
      if conn.method == "GET",
        do: put_session(conn, "pin_return_to", conn.request_path),
        else: conn

    conn |> Phoenix.Controller.redirect(to: "/unlock") |> halt()
  end

  @doc "`on_mount` for the LiveViews."
  def on_mount(:default, _params, session, socket) do
    cond do
      session["pin_local"] == true ->
        {:cont, Phoenix.Component.assign(socket, :pin_local?, true)}

      Polis.AccessPin.granted?(session["pin_grant"]) ->
        {:cont, Phoenix.Component.assign(socket, :pin_local?, false)}

      true ->
        {:halt, Phoenix.LiveView.redirect(socket, to: "/unlock")}
    end
  end

  @doc """
  Whether a request is this machine's own browser: loopback address, a Host
  that names only this machine, no forwarding header.
  """
  def local_request?(conn) do
    not behind_proxy?() and loopback?(conn.remote_ip) and own_host?(conn.host) and
      not forwarded?(conn)
  end

  # `POLIS_BEHIND_PROXY=1`: a reverse proxy on this machine is in front, and a
  # proxy that sends no forwarding header (plain nginx) looks exactly like
  # this machine's own browser. Then nobody is local, and everybody is asked.
  defp behind_proxy?, do: Application.get_env(:polis, :behind_proxy, false)

  defp forwarded?(conn), do: Enum.any?(@forwarding, &(get_req_header(conn, &1) != []))

  @doc "Whether `host` (a Host header without its port) names this machine and nothing else."
  def own_host?(host) when is_binary(host) do
    host =
      host
      |> String.trim("[")
      |> String.trim("]")
      |> String.trim_trailing(".")
      |> String.downcase()

    host in ["localhost", "::1"] or String.ends_with?(host, ".localhost") or
      loopback_literal?(host) or host in machine_names() or
      host in Application.get_env(:polis, :local_hosts, [])
  end

  def own_host?(_host), do: false

  defp loopback_literal?(host) do
    case :inet.parse_ipv4strict_address(String.to_charlist(host)) do
      {:ok, address} -> loopback?(address)
      _not_ipv4 -> false
    end
  end

  defp machine_names do
    {:ok, name} = :inet.gethostname()
    name = name |> to_string() |> String.downcase()
    [name, name <> ".local"]
  end

  defp loopback?({127, _, _, _}), do: true
  defp loopback?({0, 0, 0, 0, 0, 0, 0, 1}), do: true
  defp loopback?({0, 0, 0, 0, 0, 65_535, 32_512, _}), do: true
  defp loopback?(_other), do: false
end
