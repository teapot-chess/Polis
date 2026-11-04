defmodule Polis.Application do
  @moduledoc false

  # The order is the order of need: the state file before anything that
  # reads it, the queue before the lines that fill it, the page last.
  # `rest_for_one`, so a state process that falls over takes down what
  # holds a stale view of it, and only that.
  #
  # Stopping goes the other way round, and every child has a deadline: no
  # supervisor waits `:infinity` for anything, so a stop is over in seconds
  # rather than when the launcher loses patience. The reaper is first so
  # that it stops last, killing any `lp` that is still thinking.

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        Polis.Cmd.Reaper,
        # The access PIN is read, or made, before the page can be asked for.
        Polis.AccessPin.Throttle,
        Polis.AccessPin.Boot,
        bounded({Phoenix.PubSub, name: Polis.PubSub}),
        bounded({Task.Supervisor, name: Polis.TaskSupervisor}),
        Polis.State,
        bounded({Registry, keys: :unique, name: Polis.LinkRegistry}),
        bounded({DynamicSupervisor, name: Polis.Links, strategy: :one_for_one}),
        Polis.Queue,
        Polis.LauncherDetails,
        {Polis.Updates.Checker, timer: Application.get_env(:polis, :updates_timer, true)}
      ] ++
        links() ++ [bounded(PolisWeb.Endpoint, 8_000)]

    Supervisor.start_link(children, strategy: :rest_for_one, name: Polis.Supervisor)
  end

  # A supervisor's own default is to wait for its children forever.
  defp bounded(spec, ms \\ 5_000), do: Supervisor.child_spec(spec, shutdown: ms)

  # The lines to the joined tournaments, started once everything they call
  # is up. A task, so a station with ten tournaments and no network does
  # not hold the page up while it finds out.
  defp links do
    if Application.get_env(:polis, :autostart_links, true) do
      [
        Supervisor.child_spec({Task, &Polis.Station.start_links/0},
          id: :start_links,
          restart: :temporary
        )
      ]
    else
      []
    end
  end

  @impl true
  def config_change(changed, _new, removed) do
    PolisWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
