# Ash Generic Actions with a Plain Module as the `run` Implementation
#
# Demonstrates how to use `Ash.Resource.Actions.Implementation` to define
# a standalone module that handles the logic for a generic (non-CRUD) action.
#
# Based on the Generic Action Example from:
# https://github.com/ash-project/ash/blob/v3.19.3/documentation/topics/advanced/multi-step-actions.md
#
# The doc example defines:
#
#   defmodule HelpDesk.Actions.AssignTicket do
#     def run(input, context) do
#       with {:ok, agent} <- HelpDesk.AgentManager.find_available_agent(),
#            {:ok, ticket} <- HelpDesk.get_ticket_by_id(input.arguments.ticket_id),
#            {:ok, ticket} <- HelpDesk.update_ticket(ticket, ...),
#            :ok <- Helpdesk.Notifications.notify_assignment(agent, ticket) do
#         {:ok, ticket}
#       end
#     end
#   end
#
# Note: The original doc has a syntax error (missing comma before `:ok <-`).
# This script fixes that and uses the proper `Ash.Resource.Actions.Implementation`
# behaviour with the correct `run/3` callback signature.
#
# Run: elixir 007-multi-step-generic-action.exs

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "007-multi-step-generic-action.sqlite3")
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

# --- Stub: Notification tracker backed by an Elixir Agent ---

defmodule HelpDesk.Notifications do
  use Agent

  def start_link(_opts \\ []), do: Agent.start_link(fn -> [] end, name: __MODULE__)

  def notify_assignment(agent, ticket) do
    entry = %{
      agent_name: agent.name,
      agent_id: agent.id,
      ticket_id: ticket.id,
      ticket_title: ticket.title,
      at: DateTime.utc_now()
    }

    Agent.update(__MODULE__, fn notifs -> notifs ++ [entry] end)
    :ok
  end

  def get_notifications, do: Agent.get(__MODULE__, & &1)
end

# --- Resources ---

defmodule HelpDesk.SupportAgent do
  use Ash.Resource,
    domain: HelpDesk,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "support_agents"
    repo HelpDesk.Repo
  end

  actions do
    defaults [:read, create: [:name, :status, :workload], update: [:status, :workload]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, allow_nil?: false, public?: true
    attribute :status, :string, default: "available", public?: true
    attribute :workload, :integer, default: 0, public?: true
  end
end

defmodule HelpDesk.Actions.AssignTicket do
  use Ash.Resource.Actions.Implementation

  require Ash.Query

  @impl true
  def run(input, _opts, _context) do
    ticket_id = Ash.ActionInput.get_argument(input, :ticket_id)

    with {:ok, agent} <- find_available_agent(),
         {:ok, ticket} <- fetch_ticket(ticket_id),
         {:ok, ticket} <- assign_ticket(ticket, agent),
         {:ok, agent} <- mark_agent_busy(agent),
         :ok <- HelpDesk.Notifications.notify_assignment(agent, ticket) do
      {:ok, ticket}
    end
  end

  defp find_available_agent do
    case HelpDesk.SupportAgent
         |> Ash.Query.filter(status == "available")
         |> Ash.Query.sort(:workload)
         |> Ash.read!() do
      [agent | _] -> {:ok, agent}
      [] -> {:error, "No available agents"}
    end
  end

  defp fetch_ticket(ticket_id) do
    case Ash.get(HelpDesk.Ticket, ticket_id) do
      {:ok, ticket} -> {:ok, ticket}
      {:error, _} = err -> err
    end
  end

  defp assign_ticket(ticket, agent) do
    ticket
    |> Ash.Changeset.for_update(:update, %{agent_id: agent.id, status: "assigned"})
    |> Ash.update()
  end

  defp mark_agent_busy(agent) do
    agent
    |> Ash.Changeset.for_update(:update, %{status: "busy", workload: agent.workload + 1})
    |> Ash.update()
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
    defaults [:read, create: [:title, :description], update: [:agent_id, :status]]

    action :assign_to_available_agent, :struct do
      constraints instance_of: HelpDesk.Ticket
      argument :ticket_id, :uuid, allow_nil?: false
      run HelpDesk.Actions.AssignTicket
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
    resource HelpDesk.SupportAgent
    resource HelpDesk.Ticket
  end
end

# --- Boot infrastructure ---

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
  agent_id TEXT
)
""")

{:ok, _} = HelpDesk.Notifications.start_link()

# --- Demo ---

IO.puts("""
================================================================================
  Ash Generic Actions: Implementation Module Demo
