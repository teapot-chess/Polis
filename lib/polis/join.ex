defmodule Polis.Join do
  @moduledoc """
  Joining a tournament: the whole of it is one link.

  In OpenPairings, the plugin page of a tournament makes a link -
  `https://<server>/p/polis/join/<code>`, good for fifteen minutes and for
  one station - shown as text and as a QR code. The station is given that
  link (pasted into its page) and does the rest: it POSTs to the very same
  address who it is, and the answer is its own long key, where the link's
  socket is, what the server is called and which tournament this is. The
  key is stored in the state file and never shown. Nobody types an
  address; nobody sees a key.

  Any prefix before `/p/` is accepted, so an OpenPairings that lives under
  a sub-path works. A link for another hall app - the announcer's
  (`/p/nunki/...`) or the Manubrium phone app's (`manubrium://connect?...`)
  - is refused in words, naming the app, before anything is sent: the code
  stays unspent for the app it was made for.

  The link, the code in it (43 base64url characters, or 16 base32 from
  before the codes were unified - both read) and the answers are
  OpenPairings' `hall-link-v1` contract, vendored in
  `priv/contracts/vendor/openpairings/hall-link-v1/`.
  """

  alias Polis.Protocol

  @doc """
  `{:ok, attrs}` - what `Polis.State.add_tournament/1` takes - or
  `{:error, reason}`: `:not_a_link`, `{:wrong_product, name}`,
  `:used_or_expired`, `:version`, `:not_a_server`, `:unreachable`.
  """
  def redeem(link, identity, req_options \\ []) do
    with {:ok, uri} <- parse(link) do
      url = URI.to_string(%{uri | query: nil, fragment: nil})

      options =
        Keyword.merge(
          [
            json: identity,
            retry: false,
            receive_timeout: 15_000,
            connect_options: [timeout: 10_000]
          ],
          req_options
        )

      case Req.post(url, options) do
        {:ok,
         %{
           status: 200,
           body: %{"key" => key, "socket" => socket, "tournament" => %{"id" => tid} = t} = body
         }}
        when is_binary(key) and is_binary(socket) ->
          {:ok,
           %{
             "socket_url" => socket_url(uri, socket),
             "key" => key,
             "server" => body["server"] || uri.host,
             "tournament_id" => tid,
             "name" => t["name"] || ""
           }}

        {:ok, %{status: status}} when status in [404, 410] ->
          {:error, :used_or_expired}

        {:ok, %{status: 409}} ->
          {:error, :version}

        {:ok, _other} ->
          {:error, :not_a_server}

        {:error, _exception} ->
          {:error, :unreachable}
      end
    end
  end

  @doc "The join link's parts, `{:error, :not_a_link}` or `{:error, {:wrong_product, id}}`."
  def parse(link) when is_binary(link) do
    if String.starts_with?(String.downcase(String.trim(link)), "manubrium:"),
      do: {:error, {:wrong_product, "manubrium"}},
      else: parse_http(link)
  end

  def parse(_other), do: {:error, :not_a_link}

  defp parse_http(link) do
    with {:ok, %URI{scheme: scheme, host: host, path: path} = uri}
         when scheme in ["http", "https"] and is_binary(host) and host != "" and is_binary(path) <-
           URI.new(String.trim(link)),
         [_, product, code] <- Regex.run(~r{/p/([a-z0-9_-]+)/join/([^/]+)/?$}, path) do
      cond do
        code == "" -> {:error, :not_a_link}
        product == Protocol.product() -> {:ok, uri}
        true -> {:error, {:wrong_product, product}}
      end
    else
      _other -> {:error, :not_a_link}
    end
  end

  @doc """
  What a pairing link means to a print station, as the contract's
  `pairing-link` examples spell it: `{:ok, %{"server" => base url, "code" => code}}`
  for a Polis link - the base URL being everything before `/p/polis/join/`
  - or the error `parse/1` gives.
  """
  def pairing(link) do
    with {:ok, uri} <- parse(link) do
      [_, prefix, code] = Regex.run(~r{^(.*)/p/[a-z0-9_-]+/join/([^/]+)/?$}, uri.path)
      path = if prefix == "", do: nil, else: prefix
      server = URI.to_string(%URI{scheme: uri.scheme, host: uri.host, port: uri.port, path: path})
      {:ok, %{"server" => server, "code" => code}}
    end
  end

  # Where the socket is: the same host and port as the join link, ws for
  # http, wss for https. The path comes from the server (absolute), so a
  # sub-path is the server's to include.
  defp socket_url(uri, path) do
    scheme = if uri.scheme == "https", do: "wss", else: "ws"
    URI.to_string(%URI{scheme: scheme, host: uri.host, port: uri.port, path: path})
  end
end
