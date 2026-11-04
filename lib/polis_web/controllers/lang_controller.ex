defmodule PolisWeb.LangController do
  @moduledoc "`/lang/nl`, `/lang/en`: remember the language, go back to where you were."

  use PolisWeb, :controller

  def set(conn, %{"code" => code}) when code in ["en", "nl"] do
    conn |> put_session("locale", code) |> redirect(to: back(conn))
  end

  def set(conn, _params), do: redirect(conn, to: "/")

  # Back to the page that had the link, if it was one of ours.
  defp back(conn) do
    with [referer] <- get_req_header(conn, "referer"),
         %URI{path: path} when path in ["/", "/help", "/unlock"] <- URI.parse(referer) do
      path
    else
      _ -> "/"
    end
  end
end
