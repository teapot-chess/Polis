defmodule PolisWeb.StationLiveTest do
  @moduledoc """
  The page: the join form joins, a link for another program is refused in
  words, the printer list offers what the printer road has and choosing
  one sticks, a job has its Reprint and its PDF, a changed round has its
  Reprint, and the help is there in both languages.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  @endpoint PolisWeb.Endpoint

  setup do
    %{conn: build_conn()}
  end

  defp printers_listed(view) do
    eventually(fn -> has_element?(view, "#printer-select option[value='Hall printer']") end)
  end

  test "the page has its parts", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#join-form")
    assert has_element?(view, "#join-link")
    assert has_element?(view, "#printer-form")
    assert has_element?(view, "#paper-select")
    assert has_element?(view, "#test-print[disabled]")
    assert has_element?(view, "#no-tournaments")
    assert has_element?(view, "#no-jobs")
    assert has_element?(view, "#head svg.logo")
  end

  test "joining from the form", %{conn: conn} do
    State.put_setting("advanced", true)
    server = FakeServer.start()
    {:ok, view, _html} = live(conn, "/")

    view |> form("#join-form", join: %{link: FakeServer.link(server)}) |> render_submit()
    eventually(fn -> has_element?(view, "#join-message.ok") end)
    [t] = State.tournaments()
    eventually(fn -> has_element?(view, "#tournament-#{t["id"]}") end)
    assert has_element?(view, "#switch-pairings-#{t["id"]}[checked]")
    assert has_element?(view, "#switch-placecards-#{t["id"]}[checked]")
    assert has_element?(view, "#copies-#{t["id"]}")
  end

  test "a link for another hall program is refused in words", %{conn: conn} do
    server = FakeServer.start()
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#join-form", join: %{link: FakeServer.link(server, "K7Q-4MD", "nunki")})
    |> render_submit()

    eventually(fn -> has_element?(view, "#join-message.error") end)
    assert render(element(view, "#join-message")) =~ "Nunki"
    assert State.tournaments() == []
  end

  test "a Manubrium link is refused, naming the app it is for", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")

    view
    |> form("#join-form", join: %{link: "manubrium://connect?secret=abc&server=https%3A%2F%2Fx"})
    |> render_submit()

    eventually(fn -> has_element?(view, "#join-message.error") end)
    assert render(element(view, "#join-message")) =~ "Manubrium"
    assert State.tournaments() == []
  end

  test "choosing a printer and the paper", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    printers_listed(view)
    assert has_element?(view, "#no-printer")

    view |> element("#printer-form") |> render_change(%{printer: "Hall printer", paper: "letter"})
    assert Station.printer() == "Hall printer"
    assert Station.paper() == :letter
    refute has_element?(view, "#test-print[disabled]")

    # A name the list did not offer is not taken.
    view
    |> element("#printer-form")
    |> render_change(%{printer: "\\\\elsewhere\\queue", paper: "a4"})

    assert Station.printer() == "Hall printer"
  end

  test "Test print, and the job's Reprint and PDF", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/")
    printers_listed(view)
    view |> element("#printer-form") |> render_change(%{printer: "Hall printer", paper: "a4"})

    view |> element("#test-print") |> render_click()
    assert_receive {:printed, %{title: "Polis test print"}}, 2_000
    [job] = Queue.jobs()
    eventually(fn -> has_element?(view, "#job-#{job.id}") end)
    assert has_element?(view, "#reprint-#{job.id}")
    assert has_element?(view, "#pdf-#{job.id}[href='/jobs/#{job.id}/pdf']")

    view |> element("#reprint-#{job.id}") |> render_click()
    assert_receive {:printed, %{title: "Polis test print"}}, 2_000

    conn = get(build_conn(), "/jobs/#{job.id}/pdf")
    assert conn.status == 200
    assert "%PDF-1.4" <> _ = conn.resp_body
    assert get(build_conn(), "/jobs/..%2F..%2Fstate.json/pdf").status == 404
  end

  test "a changed round shows its Reprint", %{conn: conn} do
    Station.choose_printer("Hall printer")

    {:ok, id} =
      State.add_tournament(%{
        "socket_url" => "ws://127.0.0.1:1/p/polis/link",
        "key" => "k",
        "server" => "fake",
        "tournament_id" => "t-1",
        "name" => "Club Open"
      })

    Station.round_received(id, FakeServer.payload(2, "r1"))
    Station.round_received(id, FakeServer.payload(2, "r2"))

    {:ok, view, _html} = live(conn, "/")
    assert has_element?(view, "#changed-#{id}")
    view |> element("#reprint-round-#{id}") |> render_click()
    refute has_element?(view, "#changed-#{id}")
  end

  test "the help, in English and in Dutch", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")
    assert has_element?(view, "#manual")
    assert render(view) =~ "What Polis is"

    conn = get(conn, "/lang/nl")
    {:ok, view, _html} = live(recycle(conn), "/help")
    assert render(view) =~ "Wat Polis is"

    {:ok, view, _html} = live(recycle(conn), "/")
    assert render(view) =~ "Aansluiten bij een toernooi"
  end

  describe "show advanced features" do
    test "off for a fresh station: the rarely used parts are not on the page", %{conn: conn} do
      server = FakeServer.start()
      {:ok, id} = Station.join(FakeServer.link(server))
      {:ok, view, _html} = live(conn, "/")

      assert has_element?(view, "#advanced")
      refute has_element?(view, "#advanced[checked]")
      assert has_element?(view, "#advanced-note")
      assert has_element?(view, "#switch-pairings-#{id}")
      refute has_element?(view, "#copies-#{id}")
      refute has_element?(view, "#update-check")
      refute has_element?(view, "#check-now")
    end

    test "the toggle shows and hides them, and the choice is kept", %{conn: conn} do
      server = FakeServer.start()
      {:ok, id} = Station.join(FakeServer.link(server))
      {:ok, view, _html} = live(conn, "/")

      view |> element("#advanced") |> render_click()
      assert has_element?(view, "#advanced[checked]")
      assert has_element?(view, "#copies-#{id}")
      assert has_element?(view, "#update-check")
      assert has_element?(view, "#check-now")
      refute has_element?(view, "#advanced-note")
      assert State.setting("advanced") == true

      view |> element("#advanced") |> render_click()
      refute has_element?(view, "#copies-#{id}")
      assert State.setting("advanced") == false
    end

    test "an explicit off is not overruled by what is set", %{conn: conn} do
      server = FakeServer.start()
      {:ok, id} = Station.join(FakeServer.link(server))
      Station.set_copies(id, 3)
      State.put_setting("advanced", false)
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#copies-#{id}")
    end

    test "an older station with copies set turns advanced on once", %{conn: conn} do
      server = FakeServer.start()
      {:ok, id} = Station.join(FakeServer.link(server))
      Station.set_copies(id, 3)
      assert State.setting("advanced") == nil

      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#advanced[checked]")
      assert has_element?(view, "#copies-#{id}")
      assert State.setting("advanced") == true
    end

    test "an older station with updates switched off turns advanced on", %{conn: conn} do
      Polis.Updates.put_mode("never")
      {:ok, view, _html} = live(conn, "/")
      assert has_element?(view, "#advanced[checked]")
      assert has_element?(view, "#update-check")
    end

    test "an older station with nothing set stays off and stores nothing", %{conn: conn} do
      server = FakeServer.start()
      {:ok, _id} = Station.join(FakeServer.link(server))
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#advanced[checked]")
      assert State.setting("advanced") == nil
    end
  end

  test "a share of the round set on a tournament counts as advanced in use" do
    server = FakeServer.start()
    {:ok, id} = Station.join(FakeServer.link(server))
    refute Polis.Advanced.in_use?()

    State.update_tournament(id, &Map.put(&1, "station", %{"boards" => "1-20"}))
    assert Polis.Advanced.in_use?()
    assert Polis.Advanced.enabled?()
    assert State.setting("advanced") == true
  end
end
