Mix.install([
  {:ash, "~> 3.0"},
  {:ash_sqlite, "~> 0.2"}
], consolidate_protocols: false)

sqlite_path = Path.join(System.tmp_dir!(), "003-many-many-ids-append-remove.sqlite3")
File.rm(sqlite_path)

Application.put_env(:many_many_variant_demo, Demo.Repo,
  database: sqlite_path,
  pool_size: 1,
  stacktrace: true,
  show_sensitive_data_on_connection_error: true
)

defmodule Demo.Repo do
  use AshSqlite.Repo, otp_app: :many_many_variant_demo
end

defmodule Demo.Category do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "categories"
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

defmodule Demo.ProductCategory do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "product_categories"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*]
  end

  relationships do
    belongs_to :category, Demo.Category do
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

defmodule Demo.ProductFile do
  use Ash.Resource,
    domain: Demo,
    data_layer: AshSqlite.DataLayer

  sqlite do
    table "product_files"
    repo Demo.Repo
  end

  actions do
    defaults [:read, :destroy, create: :*]

    create :relate_thumbnail do
      accept [:product_id, :file_id]
      change set_attribute(:role, :thumbnail)
    end

    create :relate_image do
      accept [:product_id, :file_id]
      change set_attribute(:role, :image)
    end

    create :relate_manual do
      accept [:product_id, :file_id]
      change set_attribute(:role, :manual)
    end
  end

  attributes do
    attribute :role, :atom do
      primary_key? true
      constraints one_of: [:thumbnail, :image, :manual]
      allow_nil? false
      public? true
    end
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

      argument :category_ids, {:array, :uuid}, public?: true
      argument :thumbnail_ids, {:array, :uuid}, public?: true
      argument :image_ids, {:array, :uuid}, public?: true
      argument :manual_ids, {:array, :uuid}, public?: true

      change manage_relationship(:category_ids, :categories, type: :append_and_remove)

      change manage_relationship(:thumbnail_ids, :thumbnails,
               type: :append_and_remove,
               on_lookup: {:relate, :relate_thumbnail}
             )

      change manage_relationship(:image_ids, :images,
               type: :append_and_remove,
               on_lookup: {:relate, :relate_image}
             )

      change manage_relationship(:manual_ids, :manuals,
               type: :append_and_remove,
               on_lookup: {:relate, :relate_manual}
             )

      require_atomic? false
    end
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end

  relationships do
    has_many :thumbnails_join_assoc, Demo.ProductFile do
      destination_attribute :product_id
      filter expr(role == :thumbnail)
    end

    has_many :images_join_assoc, Demo.ProductFile do
      destination_attribute :product_id
      filter expr(role == :image)
    end

    has_many :manuals_join_assoc, Demo.ProductFile do
      destination_attribute :product_id
      filter expr(role == :manual)
    end

    many_to_many :categories, Demo.Category do
      public? true
      through Demo.ProductCategory
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :category_id
    end

    many_to_many :thumbnails, Demo.File do
      public? true
      through Demo.ProductFile
      join_relationship :thumbnails_join_assoc
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :file_id
    end

    many_to_many :images, Demo.File do
      public? true
      through Demo.ProductFile
      join_relationship :images_join_assoc
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :file_id
    end

    many_to_many :manuals, Demo.File do
      public? true
      through Demo.ProductFile
      join_relationship :manuals_join_assoc
      source_attribute_on_join_resource :product_id
      destination_attribute_on_join_resource :file_id
    end
  end
end

defmodule Demo do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.Category
    resource Demo.File
    resource Demo.Product
    resource Demo.ProductCategory
    resource Demo.ProductFile
  end
end

{:ok, _} = Demo.Repo.start_link()

Ecto.Adapters.SQL.query!(Demo.Repo, """
CREATE TABLE IF NOT EXISTS categories (
  id TEXT PRIMARY KEY,
  name TEXT
)
""")

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
CREATE TABLE IF NOT EXISTS product_categories (
  product_id TEXT NOT NULL,
  category_id TEXT NOT NULL,
  PRIMARY KEY (product_id, category_id)
)
""")

Ecto.Adapters.SQL.query!(Demo.Repo, """
CREATE TABLE IF NOT EXISTS product_files (
  product_id TEXT NOT NULL,
  file_id TEXT NOT NULL,
  role TEXT NOT NULL,
  PRIMARY KEY (product_id, file_id, role)
)
""")

cat_a = Demo.Category |> Ash.Changeset.for_create(:create, %{name: "A"}) |> Ash.create!()
cat_b = Demo.Category |> Ash.Changeset.for_create(:create, %{name: "B"}) |> Ash.create!()

thumb_1 = Demo.File |> Ash.Changeset.for_create(:create, %{name: "thumb-1.jpg"}) |> Ash.create!()
thumb_2 = Demo.File |> Ash.Changeset.for_create(:create, %{name: "thumb-2.jpg"}) |> Ash.create!()
img_1 = Demo.File |> Ash.Changeset.for_create(:create, %{name: "img-1.jpg"}) |> Ash.create!()
manual_1 = Demo.File |> Ash.Changeset.for_create(:create, %{name: "manual-1.pdf"}) |> Ash.create!()

product = Demo.Product |> Ash.Changeset.for_create(:create, %{name: "Widget"}) |> Ash.create!()

product =
  product
  |> Ash.Changeset.for_update(:update, %{
    category_ids: [cat_a.id, cat_b.id],
    thumbnail_ids: [thumb_1.id],
    image_ids: [img_1.id],
    manual_ids: [manual_1.id]
  })
  |> Ash.update!()

loaded = product |> Ash.load!([:categories, :thumbnails, :images, :manuals])

IO.inspect(Enum.map(loaded.categories, & &1.name), label: "categories")
IO.inspect(Enum.map(loaded.thumbnails, & &1.name), label: "thumbnails")
IO.inspect(Enum.map(loaded.images, & &1.name), label: "images")
IO.inspect(Enum.map(loaded.manuals, & &1.name), label: "manuals")

product
|> Ash.Changeset.for_update(:update, %{
  category_ids: [cat_b.id],
  thumbnail_ids: [thumb_2.id],
  image_ids: [img_1.id],
  manual_ids: []
})
|> Ash.update!()

after_swap = product |> Ash.load!([:categories, :thumbnails, :images, :manuals])

IO.inspect(Enum.map(after_swap.categories, & &1.name), label: "after categories")
IO.inspect(Enum.map(after_swap.thumbnails, & &1.name), label: "after thumbnails")
IO.inspect(Enum.map(after_swap.images, & &1.name), label: "after images")
IO.inspect(Enum.map(after_swap.manuals, & &1.name), label: "after manuals")

Demo.ProductFile
|> Ash.read!()
|> Enum.map(fn join -> %{role: join.role, file_id: join.file_id} end)
|> IO.inspect(label: "join rows")
