import Config

# Where the station keeps what it must not lose: the state file (the
# tournaments it joined, their keys, the settings) and the jobs. Overridden
# per environment and by POLIS_DATA.
config :polis, data_dir: Path.expand("../data", __DIR__)

# Whether the station asks GitHub, on a timer, if a newer version is out.
# Off in tests, which ask when they mean to.
config :polis, updates_timer: true

# Whether the joined tournaments' links are started with the application.
# Off in tests, which start what they test.
config :polis, autostart_links: true

config :polis, PolisWeb.Gettext, default_locale: "en", locales: ~w(en nl)

config :polis, PolisWeb.Endpoint,
  url: [host: "localhost"],
  # The hosts the station answers to, not "localhost" alone (a hall PC is
  # opened by its address) and not "anything" (DNS rebinding): see
  # `PolisWeb.HostGuard`.
  check_origin: {PolisWeb.HostGuard, :origin_allowed?, []},
  adapter: Bandit.PhoenixAdapter,
  # At a stop, open connections (the station page, a browser left on the
  # PDF) get three seconds to go, not Bandit's fifteen.
  http: [thousand_island_options: [shutdown_timeout: 3_000]],
  render_errors: [formats: [html: PolisWeb.ErrorHTML], layout: false],
  pubsub_server: Polis.PubSub,
  live_view: [signing_salt: "pQ2s7Lkd"]

# What never goes into a log, at any level: the join link carries a code,
# and the code is as good as a key for fifteen minutes.
config :phoenix, :filter_parameters, ["link", "key", "code", "token", "secret", "pin"]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

config :phoenix, :json_library, Jason

import_config "#{config_env()}.exs"
