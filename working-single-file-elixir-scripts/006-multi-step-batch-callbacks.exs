# Ash Batch Callbacks for Bulk Actions
#
# Demonstrates the batch callback lifecycle in Ash.Resource.Change:
#   batch_change/3   — replaces change/3 for bulk operations
#   before_batch/3   — runs before each batch is dispatched to the data layer
#   after_batch/3    — runs after each batch completes in the data layer
#   batch_callbacks?/3 — controls whether before_batch/after_batch hooks run
#
# Based on:
# https://github.com/ash-project/ash/blob/v3.19.3/documentation/topics/advanced/multi-step-actions.md
#
# Scenario 1 — BatchNotifyExternalSystem: bulk_create tickets, external API
#              receives a single batched notification for all of them
# Scenario 2 — BatchAssignAgents: round-robin agent assignment across a batch
# Scenario 3 — ConditionalBatchProcessing: batch_callbacks?/3 controls whether
#              before_batch/after_batch hooks fire based on batch size
#
# Run: elixir 006-multi-step-batch-callbacks.exs

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "006-batch-callbacks.sqlite3")
File.rm(sqlite_path)

Application.put_env(:helpdesk_app, HelpDesk.Repo,
  database: sqlite_path,
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
)

defmodule HelpDesk.Repo do
  use AshSqlite.Repo, otp_app: :helpdesk_app
end

# ---------------------------------------------------------------------------
# Stub modules
# ---------------------------------------------------------------------------

defmodule HelpDesk.ExternalAPI do
  @moduledoc false

  def start_link do
    Agent.start_link(
      fn -> %{health: :ok, notifications: []} end,
      name: __MODULE__
    )
  end

  def health_check do
    Agent.get(__MODULE__, & &1.health)
  end

  def set_health(status) do
    Agent.update(__MODULE__, &Map.put(&1, :health, status))
  end

  def batch_notify_tickets(notifications) do
    case Agent.get(__MODULE__, & &1.health) do
      :ok ->
        Agent.update(__MODULE__, fn state ->
          Map.update!(state, :notifications, &(&1 ++ notifications))
        end)
        {:ok, :notified}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_notifications do
    Agent.get(__MODULE__, & &1.notifications)
  end
end

defmodule HelpDesk.ProcessingTracker do
  @moduledoc false

  def start_link do
    Agent.start_link(
      fn -> %{batch_change_calls: 0, before_batch_calls: 0, after_batch_calls: 0} end,
      name: __MODULE__
    )
  end

  def record(phase) do
    Agent.update(__MODULE__, &Map.update!(&1, phase, fn n -> n + 1 end))
  end

  def get_stats do
    Agent.get(__MODULE__, & &1)
  end

  def reset do
    Agent.update(__MODULE__, fn _ ->
      %{batch_change_calls: 0, before_batch_calls: 0, after_batch_calls: 0}
    end)
  end
end

# ---------------------------------------------------------------------------
# Change modules (adapted from the documentation examples)
# ---------------------------------------------------------------------------

defmodule HelpDesk.Changes.BatchNotifyExternalSystem do
  use Ash.Resource.Change

  @impl true
  def batch_change(changesets, _opts, _context) do
    Enum.map(changesets, fn changeset ->
      Ash.Changeset.put_context(changeset, :needs_external_notification, true)
    end)
  end

  @impl true
  def before_batch(changesets, _opts, _context) do
    case HelpDesk.ExternalAPI.health_check() do
      :ok ->
        Enum.map(changesets, fn changeset ->
          Ash.Changeset.put_context(changeset, :external_api_ready, true)
        end)

      {:error, reason} ->
        Enum.map(changesets, fn changeset ->
          Ash.Changeset.add_error(changeset, message: "External API unavailable: #{reason}")
        end)
    end
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context) do
    notifications =
      changesets_and_results
      |> Enum.filter(fn {changeset, _result} ->
        changeset.context[:external_api_ready] == true
      end)
      |> Enum.map(fn {_changeset, result} ->
        %{ticket_id: result.id, title: result.title, created_at: result.inserted_at}
      end)

    case HelpDesk.ExternalAPI.batch_notify_tickets(notifications) do
      {:ok, _response} ->
        Enum.map(changesets_and_results, fn {_changeset, result} ->
          {:ok, result}
        end)

      {:error, error} ->
        Enum.map(changesets_and_results, fn {_changeset, result} ->
          {:error,
           Ash.Error.Invalid.exception(
             errors: [
               Ash.Error.Changes.InvalidChanges.exception(
                 message: "Failed to notify for ticket #{result.id}: #{error}"
               )
             ]
           )}
        end)
    end
  end
