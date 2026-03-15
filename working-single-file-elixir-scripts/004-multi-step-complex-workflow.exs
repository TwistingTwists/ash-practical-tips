# Ash Multi-Step Actions: All 4 Hook Types (before_transaction, before_action,
# after_action, after_transaction)
#
# Based on Example 3 from the Ash documentation:
# https://github.com/ash-project/ash/blob/v3.19.3/documentation/topics/advanced/multi-step-actions.md
#
# Demonstrates an urgent ticket processing workflow where each hook stage has
# a distinct responsibility:
#
#   before_transaction  - validate external service availability (no DB txn yet)
#   before_action       - reserve resources or downgrade priority (inside txn)
#   after_action        - create escalation + external case ref (inside txn)
#   after_transaction   - release slots, send notifications, record metrics
#
# Run: elixir 004-multi-step-complex-workflow.exs

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "004-multi-step-workflow.sqlite3")
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
# Stub modules backed by Agents so we can inspect state after the demo
# ---------------------------------------------------------------------------

defmodule HelpDesk.ExternalServices do
  def start_link do
    Agent.start_link(fn -> %{health: :ok, cases: []} end, name: __MODULE__)
  end

  def set_health(status), do: Agent.update(__MODULE__, &Map.put(&1, :health, status))

  def health_check do
    Agent.get(__MODULE__, & &1.health)
  end

  def create_urgent_case(ticket) do
    ref_id = "URG-#{ticket.id |> String.slice(0..7)}-#{System.system_time(:second)}"
    Agent.update(__MODULE__, fn state ->
      Map.update!(state, :cases, &[%{ticket_id: ticket.id, ref: ref_id} | &1])
    end)
    {:ok, ref_id}
  end

  def get_cases, do: Agent.get(__MODULE__, & &1.cases)
end

defmodule HelpDesk.ResourceManager do
  def start_link do
    Agent.start_link(fn -> %{next_slot: 1, reserved: [], released: []} end, name: __MODULE__)
  end

  def reserve_urgent_slot do
    Agent.get_and_update(__MODULE__, fn state ->
      slot_id = "SLOT-#{state.next_slot}"
      new_state = %{state | next_slot: state.next_slot + 1, reserved: [slot_id | state.reserved]}
      {{:ok, slot_id}, new_state}
    end)
  end

  def release_slot(slot_id) do
    Agent.update(__MODULE__, fn state ->
      %{state | released: [slot_id | state.released]}
    end)
  end

  def get_state, do: Agent.get(__MODULE__, & &1)
end

defmodule HelpDesk.Notifications do
  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def notify_priority_downgrade(ticket) do
    Agent.update(__MODULE__, &[%{type: :priority_downgrade, ticket_id: ticket.id, priority: ticket.priority} | &1])
  end

  def get_all, do: Agent.get(__MODULE__, & &1)
end

defmodule HelpDesk.Metrics do
  def start_link do
    Agent.start_link(fn -> %{urgent_tickets: 0} end, name: __MODULE__)
  end

  def increment_urgent_tickets do
    Agent.update(__MODULE__, &Map.update!(&1, :urgent_tickets, fn c -> c + 1 end))
  end

  def get_all, do: Agent.get(__MODULE__, & &1)
end

defmodule HelpDesk.AppLogger do
  def start_link do
    Agent.start_link(fn -> [] end, name: __MODULE__)
  end

  def log(level, message) do
    Agent.update(__MODULE__, &[%{level: level, message: message, at: DateTime.utc_now()} | &1])
  end

  def info(msg), do: log(:info, msg)
  def error(msg), do: log(:error, msg)

  def get_all, do: Agent.get(__MODULE__, & &1)
end

# ---------------------------------------------------------------------------
# Resources
# ---------------------------------------------------------------------------

defmodule HelpDesk.Escalation do
  use Ash.Resource,
    domain: HelpDesk,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "escalations"
    repo HelpDesk.Repo
  end

  actions do
    defaults [:read]

    create :create do
      accept [:ticket_id, :level, :escalated_at]
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :ticket_id, :uuid do
      allow_nil? false
      public? true
    end

    attribute :level, :integer do
      allow_nil? false
      public? true
    end

    attribute :escalated_at, :utc_datetime do
      allow_nil? false
      public? true
    end
  end
end

