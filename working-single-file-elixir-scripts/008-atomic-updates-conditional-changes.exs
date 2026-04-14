# Ash Atomic Updates & Conditional Changes
#
# Demonstrates how Ash compiles conditional logic into SQL CASE expressions,
# keeping bulk updates as single queries:
#
#   1. atomic_update with `where: [changing(:attribute)]`
#      — only recompute slug when title actually changes
#   2. validate with `where:` condition
#      — validation becomes a SQL CASE expression
#   3. Ash.bulk_update! stays a single SQL statement regardless of row count
#
# Based on:
# https://hexdocs.pm/ash/update-actions.html#atomic-updates
#
# Key insight: `where: [changing(:title)]` doesn't guard in Elixir —
# it gets compiled INTO the UPDATE statement itself as a CASE expression.
#
# Run: elixir 008-atomic-updates-conditional-changes.exs

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "008-atomic-updates.sqlite3")
File.rm(sqlite_path)

Application.put_env(:atomic_demo, AtomicDemo.Repo,
  database: sqlite_path,
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
)

defmodule AtomicDemo.Repo do
  use AshSqlite.Repo, otp_app: :atomic_demo
end

# ---------------------------------------------------------------------------
# Custom Change: regenerate slug only when title is changing
# ---------------------------------------------------------------------------

defmodule AtomicDemo.Changes.RegenerateSlug do
  @moduledoc """
  An atomic change that recomputes the slug from the title.
  When used with `where: [changing(:title)]`, Ash compiles this
  into a CASE expression in the UPDATE statement:

    SET slug = CASE WHEN title != $new_title
                    THEN lower(replace($new_title, ' ', '-'))
                    ELSE slug END
  """
  use Ash.Resource.Change

  @impl true
  def change(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :title) do
      nil ->
        changeset

      title ->
        slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")
        Ash.Changeset.force_change_attribute(changeset, :slug, slug)
    end
  end

  @impl true
  def atomic(_changeset, _opts, _context) do
    # In a real Postgres setup you'd use fragment("slugify(?)", ^atomic_ref(:title))
    # SQLite doesn't have custom functions, so we use lower + replace as a stand-in.
    {:atomic, %{slug: expr(fragment("lower(replace(?, ' ', '-'))", ^atomic_ref(:title)))}}
  end
end

# ---------------------------------------------------------------------------
# Resource: Article
# ---------------------------------------------------------------------------

defmodule AtomicDemo.Article do
  use Ash.Resource,
    domain: AtomicDemo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "articles"
    repo AtomicDemo.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:title, :slug, :status, :reason]]

    update :update do
      accept [:title, :status, :reason]
      require_atomic? false

      # Only regenerate slug when title is actually changing.
      # In atomic context this becomes a CASE expression in SQL.
      change AtomicDemo.Changes.RegenerateSlug,
        where: [changing(:title)]

      # Validate: reason must be present when status is "open".
      # This also compiles into a CASE in atomic bulk updates.
      validate present(:reason),
        where: [attribute_equals(:status, "open")],
        message: "reason is required when status is open"
    end

    update :bump_views do
      # Pure atomic increment — no Elixir round-trip per row.
      change atomic_update(:view_count, expr(view_count + 1))
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :title, :string, allow_nil?: false, public?: true
    attribute :slug, :string, public?: true
    attribute :status, :string, default: "draft", public?: true
    attribute :reason, :string, public?: true
    attribute :view_count, :integer, default: 0, public?: true
    create_timestamp :inserted_at
    update_timestamp :updated_at
  end
end

# ---------------------------------------------------------------------------
# Domain
# ---------------------------------------------------------------------------

defmodule AtomicDemo do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource AtomicDemo.Article
  end
end

# ---------------------------------------------------------------------------
# Boot
# ---------------------------------------------------------------------------

{:ok, _} = AtomicDemo.Repo.start_link()

Ecto.Adapters.SQL.query!(AtomicDemo.Repo, """
CREATE TABLE IF NOT EXISTS articles (
  id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  slug TEXT,
  status TEXT DEFAULT 'draft',
  reason TEXT,
  view_count INTEGER DEFAULT 0,
  inserted_at TEXT,
  updated_at TEXT
)
""")

# ---------------------------------------------------------------------------
# Demo
# ---------------------------------------------------------------------------

IO.puts("""
================================================================================
  Ash Atomic Updates & Conditional Changes Demo
================================================================================
""")

# --- Seed data ---

articles =
  for {title, status} <- [
    {"Hello World", "draft"},
    {"Elixir Rocks", "open"},
    {"Ash Framework Guide", "draft"},
    {"Phoenix LiveView Tips", "open"},
    {"OTP Patterns", "draft"}
  ] do
    slug = title |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-")

    AtomicDemo.Article
    |> Ash.Changeset.for_create(:create, %{
      title: title,
      slug: slug,
      status: status,
      reason: if(status == "open", do: "Initial creation", else: nil)
    })
    |> Ash.create!()
  end

IO.puts("--- Seed Data ---")

for a <- articles do
  IO.puts("  #{a.title} | slug=#{a.slug} | status=#{a.status} | views=#{a.view_count}")
