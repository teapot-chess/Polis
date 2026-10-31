defmodule Polis.Contracts.HallLinkTest do
  @moduledoc """
  OpenPairings' `hall-link-v1` (vendored), from the station's side.

  Every pairing link the contract has an example of goes through the
  station's link reader; the join answers it has examples of are served,
  as they are, to `Polis.Join.redeem/3`; every frame the station sends on
  a real line (to `Polis.FakeServer`) is checked against the device
  schemas; and the server's example frames are pushed down that line and
  must do what they say. The stand-in server's own join answer and welcome
  are held to the schemas too: a fake that drifts proves nothing.
  """

  use Polis.StationCase, async: false

  alias Polis.{Contract, Join, Link}

  @identity %{"v" => 1, "device" => "d-1", "name" => "Hall PC", "software" => "polis 0.5.0"}

  describe "pairing links" do
    test "a Polis link gives its server and code; another app's is refused by name" do
      examples = Contract.examples("pairing-link")
      assert Enum.any?(examples, fn {_, e} -> e["app"] == "polis" end)
      assert Enum.any?(examples, fn {_, e} -> e["app"] != "polis" end)

      for {name, example} <- examples do
        case example["app"] do
          "polis" ->
            assert {:ok, %{"server" => server, "code" => code}} = Join.pairing(example["link"]),
                   name

            assert server == example["server"], name
            assert code == example["code"], name

          other ->
            assert {:error, {:wrong_product, ^other}} = Join.parse(example["link"]), name
        end
      end
    end
  end

  describe "joining" do
    defp serve(status, body) do
      plug = fn conn ->
        {:ok, raw, conn} = Plug.Conn.read_body(conn)
        send(self_pid(conn), {:join_request, Jason.decode!(raw)})

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(status, Jason.encode!(body))
      end

      [plug: plug]
    end

    # The plug runs in the test process (Req's plug adapter), so self() is
    # the test.
    defp self_pid(_conn), do: self()

    test "the join request fits; every 200 example joins" do
      for {name, answer} <- Contract.examples("join-response") do
        link = "https://pairings.cloud/p/polis/join/" <> String.duplicate("A", 43)
        assert {:ok, attrs} = Join.redeem(link, @identity, serve(200, answer)), name
        assert_received {:join_request, request}
        Contract.assert_valid!("join-request", request)

        assert attrs["key"] == answer["key"]
        assert attrs["tournament_id"] == answer["tournament"]["id"]
        assert attrs["socket_url"] == "wss://pairings.cloud" <> answer["socket"]
      end
    end

    test "every refusal example is read by its status" do
      expected = %{
        400 => :not_a_server,
        404 => :used_or_expired,
        410 => :used_or_expired,
        409 => :version,
        429 => :not_a_server
      }

      status_of = %{
        "bad_request" => 400,
        "too_large" => 400,
        "unknown_code" => 404,
        "used" => 410,
        "expired" => 410,
        "version" => 409,
        "too_many_attempts" => 429
      }

      for {name, answer} <- Contract.examples("join-error") do
        status = Map.fetch!(status_of, answer["error"])
        link = "https://pairings.cloud/p/polis/join/k3m9q2x7v4w8z6y5"

        assert {:error, expected[status]} == Join.redeem(link, @identity, serve(status, answer)),
               name
      end
    end
  end

  describe "the line" do
    setup do
      server = FakeServer.start()
      Station.choose_printer("Hall printer")
      {:ok, id} = Station.join(FakeServer.link(server))
      eventually(fn -> Link.info(id).up? end)
      %{server: server, id: id}
    end

    test "the stand-in server speaks the contract", %{server: server} do
      Contract.assert_valid!("join-request", FakeServer.get(server, :identity))

      Contract.assert_valid!("join-response", %{
        "key" => FakeServer.get(server, :key),
        "socket" => "/p/polis/link",
        "server" => "fake",
        "tournament" => FakeServer.get(server, :tournament)
      })
    end

    test "every frame the station sends fits its schema", %{server: server, id: id} do
      FakeServer.set(server, :settings, FakeServer.settings(%{"rooms_available" => ["Annex"]}))
      Station.restart_link(id)
      eventually(fn -> Link.info(id).up? end)

      :ok = Link.send_settings(id, %{"name" => "Bar printer", "boards" => "1-10"})
      :ok = Link.send_settings(id, %{"room" => "Annex", "categories" => ["U12"]})
      eventually(fn -> length(FakeServer.settings_sent(server)) == 2 end)

      Station.remove(id)
      eventually(fn -> FakeServer.get(server, :left?) end)

      frames = FakeServer.received(server)
      types = frames |> Enum.map(& &1["type"]) |> Enum.uniq() |> Enum.sort()
      assert types == ~w(hello leave settings status)

      for frame <- frames do
        schema =
          case frame["type"] do
            "hello" -> "device-hello"
            "status" -> "device-status-polis"
            "settings" -> "device-settings-polis"
            "leave" -> "device-leave"
          end

        Contract.assert_valid!(schema, frame)
      end
    end

    test "a round, its selection variant and print do what they say", %{server: server} do
      FakeServer.push(server, Contract.example("server-round"))
      assert_receive {:printed, %{title: "Open Brugge - " <> _}}, 3_000
      assert_receive {:printed, _}, 3_000

      # "both": the pairings and the place cards again.
      FakeServer.push(server, Contract.example("server-print"))
      assert_receive {:printed, %{title: "Open Brugge - " <> _}}, 3_000
      assert_receive {:printed, %{title: "Open Brugge - " <> _}}, 3_000

      # The same round with another rev (a share of it): changed, not printed by itself.
      FakeServer.push(server, Contract.example("server-round.polis-selection"))
      refute_receive {:printed, _}, 500
    end

    test "settings are kept as the server says", %{server: server, id: id} do
      for {_name, frame} <- Contract.examples("server-settings-polis") do
        FakeServer.push(server, frame)
      end

      FakeServer.push(server, Contract.example("server-settings-polis"))

      eventually(fn ->
        match?(%{"name" => "Main hall printer"}, State.tournament(id)["station"])
      end)
    end

    test "refused for a key: said, and the tournament kept", %{server: server, id: id} do
      FakeServer.push(server, Contract.example("server-refused"))
      eventually(fn -> Link.info(id).error == {:refused, "key"} end)
      assert [_] = State.tournaments()
    end

    test "refused as revoked: forgotten", %{server: server} do
      FakeServer.push(server, Contract.example("server-refused.revoked"))
      eventually(fn -> State.tournaments() == [] end)
    end

    test "leave: forgotten", %{server: server} do
      FakeServer.push(server, Contract.example("server-leave"))
      eventually(fn -> State.tournaments() == [] end)
    end

    test "welcome and pong are taken without a fuss", %{server: server, id: id} do
      FakeServer.push(server, Contract.example("server-welcome"))
      FakeServer.push(server, Contract.example("server-pong"))
      eventually(fn -> State.tournament(id)["name"] == "Open Brugge" end)
      assert Link.info(id).up?
    end
  end
end
