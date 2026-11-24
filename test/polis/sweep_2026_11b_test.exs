defmodule Polis.Sweep202611bTest do
  @moduledoc "The fixes of the second November sweep."

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Polis.AccessPin

  @endpoint PolisWeb.Endpoint

  defp joined do
    {:ok, id} =
      State.add_tournament(%{
        "socket_url" => "ws://127.0.0.1:1/p/polis/link",
        "key" => "k",
        "server" => "fake",
        "tournament_id" => "t-1",
        "name" => "Club Open"
      })

    id
  end

  test "Open PDF on a job that could not be laid out is a 404, and the queue lives" do
    id = joined()
    payload = FakeServer.payload(1)
    bad = %{payload | "boards" => [%{"board" => %{"x" => 1}, "white" => nil, "black" => nil}]}
    Station.round_received(id, bad)

    failed = Enum.find(Queue.jobs(), &(&1.status == :failed))
    assert failed
    queue = Process.whereis(Polis.Queue)

    assert :error = Queue.pdf(failed.id)
    assert Process.whereis(Polis.Queue) == queue

    conn = get(local_conn(), "/jobs/#{failed.id}/pdf")
    assert conn.status == 404
    assert Process.whereis(Polis.Queue) == queue
  end

  test "the queue's callers wait long enough for a big round to be laid out" do
    source = File.read!(Path.expand("../../lib/polis/queue.ex", __DIR__))
    assert source =~ "GenServer.call(__MODULE__, {:enqueue, attrs}, 30_000)"
  end

  test "this machine's page shows the PIN as it is now, after another tab changed it" do
    {:ok, view, _html} = live(local_conn(), "/")
    assert has_element?(view, "#access-pin-current", AccessPin.current())

    # Another tab, or another browser on this machine.
    :ok = AccessPin.change("changed elsewhere 7")
    send(view.pid, :refresh)
    assert has_element?(view, "#access-pin-current", "changed elsewhere 7")
  end
end
