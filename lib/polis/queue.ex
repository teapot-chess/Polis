defmodule Polis.Queue do
  @moduledoc """
  The print queue: one job at a time, in the order they came, and the last
  fifty kept so a sheet can be printed again or opened as a PDF.

  A job:

      %{id, tournament, tournament_name, round, rev, what, copies, status,
        error, created_at, printed_at}

  `what` is `:pairings`, `:placecards`, `:standings`, `:playerlist`,
  `:slips` or `:test`. `status` is one of

    * `:waiting_printer` - no printer is chosen yet; it goes once one is;
    * `:queued` - waiting for the job before it;
    * `:printing` - with the printer now (the update refuses meanwhile);
    * `:printed`;
    * `:failed` - with `error`, the printer road's own words.

  On disk, in `<data>/jobs/`: `jobs.json` (the list), and per job its
  source (`<id>.src.json`: the round payload it was made from) and its PDF
  (`<id>.pdf`). The PDF is laid out when the job is queued, so "Open PDF"
  works at once, and again when it is printed, on the paper chosen by
  then.

  Printing runs in a task under `Polis.TaskSupervisor`, never in this
  process: a printer that takes a minute to answer must not take the page
  down with it.
  """

  use GenServer

  require Logger

  alias Polis.{Layout, Paths, Pdf, Printer, Station}

  @keep 50
  @topic "queue"

  def topic, do: @topic

  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Queues a job: `%{tournament, tournament_name, round, rev, what, copies,
  payload}` (`payload` nil for a test page). Returns the job id.
  """
  def enqueue(attrs), do: GenServer.call(__MODULE__, {:enqueue, attrs})

  @doc "The test page, on the chosen printer."
  def test_print do
    enqueue(%{
      tournament: nil,
      tournament_name: nil,
      round: nil,
      rev: nil,
      what: :test,
      copies: 1,
      payload: nil
    })
  end

  @doc "The jobs, newest first."
  def jobs, do: GenServer.call(__MODULE__, :jobs)

  def job(id), do: Enum.find(jobs(), &(&1.id == id))

  @doc "A job again: a new job with the same source. `{:ok, id}` or `:error`."
  def reprint(id), do: GenServer.call(__MODULE__, {:reprint, id})

  @doc "A printer was chosen: what waited for one is queued."
  def printer_chosen, do: GenServer.call(__MODULE__, :printer_chosen)

  @doc "Whether a job is with the printer now."
  def busy?, do: Enum.any?(jobs(), &(&1.status == :printing))

  @doc "Jobs not printed yet: waiting for a printer, queued or printing."
  def pending_count,
    do: Enum.count(jobs(), &(&1.status in [:waiting_printer, :queued, :printing]))

  @doc "The PDF of a job, laid out now if it is not there. `{:ok, path}` or `:error`."
  def pdf(id), do: GenServer.call(__MODULE__, {:pdf, id}, 30_000)

  @doc "Waits until the job in hand (if any) is done. For tests."
  def drain(timeout \\ 5_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    wait_idle(deadline)
  end

  defp wait_idle(deadline) do
    cond do
      not Enum.any?(jobs(), &(&1.status in [:queued, :printing])) ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        :timeout

      true ->
        receive do
        after
          20 -> wait_idle(deadline)
        end
    end
  end

  # --- the process -------------------------------------------------------------------

  @impl true
  def init(_opts) do
    jobs =
      read_list()
      |> Enum.map(fn
        # Whatever was with the printer when the station stopped: it may or
        # may not have come out. Said so, not guessed: Reprint is one click.
        %{status: :printing} = job -> %{job | status: :failed, error: "stopped"}
        job -> job
      end)

    state = %{jobs: jobs, task: nil}
    save(state)
    {:ok, state, {:continue, :advance}}
  end

  @impl true
  def handle_continue(:advance, state), do: {:noreply, advance(state)}

  @impl true
  def handle_call({:enqueue, attrs}, _from, state) do
    id = new_id()

    File.write!(
      source_file(id),
      Jason.encode!(%{"what" => attrs.what, "payload" => attrs.payload})
    )

    job = %{
      id: id,
      tournament: attrs.tournament,
      tournament_name: attrs.tournament_name,
      round: attrs.round,
      rev: attrs.rev,
      what: attrs.what,
      copies: attrs.copies,
      status: if(Station.printer(), do: :queued, else: :waiting_printer),
      error: nil,
      created_at: DateTime.utc_now(:second),
      printed_at: nil
    }

    # Laid out now, so that "Open PDF" has something at once.
    write_pdf(job, Station.paper(), Station.printer())

    state = %{state | jobs: [job | state.jobs]} |> prune() |> changed()
    {:reply, id, advance(state)}
  end

  def handle_call(:jobs, _from, state), do: {:reply, state.jobs, state}

  def handle_call({:reprint, id}, _from, state) do
    with %{} = old <- Enum.find(state.jobs, &(&1.id == id)),
         {:ok, source} <- read_source(id) do
      new = new_id()
      File.write!(source_file(new), Jason.encode!(source))

      job = %{
        old
        | id: new,
          status: if(Station.printer(), do: :queued, else: :waiting_printer),
          error: nil,
          created_at: DateTime.utc_now(:second),
          printed_at: nil
      }

      write_pdf(job, Station.paper(), Station.printer())
      state = %{state | jobs: [job | state.jobs]} |> prune() |> changed()
      {:reply, {:ok, new}, advance(state)}
    else
      _missing -> {:reply, :error, state}
    end
  end

  def handle_call(:printer_chosen, _from, state) do
    jobs =
      Enum.map(state.jobs, fn
        %{status: :waiting_printer} = job -> %{job | status: :queued}
        job -> job
      end)

    state = changed(%{state | jobs: jobs})
    {:reply, :ok, advance(state)}
  end

  def handle_call({:pdf, id}, _from, state) do
    path = pdf_file(id)

    cond do
      File.exists?(path) ->
        {:reply, {:ok, path}, state}

      job = Enum.find(state.jobs, &(&1.id == id)) ->
        case write_pdf(job, Station.paper(), Station.printer()) do
          {:ok, _doc} -> {:reply, {:ok, path}, state}
          :error -> {:reply, :error, state}
        end

      true ->
        {:reply, :error, state}
    end
  end

  @impl true
  def handle_info({ref, result}, %{task: {id, ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, state |> finish(id, result) |> advance()}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{task: {id, ref}} = state) do
    {:noreply, state |> finish(id, {:error, "crashed: #{inspect(reason)}"}) |> advance()}
  end

  def handle_info(_other, state), do: {:noreply, state}

  # --- one at a time ---------------------------------------------------------------------

  defp advance(%{task: nil} = state) do
    printer = Station.printer()

    case printer && state.jobs |> Enum.reverse() |> Enum.find(&(&1.status == :queued)) do
      nil ->
        state

      false ->
        state

      job ->
        paper = Station.paper()

        task =
          Task.Supervisor.async_nolink(Polis.TaskSupervisor, fn ->
            print_job(job, paper, printer)
          end)

        state
        |> put_job(job.id, &%{&1 | status: :printing})
        |> Map.put(:task, {job.id, task.ref})
        |> changed()
    end
  end

  defp advance(state), do: state

  defp print_job(job, paper, printer) do
    case write_pdf(job, paper, printer) do
      {:ok, doc} ->
        Printer.print(%{
          pdf: pdf_file(job.id),
          layout: doc,
          printer: printer,
          copies: job.copies,
          title: doc.title,
          paper: paper
        })

      :error ->
        {:error, "the job's source is missing"}
    end
  end

  defp finish(state, id, result) do
    state = %{state | task: nil}

    case result do
      :ok ->
        job = Enum.find(state.jobs, &(&1.id == id))
        if job && job.tournament, do: Station.printed(job.tournament, job.round)

        state
        |> put_job(
          id,
          &%{&1 | status: :printed, error: nil, printed_at: DateTime.utc_now(:second)}
        )
        |> changed()

      {:error, words} ->
        Logger.warning("polis: job #{id} did not print: #{words}")
        state |> put_job(id, &%{&1 | status: :failed, error: to_string(words)}) |> changed()

      other ->
        state |> put_job(id, &%{&1 | status: :failed, error: inspect(other)}) |> changed()
    end
  end

  defp put_job(state, id, fun) do
    %{state | jobs: Enum.map(state.jobs, fn job -> if job.id == id, do: fun.(job), else: job end)}
  end

  # The newest fifty; the files of the rest go with them. Never the one
  # being printed.
  defp prune(state) do
    {keep, drop} = Enum.split(state.jobs, @keep)
    {printing, drop} = Enum.split_with(drop, &(&1.status == :printing))

    for job <- drop do
      File.rm(pdf_file(job.id))
      File.rm(source_file(job.id))
    end

    %{state | jobs: keep ++ printing}
  end

  defp changed(state) do
    save(state)
    Phoenix.PubSub.broadcast(Polis.PubSub, @topic, :queue_changed)
    state
  end

  # --- the files -----------------------------------------------------------------------------

  @doc false
  # The document of a job, on `paper`, written as its PDF. `{:ok, doc}` or `:error`.
  def write_pdf(job, paper, printer) do
    with {:ok, source} <- read_source(job.id),
         {:ok, doc} <- layout(source, paper, printer) do
      File.write!(pdf_file(job.id), Pdf.render(doc))
      {:ok, doc}
    else
      _missing -> :error
    end
  end

  defp layout(%{"what" => "test"}, paper, printer),
    do: {:ok, Layout.test_page(paper, printer: printer)}

  defp layout(%{"what" => "pairings", "payload" => p}, paper, _printer) when is_map(p),
    do: {:ok, Layout.pairings(p, paper)}

  defp layout(%{"what" => "placecards", "payload" => p}, paper, _printer) when is_map(p),
    do: {:ok, Layout.place_cards(p, paper)}

  defp layout(%{"what" => "standings", "payload" => p}, paper, _printer) when is_map(p),
    do: {:ok, Layout.standings(p, paper)}

  defp layout(%{"what" => "playerlist", "payload" => p}, paper, _printer) when is_map(p),
    do: {:ok, Layout.player_list(p, paper)}

  defp layout(%{"what" => "slips", "payload" => p}, paper, _printer) when is_map(p),
    do: {:ok, Layout.result_slips(p, paper)}

  defp layout(_other, _paper, _printer), do: :error

  defp read_source(id) do
    with {:ok, text} <- File.read(source_file(id)),
         {:ok, source} <- Jason.decode(text) do
      {:ok, source}
    else
      _ -> :error
    end
  end

  def pdf_file(id), do: Path.join(Paths.jobs(), "#{id}.pdf")
  defp source_file(id), do: Path.join(Paths.jobs(), "#{id}.src.json")
  defp list_file, do: Path.join(Paths.jobs(), "jobs.json")

  defp new_id do
    stamp = System.os_time(:millisecond) |> Integer.to_string(36)
    stamp <> "-" <> Base.url_encode64(:crypto.strong_rand_bytes(3), padding: false)
  end

  defp save(state) do
    list = Enum.map(state.jobs, &job_json/1)
    Polis.State.write(list_file(), list)
  end

  defp job_json(job) do
    %{
      "id" => job.id,
      "tournament" => job.tournament,
      "tournament_name" => job.tournament_name,
      "round" => job.round,
      "rev" => job.rev,
      "what" => to_string(job.what),
      "copies" => job.copies,
      "status" => to_string(job.status),
      "error" => job.error,
      "created_at" => job.created_at && DateTime.to_iso8601(job.created_at),
      "printed_at" => job.printed_at && DateTime.to_iso8601(job.printed_at)
    }
  end

  @whats %{
    "pairings" => :pairings,
    "placecards" => :placecards,
    "standings" => :standings,
    "playerlist" => :playerlist,
    "slips" => :slips,
    "test" => :test
  }
  @statuses %{
    "waiting_printer" => :waiting_printer,
    "queued" => :queued,
    "printing" => :printing,
    "printed" => :printed,
    "failed" => :failed
  }

  defp read_list do
    with {:ok, text} <- File.read(list_file()),
         {:ok, list} when is_list(list) <- Jason.decode(text) do
      for %{"id" => id, "what" => what, "status" => status} = j <- list,
          Map.has_key?(@whats, what) and Map.has_key?(@statuses, status) do
        %{
          id: id,
          tournament: j["tournament"],
          tournament_name: j["tournament_name"],
          round: j["round"],
          rev: j["rev"],
          what: @whats[what],
          copies: j["copies"] || 1,
          status: @statuses[status],
          error: j["error"],
          created_at: time(j["created_at"]),
          printed_at: time(j["printed_at"])
        }
      end
    else
      _none -> []
    end
  end

  defp time(nil), do: nil

  defp time(text) do
    case DateTime.from_iso8601(text) do
      {:ok, dt, _} -> dt
      _ -> nil
    end
  end
end
