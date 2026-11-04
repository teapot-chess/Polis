defmodule PolisWeb.PinGateTest do
  @moduledoc """
  The door: this machine is never asked, another machine is, for every page
  and the PDF; the unlock page is a plain password field; a wrong PIN counts,
  a right one lets in; a changed PIN voids the grant; only the machine itself
  sees and changes the PIN.
  """

  use Polis.StationCase, async: false

  import Phoenix.ConnTest
  import Phoenix.LiveViewTest

  alias Polis.AccessPin

  @endpoint PolisWeb.Endpoint

  defp unlock(conn, pin), do: post(conn, "/unlock", %{"pin" => pin})

  # A remote browser that has given the PIN: its cookie, on a fresh conn.
  defp unlocked(ip \\ {192, 168, 1, 50}) do
    conn = remote_conn(ip) |> unlock(AccessPin.current())
    assert redirected_to(conn) == "/"
    again(conn, ip)
  end

  defp count(doc, selector), do: doc |> LazyHTML.query(selector) |> Enum.count()

  defp again(conn, ip), do: conn |> Phoenix.ConnTest.recycle() |> Map.put(:remote_ip, ip)

  describe "who is asked" do
    test "this machine is not, for any page" do
      for path <- ["/", "/help", "/unlock", "/jobs/none/pdf"] do
        conn = get(local_conn(), path)
        refute redirected_to_unlock?(conn, path), path
      end
    end

    test "another machine is, for every page and the PDF" do
      for path <- ["/", "/help", "/jobs/abc/pdf"] do
        conn = get(remote_conn(), path)
        assert redirected_to(conn) == "/unlock", path
      end
    end

    test "a proxy on this machine is another machine: forwarding headers" do
      for header <- ~w(x-forwarded-for forwarded x-real-ip cf-connecting-ip x-forwarded-host) do
        conn = local_conn() |> Plug.Conn.put_req_header(header, "203.0.113.9") |> get("/")
        assert redirected_to(conn) == "/unlock", header
      end
    end

    test "loopback to a name that is not this machine's is asked too" do
      conn = Phoenix.ConnTest.build_conn() |> get("/help")
      assert redirected_to(conn) == "/unlock"
    end

    test "static files and the favicon are not behind it" do
      assert get(remote_conn(), "/favicon.svg").status == 200
      assert get(remote_conn(), "/app.css").status == 200
    end

    test "the language link is open and does not show the station" do
      conn = get(remote_conn(), "/lang/nl")
      assert redirected_to(conn) == "/"
    end

    test "a remote LiveView is turned away without a grant" do
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(remote_conn(), "/")
    end
  end

  defp redirected_to_unlock?(conn, path) do
    path != "/unlock" and conn.status == 302 and
      Plug.Conn.get_resp_header(conn, "location") == ["/unlock"]
  end

  describe "the unlock page" do
    test "is a password field with a show toggle, not a keypad" do
      html = remote_conn() |> get("/unlock") |> html_response(200)
      doc = LazyHTML.from_fragment(html)

      assert count(doc, "form#unlock-form") == 1

      assert count(doc, "input#unlock-pin[type=password][maxlength='64'][autocomplete]") == 1

      assert count(doc, "button#unlock-show") == 1
      assert count(doc, "[inputmode]") == 0
      assert count(doc, "input[type=number]") == 0
    end

    test "the right PIN lets in, and the page it was asked for is where it goes" do
      conn = get(remote_conn(), "/help")
      assert redirected_to(conn) == "/unlock"
      conn = conn |> again({192, 168, 1, 50}) |> unlock(AccessPin.current())
      assert redirected_to(conn) == "/help"

      conn = conn |> again({192, 168, 1, 50}) |> get("/help")
      assert html_response(conn, 200) =~ "page-help"
    end

    test "a wrong PIN is refused and says so" do
      conn = unlock(remote_conn(), "000000x")
      assert html_response(conn, 403) =~ "unlock-error"
      assert redirected_to(get(again(conn, {192, 168, 1, 50}), "/")) == "/unlock"
    end

    test "after five wrong PINs the address waits, even with the right one" do
      ip = {192, 168, 1, 77}
      for _ <- 1..5, do: assert(html_response(unlock(remote_conn(ip), "wrong-pin"), 403))

      conn = unlock(remote_conn(ip), AccessPin.current())
      assert html_response(conn, 429) =~ "unlock-wait"
      assert html_response(get(remote_conn(ip), "/unlock"), 200) =~ "unlock-wait"

      # Another address is not held up.
      assert redirected_to(unlock(remote_conn({192, 168, 1, 78}), AccessPin.current())) == "/"
    end

    test "this machine is sent on to the station" do
      assert redirected_to(get(local_conn(), "/unlock")) == "/"
    end

    test "it cannot be used to be sent elsewhere" do
      conn = remote_conn() |> Plug.Test.init_test_session(%{"pin_return_to" => "//evil.example"})
      conn = unlock(conn, AccessPin.current())
      assert redirected_to(conn) == "/"
    end
  end

  describe "a granted browser" do
    test "gets the pages and the live socket, and does not see the PIN" do
      conn = unlocked()
      {:ok, view, _html} = live(conn, "/")
      refute has_element?(view, "#access-pin")
      refute render(view) =~ AccessPin.current()
    end

    test "is turned away once the PIN has changed" do
      conn = unlocked()
      assert {:ok, _view, _html} = live(conn, "/")

      assert :ok = AccessPin.change("a different one")

      assert redirected_to(get(conn, "/help")) == "/unlock"
      assert {:error, {:redirect, %{to: "/unlock"}}} = live(conn, "/")
    end

    test "has its open socket dropped when the PIN changes" do
      # A real socket listens on the live_socket_id of its cookie (the test
      # client has no transport): the unlock names it, a change broadcasts to it.
      conn = remote_conn() |> unlock(AccessPin.current())
      assert Plug.Conn.get_session(conn, "live_socket_id") == AccessPin.socket_id()

      PolisWeb.Endpoint.subscribe(AccessPin.socket_id())
      assert :ok = AccessPin.change("another one 2")
      assert_receive %Phoenix.Socket.Broadcast{event: "disconnect"}
    end

    test "cannot change the PIN by sending the event" do
      conn = unlocked()
      {:ok, view, _html} = live(conn, "/")
      before = AccessPin.current()
      render_hook(view, "pin_new", %{})
      assert AccessPin.current() == before
    end
  end

  describe "this machine's page" do
    test "shows the PIN and a change form, with no remove" do
      {:ok, view, _html} = live(local_conn(), "/")
      assert has_element?(view, "#access-pin")
      assert has_element?(view, "#access-pin-current", AccessPin.current())
      assert has_element?(view, "#access-pin-form input#access-pin-input[type=password]")
      assert has_element?(view, "#access-pin-show")
      assert has_element?(view, "#access-pin-save")
      assert has_element?(view, "#access-pin-new")
      refute has_element?(view, "#access-pin button", "Remove")
    end

    test "changing it writes the file" do
      {:ok, view, _html} = live(local_conn(), "/")

      view |> form("#access-pin-form", pin: %{value: "hall door 9"}) |> render_submit()

      assert AccessPin.current() == "hall door 9"
      assert File.read!(AccessPin.path()) == "hall door 9\n"
      assert has_element?(view, "#access-pin-current", "hall door 9")
      assert has_element?(view, "#flash-info")
    end

    test "a PIN the rules refuse is said so and kept as it was" do
      {:ok, view, _html} = live(local_conn(), "/")
      before = AccessPin.current()

      view |> form("#access-pin-form", pin: %{value: "123"}) |> render_submit()
      assert has_element?(view, "#access-pin-error")
      assert AccessPin.current() == before

      view |> form("#access-pin-form", pin: %{value: ""}) |> render_submit()
      assert has_element?(view, "#access-pin-error")
      assert AccessPin.current() == before
    end

    test "New random PIN makes six digits and shows them" do
      {:ok, view, _html} = live(local_conn(), "/")
      view |> element("#access-pin-new") |> render_click()
      assert AccessPin.current() =~ ~r/\A\d{6}\z/
      assert has_element?(view, "#access-pin-current", AccessPin.current())
    end

    test "the help page does not show it" do
      {:ok, view, _html} = live(local_conn(), "/help")
      refute has_element?(view, "#access-pin")
    end
  end
end
