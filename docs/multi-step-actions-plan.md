# Multi-Step Actions — Standalone Examples Plan

Source: https://github.com/ash-project/ash/blob/v3.19.3/documentation/topics/advanced/multi-step-actions.md

## Script 003 — Simple Hooks (Examples 1 & 2)
- **Activity Logging**: `after_action` hook that logs ticket creation
- **Multi-Hook Assignment**: `before_action` (find agent) + `after_action` (notify)
- Stub modules: `HelpDesk.ActivityLog`, `HelpDesk.AgentManager`, `HelpDesk.Notifications`
- SQLite-backed Ticket + Agent resources

## Script 004 — Complex Workflow with External Services (Example 3)
- All 4 hook types: `before_transaction` → `before_action` → `after_action` → `after_transaction`
- Priority downgrade fallback logic, escalation paths, external service health checks
- Stub modules: `ExternalServices`, `ResourceManager`, `Metrics`, `Logger`
- SQLite-backed Ticket + Escalation resources

## Script 005 — Hook Shortcuts (Examples 4 & 5)
- Anonymous function change (`change fn changeset, context -> ...`)
- Builtin hook change (`change after_action(changeset, result, context -> ...)`)
- Minimal Ticket resource demonstrating both syntaxes side by side

## Script 006 — Batch Callbacks (Examples 6, 7, 8)
- `BatchNotifyExternalSystem`: batch_change + before_batch + after_batch with external API
- `BatchAssignAgents`: pre-load agents once, distribute across batch, bulk update workloads
- `ConditionalBatchProcessing`: `batch_callbacks?/3` to switch between individual & batch paths
- Uses `Ash.bulk_create` to trigger the batch code paths

## Script 007 — Generic Action (Example 9)
- Plain Elixir module as `run` function for an `action` block
- `transaction? true` generic action with argument
- Demonstrates the non-hook approach to multi-step coordination
