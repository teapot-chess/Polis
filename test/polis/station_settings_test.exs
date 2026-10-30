defmodule Polis.StationSettingsTest do
  @moduledoc """
  The station's name, room and share of the round, over the line and on
  the page: what the server says is kept and shown, a change goes to the
  server and what it keeps comes back, the form waits while the line is
  down, and a round with nothing for this station prints nothing.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Polis.{BoardRanges, Link, Queue}

  @endpoint PolisWeb.Endpoint

  setup do
    server = FakeServer.start()
    FakeServer.set(server, :settings, FakeServer.settings())
    State.put_setting("advanced", true)
    Station.choose_printer("Hall printer")
    {:ok, id} = Station.join(FakeServer.link(server))
    eventually(fn -> Link.info(id).up? end)
    %{server: server, id: id, conn: build_conn()}
  end

  test "the board-number reader agrees with the server's" do
    assert {:ok, [{1, 20}, {35, 35}, {40, 45}]} = BoardRanges.parse("40-45, 1 - 20; 35")
    assert {:error, {:backwards, "9-3"}} = BoardRanges.parse("9-3")
  end

  test "the server's word after welcome is kept per tournament", %{id: id} do
    eventually(fn -> State.tournament(id)["station"] end)

    assert %{"name" => "Hall PC", "room" => "", "categories_available" => ["U12", "Women"]} =
             State.tournament(id)["station"]
  end

  test "a change goes to the server, and what it keeps comes back", %{server: server, id: id} do
    eventually(fn -> State.tournament(id)["station"] end)

    change = %{"name" => " Door ", "room" => "Annex", "categories" => ["", "U12"]}

    # Board numbers that do not read never leave the station.
    assert {:error, {:boards, {:backwards, "20-1"}}} =
             Station.change_settings(id, Map.put(change, "boards", "20-1"))

    assert FakeServer.settings_sent(server) == []

    assert :ok = Station.change_settings(id, Map.put(change, "boards", "1-5, 3-10"))

    eventually(fn -> FakeServer.settings_sent(server) != [] end)

    assert [%{"name" => "Door", "room" => "Annex", "categories" => ["U12"], "boards" => "1-10"}] =
             FakeServer.settings_sent(server)

    eventually(fn -> State.tournament(id)["station"]["room"] == "Annex" end)
    assert State.tournament(id)["station"]["boards"] == "1-10"
  end

  test "a rename in OpenPairings shows here at the next push", %{server: server, id: id} do
    FakeServer.push(
      server,
      Map.put(FakeServer.settings(%{"name" => "Renamed"}), "type", "settings")
    )

    eventually(fn -> State.tournament(id)["station"]["name"] == "Renamed" end)
  end

  test "a turned-down change is said, and nothing else changes", %{id: id} do
    eventually(fn -> State.tournament(id)["station"] end)
    :ok = Link.send_settings(id, %{"boards" => "bad"})
    eventually(fn -> State.tournament(id)["station"]["error"] == "boards" end)
    assert State.tournament(id)["station"]["boards"] == ""
  end

  test "rooms_available is kept when the server sends it, and absent when it does not", %{
    server: server,
    id: id
  } do
    eventually(fn -> State.tournament(id)["station"] end)
    refute Map.has_key?(State.tournament(id)["station"], "rooms_available")

    push_rooms(server, ["Hall A", "Annex"])

    eventually(fn ->
      State.tournament(id)["station"]["rooms_available"] == ["Hall A", "Annex"]
    end)
  end

  test "a room the server does not know is turned down; a known one is kept as the server spells it",
       %{server: server, id: id} do
    push_rooms(server, ["Hall A", "Annex"])
    eventually(fn -> State.tournament(id)["station"]["rooms_available"] end)

    :ok = Link.send_settings(id, %{"room" => "Nowhere"})
    eventually(fn -> State.tournament(id)["station"]["error"] == "room" end)
    assert State.tournament(id)["station"]["room"] == ""

    :ok = Link.send_settings(id, %{"room" => " annex "})
    eventually(fn -> State.tournament(id)["station"]["room"] == "Annex" end)
    assert State.tournament(id)["station"]["error"] == nil
  end

  test "a share with no board in this round prints nothing", %{server: server, id: id} do
    payload =
      FakeServer.payload(2)
      |> Map.put("boards", [])
      |> Map.put("selection", %{"room" => "B", "boards" => "40-60", "categories" => []})

    FakeServer.push(server, %{"type" => "round", "round" => payload})
    eventually(fn -> State.tournament(id)["last_round"] == 2 end)
    refute_receive {:printed, _}, 300
    assert Queue.jobs() == []
  end

  test "a share prints, and the sheet says which part it is", %{server: server} do
    payload =
      FakeServer.payload(3)
      |> Map.put("selection", %{"room" => "Room B", "boards" => "1-3", "categories" => ["U12"]})

    FakeServer.push(server, %{"type" => "round", "round" => payload})
    assert_receive {:printed, %{title: "Club Open - Pairings 3"}}, 3_000

    doc = Polis.Layout.pairings(payload)
    texts = for page <- doc.pages, {:text, _, _, _, _, text, _} <- page, do: text
    assert Enum.any?(texts, &(&1 =~ "Room B" and &1 =~ "1-3" and &1 =~ "U12"))
  end

  describe "the page" do
    test "shows the station's name, room and share, and saves a change", %{
      conn: conn,
      server: server,
      id: id
    } do
      eventually(fn -> State.tournament(id)["station"] end)
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#station-#{id}", "Hall PC")
      assert has_element?(view, "#station-cat-#{id}-1[value='Women']")

      view
      |> form("#station-form-#{id}", %{"boards" => "35, 1-20"})
      |> render_change()

      assert has_element?(view, "#station-boards-parsed-#{id}", "1-20, 35")

      view
      |> form("#station-form-#{id}", %{"boards" => "x"})
      |> render_change()

      assert has_element?(view, "#station-boards-parsed-#{id}.error")

      view
      |> form("#station-form-#{id}", %{
        "name" => "Door",
        "room" => "Annex",
        "boards" => "1-20",
        "categories" => ["", "Women"]
      })
      |> render_submit()

      eventually(fn -> FakeServer.settings_sent(server) != [] end)
      eventually(fn -> render(view) =~ "Annex" end)
      assert has_element?(view, "#station-note-#{id}.ok")
    end

    test "offers a room picker when the server knows rooms", %{conn: conn, server: server, id: id} do
      push_rooms(server, ["Hall A", "Annex"], %{"room" => "Annex"})
      eventually(fn -> State.tournament(id)["station"]["rooms_available"] end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "select#station-room-#{id}")
      assert has_element?(view, "select#station-room-#{id} option[value='']")
      assert has_element?(view, "select#station-room-#{id} option[value='Hall A']")
      assert has_element?(view, "select#station-room-#{id} option[value='Annex'][selected]")
      refute has_element?(view, "#station-room-stray-#{id}")
      refute has_element?(view, "#station-rooms-none-#{id}")
    end

    test "a tournament without rooms gets the picker with no room and a hint", %{
      conn: conn,
      server: server,
      id: id
    } do
      push_rooms(server, [])
      eventually(fn -> State.tournament(id)["station"]["rooms_available"] == [] end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "select#station-room-#{id}")
      assert has_element?(view, "#station-rooms-none-#{id}")
    end

    test "legacy free text is shown as an option that filters nothing", %{
      conn: conn,
      server: server,
      id: id
    } do
      push_rooms(server, ["Hall A"], %{"room" => "Old label"})
      eventually(fn -> State.tournament(id)["station"]["rooms_available"] end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "select#station-room-#{id} option[value='Old label'][selected]")
      assert has_element?(view, "#station-room-stray-#{id}")
    end

    test "an older server keeps the free-text room field", %{conn: conn, id: id} do
      eventually(fn -> State.tournament(id)["station"] end)
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "input#station-room-#{id}[type=text]")
      refute has_element?(view, "select#station-room-#{id}")
    end

    test "a refused room is said", %{conn: conn, server: server, id: id} do
      push_rooms(server, ["Hall A"])
      eventually(fn -> State.tournament(id)["station"]["rooms_available"] end)
      {:ok, view, _html} = live(conn, "/")

      :ok = Link.send_settings(id, %{"room" => "Nowhere"})
      eventually(fn -> has_element?(view, "#station-room-refused-#{id}") end)
    end

    test "waits while the line is down", %{conn: conn, server: server, id: id} do
      eventually(fn -> State.tournament(id)["station"] end)
      FakeServer.down(server)
      eventually(fn -> not Link.info(id).up? end)

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#station-down-#{id}")
      assert has_element?(view, "#station-form-#{id} fieldset[disabled]")
      assert {:error, :down} = Station.change_settings(id, %{"room" => "X"})
    end
  end

  defp push_rooms(server, rooms, fields \\ %{}) do
    settings = FakeServer.settings(Map.put(fields, "rooms_available", rooms))
    FakeServer.set(server, :settings, settings)
    FakeServer.push(server, Map.put(settings, "type", "settings"))
  end
end
