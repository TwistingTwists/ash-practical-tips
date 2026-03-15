# Ash Multi-Step Actions Using Simple Hooks
#
# Demonstrates how to use `Ash.Changeset.before_action/2` and
# `Ash.Changeset.after_action/2` inside custom Change modules to
# compose multi-step logic around a single Ash action.
#
# Based on:
# https://github.com/ash-project/ash/blob/v3.19.3/documentation/topics/advanced/multi-step-actions.md
#
# Example 1 — Simple Activity Logging (after_action hook)
# Example 2 — Multi-Hook Ticket Assignment (before_action + after_action hooks)
#
# Run: elixir 003-multi-step-simple-hooks.exs

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "003-multi-step-simple-hooks.sqlite3")
File.rm(sqlite_path)

Application.put_env(:helpdesk, HelpDesk.Repo,
  database: sqlite_path,
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
)

defmodule HelpDesk.Repo do
  use AshSqlite.Repo, otp_app: :helpdesk
end

# --- Stub modules backed by Elixir Agents ---

defmodule HelpDesk.ActivityLog do
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def log(entry) do
    Agent.update(__MODULE__, fn logs -> logs ++ [entry] end)
  end

  def get_logs, do: Agent.get(__MODULE__, & &1)
end

defmodule HelpDesk.Notifications do
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def notify_assignment(agent, ticket) do
    entry = "Agent #{agent.name} assigned to ticket #{ticket.id} (#{ticket.title})"
    Agent.update(__MODULE__, fn notifs -> notifs ++ [entry] end)
  end

  def get_notifications, do: Agent.get(__MODULE__, & &1)
end

defmodule HelpDesk.AgentManager do
  require Ash.Query

  def find_available_agent do
    case HelpDesk.Agent |> Ash.Query.filter(status == "available") |> Ash.read!() do
      [agent | _] -> {:ok, agent}
      [] -> {:error, "no agents available"}
    end
  end
end

# --- Change modules (mirror the documentation examples) ---

defmodule HelpDesk.Changes.LogActivity do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    Ash.Changeset.after_action(changeset, fn _changeset, ticket ->
      HelpDesk.ActivityLog.log("Ticket #{ticket.id} created: #{ticket.title}")
      {:ok, ticket}
    end)
  end
end

defmodule HelpDesk.Changes.AssignTicket do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_action(&find_and_assign_agent/1)
    |> Ash.Changeset.after_action(&notify_assignment/2)
  end

  defp find_and_assign_agent(changeset) do
    case HelpDesk.AgentManager.find_available_agent() do
      {:ok, agent} ->
        changeset
        |> Ash.Changeset.force_change_attribute(:agent_id, agent.id)
        |> Ash.Changeset.force_change_attribute(:status, "assigned")
        |> Ash.Changeset.put_context(:assigned_agent, agent)

      {:error, reason} ->
        Ash.Changeset.add_error(changeset, "No agents available: #{reason}")
    end
  end

  defp notify_assignment(changeset, ticket) do
    agent = changeset.context[:assigned_agent]
    HelpDesk.Notifications.notify_assignment(agent, ticket)
    {:ok, ticket}
  end
end

# --- Resources ---

defmodule HelpDesk.Agent do
  use Ash.Resource,
    domain: HelpDesk,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "agents"
    repo HelpDesk.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:name, :status], update: [:name, :status]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :status, :string, default: "available", public?: true
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
    defaults [:read, :destroy]

    create :create do
      accept [:title, :description]
      change HelpDesk.Changes.LogActivity
    end

    create :create_and_assign do
      accept [:title, :description]
      change HelpDesk.Changes.LogActivity
      change HelpDesk.Changes.AssignTicket
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :description, :string, public?: true
    attribute :status, :string, default: "open", public?: true
    attribute :agent_id, :uuid, public?: true
  end
end

# --- Domain ---

defmodule HelpDesk do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource HelpDesk.Agent
    resource HelpDesk.Ticket
  end
end

# --- Boot infrastructure ---

{:ok, _} = HelpDesk.Repo.start_link()

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS agents (
  id TEXT PRIMARY KEY,
  name TEXT NOT NULL,
  status TEXT DEFAULT 'available'
)
""")

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS tickets (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT,
  status TEXT DEFAULT 'open',
  agent_id TEXT
)
""")

{:ok, _} = HelpDesk.ActivityLog.start_link()
{:ok, _} = HelpDesk.Notifications.start_link()

# --- Demo ---

IO.puts("=== Ash Multi-Step Actions: Simple Hooks ===\n")

# 1. Create a support agent
agent =
  HelpDesk.Agent
  |> Ash.Changeset.for_create(:create, %{name: "Alice"})
  |> Ash.create!()

IO.puts("1) Created agent: #{agent.name} (status: #{agent.status})")

# 2. Create a basic ticket (LogActivity hook fires)
ticket1 =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create, %{
    title: "Login page broken",
    description: "Users cannot log in since last deploy"
  })
  |> Ash.create!()

IO.puts("\n2) Created ticket: #{ticket1.title}")
IO.puts("   status: #{ticket1.status}, agent_id: #{inspect(ticket1.agent_id)}")
IO.puts("   Activity logs so far: #{inspect(HelpDesk.ActivityLog.get_logs())}")

# 3. Create a ticket with assignment (both LogActivity and AssignTicket hooks fire)
ticket2 =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create_and_assign, %{
    title: "Password reset email delayed",
    description: "Reset emails take over 10 minutes to arrive"
  })
  |> Ash.create!()

IO.puts("\n3) Created + assigned ticket: #{ticket2.title}")
IO.puts("   status: #{ticket2.status}, agent_id: #{ticket2.agent_id}")

# 4. Print all activity logs and notifications
IO.puts("\n4) All activity logs:")

for log <- HelpDesk.ActivityLog.get_logs() do
  IO.puts("   - #{log}")
end

IO.puts("\n5) All notifications:")

for notif <- HelpDesk.Notifications.get_notifications() do
  IO.puts("   - #{notif}")
end

IO.puts("\nDone.")
