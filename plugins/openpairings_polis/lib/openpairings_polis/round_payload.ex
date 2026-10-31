defmodule OpenPairingsPolis.RoundPayload do
  @moduledoc """
  The round a station is sent: the hall-link protocol's round payload,
  identical in shape to the hall announcer's: `round_payload` in
  OpenPairings' `hall-link-v1` contract, vendored in the Polis repository.

  The boards are the core's printed pairing list
  (`PairingsEngineWeb.PrintController.pairing_list/2`): hidden pairings
  left out, the frozen display boards and their order
  (`PairingsEngine.PairingDisplay.with_display_boards/1`), each player's
  score coming into the round
  (`PairingsEngine.Standings.player_scores_before_round/2`), and the rating
  by the tournament's own rating method (`Player.rating/2`). What the hall
  printer prints is what the arbiter's own printer would have.

  `rev` is the SHA-256 of the payload without it, so "has anything
  changed?" is a string comparison and the station can say "already
  printed that" for free.
  """
  alias PairingsEngine.{BoardRanges, PairingDisplay, Repo, Rooms, Standings, Tournaments}
  alias PairingsEngine.Tournaments.{Player, Round, Tournament}

  @doc """
  The latest published round's payload, `{:ok, number, payload}`; `:none`
  while nothing is public. `selection` as for `build/3`.
  """
  def latest(%Tournament{} = tournament, selection \\ nil) do
    case Tournaments.latest_published_round_number(tournament) do
      0 -> :none
      n -> with {:ok, payload} <- build(tournament, n, selection), do: {:ok, n, payload}
    end
  end

  @doc """
  Round `number`'s payload, `{:ok, map}` with string keys ready for JSON, or
  `:none` when that round is not paired or not public. Not public means not
  sent, whoever asks.

  `selection` is one station's share of the round (nil for all of it):
  `%{room:, categories:, boards:}` as `OpenPairingsPolis.Stations.filter/2`
  makes it. A board is kept when it is in the station's `room` (a room of
  the tournament, `PairingsEngine.Rooms.holds?/2`), its number is in
  `boards` and either player is in one of `categories` - a bye's one
  player, alone - each test passing when it is nil or empty. A selection
  that is not "everything" is written into the payload as `selection`
  (`room`, `boards`, `categories`), so the sheet can say which part of the
  hall it is for, and so the `rev` changes when the part does.
  """
  def build(%Tournament{} = tournament, number, selection \\ nil) when is_integer(number) do
    tournament = Repo.preload(tournament, :user)

    case Tournaments.get_round(tournament.id, number) do
      %Round{} = round ->
        if Tournaments.round_published?(tournament, round),
          do: {:ok, payload(tournament, round, selection)},
          else: :none

      nil ->
        :none
    end
  end

  defp payload(tournament, round, selection) do
    scores = Standings.player_scores_before_round(tournament, round.number)

    boards =
      round.pairings
      |> Enum.reject(& &1.hidden)
      |> PairingDisplay.with_display_boards()
      |> Enum.filter(&selected?(&1, selection))
      |> Enum.map(fn %{pairing: p, board: board} ->
        %{
          "board" => to_string(board),
          "white" => player(p.white_player, tournament, scores),
          "black" => player(p.black_player, tournament, scores),
          "bye" => if(is_nil(p.black_player), do: "bye")
        }
      end)

    body = %{
      "tournament" => %{
        "id" => tournament.id,
        "name" => tournament.name,
        "city" => tournament.city || "",
        "dates" => dates(tournament)
      },
      "round" => round.number,
      "rounds" => tournament.rounds_count,
      "published_at" => round.published_at && DateTime.to_iso8601(round.published_at),
      "locale" => locale(tournament),
      "rating_label" => rating_label(tournament),
      "team" => Tournament.team?(tournament),
      "boards" => boards
    }

    body
    |> put_selection(selection)
    |> then(&Map.put(&1, "rev", rev(&1)))
  end

  defp selected?(_row, nil), do: true

  defp selected?(%{pairing: p, board: board}, selection) do
    in_room?(Map.get(selection, :room), board) and
      BoardRanges.member?(selection.boards, board) and
      in_categories?(selection.categories, [p.white_player, p.black_player])
  end

  defp in_room?(nil, _board), do: true
  defp in_room?(room, board), do: Rooms.holds?(room, board)

  defp in_categories?([], _players), do: true

  defp in_categories?(categories, players) do
    Enum.any?(players, fn
      %Player{categories: tags} -> Enum.any?(tags || [], &(&1 in categories))
      nil -> false
    end)
  end

  defp put_selection(body, nil), do: body

  defp put_selection(body, selection) do
    room =
      case Map.get(selection, :room) do
        %{name: name} -> name
        _none -> ""
      end

    if room == "" and selection.boards == [] and selection.categories == [] do
      body
    else
      Map.put(body, "selection", %{
        "room" => room,
        "boards" => BoardRanges.format(selection.boards),
        "categories" => selection.categories
      })
    end
  end

  @doc "SHA-256 (hex) of the payload's JSON. Maps this small encode in key order, so it is stable."
  def rev(body),
    do: body |> Jason.encode!() |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)

  defp player(nil, _tournament, _scores), do: nil

  defp player(%Player{} = p, tournament, scores) do
    %{
      "name" => p.name,
      "spoken" => spoken(p.name),
      "title" => p.title || "",
      "rating" => Player.rating(p, tournament),
      "federation" => p.federation || "",
      "club" => p.club || "",
      "number" => p.pairing_number,
      "score" => score(Map.get(scores, p.id, 0.0))
    }
  end

  @doc ~s(A name as it is said: "Carlsen, Magnus" becomes "Magnus Carlsen"; a name without a comma stays as it is.)
  def spoken(nil), do: ""

  def spoken(name) do
    case String.split(name, ",", parts: 2) do
      [last, first] ->
        case String.trim(first) do
          "" -> String.trim(last)
          first -> first <> " " <> String.trim(last)
        end

      [_] ->
        String.trim(name)
    end
  end

  # "2", "2.5": what the printed pairing list puts in brackets.
  defp score(v) when is_float(v) do
    if v == Float.round(v, 0), do: Integer.to_string(trunc(v)), else: Float.to_string(v)
  end

  defp score(v) when is_integer(v), do: Integer.to_string(v)
  defp score(v), do: to_string(v)

  defp dates(%{start_date: s, end_date: e}) do
    case {s || "", e || ""} do
      {"", ""} -> ""
      {s, ""} -> s
      {"", e} -> e
      {same, same} -> same
      {s, e} -> s <> " - " <> e
    end
  end

  @doc ~s(The owner's account language, as the station should print: "nl" or "en".)
  def locale(%Tournament{user: %{locale: "nl" <> _}}), do: "nl"
  def locale(%Tournament{}), do: "en"

  # The column header the printed list uses for the same number (the print
  # controller's own reading, which is private there): "Elo" where FIDE
  # leads, "Nat." for a national list, "Rtg" for anything else.
  defp rating_label(%{rating_method: method}) when method in ["FIDE", "FIDON", nil], do: "Elo"
  defp rating_label(%{rating_method: method}) when method in ["NRO", "NIDOF"], do: "Nat."
  defp rating_label(_tournament), do: "Rtg"
end
