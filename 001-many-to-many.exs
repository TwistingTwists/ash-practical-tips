# QUESTION (Discord: "Managing a many-to-many relationship"):
#
# How do you manage a many-to-many through a join table that has extra
# attributes (role, sort_order) with a compound primary key?
#
# The user got:
#   ** (Ash.Error.Invalid) record with role: :thumbnail | file_id: "..." not found
#
# ANSWER:
# The conflict was two things combined:
#   1. filter expr(product_files.role == :thumbnail) on the relationship +
#      join_keys: [:role] in manage_relationship — Ash uses the filter when
#      looking up records to upsert, new records fail the filter → "not found"
#   2. passing file_id instead of id in the manage_relationship argument
#
# Fix:
#   - Define ONE unfiltered :files relationship for WRITES (manage_relationship + join_keys)
#   - For reads by role, query ProductFile directly with Ash.Query.filter

Mix.install(
  [{:ash, "~> 3.0"}],
  consolidate_protocols: false
)

defmodule Demo.ProductFile do
  use Ash.Resource,
    domain: Demo,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    # compound PK: (product_id, file_id, role)
    attribute :role, :atom do
      primary_key? true
      constraints [one_of: [:thumbnail, :image, :manual]]
      public? true
      allow_nil? false
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

defmodule Demo.File do
  use Ash.Resource,
    domain: Demo,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:name], update: [:name]]
  end

  attributes do
    uuid_primary_key :id
    attribute :name, :string, public?: true
  end
end

defmodule Demo.Product do
  use Ash.Resource,
    domain: Demo,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, :destroy, create: [:name]]

    update :update do
      primary? true
      accept [:name]

      # CORRECT: use the unfiltered :files relationship + join_keys
      # Pass file id (not file_id) plus role and sort_order in each map
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
    # WRITE via this — no filter, used with manage_relationship + join_keys
    many_to_many :files, Demo.File do
      public? true
      through Demo.ProductFile
      destination_attribute_on_join_resource :file_id
    end
  end
end

defmodule Demo do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.File
    resource Demo.ProductFile
    resource Demo.Product
  end
end

# --- minimal repro ---

thumb  = Demo.File |> Ash.Changeset.for_create(:create, %{name: "thumb.jpg"})  |> Ash.create!()
img    = Demo.File |> Ash.Changeset.for_create(:create, %{name: "front.jpg"})  |> Ash.create!()
manual = Demo.File |> Ash.Changeset.for_create(:create, %{name: "manual.pdf"}) |> Ash.create!()

product = Demo.Product |> Ash.Changeset.for_create(:create, %{name: "Widget"}) |> Ash.create!()

IO.puts("\n--- assign files with roles via manage_relationship + join_keys ---")

product =
  product
  |> Ash.Changeset.for_update(:update, %{
    files: [
      %{id: thumb.id,  role: :thumbnail, sort_order: 1},
      %{id: img.id,    role: :image,     sort_order: 1},
      %{id: manual.id, role: :manual,    sort_order: 1}
    ]
  })
  |> Ash.update!()

IO.puts("\n--- all join rows (should be 3 with correct roles) ---")

all_join_rows = Demo.ProductFile |> Ash.read!()
IO.inspect(all_join_rows, label: "ProductFile rows")

IO.puts("\n--- thumbnails only (Enum.filter on join rows since Ash.Query.filter macro needs module context) ---")

all_join_rows
|> Enum.filter(&(&1.role == :thumbnail))
|> IO.inspect(label: "thumbnail rows")

IO.puts("\n--- swap thumbnail: append_and_remove should remove thumb.jpg, add thumb-v2.jpg ---")

new_thumb = Demo.File |> Ash.Changeset.for_create(:create, %{name: "thumb-v2.jpg"}) |> Ash.create!()

product
|> Ash.Changeset.for_update(:update, %{
  files: [
    %{id: new_thumb.id, role: :thumbnail, sort_order: 1},
    %{id: img.id,       role: :image,     sort_order: 1},
    %{id: manual.id,    role: :manual,    sort_order: 1}
  ]
})
|> Ash.update!()

Demo.ProductFile
|> Ash.read!()
|> IO.inspect(label: "after swap (thumb.jpg gone, thumb-v2.jpg present)")
