defmodule PolisWeb.SecondJobPageTest do
  @moduledoc """
  The extra sheets on the page: the player list and the result slips are
  off by themselves and switch on for each new round; the buttons print
  them on request; the standings button appears once the server has sent
  some, and what the server sent is held, not printed.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PolisWeb.Endpoint

  setup do
    Station.choose_printer("Hall printer")

    {:ok, id} =
      State.add_tournament(%{
        "socket_url" => "ws://127.0.0.1:1/p/polis/link",
        "key" => "k",
        "server" => "fake",
        "tournament_id" => "t-1",
        "name" => "Club Open"
      })

    %{conn: build_conn(), id: id}
  end

  defp standings_frame do
    %{
      "type" => "standings",
      "tournament" => %{"id" => 1, "name" => "Club Open", "city" => "", "dates" => ""},
      "round" => 2,
      "rounds" => 7,
      "locale" => "en",
      "rating_label" => "Rtg",
      "tiebreaks" => ["Bch"],
      "rev" => "s1",
      "rows" => [
        %{
          "rank" => "1",
          "name" => "Player One",
          "title" => "",
          "rating" => 2100,
          "federation" => "BEL",
          "club" => "",
          "number" => 1,
          "score" => "2",
          "tiebreaks" => ["3"]
        }
      ]
    }
  end

  test "the two new switches are off until somebody turns them on", %{conn: conn, id: id} do
    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#switch-playerlist-#{id}[checked]")
    refute has_element?(view, "#switch-slips-#{id}[checked]")
    assert has_element?(view, "#switch-pairings-#{id}[checked]")

    view |> element("#switch-slips-#{id}") |> render_click()
    assert has_element?(view, "#switch-slips-#{id}[checked]")
    assert State.tournament(id)["print_slips"] == true
  end

  test "a new round prints the new sheets only when their switch is on", %{id: id} do
    assert :printing = Station.round_received(id, FakeServer.payload(1))
    assert_receive {:printed, _}, 3_000
    assert_receive {:printed, _}, 3_000
    refute_receive {:printed, _}, 300

    Station.set_switch(id, "print_slips", true)
    Station.set_switch(id, "print_playerlist", true)
    assert :printing = Station.round_received(id, FakeServer.payload(2))

    titles = for _ <- 1..4, do: receive_title()
    assert Enum.any?(titles, &(&1 =~ "Result slips"))
    assert Enum.any?(titles, &(&1 =~ "Player list"))
  end

  defp receive_title do
    assert_receive {:printed, %{title: title}}, 3_000
    title
  end

  test "the buttons print the player list and the slips of the round held", %{conn: conn, id: id} do
    Station.round_received(id, FakeServer.payload(2))
    assert_receive {:printed, _}, 3_000
    assert_receive {:printed, _}, 3_000

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#print-now-standings-#{id}")

    view |> element("#print-now-slips-#{id}") |> render_click()
    assert_receive {:printed, %{title: "Club Open - Result slips 2"}}, 3_000

    view |> element("#print-now-playerlist-#{id}") |> render_click()
    assert_receive {:printed, %{title: "Club Open - Player list 2"}}, 3_000
  end

  test "standings are held, not printed, and then have a button", %{conn: conn, id: id} do
    Station.round_received(id, FakeServer.payload(2))
    assert_receive {:printed, _}, 3_000
    assert_receive {:printed, _}, 3_000

    assert :kept = Station.standings_received(id, standings_frame())
    refute_receive {:printed, _}, 300

    {:ok, view, _html} = live(conn, "/")
    view |> element("#print-now-standings-#{id}") |> render_click()
    assert_receive {:printed, %{title: "Club Open - Standings 2"}}, 3_000
  end

  test "nothing held means nothing to print", %{id: id} do
    assert :nothing = Station.print_now(id, "slips")
    assert :ignored = Station.standings_received(id, %{"rows" => "not a list"})
    assert :ignored = Station.standings_received("no-such-tournament", standings_frame())
  end

  test "a print for a word it does not know, or a round it does not hold, does nothing", %{
    id: id
  } do
    Station.round_received(id, FakeServer.payload(2))
    assert_receive {:printed, _}, 3_000
    assert_receive {:printed, _}, 3_000

    assert :unknown_what = Station.print_command(id, 2, "certificates")
    assert :unknown_round = Station.print_command(id, 9, "slips")
    refute_receive {:printed, _}, 300
  end
end
