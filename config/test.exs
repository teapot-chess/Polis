import Config

File.mkdir_p!(Path.expand("../tmp/test/data", __DIR__))

config :polis, PolisWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4161],
  secret_key_base: "test-only-Polis-N3kQ8vR1mZ6tY0pL4sW9cH2jB7fD5gA8xE1uI6oP3yT0wX5vB2nM9kJ4hG7f",
  server: false

config :polis,
  # Phoenix's test connections ask for this host.
  extra_hosts: ["www.example.com"],
  data_dir: Path.expand("../tmp/test/data", __DIR__),
  updates_timer: false,
  autostart_links: false,
  # No launcher secret, no token file; the tests that need them start
  # their own `Polis.LauncherDetails`.
  launcher_details: false,
  install_kind: :manual,
  autostart_cmd: &Polis.NoReg.cmd/3,
  # Never a real printer. The dry run writes files; the queue tests swap in
  # a recording fake (test/support/recording_printer.ex).
  printer_backend: Polis.Printer.DryRun

config :logger, level: :warning
config :phoenix, :plug_init_mode, :runtime
config :phoenix_live_view, enable_expensive_runtime_checks: true

# A contract schema's `$ref` is a GitHub address; the tests answer it from
# the vendored copy (`Polis.Contract.resolve/1`), never from the network.
config :ex_json_schema, :remote_schema_resolver, {Polis.Contract, :resolve}
