# QUESTION:
# In a change, how do we manually dump an Ash TypedStruct attribute to native
# value (map) instead of getting `:error`?
#
# ISSUE:
# Calling `dump_to_native` with empty/incorrect constraints returns `:error`.
# Ash needs the attribute constraints for proper dump/cast/type behavior.
#
# FIX:
# Pull constraints from the resource attribute definition via
# `Ash.Resource.Info.attribute(Resource, :attr).constraints`, then call
# `Ash.Type.dump_to_native(TypeModule, value, constraints)`.
#
# NOTE:
# `MyTypedStruct.constraints()` is not enough for this manual dump path here.
# Use the resource attribute constraints to get the fully dumped native map.

Mix.install([
  {:ash, "~> 3.0"}
], consolidate_protocols: false)

defmodule Demo.MyTypedStruct do
  use Ash.TypedStruct

  typed_struct do
    field :title, :string, allow_nil?: false
    field :count, :integer
  end
end

defmodule Demo.Resource do
  use Ash.Resource,
    domain: Demo,
    data_layer: Ash.DataLayer.Ets

  actions do
    defaults [:read, create: :*]
  end

  attributes do
    uuid_primary_key :id

    attribute :my_typed_struct_data, Demo.MyTypedStruct do
      allow_nil? false
    end
  end
end

defmodule Demo do
  use Ash.Domain, validate_config_inclusion?: false

  resources do
    resource Demo.Resource
  end
end

# Value to manually dump (same shape you would read from a changeset in a change).
value = struct(Demo.MyTypedStruct, title: "legacy payload", count: 42)

IO.puts("\n--- calls from the question (expected: :error) ---")
IO.inspect(Demo.MyTypedStruct.dump_to_native(value, []), label: "MyTypedStruct.dump_to_native(value, [])")
IO.inspect(Ash.Type.dump_to_native(Demo.MyTypedStruct, value, []), label: "Ash.Type.dump_to_native(MyTypedStruct, value, [])")

if function_exported?(Demo.MyTypedStruct, :constraints, 0) do
  IO.inspect(
    Demo.MyTypedStruct.dump_to_native(value, Demo.MyTypedStruct.constraints()),
    label: "MyTypedStruct.dump_to_native(value, MyTypedStruct.constraints())"
  )

  IO.inspect(
    Ash.Type.dump_to_native(Demo.MyTypedStruct, value, Demo.MyTypedStruct.constraints()),
    label: "Ash.Type.dump_to_native(MyTypedStruct, value, MyTypedStruct.constraints())"
  )
end

IO.puts("\n--- correct way from thread (expected: {:ok, map}) ---")

attribute = Ash.Resource.Info.attribute(Demo.Resource, :my_typed_struct_data)
constraints = attribute.constraints

IO.inspect(constraints, label: "constraints from Ash.Resource.Info.attribute")

IO.inspect(
  Ash.Type.dump_to_native(Demo.MyTypedStruct, value, constraints),
  label: "Ash.Type.dump_to_native(MyTypedStruct, value, attribute.constraints)"
)
