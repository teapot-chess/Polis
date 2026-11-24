defmodule Polis.Printer.DryRun do
  @moduledoc """
  The printer that prints nothing. Each job's PDF and its layout, as the
  JSON the Windows road would draw, are written to `<data>/dry-run/` under
  the job's own name, and the job counts as printed.

  The default in development and in the tests, so that nobody's printer
  wakes up because somebody ran the tests; `POLIS_PRINTER=dry-run` makes a
  release do the same, for a rehearsal. It offers one printer, so that
  everything that needs a printer chosen can be tried: "Dry run".
  """

  @behaviour Polis.Printer

  @name "Dry run"

  def name, do: @name

  @impl true
  def printers, do: {:ok, [@name]}

  @impl true
  def default_printer, do: nil

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def print(job) do
    dir = Path.join(Polis.Paths.data(), "dry-run")
    File.mkdir_p!(dir)
    base = Path.join(dir, Path.basename(job.pdf, ".pdf"))
    File.cp!(job.pdf, base <> ".pdf")

    File.write!(
      base <> ".json",
      Jason.encode!(Map.put(Polis.Printer.Windows.job_json(job), "dry_run", true), pretty: true)
    )

    :ok
  end
end