================================================================================
""")

# ---- Scenario 1: Successful assignment ----

IO.puts("--- Scenario 1: Successful ticket assignment ---\n")

agent1 =
  HelpDesk.SupportAgent
  |> Ash.Changeset.for_create(:create, %{name: "Alice"})
  |> Ash.create!()

IO.puts("  Created agent: #{agent1.name} (status: #{agent1.status}, workload: #{agent1.workload})")

ticket1 =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create, %{
    title: "Login page broken",
    description: "Users cannot log in since last deploy"
  })
  |> Ash.create!()

IO.puts("  Created ticket: \"#{ticket1.title}\" (status: #{ticket1.status}, agent_id: #{inspect(ticket1.agent_id)})")
IO.puts("")

IO.puts("  Calling :assign_to_available_agent generic action...")

assigned_ticket =
  HelpDesk.Ticket
  |> Ash.ActionInput.for_action(:assign_to_available_agent, %{ticket_id: ticket1.id})
  |> Ash.run_action!()

IO.puts("  Result:")
IO.puts("    ticket.status   = #{assigned_ticket.status}")
IO.puts("    ticket.agent_id = #{assigned_ticket.agent_id}")

refreshed_agent = Ash.get!(HelpDesk.SupportAgent, agent1.id)
IO.puts("    agent.status    = #{refreshed_agent.status}")
IO.puts("    agent.workload  = #{refreshed_agent.workload}")
IO.puts("")

# ---- Scenario 2: No agents available ----

IO.puts("--- Scenario 2: No available agents ---\n")

ticket2 =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create, %{
    title: "Password reset broken",
    description: "Reset emails never arrive"
  })
  |> Ash.create!()

IO.puts("  Created ticket: \"#{ticket2.title}\" (no available agents remain)")
IO.puts("  Calling :assign_to_available_agent...")

case HelpDesk.Ticket
     |> Ash.ActionInput.for_action(:assign_to_available_agent, %{ticket_id: ticket2.id})
     |> Ash.run_action() do
  {:ok, _ticket} ->
    IO.puts("  UNEXPECTED: assignment succeeded")

  {:error, error} ->
    IO.puts("  Got expected error: #{inspect(error)}")
end

IO.puts("")

# ---- Scenario 3: Multiple assignments (round-robin-like) ----

IO.puts("--- Scenario 3: Multiple assignments across 3 agents ---\n")

Ecto.Adapters.SQL.query!(HelpDesk.Repo, "DELETE FROM support_agents")
Ecto.Adapters.SQL.query!(HelpDesk.Repo, "DELETE FROM tickets")

agents =
  for name <- ["Bob", "Carol", "Dave"] do
    HelpDesk.SupportAgent
    |> Ash.Changeset.for_create(:create, %{name: name})
    |> Ash.create!()
  end

IO.puts("  Created agents: #{Enum.map_join(agents, ", ", & &1.name)}")

tickets =
  for title <- ["Server crash", "API timeout", "UI glitch"] do
    HelpDesk.Ticket
    |> Ash.Changeset.for_create(:create, %{
      title: title,
      description: "Issue: #{title}"
    })
    |> Ash.create!()
  end

IO.puts("  Created tickets: #{Enum.map_join(tickets, ", ", &"\"#{&1.title}\"")}")
IO.puts("")

IO.puts("  Assigning tickets one by one...")

_assigned_tickets =
  for ticket <- tickets do
    result =
      HelpDesk.Ticket
      |> Ash.ActionInput.for_action(:assign_to_available_agent, %{ticket_id: ticket.id})
      |> Ash.run_action!()

    assigned_agent = Ash.get!(HelpDesk.SupportAgent, result.agent_id)

    IO.puts("    \"#{result.title}\" -> #{assigned_agent.name} (agent workload: #{assigned_agent.workload})")

    result
  end

IO.puts("")

IO.puts("  Final agent states:")

all_agents =
  HelpDesk.SupportAgent
  |> Ash.Query.sort(:name)
  |> Ash.read!()

for agent <- all_agents do
  IO.puts("    #{agent.name}: status=#{agent.status}, workload=#{agent.workload}")
end

IO.puts("")

# ---- Print all notifications ----

IO.puts("--- All Notifications ---\n")

for notif <- HelpDesk.Notifications.get_notifications() do
  IO.puts("  Agent \"#{notif.agent_name}\" assigned to ticket #{notif.ticket_id} (#{notif.ticket_title})")
end

IO.puts("""

================================================================================
  Demo complete.
================================================================================
""")