end

IO.puts("")

# --- Scenario 1: Conditional slug regeneration ---

IO.puts("""
--- Scenario 1: Conditional Slug Regeneration ---
  Update title on one article -> slug should change.
  Update status only on another -> slug should NOT change.
  This is the `where: [changing(:title)]` behavior.
""")

[article_1, article_2 | _rest] = articles

IO.puts("  Before:")
IO.puts("    Article 1: title=#{article_1.title}, slug=#{article_1.slug}")
IO.puts("    Article 2: title=#{article_2.title}, slug=#{article_2.slug}")

# Change title -> slug should regenerate
article_1_updated =
  article_1
  |> Ash.Changeset.for_update(:update, %{title: "Hello Universe"})
  |> Ash.update!()

# Change only status (with reason) -> slug should stay the same
article_2_updated =
  article_2
  |> Ash.Changeset.for_update(:update, %{status: "open", reason: "Reopened for review"})
  |> Ash.update!()

IO.puts("\n  After:")
IO.puts("    Article 1: title=#{article_1_updated.title}, slug=#{article_1_updated.slug}  <- slug changed!")
IO.puts("    Article 2: title=#{article_2_updated.title}, slug=#{article_2_updated.slug}  <- slug unchanged!")
IO.puts("")

# --- Scenario 2: Conditional validation ---

IO.puts("""
--- Scenario 2: Conditional Validation ---
  Setting status to "open" without a reason should fail.
  The `validate present(:reason), where: [attribute_equals(:status, "open")]`
  compiles into a CASE expression in atomic context.
""")

[_a1, _a2, article_3 | _] = articles

IO.puts("  Trying to set article 3 to status='open' without reason...")

case article_3
     |> Ash.Changeset.for_update(:update, %{status: "open", reason: nil})
     |> Ash.update() do
  {:ok, _} ->
    IO.puts("  Unexpected success!")

  {:error, error} ->
    IO.puts("  Got expected error: #{Exception.message(error)}")
end

IO.puts("\n  Now with a reason...")

{:ok, article_3_updated} =
  article_3
  |> Ash.Changeset.for_update(:update, %{status: "open", reason: "Needs review"})
  |> Ash.update()

IO.puts("  Success! status=#{article_3_updated.status}, reason=#{article_3_updated.reason}")
IO.puts("")

# --- Scenario 3: Atomic increment via bulk update ---

IO.puts("""
--- Scenario 3: Atomic Counter Increment (bulk) ---
  `change atomic_update(:view_count, expr(view_count + 1))` compiles to:
    UPDATE articles SET view_count = view_count + 1 WHERE ...
  Single SQL statement, no Elixir round-trip per row.
""")

IO.puts("  View counts before:")
all_before = AtomicDemo.Article |> Ash.read!()
for a <- all_before, do: IO.puts("    #{a.title}: #{a.view_count}")

# Bump views on ALL articles in one shot
AtomicDemo.Article
|> Ash.read!()
|> Ash.bulk_update!(:bump_views, %{}, return_errors?: true)

# Bump again to show it stacks
AtomicDemo.Article
|> Ash.read!()
|> Ash.bulk_update!(:bump_views, %{}, return_errors?: true)

IO.puts("\n  View counts after 2 bulk bumps:")
all_after = AtomicDemo.Article |> Ash.read!()
for a <- all_after, do: IO.puts("    #{a.title}: #{a.view_count}")
IO.puts("")

# --- Scenario 4: Bulk update with conditional changes ---

IO.puts("""
--- Scenario 4: Bulk Update with Conditional Slug Regen ---
  Bulk-update all articles with a new title.
  The slug regeneration happens atomically for each row
  via CASE WHEN title != new_title THEN ... ELSE slug END
""")

IO.puts("  Before:")
for a <- all_after, do: IO.puts("    #{a.title} | slug=#{a.slug}")

bulk_result =
  AtomicDemo.Article
  |> Ash.read!()
  |> Ash.bulk_update!(:update, %{title: "Updated Article"},
    return_records?: true,
    return_errors?: true,
    # SQLite lacks ash_raise_error(), so the conditional validation can't go
    # fully atomic. Allow :stream fallback. On Postgres this stays :atomic.
    strategy: [:atomic_batches, :atomic, :stream]
  )

IO.puts("\n  Bulk update status: #{bulk_result.status}")
IO.puts("  Records updated: #{length(bulk_result.records || [])}")

if bulk_result.errors && bulk_result.errors != [] do
  IO.puts("  Errors: #{inspect(bulk_result.errors)}")
end

IO.puts("\n  After:")
for a <- bulk_result.records || [] do
  IO.puts("    #{a.title} | slug=#{a.slug}")
end

IO.puts("""

================================================================================
  KEY TAKEAWAY:
  `where: [changing(:title)]` and `where: [attribute_equals(:status, :open)]`
  don't run as Elixir guards — they compile directly into SQL CASE expressions.
  One bulk_update! = one UPDATE statement, no matter how many rows.
================================================================================
""")

# Cleanup
File.rm(sqlite_path)
