# QUESTION:
# Why does `manage_relationship` on this many-to-many fail with
# `record with role: :thumbnail | file_id: "..." not found`?
#
# ISSUE:
# The write payload used `%{file_id: ...}` for the destination identifier.
# In this write path, Ash expects destination `%{id: ...}` and role/sort metadata via `join_keys`.
#
# FIX:
# Manage through unfiltered `:files` relationship and pass
# `%{id: file_id, role: :thumbnail, sort_order: 1}`.
# Keep filtered relationships for reads only.

Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "001-many-many.sqlite3")
File.rm(sqlite_path)

Application.put_env(:many_many_demo, Demo.Repo,
  database: sqlite_path,
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
)

defmodule Demo.Repo do
  use AshSqlite.Repo, otp_app: :many_many_demo
end

defmodule Demo.File do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "files"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end

defmodule Demo.ProductFile do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "product_files"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :role, :atom do
      primary_key? true
      constraints one_of: [:thumbnail, :image, :resource]
      allow_nil? false
      public? true
    end

    attribute :sort_order, :integer, public?: true
  end

  relationships do
    belongs_to :file, Demo.File do
      primary_key? true
      allow_nil? false
      public? true
    end

    belongs_to :product, Demo.Product do
      primary_key? true
      allow_nil? false
      public? true
    end
  end
end

defmodule Demo.Product do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "products"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy, create: [:name]]

    update :update do
      primary? true
      accept [:name]

      argument :files, {:array, :map}, public?: true

      change manage_relationship(:files, :files,
               type: :append_and_remove,
               join_keys: [:role, :sort_order]
             )

      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    many_to_many :files, Demo.File do
      public? true
      through Demo.ProductFile
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :file_id
    end
  end
end

defmodule Demo do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.File
    resource Demo.Product
    resource Demo.ProductFile
  end
end

{:ok, _} = Demo.Repo.start_link()

Ecto.Adapters.SQL.query!(Demo.Repo, """
CREATE TABLE IF NOT EXISTS files (
  id TEXT PRIMARY KEY,
  name TEXT
)
""")

Ecto.Adapters.SQL.query!(Demo.Repo, """
CREATE TABLE IF NOT EXISTS products (
  id TEXT PRIMARY KEY,
  name TEXT
)
""")

Ecto.Adapters.SQL.query!(Demo.Repo, """
CREATE TABLE IF NOT EXISTS product_files (
  product_id TEXT NOT NULL,
  file_id TEXT NOT NULL,
  role TEXT NOT NULL,
  sort_order INTEGER,
  PRIMARY KEY (product_id, file_id, role)
)
""")

thumb = Demo.File |> Ash.Changeset.for_create(:create, %{name: "thumb.jpg"}) |> Ash.create!()
product = Demo.Product |> Ash.Changeset.for_create(:create, %{name: "Widget"}) |> Ash.create!()

IO.puts("\n1) REPRO: passing file_id in manage_relationship payload")

repro_result =
  try do
    product
    |> Ash.Changeset.for_update(:update, %{
      files: [%{file_id: thumb.id, role: :thumbnail, sort_order: 1}]
    })
    |> Ash.update!()

    :unexpected_success
  rescue
    error -> {:error, Exception.message(error)}
  end

IO.inspect(repro_result, label: "repro_result")

IO.puts("\n2) FIX: pass id instead of file_id")

product
|> Ash.Changeset.for_update(:update, %{
  files: [%{id: thumb.id, role: :thumbnail, sort_order: 1}]
})
|> Ash.update!()

Demo.ProductFile
|> Ash.read!()
|> IO.inspect(label: "join rows after fix")
