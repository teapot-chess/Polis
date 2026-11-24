defmodule PolisWeb.JobController do
  @moduledoc """
  `/jobs/:id/pdf`: a job's PDF, shown in the browser ("Open PDF" in the
  queue). Only ids the queue knows; the id is never taken for a path.
  """

  use PolisWeb, :controller

  # sobelow_skip ["Traversal.SendFile"]
  def pdf(conn, %{"id" => id}) do
    with %{} = job <- Polis.Queue.job(id),
         {:ok, path} <- Polis.Queue.pdf(job.id) do
      conn
      |> put_resp_content_type("application/pdf", nil)
      |> put_resp_header("content-disposition", ~s(inline; filename="#{filename(job)}"))
      |> put_resp_header("cache-control", "no-store")
      |> send_file(200, path)
    else
      _missing -> conn |> put_resp_content_type("text/plain") |> send_resp(404, "Not Found")
    end
  end

  defp filename(%{what: :test}), do: "test-print.pdf"
  defp filename(job), do: "round-#{job.round}-#{job.what}.pdf"
end