end

defmodule HelpDesk.Changes.BatchAssignAgents do
  use Ash.Resource.Change

  @impl true
  def batch_change(changesets, _opts, _context) do
    changesets
  end

  @impl true
  def before_batch(changesets, _opts, _context) do
    require Ash.Query

    available_agents =
      HelpDesk.SupportAgent
      |> Ash.Query.filter(status == "available")
      |> Ash.Query.sort(workload: :asc)
      |> Ash.read!()

    if available_agents == [] do
      Enum.map(changesets, fn changeset ->
        Ash.Changeset.add_error(changeset, message: "No agents available for assignment")
      end)
    else
      {assigned_changesets, _remaining_agents} =
        Enum.map_reduce(changesets, available_agents, fn changeset, agents ->
          [agent | rest] = agents

          updated_changeset =
            changeset
            |> Ash.Changeset.force_change_attribute(:agent_id, agent.id)
            |> Ash.Changeset.force_change_attribute(:status, "assigned")
            |> Ash.Changeset.put_context(:assigned_agent, agent)

          updated_agent = Map.update!(agent, :workload, &(&1 + 1))
          {updated_changeset, rest ++ [updated_agent]}
        end)

      assigned_changesets
    end
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context) do
    agent_updates =
      changesets_and_results
      |> Enum.map(fn {changeset, _result} -> changeset.context[:assigned_agent] end)
      |> Enum.filter(& &1)
      |> Enum.group_by(& &1.id)
      |> Enum.map(fn {agent_id, assignments} ->
        %{id: agent_id, workload_increment: length(assignments)}
      end)

    IO.inspect(agent_updates, label: "  Agent workload updates")

    Enum.map(changesets_and_results, fn {_changeset, result} ->
      {:ok, result}
    end)
  end
end

defmodule HelpDesk.Changes.ConditionalBatchProcessing do
  use Ash.Resource.Change

  @impl true
  def batch_callbacks?(changesets, _opts, _context) do
    length(changesets) >= 10
  end

  @impl true
  def batch_change(changesets, _opts, _context) do
    HelpDesk.ProcessingTracker.record(:batch_change_calls)
    changesets
  end

  @impl true
  def before_batch(changesets, _opts, _context) do
    HelpDesk.ProcessingTracker.record(:before_batch_calls)
    changesets
  end

  @impl true
  def after_batch(changesets_and_results, _opts, _context) do
    HelpDesk.ProcessingTracker.record(:after_batch_calls)
    Enum.map(changesets_and_results, fn {_changeset, result} -> {:ok, result} end)
  end
end

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

defmodule HelpDesk.SupportAgent do
  use Ash.Resource,
    domain: HelpDesk,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "support_agents"
    repo HelpDesk.Repo
  end

  actions do
    defaults [:read, create: [:name, :status, :workload], update: [:workload, :status]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :status, :string, default: "available", public?: true
    attribute :workload, :integer, default: 0, public?: true
  end
end

defmodule HelpDesk.Ticket do
  use Ash.Resource,
    domain: HelpDesk,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "tickets"
    repo HelpDesk.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:title, :description]
    end

    create :create_with_notification do
      accept [:title, :description]
      change HelpDesk.Changes.BatchNotifyExternalSystem
    end

    create :create_with_assignment do
      accept [:title, :description]
      change HelpDesk.Changes.BatchAssignAgents
    end

    create :create_conditional do
      accept [:title, :description]
      change HelpDesk.Changes.ConditionalBatchProcessing
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :status, :string, default: "open", public?: true
    attribute :agent_id, :uuid, public?: true
    create_timestamp :inserted_at
  end
