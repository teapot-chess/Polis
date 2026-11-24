defmodule Polis.Paths do
  @moduledoc """
  Where the station keeps things. One directory (`config :polis,
  :data_dir`, `POLIS_DATA`) holds the state file (`state.json`), the jobs
  (`jobs/`: a PDF and its source per job, and the list of them) and, on a
  dry run, what would have been printed (`dry-run/`).
  """

  def data, do: ensure(Application.fetch_env!(:polis, :data_dir))
  def state_file, do: Path.join(data(), "state.json")
  def jobs, do: ensure(Path.join(data(), "jobs"))

  # sobelow_skip ["Traversal.FileModule"]
  defp ensure(dir) do
    File.mkdir_p!(dir)
    dir
  end
end
