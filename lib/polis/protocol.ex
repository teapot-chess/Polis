defmodule Polis.Protocol do
  @moduledoc """
  The hall link, version 1, as Polis speaks it: JSON text frames over one
  WebSocket per joined tournament, each an object with a `"type"`.
  OpenPairings' `hall-link-v1` contract (vendored in
  `priv/contracts/vendor/openpairings/hall-link-v1/`) is the same thing as
  JSON Schemas, `docs/protocol.md` what Polis does with it, and the OpenPairings
  plugin (`plugins/openpairings_polis`) is the other end.

  Polis to server: `hello` (always first, with the key), `status`
  (`printer`, `last_printed_round`), `settings` (any of `name`, `room`,
  `categories`, `boards`: a change the station's page asked for), `leave`.

  Server to Polis: `welcome`, `standings` (held until a `print` asks for them), `settings` (`name`, `room`, `categories`,
  `boards`, `categories_available`, and `error` when a change was turned
  down), `refused` (`version`, `key`, `revoked`), `round` (the round
  payload), `leave`, and `print` (`round`, `what`: `pairings`,
  `placecards`, `both`, `standings`, `playerlist` or `slips`).
  """

  @version 1
  @product "polis"

  def version, do: @version
  def product, do: @product

  def encode(%{"type" => _} = frame), do: Jason.encode!(frame)

  @doc "`{:ok, frame}` for a JSON object with a type, `{:error, :bad_frame}` otherwise."
  def decode(text) do
    case Jason.decode(text) do
      {:ok, %{"type" => type} = frame} when is_binary(type) -> {:ok, frame}
      _other -> {:error, :bad_frame}
    end
  end

  def hello(device, key, name, software),
    do: %{
      "type" => "hello",
      "v" => @version,
      "device" => device,
      "key" => key,
      "name" => name,
      "software" => software
    }

  def status(fields) when is_map(fields), do: Map.put(fields, "type", "status")
  def leave, do: %{"type" => "leave"}

  @doc "A change to the station's name, room or filters, for the server to keep."
  def settings(fields) when is_map(fields),
    do: fields |> Map.take(~w(name room categories boards)) |> Map.put("type", "settings")

  @doc "What this program calls itself on the wire: `polis 0.1.0`."
  def software, do: "polis " <> to_string(Application.spec(:polis, :vsn))
end