end

defmodule HelpDesk do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource HelpDesk.SupportAgent
    resource HelpDesk.Ticket
  end
end

# ---------------------------------------------------------------------------
# Boot infrastructure
# ---------------------------------------------------------------------------

{:ok, _} = HelpDesk.Repo.start_link()

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS support_agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  status TEXT DEFAULT 'available',
  workload INTEGER DEFAULT 0
)
""")

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS tickets (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT DEFAULT 'open',
  agent_id TEXT,
  inserted_at TEXT
)
""")

{:ok, _} = HelpDesk.ExternalAPI.start_link()
{:ok, _} = HelpDesk.ProcessingTracker.start_link()

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

IO.puts("""
================================================================================
  Ash Batch Callbacks Demo
================================================================================
""")

# --- Scenario 1: Batch notification via ExternalAPI ---

IO.puts("""
--- Scenario 1: BatchNotifyExternalSystem ---
  Bulk-create 5 tickets with :create_with_notification.
  The ExternalAPI should receive all notifications in a single batch call.
""")

ticket_inputs =
  for i <- 1..5 do
    %{title: "Ticket #{i}", description: "Description for ticket #{i}"}
  end

result =
  Ash.bulk_create(ticket_inputs, HelpDesk.Ticket, :create_with_notification,
    return_records?: true,
    return_errors?: true,
    sorted?: true
  )

IO.puts("  Bulk create status: #{result.status}")
IO.puts("  Records created: #{length(result.records || [])}")

if result.errors && result.errors != [] do
  IO.puts("  Errors: #{inspect(result.errors)}")
end

for ticket <- result.records || [] do
  IO.puts("    - #{ticket.title} (id: #{String.slice(ticket.id, 0..7)}..., inserted_at: #{ticket.inserted_at})")
end

notifications = HelpDesk.ExternalAPI.get_notifications()
IO.puts("\n  ExternalAPI received #{length(notifications)} notification(s):")

for n <- notifications do
  IO.puts("    - ticket_id: #{String.slice(n.ticket_id, 0..7)}..., title: #{n.title}")
end

IO.puts("")

# --- Scenario 2: Batch agent assignment ---

IO.puts("""
--- Scenario 2: BatchAssignAgents ---
  Create 3 agents, then bulk-create 3 tickets with :create_with_assignment.
  Agents should be distributed across tickets in round-robin fashion.
""")

agents =
  for name <- ["Alice", "Bob", "Carol"] do
    HelpDesk.SupportAgent
    |> Ash.Changeset.for_create(:create, %{name: name, status: "available", workload: 0})
    |> Ash.create!()
  end

IO.puts("  Created agents:")

for agent <- agents do
  IO.puts("    - #{agent.name} (workload: #{agent.workload}, status: #{agent.status})")
end

IO.puts("")

assignment_inputs =
  for i <- 1..3 do
    %{title: "Support request #{i}", description: "Needs agent attention #{i}"}
  end

assign_result =
  Ash.bulk_create(assignment_inputs, HelpDesk.Ticket, :create_with_assignment,
    return_records?: true,
    return_errors?: true,
    sorted?: true
  )

IO.puts("  Bulk create status: #{assign_result.status}")
IO.puts("  Records created: #{length(assign_result.records || [])}")

if assign_result.errors && assign_result.errors != [] do
  IO.puts("  Errors: #{inspect(assign_result.errors)}")
end

IO.puts("\n  Assigned tickets:")