defmodule HelpDesk.Changes.ProcessUrgentTicket do
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    changeset
    |> Ash.Changeset.before_transaction(&validate_external_services/1)
    |> Ash.Changeset.before_action(&prepare_urgent_processing/1)
    |> Ash.Changeset.after_action(&complete_urgent_workflow/2)
    |> Ash.Changeset.after_transaction(&cleanup_and_notify/2)
  end

  defp validate_external_services(changeset) do
    HelpDesk.AppLogger.info("[before_transaction] Checking external service health...")

    case HelpDesk.ExternalServices.health_check() do
      :ok ->
        HelpDesk.AppLogger.info("[before_transaction] External services healthy")
        changeset

      {:error, service} ->
        HelpDesk.AppLogger.error("[before_transaction] Service #{service} unavailable")

        Ash.Changeset.add_error(changeset,
          message: "External service #{service} unavailable for urgent processing"
        )
    end
  end

  defp prepare_urgent_processing(changeset) do
    priority = Ash.Changeset.get_attribute(changeset, :priority)
    HelpDesk.AppLogger.info("[before_action] Preparing ticket with priority=#{priority}")

    if priority == "urgent" do
      case HelpDesk.ResourceManager.reserve_urgent_slot() do
        {:ok, slot_id} ->
          HelpDesk.AppLogger.info("[before_action] Reserved #{slot_id} for urgent processing")

          changeset
          |> Ash.Changeset.force_change_attribute(:status, "urgent_processing")
          |> Ash.Changeset.force_change_attribute(:processing_slot_id, slot_id)
          |> Ash.Changeset.put_context(:reserved_slot, slot_id)

        {:error, :no_slots_available} ->
          HelpDesk.AppLogger.info("[before_action] No slots available, downgrading to high")

          changeset
          |> Ash.Changeset.force_change_attribute(:priority, "high")
          |> Ash.Changeset.put_context(:priority_downgraded, true)
      end
    else
      HelpDesk.AppLogger.info("[before_action] Non-urgent ticket, skipping slot reservation")
      changeset
    end
  end

  defp complete_urgent_workflow(_changeset, ticket) do
    HelpDesk.AppLogger.info("[after_action] Completing workflow for ticket #{ticket.id}")

    if ticket.status == "urgent_processing" do
      with {:ok, escalation} <- create_escalation_path(ticket),
           {:ok, ref_id} <- HelpDesk.ExternalServices.create_urgent_case(ticket) do
        HelpDesk.AppLogger.info(
          "[after_action] Created escalation level=#{escalation.level}, external ref=#{ref_id}"
        )

        {:ok, ticket}
      else
        {:error, reason} ->
          HelpDesk.AppLogger.error(
            "[after_action] Failed to complete urgent workflow: #{inspect(reason)}"
          )

          {:ok, ticket}
      end
    else
      HelpDesk.AppLogger.info("[after_action] Ticket not urgent_processing, skipping escalation")
      {:ok, ticket}
    end
  end

  defp cleanup_and_notify(changeset, {:ok, ticket}) do
    HelpDesk.AppLogger.info("[after_transaction] Success path for ticket #{ticket.id}")

    if slot_id = changeset.context[:reserved_slot] do
      HelpDesk.ResourceManager.release_slot(slot_id)
      HelpDesk.AppLogger.info("[after_transaction] Released #{slot_id}")
    end

    if changeset.context[:priority_downgraded] do
      HelpDesk.Notifications.notify_priority_downgrade(ticket)
      HelpDesk.AppLogger.info("[after_transaction] Sent priority downgrade notification")
    end

    HelpDesk.Metrics.increment_urgent_tickets()
    HelpDesk.AppLogger.info("[after_transaction] Incremented urgent ticket metrics")

    {:ok, ticket}
  end

  defp cleanup_and_notify(changeset, {:error, _reason} = error) do
    HelpDesk.AppLogger.error("[after_transaction] Error path, cleaning up resources")

    if slot_id = changeset.context[:reserved_slot] do
      HelpDesk.ResourceManager.release_slot(slot_id)
      HelpDesk.AppLogger.error("[after_transaction] Released #{slot_id} after error")
    end

    error
  end

  defp create_escalation_path(ticket) do
    HelpDesk.Escalation
    |> Ash.Changeset.for_create(:create, %{
      ticket_id: ticket.id,
      level: 1,
      escalated_at: DateTime.utc_now()
    })
    |> Ash.create()
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
      accept [:title, :description, :priority]
    end

    create :create_urgent do
      accept [:title, :description, :priority]
      change HelpDesk.Changes.ProcessUrgentTicket
    end
  end

  attributes do
    uuid_primary_key :id

    attribute :title, :string do
      allow_nil? false
      public? true
    end

    attribute :description, :string do
      allow_nil? false
      public? true
    end

    attribute :priority, :string do
      allow_nil? false
      public? true
    end

    attribute :status, :string do
      allow_nil? false
      default "open"
      public? true
    end

    attribute :processing_slot_id, :string do
      allow_nil? true
      public? true
    end

    attribute :external_ref, :string do
      allow_nil? true
      public? true
    end
  end
end

defmodule HelpDesk do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource HelpDesk.Ticket
    resource HelpDesk.Escalation
  end
end

# ---------------------------------------------------------------------------
# Boot infrastructure
# ---------------------------------------------------------------------------

{:ok, _} = HelpDesk.Repo.start_link()

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS tickets (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  description TEXT NOT NULL,
  priority TEXT NOT NULL,
  status TEXT NOT NULL DEFAULT 'open',
  processing_slot_id TEXT,
  external_ref TEXT
)
""")

Ecto.Adapters.SQL.query!(HelpDesk.Repo, """
CREATE TABLE IF NOT EXISTS escalations (
  id TEXT PRIMARY KEY,
  ticket_id TEXT NOT NULL,
  level INTEGER NOT NULL,
  escalated_at TEXT NOT NULL
)
""")

HelpDesk.ExternalServices.start_link()
HelpDesk.ResourceManager.start_link()
HelpDesk.Notifications.start_link()
HelpDesk.Metrics.start_link()
HelpDesk.AppLogger.start_link()

# ---------------------------------------------------------------------------
# Demo scenarios
# ---------------------------------------------------------------------------

IO.puts("""
================================================================================
  Ash Multi-Step Actions: 4-Hook Lifecycle Demo
