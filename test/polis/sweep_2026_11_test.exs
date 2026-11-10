defmodule Polis.Sweep202611Test do
  @moduledoc "The fixes of the 2026-11 sweep that have no better home."

  use Polis.StationCase, async: false

  alias Polis.{AccessPin, Layout}
  alias Polis.AccessPin.Boot

  @root Path.expand("../..", __DIR__)

  defp read(path), do: File.read!(Path.join(@root, path))

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

  describe "the access PIN file" do
    test "a PIN from a CRLF editor is the PIN" do
      File.write!(AccessPin.path(), "246810\r\n")
      AccessPin.forget()
      assert :ignore = Boot.start_link([])
      assert AccessPin.current() == "246810"
    end

    test "an unusable file is kept aside, not written over" do
      File.write!(AccessPin.path(), "12\n")
      AccessPin.forget()
      assert :ignore = Boot.start_link([])
      assert AccessPin.current() =~ ~r/\A\d{6}\z/
      assert File.read!(AccessPin.path() <> ".invalid") == "12\n"
    end
  end

  test "a PIN is not written to the log, whatever the level" do
    assert read("config/config.exs") =~ ~s("secret", "pin")
  end

  describe "the Linux scripts" do
    test "no longer say there is no PIN, and show where it is" do
      install = read("rel/linux/install.sh")
      refute install =~ "no PIN"
      refute install =~ "There is no PIN"
      assert install =~ "Access PIN:"
      assert install =~ "access-pin"
      assert read("README.md") =~ "sudo cat /var/lib/polis/access-pin"
    end

    test "the updater follows no symlink the service user could have planted" do
      update = read("rel/linux/update.sh")
      assert update =~ ~s([ ! -L "$DATA_DIR/state.json" ])
      assert update =~ ~s([ -L "$DATA_DIR/backups" ])
      assert update =~ ~s([ ! -L "$REQUEST_FILE" ])
      assert update =~ "--no-dereference"
      assert update =~ "chown -R -h"
    end
  end

  describe "a round the layout cannot take" do
    # A payload whose board label is a map: the layout calls to_string on it.
    defp bad_round(round) do
      payload = FakeServer.payload(round)
      %{payload | "boards" => [%{"board" => %{"x" => 1}, "white" => nil, "black" => nil}]}
    end

    test "is a failed job in the list, and the queue lives to take the next" do
      Station.choose_printer("Hall printer")
      id = joined()
      queue = Process.whereis(Polis.Queue)

      assert :printing = Station.round_received(id, bad_round(1))
      assert Process.whereis(Polis.Queue) == queue
      assert Enum.any?(Queue.jobs(), &(&1.status == :failed and &1.error =~ "laid out"))

      # And the station still prints what is sane.
      assert :printing = Station.round_received(id, FakeServer.payload(2))
      assert_receive {:printed, _}, 2_000
    end
  end

  test "a queue that is not there does not make the round 'handled'" do
    id = joined()
    Supervisor.terminate_child(Polis.Supervisor, Polis.Queue)

    try do
      assert :kept = Station.round_received(id, FakeServer.payload(1))
      refute Map.has_key?(State.tournament(id)["printed"] || %{}, "1")
    after
      Supervisor.restart_child(Polis.Supervisor, Polis.Queue)
    end
  end

  test "sheets nobody has seen are not pruned away" do
    id = joined()
    # No printer: everything waits.
    for round <- 1..30, do: Station.round_received(id, FakeServer.payload(round))
    jobs = Queue.jobs()
    assert length(jobs) > 50
    assert Enum.all?(jobs, &(&1.status == :waiting_printer))
  end

  test "place cards for a round with nobody seated is a page, not a document of none" do
    payload = %{FakeServer.payload(1) | "boards" => []}
    doc = Layout.place_cards(payload, :a4)
    assert [_one_page] = doc.pages
  end

  test "Link.info reads what the line published, and does not wait for a line that is busy" do
    me = self()

    {:ok, busy} =
      Task.start_link(fn ->
        {:ok, _} = Registry.register(Polis.LinkRegistry, "busy-line", %{up?: true, error: nil})
        send(me, :registered)
        # Not in a receive: a line stuck in its connect answers nobody.
        Process.sleep(:infinity)
      end)

    assert_receive :registered, 2_000
    {micros, info} = :timer.tc(fn -> Polis.Link.info("busy-line") end)
    assert info == %{up?: true, error: nil}
    assert micros < 500_000
    assert %{up?: false, error: nil} = Polis.Link.info("no-such-line")
    Process.unlink(busy)
    Process.exit(busy, :kill)
  end
end
