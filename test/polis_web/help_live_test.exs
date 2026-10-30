defmodule PolisWeb.HelpLiveTest do
  @moduledoc """
  The help at /help, in both languages and with every section; the update
  banner that follows the visitor there; and the second yes an update needs
  while a sheet is coming out of the printer.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Polis.{FakeReleases, Updates}

  @endpoint PolisWeb.Endpoint

  @sections ~w(help-what help-join help-printer help-what-prints help-share help-queue help-update help-advanced help-data help-trouble)

  setup do
    start_supervised!(FakeReleases)
    FakeReleases.install()

    on_exit(fn ->
      FakeReleases.uninstall()
      Application.put_env(:polis, :install_kind, :manual)
      Application.delete_env(:polis, :updates_stop_fun)
      Application.delete_env(:polis, :printer_backend)
      Updates.Checker.forget()
    end)

    %{conn: build_conn()}
  end

  defp newer do
    v = Version.parse!(Updates.current_version())
    "#{v.major}.#{v.minor + 1}.0"
  end

  defp heard_of_newer do
    FakeReleases.publish(newer())
    {:ok, info, _} = Updates.check()
    Updates.Checker.put(info)
  end

  test "every section, in English and in Dutch, with the way back", %{conn: conn} do
    {:ok, view, html} = live(conn, "/help")
    assert html =~ ~s(lang="en")
    assert has_element?(view, "#manual")
    for id <- @sections, do: assert(has_element?(view, "##{id}"))
    assert has_element?(view, "#back-link[href='/']")
    assert has_element?(view, "#head svg.logo")

    conn = get(conn, "/lang/nl")
    {:ok, view, html} = live(recycle(conn), "/help")
    assert html =~ ~s(lang="nl")
    for id <- @sections, do: assert(has_element?(view, "##{id}"))
    assert has_element?(view, "#help-join h2", "Aansluiten bij een toernooi")
  end

  test "no banner when there is nothing newer", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")
    refute has_element?(view, "#update-banner")
  end

  test "a newer version is announced on the help page too, and sent to the station page",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/help")
    refute has_element?(view, "#update-banner")

    heard_of_newer()
    Updates.broadcast()

    assert has_element?(view, "#update-banner", newer())
    assert has_element?(view, "#update-banner-station[href='/#update']")
  end

  test "the favicon is the mark on its tile" do
    conn = get(build_conn(), "/favicon.svg")
    assert response(conn, 200) =~ "#8fb8ec"
  end

  test "while a sheet prints, Install asks; Install anyway is the second yes", %{conn: conn} do
    Application.put_env(:polis, :install_kind, :velopack)
    me = self()
    Application.put_env(:polis, :updates_stop_fun, fn code -> send(me, {:stopped, code}) end)
    heard_of_newer()

    Application.put_env(:polis, :printer_backend, Polis.SlowPrinter)
    Polis.Station.choose_printer("Hall printer")
    Polis.Queue.test_print()
    eventually(fn -> Polis.Queue.busy?() end)

    {:ok, view, _html} = live(conn, "/")
    refute has_element?(view, "#update-force")

    view |> form("#update-form") |> render_submit()
    assert has_element?(view, "#update-busy")
    assert has_element?(view, "#update-force[data-confirm]")
    refute_received {:stopped, _}

    view |> element("#update-force") |> render_click()
    refute has_element?(view, "#update-busy")
    assert_receive {:stopped, 90}, 2_000
  end
end