agent_map = Map.new(agents, fn a -> {a.id, a.name} end)

for ticket <- assign_result.records || [] do
  agent_name = Map.get(agent_map, ticket.agent_id, "(unknown)")

  IO.puts(
    "    - #{ticket.title} -> agent: #{agent_name}, status: #{ticket.status}"
  )
end

IO.puts("")

# --- Scenario 3: Conditional batch processing ---

IO.puts("""
--- Scenario 3: ConditionalBatchProcessing ---
  batch_callbacks?/3 returns true only when batch size >= 10.
  This controls whether before_batch/3 and after_batch/3 fire.
  batch_change/3 always runs in bulk operations regardless.

  Small batch (3 items)  -> batch_change runs, but before/after_batch skipped
  Large batch (12 items) -> batch_change runs, AND before/after_batch fire
""")

HelpDesk.ProcessingTracker.reset()

small_inputs =
  for i <- 1..3 do
    %{title: "Small batch #{i}", description: "small"}
  end

IO.puts("  Creating 3 tickets (small batch, below threshold)...")

Ash.bulk_create(small_inputs, HelpDesk.Ticket, :create_conditional,
  return_errors?: true
)

stats_after_small = HelpDesk.ProcessingTracker.get_stats()

IO.puts("  After small batch:")
IO.puts("    batch_change calls:  #{stats_after_small.batch_change_calls}")
IO.puts("    before_batch calls:  #{stats_after_small.before_batch_calls}")
IO.puts("    after_batch calls:   #{stats_after_small.after_batch_calls}")

large_inputs =
  for i <- 1..12 do
    %{title: "Large batch #{i}", description: "large"}
  end

IO.puts("\n  Creating 12 tickets (large batch, above threshold)...")

Ash.bulk_create(large_inputs, HelpDesk.Ticket, :create_conditional,
  return_records?: true,
  return_errors?: true
)

stats_after_large = HelpDesk.ProcessingTracker.get_stats()

IO.puts("  After large batch (cumulative):")
IO.puts("    batch_change calls:  #{stats_after_large.batch_change_calls}")
IO.puts("    before_batch calls:  #{stats_after_large.before_batch_calls}")
IO.puts("    after_batch calls:   #{stats_after_large.after_batch_calls}")

if stats_after_small.before_batch_calls == 0 && stats_after_small.after_batch_calls == 0 do
  IO.puts("\n  [OK] Small batch: before/after_batch correctly skipped (batch_callbacks? -> false)")
else
  IO.puts("\n  [!!] Small batch: before/after_batch ran unexpectedly")
end

if stats_after_large.before_batch_calls > stats_after_small.before_batch_calls &&
     stats_after_large.after_batch_calls > stats_after_small.after_batch_calls do
  IO.puts("  [OK] Large batch: before/after_batch correctly fired (batch_callbacks? -> true)")
else
  IO.puts("  [!!] Large batch: before/after_batch did not fire as expected")
end

# --- Summary ---

IO.puts("""

================================================================================
  Summary
================================================================================
""")

all_tickets = Ash.read!(HelpDesk.Ticket)
IO.puts("Total tickets in database: #{length(all_tickets)}")
IO.puts("  - With notification change: 5")
IO.puts("  - With agent assignment:    3")
IO.puts("  - Conditional (small):      3")
IO.puts("  - Conditional (large):      12")
IO.puts("  - Total expected:           23")

IO.puts("\nExternalAPI notifications stored: #{length(HelpDesk.ExternalAPI.get_notifications())}")

final_stats = HelpDesk.ProcessingTracker.get_stats()
IO.puts("Processing tracker:")
IO.puts("  batch_change calls:  #{final_stats.batch_change_calls}")
IO.puts("  before_batch calls:  #{final_stats.before_batch_calls}")
IO.puts("  after_batch calls:   #{final_stats.after_batch_calls}")

IO.puts("""

================================================================================
  Done.
================================================================================
""")
