defmodule Polis.StationCase do
  @moduledoc """
  For the tests that use the running station - the state file, the queue,
  the lines: each starts from an empty data folder, with the recording
  printer instead of any real one, and leaves the dry run behind it.

  Not async: there is one station per BEAM, as there is one per hall.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      import Polis.StationCase
      alias Polis.{FakeServer, Queue, RecordingPrinter, State, Station}
    end
  end

  setup do
    reset!()
    Polis.RecordingPrinter.install()
    on_exit(&Polis.RecordingPrinter.uninstall/0)
    :ok
  end

  @doc "Every line stopped, the queue and the state started again on an empty folder."
  def reset! do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(Polis.Links),
        do: DynamicSupervisor.terminate_child(Polis.Links, pid)

    # A print from the test before, still under way, would write into the
    # folder while it goes.
    for pid <- Task.Supervisor.children(Polis.TaskSupervisor),
        do: Task.Supervisor.terminate_child(Polis.TaskSupervisor, pid)

    :ok = Supervisor.terminate_child(Polis.Supervisor, Polis.Queue)
    :ok = Supervisor.terminate_child(Polis.Supervisor, Polis.State)

    data = Application.fetch_env!(:polis, :data_dir)
    File.rm_rf!(data)
    File.mkdir_p!(data)

    # The folder was emptied, the PIN with it: made again, as at a start.
    Polis.AccessPin.forget()
    Polis.AccessPin.boot()
    Polis.AccessPin.Throttle.reset()

    {:ok, _} = Supervisor.restart_child(Polis.Supervisor, Polis.State)
    {:ok, _} = Supervisor.restart_child(Polis.Supervisor, Polis.Queue)
    :ok
  end

  @doc "A request from this machine itself: never asked for the PIN."
  def local_conn do
    Phoenix.ConnTest.build_conn() |> Map.put(:host, "localhost")
  end

  @doc "A request from another machine on the hall network, to the host the test connections use."
  def remote_conn(ip \\ {192, 168, 1, 50}) do
    Phoenix.ConnTest.build_conn() |> Map.put(:remote_ip, ip)
  end

  @doc "Waits, up to `timeout` ms, for `fun` to return something truthy; returns it."
  def eventually(fun, timeout \\ 3_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    loop(fun, deadline)
  end

  defp loop(fun, deadline) do
    case fun.() do
      result when result not in [nil, false] ->
        result

      _no ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("the condition did not come true in time")
        else
          receive do
          after
            20 -> loop(fun, deadline)
          end
        end
    end
  end
end
