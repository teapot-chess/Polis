defmodule Polis.Printer.Windows do
  @moduledoc """
  Printing on Windows: Windows PowerShell 5.1 (`powershell.exe`, part of
  every Windows 10 and 11) runs `priv/print/print.ps1`, which draws the
  layout with System.Drawing.Printing.PrintDocument on the chosen printer,
  in Arial, through the printer's own driver. Nothing is bundled and
  nothing is installed; see `Polis.Printer` for why it is not the PDF that
  is printed here.

  The script is given one file: the job as JSON (`job_json/1`) - printer,
  copies, title, paper and the layout - so that no name ever travels as a
  command-line argument, where Windows' quoting rules would have a say in
  it. It answers on standard output in UTF-8:

    * `-Action printers` - one printer name per line;
    * `-Action default` - the default printer's name;
    * `-Action print -Job FILE` - `ok`, or a line saying what went wrong.

  The runner can be swapped (`config :polis, :windows_cmd`, a function like
  `System.cmd/3`) so the tests look at the arguments and the JSON without
  starting PowerShell.
  """

  @behaviour Polis.Printer

  @impl true
  def printers do
    case run(args("printers")) do
      {out, 0} -> {:ok, lines(out)}
      {out, _status} -> {:error, trouble(out)}
    end
  end

  @impl true
  def default_printer do
    case run(args("default")) do
      {out, 0} -> out |> lines() |> List.first()
      _failed -> nil
    end
  end

  @impl true
  # sobelow_skip ["Traversal.FileModule"]
  def print(job) do
    file = job_file(job)
    File.write!(file, Jason.encode!(job_json(job)))

    try do
      case run(args("print", file)) do
        {out, 0} ->
          if "ok" in lines(out), do: :ok, else: {:error, trouble(out)}

        {out, _status} ->
          {:error, trouble(out)}
      end
    after
      File.rm(file)
    end
  end

  @doc "The arguments of `powershell.exe` for an action."
  def args(action, job_file \\ nil) do
    ~w(-NoProfile -NonInteractive -ExecutionPolicy Bypass -File) ++
      [script(), "-Action", action] ++
      if(job_file, do: ["-Job", job_file], else: [])
  end

  @doc "What the script is given: the job, the layout inside it."
  def job_json(job) do
    %{
      "printer" => job.printer,
      "copies" => job.copies,
      "title" => job.title,
      "paper" => to_string(job.paper),
      "layout" => Polis.Layout.to_json(job.layout)
    }
  end

  @doc "Where the script is, in this release or checkout."
  def script, do: Application.app_dir(:polis, ["priv", "print", "print.ps1"])

  defp job_file(job), do: Path.rootname(job.pdf) <> ".print.json"

  defp lines(out),
    do:
      out
      |> String.split(["\r\n", "\n"], trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))

  defp trouble(out) do
    case out |> lines() |> List.last() do
      nil -> "Windows refused, without saying why"
      words -> String.slice(words, 0, 300)
    end
  end

  defp run(args) do
    runner = Application.get_env(:polis, :windows_cmd, &Polis.Cmd.run/3)
    # Two minutes: PowerShell's start, the driver's thinking and a few pages.
    runner.("powershell.exe", args, stderr_to_stdout: true, timeout: 120_000)
  rescue
    error -> {"PowerShell did not start: #{Exception.message(error)}", 1}
  end
end
