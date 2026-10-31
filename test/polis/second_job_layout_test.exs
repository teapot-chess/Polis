defmodule Polis.SecondJobLayoutTest do
  @moduledoc """
  The three sheets Polis learned after the pairings and the place cards:
  the standings, an alphabetical player list with board and room, and the
  result slips.
  """

  use ExUnit.Case, async: true

  alias Polis.{FakeServer, Layout}

  defp texts(ops), do: for({:text, _, _, _, _, text, _} <- ops, do: text)

  defp standings(rows) do
    %{
      "type" => "standings",
      "tournament" => %{"id" => 1, "name" => "Club Open", "city" => "Gent", "dates" => ""},
      "round" => 3,
      "rounds" => 7,
      "locale" => "en",
      "rating_label" => "Elo",
      "tiebreaks" => ["Bch", "SB"],
      "rev" => "r1",
      "rows" => rows
    }
  end

  defp row(i) do
    %{
      "rank" => Integer.to_string(i),
      "name" => "Player #{i}",
      "title" => "",
      "rating" => 2000 - i,
      "federation" => "BEL",
      "club" => "",
      "number" => i,
      "score" => "2.5",
      "tiebreaks" => ["6.5", "4"]
    }
  end

  defp with_rooms(payload) do
    boards =
      Enum.map(payload["boards"], fn b ->
        Map.put(b, "room", if(b["board"] == "1", do: "Hall A", else: "Hall B"))
      end)

    %{payload | "boards" => boards}
  end

  describe "the standings" do
    test "a table with the heading, the tie-break columns and the page number" do
      doc = Layout.standings(standings([row(1), row(2)]))
      assert %{pages: [page], title: "Club Open - Standings 3"} = doc
      t = texts(page)

      assert "Club Open" in t
      assert "Standings after round 3" in t
      for title <- ["Name", "Fed", "Elo", "Pts", "Bch", "SB"], do: assert(title in t)
      assert "Player 1" in t and "Player 2" in t
      assert "6.5" in t
      assert "Page 1 of 1" in t
    end

    test "a long table breaks into pages, each with its header" do
      doc = Layout.standings(standings(for i <- 1..150, do: row(i)))
      assert length(doc.pages) > 2

      for {page, n} <- Enum.with_index(doc.pages, 1) do
        assert "Standings after round 3" in texts(page)
        assert "Page #{n} of #{length(doc.pages)}" in texts(page)
      end
    end

    test "no players still says so, and more than four tie-breaks are cut to four" do
      assert %{pages: [page]} = Layout.standings(standings([]))
      assert "No standings yet." in texts(page)

      many = %{standings([row(1)]) | "tiebreaks" => ~w(a b c d e f)}
      assert %{pages: [page]} = Layout.standings(many)
      assert ~w(a b c d) -- texts(page) == []
      refute "e" in texts(page)
    end

    test "Dutch follows the payload's locale" do
      doc = Layout.standings(%{standings([row(1)]) | "locale" => "nl"})
      assert "Stand na ronde 3" in texts(hd(doc.pages))
    end
  end

  describe "the player list" do
    test "every player once, alphabetical, with board and colour; a bye says bye" do
      doc = Layout.player_list(FakeServer.payload(3))
      assert %{pages: [page], title: "Club Open - Player list 3"} = doc
      t = texts(page)

      names = Enum.filter(t, &String.starts_with?(&1, "Player "))
      assert names == ["Player Five", "Player Four", "Player One", "Player Three", "Player Two"]
      assert "bye" in t
      assert "Players - round 3 of 7" in t
      assert "Colour" in t
      refute "Room" in t
    end

    test "a tournament with rooms gets the room column" do
      doc = Layout.player_list(with_rooms(FakeServer.payload(3)))
      t = texts(hd(doc.pages))
      assert "Room" in t
      assert "Hall A" in t and "Hall B" in t
    end

    test "accents and case do not decide the order" do
      payload = FakeServer.payload(3)

      boards = [
        %{
          "board" => "1",
          "white" => %{"name" => "Émile, A", "rating" => 0, "score" => "0"},
          "black" => %{"name" => "eagle, B", "rating" => 0, "score" => "0"},
          "bye" => nil
        }
      ]

      doc = Layout.player_list(%{payload | "boards" => boards})
      names = texts(hd(doc.pages)) |> Enum.filter(&(&1 in ["Émile, A", "eagle, B"]))
      assert names == ["eagle, B", "Émile, A"]
    end

    test "an empty round says so" do
      doc = Layout.player_list(%{FakeServer.payload(3) | "boards" => []})
      assert "No players in this round." in texts(hd(doc.pages))
    end
  end

  describe "the result slips" do
    test "one slip a game, none for a bye, with both names, the board and three results" do
      doc = Layout.result_slips(FakeServer.payload(3))
      assert %{pages: [page], title: "Club Open - Result slips 3"} = doc
      t = texts(page)

      assert "Board 1" in t and "Board 2" in t
      refute "Board 3" in t
      assert "Player One" in t and "Player Four" in t
      refute "Player Five" in t

      for result <- ["1 - 0", "1/2 - 1/2", "0 - 1"],
          do: assert(Enum.count(t, &(&1 == result)) == 2)

      assert Enum.count(t, &(&1 == "White signs")) == 2
    end

    test "four to a sheet" do
      boards =
        for i <- 1..9 do
          %{
            "board" => Integer.to_string(i),
            "white" => %{"name" => "White #{i}", "rating" => 0, "score" => "0"},
            "black" => %{"name" => "Black #{i}", "rating" => 0, "score" => "0"},
            "bye" => nil
          }
        end

      doc = Layout.result_slips(%{FakeServer.payload(3) | "boards" => boards})
      assert length(doc.pages) == 3
    end

    test "the room is on the slip when the board has one" do
      doc = Layout.result_slips(with_rooms(FakeServer.payload(3)))
      assert Enum.any?(texts(hd(doc.pages)), &String.contains?(&1, "Hall A"))
    end

    test "every text is drawn inside the sheet" do
      for doc <- [
            Layout.result_slips(FakeServer.payload(3)),
            Layout.player_list(FakeServer.payload(3)),
            Layout.standings(standings([row(1)]))
          ],
          page <- doc.pages,
          {:text, x, y, _, _, _, _} <- page do
        assert x >= 0 and x <= doc.width
        assert y >= 0 and y <= doc.height
      end
    end
  end
end
