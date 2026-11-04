import Config

# Read when the application starts, in every environment, also inside a
# release.

if System.get_env("PHX_SERVER") do
  config :polis, PolisWeb.Endpoint, server: true
end

# Where everything is kept. No environment variable is required: a station
# that has to be configured before it starts is a station that does not
# print in a playing hall. `Polis.DataHome` says where an installed copy
# keeps it and why that is never a folder an installer owns.
data_dir =
  cond do
    data = System.get_env("POLIS_DATA") -> Path.expand(data)
    config_env() == :prod -> Path.expand(Polis.DataHome.default())
    true -> nil
  end

# Who may open the page: this machine (the default), or the hall's network with
# POLIS_LISTEN=lan. There is always an access PIN (<data>/access-pin, made at
# the first start, shown on the station's own page); this machine is never
# asked for it, other machines always are. See PolisWeb.PinGate.
lan? = System.get_env("POLIS_LISTEN") == "lan"
listen = if lan?, do: {0, 0, 0, 0}, else: {127, 0, 0, 1}

# `PolisWeb.HostGuard` adds this machine's names and addresses to the hosts it
# answers to only when the station was told to listen on the network.
config :polis, listen: if(lan?, do: :lan, else: :loopback)

if config_env() != :test do
  config :polis, PolisWeb.Endpoint,
    http: [ip: listen, port: String.to_integer(System.get_env("PORT", "4061"))]
end

# Which printer road: `auto` (CUPS on macOS and Linux, Windows' own on
# Windows) or `dry-run` (PDFs in <data>/dry-run, nothing printed).
case System.get_env("POLIS_PRINTER") do
  "dry-run" -> config :polis, printer_backend: Polis.Printer.DryRun
  "auto" -> config :polis, printer_backend: :auto
  _unset -> :ok
end

if data_dir do
  config :polis, data_dir: data_dir
end

if config_env() == :prod do
  data = data_dir

  # Refused before anything is written there: data inside a folder that an
  # update replaces or an uninstall removes is data with a date on it.
  if reason = Polis.DataHome.refusal(data) do
    raise Polis.DataHome.refusal_message(data, reason)
  end

  File.mkdir_p!(data)

  # The cookie-signing secret is made once and kept beside the data.
  secret_file = Path.join(data, "secret_key_base")

  secret =
    System.get_env("SECRET_KEY_BASE") ||
      case File.read(secret_file) do
        {:ok, secret} when byte_size(secret) >= 64 ->
          String.trim(secret)

        _missing ->
          secret = 48 |> :crypto.strong_rand_bytes() |> Base.encode64()
          File.write!(secret_file, secret)
          File.chmod(secret_file, 0o600)
          secret
      end

  config :polis, PolisWeb.Endpoint,
    url: [host: System.get_env("PHX_HOST") || "localhost"],
    secret_key_base: secret
end
