Managing a many-to-many relationship
tjtuom
OP
 — Yesterday at 3:46 PM
I have a generic File resource that represents a file uploaded by the user. I also have a Product resource that uses the file resource is multiple places through a join table. Products have a thumbnail, product images and resources like manuals, so my join table has a compound primary key on file_id, product_id and role. I have a live component that allows the user to upload and/or pick files from a list. The component gives a list of file ids to the product form. The same file could have two entries in the join table, one as a thumbnail and one as an image.

In product resource
    many_to_many :thumbnails, Eravuokraamo.Media.File do
      public? true
      through Eravuokraamo.Media.ProductFile
      destination_attribute_on_join_resource :file_id
      filter expr(product_files.role == :thumbnail)
    end


In product resource
    update :update do
      primary? true
      accept [:name, :price, :description, :translations]

      argument :category_ids, {:array, :uuid}
      argument :thumbnails, {:array, :map}

      change manage_relationship(:category_ids, :categories, type: :append_and_remove)

      change manage_relationship(:thumbnails,
               type: :append_and_remove,
               join_keys: [:role, :sort_order]
             )

      require_atomic? false
    end


I can't figure out how to get this to work. Any guidance would be greatly appreciated.
Answer Overflow
APP
 — Yesterday at 3:46 PM
To help others find answers, you can mark your question as solved via Right click solution message -> Apps -> ✅ Mark Solution
Image
tjtuom
OP
 — Yesterday at 3:46 PM
defmodule Eravuokraamo.Media.ProductFile do
  @moduledoc false

  use Ash.Resource,
    otp_app: :eravuokraamo,
    domain: Eravuokraamo.Media,
    data_layer: AshPostgres.DataLayer

  postgres do
    table "product_files"
    repo Eravuokraamo.Repo

    references do
      reference :file, index?: true, on_delete: :delete
      reference :product, index?: true, on_delete: :delete
    end
  end

  actions do
    defaults [:read, :destroy, create: :*, update: :*]
  end

  attributes do
    attribute :sort_order, :integer do
      public? true
    end

    attribute :role, :atom do
      primary_key? true
      constraints one_of: [:thumbnail, :image, :resource]
      public? true
      allow_nil? false
    end
  end

  relationships do
    belongs_to :file, Eravuokraamo.Media.File do
      allow_nil? false
      primary_key? true
    end

    belongs_to :product, Eravuokraamo.Inventory.Product do
      allow_nil? false
      primary_key? true
    end
  end
end
          <.fieldset>
            <.fieldset_legend>Thumbnail</.fieldset_legend>
            <.inputs_for :let={file} field={@form[:thumbnails]}>
              <.file_preview file={file} />
              <.inputs_for :let={join} field={file[:_join]}>
                <.input field={join[:role]} type="hidden" />
                <.input field={join[:file_id]} type="hidden" />
              </.inputs_for>
            </.inputs_for>
            <.button type="button" phx-click={show_modal("thumbnail-picker")}>Pick thumbnail</.button>
          </.fieldset>
        </div>


When I try to update an entry for which I've manually created a join table row in the db I can see the image preview fine, but the form doesn't have any fields for the _join field. I can see that it's avaiable under 
form_keys
 in the form but not under 
forms
. 

Also, if I try to manually update the product in the console that also throws an error.
Inventory.update_product!(product, %{thumbnails: [%{file_id: thumbnail.id, role: :thumbnail}]})


** (Ash.Error.Invalid)
Bread Crumbs:
  > Managed relationship create: Eravuokraamo.Inventory.Product.thumbnails
  > Managed relationship manage: Eravuokraamo.Inventory.Product.thumbnails
  > Error returned from: Eravuokraamo.Inventory.Product.update

Invalid Error

* record with role: :thumbnail | file_id: "8cd5d4e9-bf7b-4513-8d5e-cf0ccf338f10" not found
    at thumbnails, 0
ken-kost

Role icon, contributor — Yesterday at 4:58 PM
I think filter expr(product_files.role == :thumbnail) is giving you problems with join_keys: [:role, ...]
you could simplify by removing the filter, naming that relationship files for example and than storing the role information in it.

or you could define all the different many to many relationships with filter:
many_to_many :thumbnails, Eravuokraamo.Media.File do  
  public? true  
  through Eravuokraamo.Media.ProductFile  
  destination_attribute_on_join_resource :file_id  
  filter expr(product_files.role == :thumbnail)  
end  
  
many_to_many :images, Eravuokraamo.Media.File do  
  public? true  
  through Eravuokraamo.Media.ProductFile  
  destination_attribute_on_join_resource :file_id  
  filter expr(product_files.role == :image)  
end  
  
many_to_many :manuals, Eravuokraamo.Media.File do  
  public? true  
  through Eravuokraamo.Media.ProductFile  
  destination_attribute_on_join_resource :file_id  
  filter expr(product_files.role == :manual)  
end

and your update action:
update :update do  
  primary? true  
  accept [:name, :price, :description, :translations]  
  
  argument :category_ids, {:array, :uuid}  
  argument :thumbnail_ids, {:array, :uuid}  
  argument :image_ids, {:array, :uuid}  
  argument :manual_ids, {:array, :uuid}  
  
  change manage_relationship(:category_ids, :categories, type: :append_and_remove)  
  change manage_relationship(:thumbnail_ids, :thumbnails, type: :append_and_remove)  
  change manage_relationship(:image_ids, :images, type: :append_and_remove)  
  change manage_relationship(:manual_ids, :manuals, type: :append_and_remove)  
  
  require_atomic? false  
end

I think this would, based on the filter defined in the relationship and manage_relationship, make ash mechanism know to set the filtered role.

so option 1 is more flexible and relies on join_keyswhile option 2 has strongly typed separate relationships that relies on filter . But using both afais creates conflict.
tjtuom
OP
 — Yesterday at 6:47 PM
I tried with just ids at first and it failed to save because no role was set. Then I wasn't using any join_keys. The one thing I haven't tried yet is making create actions for different roles where I manually set the attribute and force the manage_relationship to use that. However, I don't think that would still help me much cause I still want to be able to pass the sorting stuff through the product form, which is why I want to get this to work for real in the way that it's supposed to work.
ken-kost

Role icon, contributor — Yesterday at 7:23 PM
Did you try:
many_to_many :files, Eravuokraamo.Media.File do  
  public? true  
  through Eravuokraamo.Media.ProductFile  
  destination_attribute_on_join_resource :file_id  
end

with join_keys in manage_relationship?
Then you can just load files and do Enum.group_byor define relationships with filters and load through that, the important part is the role being passed through the action to the db right
tjtuom
OP
 — 1:40 PM
Ok so yea the filter call was messing up the insert, along with using file_id instead of id. So now I can do the management via :files and use the filtered relationships for getting the right kind of file out. Thanks for your help. Now I just need to figure out how to structure my form...