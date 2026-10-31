defmodule OpenPairingsPolis.StandingsPayload do
  @moduledoc """
  The standings a station is sent just before a `print` asks for them: the
  hall-link protocol's `standings` frame (`server-standings` in OpenPairings'
  `hall-link-v1` contract, vendored in the Polis repository).

  The table is the Standings page's: `Standings.standings/2` with the
  arbiter's hand-set order applied, the rank as the page shows it
  (`Standings.shown_rank_label/2`, a shared place reads `2-3`), the points
  with extra points counted, and the tie-breaks the tournament actually
  applies (`Standings.effective_tiebreaks/1`: one that FIDE refuses with
  unrated players present is not in the table, and not in the frame). A
  Keizer tournament has its own table and no tie-breaks.

  There is no standings frame for a table nobody should hand prizes out
  from: with FIDE rules and the last round paired while a postponed game is
  still open (`PairingsEngine.PostponedGames.final_standings_refused?/2`),
  and for a team event, whose table is the teams' and not this one. Those
  are `:none`, and the station is told nothing.

  `rev` is the SHA-256 of the frame without it, as for the round payload.
  """
  alias PairingsEngine.{Keizer, PostponedGames, Standings}
  alias PairingsEngine.Tournaments.{Player, Tournament}

  @doc "`{:ok, frame}` with string keys ready for JSON, or `:none`."
  def build(%Tournament{} = tournament) do
    cond do
      Tournament.team?(tournament) -> :none
      PostponedGames.final_standings_refused?(tournament, nil) -> :none
      true -> {:ok, frame(tournament)}
    end
  end

  defp frame(tournament) do
    {entries, codes, through} = table(tournament)

    body = %{
      "type" => "standings",
      "tournament" => %{
        "id" => tournament.id,
        "name" => tournament.name,
        "city" => tournament.city || "",
        "dates" => OpenPairingsPolis.RoundPayload.dates(tournament)
      },
      "round" => through,
      "rounds" => tournament.rounds_count,
      "locale" => OpenPairingsPolis.RoundPayload.locale(tournament),
      "rating_label" => OpenPairingsPolis.RoundPayload.rating_label(tournament),
      "tiebreaks" => codes,
      "rows" => Enum.map(entries, &row(&1, codes, tournament))
    }

    Map.put(body, "rev", OpenPairingsPolis.RoundPayload.rev(body))
  end

  # {entries in the order the page shows them, tie-break codes, rounds the
  # table stands after}
  defp table(%Tournament{pairing_system: "keizer"} = tournament) do
    entries = Keizer.standings(tournament)
    {entries, [], Standings.rounds_paired(tournament.id)}
  end

  defp table(tournament) do
    entries =
      tournament
      |> Standings.standings(pending: true)
      |> Standings.apply_manual_ranking(tournament)

    through =
      case entries do
        [first | _] -> Map.get(first, :completed_rounds, 0)
        [] -> 0
      end

    {entries, Standings.effective_tiebreaks(tournament), through}
  end

  defp row(%{player: %Player{} = p} = e, codes, tournament) do
    %{
      "rank" => rank(e, tournament),
      "name" => p.name,
      "title" => p.title || "",
      "rating" => Player.rating(p, tournament),
      "federation" => p.federation || "",
      "club" => p.club || "",
      "number" => p.pairing_number,
      "score" => number(Map.get(e, :total, Map.get(e, :points, 0))),
      "tiebreaks" => Enum.map(codes, &number(Map.get(e.tiebreaks || %{}, &1, 0)))
    }
  end

  defp rank(e, %Tournament{pairing_system: "keizer"}), do: to_string(Map.get(e, :rank, ""))
  defp rank(e, tournament), do: to_string(Standings.shown_rank_label(e, tournament))

  # "6", "6.5", "5.25": the table's own figures, no trailing zeros.
  defp number(v) when is_float(v) do
    rounded = Float.round(v, 2)

    if rounded == Float.round(rounded, 0),
      do: Integer.to_string(trunc(rounded)),
      else: Float.to_string(rounded)
  end

  defp number(v) when is_integer(v), do: Integer.to_string(v)
  defp number(v), do: to_string(v)
end