================================================================================
""")

# --- Scenario 1: Urgent ticket (full lifecycle) ---
IO.puts("""
--- Scenario 1: Create an URGENT ticket ---
  Expected flow:
    before_transaction  -> health check passes
    before_action       -> slot reserved, status set to urgent_processing
    after_action        -> escalation created, external case created
    after_transaction   -> slot released, metrics incremented
""")

urgent_ticket =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create_urgent, %{
    title: "Production DB down",
    description: "Primary database cluster is unreachable",
    priority: "urgent"
  })
  |> Ash.create!()

IO.puts("  Created ticket: #{urgent_ticket.id}")
IO.puts("  Title:          #{urgent_ticket.title}")
IO.puts("  Priority:       #{urgent_ticket.priority}")
IO.puts("  Status:         #{urgent_ticket.status}")
IO.puts("  Slot ID:        #{urgent_ticket.processing_slot_id || "(none)"}")
IO.puts("")

# --- Scenario 2: Non-urgent ticket through the same action ---
IO.puts("""
--- Scenario 2: Create a NORMAL ticket via :create_urgent action ---
  Expected flow:
    before_transaction  -> health check passes
    before_action       -> priority != urgent, skips slot reservation
    after_action        -> status != urgent_processing, skips escalation
    after_transaction   -> no slot to release, metrics still incremented
""")

normal_ticket =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create_urgent, %{
    title: "Update docs",
    description: "README needs a refresh",
    priority: "normal"
  })
  |> Ash.create!()

IO.puts("  Created ticket: #{normal_ticket.id}")
IO.puts("  Title:          #{normal_ticket.title}")
IO.puts("  Priority:       #{normal_ticket.priority}")
IO.puts("  Status:         #{normal_ticket.status}")
IO.puts("  Slot ID:        #{normal_ticket.processing_slot_id || "(none)"}")
IO.puts("")

# --- Scenario 3: External service failure ---
IO.puts("""
--- Scenario 3: External service DOWN, attempt urgent ticket ---
  Expected flow:
    before_transaction  -> health check FAILS, error added to changeset
    (remaining hooks never execute)
""")

HelpDesk.ExternalServices.set_health({:error, "ticketing-gateway"})

failure_result =
  HelpDesk.Ticket
  |> Ash.Changeset.for_create(:create_urgent, %{
    title: "This should fail",
    description: "External service is down",
    priority: "urgent"
  })
  |> Ash.create()

case failure_result do
  {:error, error} ->
    IO.puts("  Got expected error:")
    IO.puts("  #{inspect(error)}")

  {:ok, ticket} ->
    IO.puts("  UNEXPECTED SUCCESS: #{ticket.id}")
end

IO.puts("")

# Reset health for completeness
HelpDesk.ExternalServices.set_health(:ok)

# --- Scenario 4: Print all tracked state ---
IO.puts("""
================================================================================
  Final State Summary
================================================================================
""")

resource_state = HelpDesk.ResourceManager.get_state()
IO.puts("ResourceManager:")
IO.puts("  Reserved slots: #{inspect(Enum.reverse(resource_state.reserved))}")
IO.puts("  Released slots: #{inspect(Enum.reverse(resource_state.released))}")
IO.puts("")

escalations = HelpDesk.Escalation |> Ash.read!()
IO.puts("Escalations (#{length(escalations)}):")

Enum.each(escalations, fn esc ->
  IO.puts("  ticket=#{esc.ticket_id} level=#{esc.level} at=#{esc.escalated_at}")
end)

IO.puts("")

external_cases = HelpDesk.ExternalServices.get_cases()
IO.puts("External Cases (#{length(external_cases)}):")

Enum.each(external_cases, fn c ->
  IO.puts("  ticket=#{c.ticket_id} ref=#{c.ref}")
end)

IO.puts("")

metrics = HelpDesk.Metrics.get_all()
IO.puts("Metrics:")
IO.puts("  urgent_tickets processed: #{metrics.urgent_tickets}")
IO.puts("")

notifications = HelpDesk.Notifications.get_all()
IO.puts("Notifications (#{length(notifications)}):")

Enum.each(notifications, fn n ->
  IO.puts("  type=#{n.type} ticket=#{n.ticket_id}")
end)

if notifications == [], do: IO.puts("  (none -- no priority downgrades occurred)")
IO.puts("")

logs = HelpDesk.AppLogger.get_all() |> Enum.reverse()
IO.puts("AppLogger (#{length(logs)} entries):")

Enum.each(logs, fn entry ->
  IO.puts("  [#{entry.level}] #{entry.message}")
end)

IO.puts("""

================================================================================
  Demo complete.
================================================================================
""")
