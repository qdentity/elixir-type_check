defmodule TypeCheck.Builtin.Guarded do
  defstruct [:type, :guard, :original_module]

  use TypeCheck
  import TypeCheck.Type.StreamData
  @type! ast() :: term() |> wrap_with_gen(&TypeCheck.Builtin.Guarded.ast_gen/1)
  def ast_gen(term) do
    Macro.escape(term)
  end

  @type! t() :: %TypeCheck.Builtin.Guarded{type: TypeCheck.Type.t(), guard: ast(), original_module: module() | nil}


  defimpl TypeCheck.Protocols.Escape do
    def escape(s) do
      update_in(s.type, &TypeCheck.Protocols.Escape.escape(&1))
    end
  end

  @doc false
  def extract_names(type) do
    case type do
      # Do not extract names across non-local types
      %TypeCheck.Builtin.NamedType{local: false} ->
        []

      %TypeCheck.Builtin.NamedType{local: true} ->
        [type.name | extract_names(type.type)]

      %TypeCheck.Builtin.FixedList{} ->
        Enum.flat_map(type.element_types, &extract_names/1)

      %TypeCheck.Builtin.FixedTuple{} ->
        Enum.flat_map(type.element_types, &extract_names/1)

      %TypeCheck.Builtin.FixedMap{} ->
        Enum.flat_map(type.keypairs, fn {_key, value} -> extract_names(value) end)

      %TypeCheck.Builtin.List{} ->
        extract_names(type.element_type)

      %TypeCheck.Builtin.Map{} ->
        extract_names(type.key_type) ++ extract_names(type.value_type)

      %TypeCheck.Builtin.OneOf{} ->
        names =
          type.choices
          |> Enum.map(&extract_names/1)
          |> Enum.sort()
          |> Enum.into(%MapSet{})

        if MapSet.size(names) > 1 do
          raise TypeCheck.CompileError, """
          Attempted to construct a union type
          containing named types where one or multiple names
          do not exist in all of the possibilities:
          #{inspect(type)}
          """
        end

        Enum.at(names, 0)

      %TypeCheck.Builtin.Guarded{} ->
        # Recurse :-)
        extract_names(type.type)

      _other ->
        []
    end
  end

  defimpl TypeCheck.Protocols.ToCheck do
    def to_check(s, param) do
      type_check = TypeCheck.Protocols.ToCheck.to_check(s.type, param)

      type_names = MapSet.new(TypeCheck.Builtin.Guarded.extract_names(s.type))
      guard_names = TypeCheck.Internals.Helper.extract_vars_from_ast(s.guard)
      used_and_existing_names = MapSet.intersection(type_names, guard_names)

      names_map =
        used_and_existing_names
        |> Enum.map(fn name -> {name, {:unquote, [], [Macro.var(name, nil)]}} end)
        |> Enum.into(%{})
        |> Macro.escape(unquote: true)

      # We import the original module, if possible.
      # This way, Elixir is able to find unqualified functions that are used in the type guard,
      # even if the type containing the guard ends up being used in another module.
      # C.f. issue #147.
      guard_ast =
        if s.original_module && !Module.open?(s.original_module) do
          quote do
            import unquote(s.original_module)
            unquote(s.guard)
          end
        else
          s.guard
        end

      quote generated: true, location: :keep do
        case unquote(type_check) do
          {:ok, bindings, altered_param} ->
            # Shadows all but the most recently-bound value for each name
            bindings_map = Enum.into(bindings, %{})

            unquote(names_map) = bindings_map

            if unquote(guard_ast) do
              {:ok, bindings, altered_param}
            else
              {:error,
               {unquote(Macro.escape(s)), :guard_failed, %{bindings: bindings_map},
                unquote(param)}}
            end

          {:error, problem} ->
            {:error,
             {unquote(Macro.escape(s)), :type_failed, %{problem: problem}, unquote(param)}}
        end
      end
    end
  end

  defimpl TypeCheck.Protocols.Inspect do

    @map_with_single_required_key_type %{
      __struct__: TypeCheck.Builtin.Guarded,
      guard: {:>=, [context: TypeCheck.Builtin, import: Kernel],
              [
                {:map_size, [context: TypeCheck.Builtin, import: Kernel],
                 [{:map, [], nil}]},
                1
              ]},
      type: %{
        __struct__: TypeCheck.Builtin.NamedType,
        local: true,
        name: :map,
        type: %{
          __struct__: TypeCheck.Builtin.Map,
          key_type: %{__struct__: TypeCheck.Builtin.Number},
          value_type: %{__struct__: TypeCheck.Builtin.Boolean}
        }
      }
}
    def inspect(s = @map_with_single_required_key_type, opts) do
      key_inspect = TypeCheck.Protocols.Inspect.inspect(s.type.type.key_type, opts)
      value_inspect = TypeCheck.Protocols.Inspect.inspect(s.type.type.value_type, opts)
      "%{required(#{key_inspect}) => #{value_inspect}}"
    end

    def inspect(s, opts) do
      ("(" |> Inspect.Algebra.color(:builtin_type, opts))
      |> Inspect.Algebra.concat(TypeCheck.Protocols.Inspect.inspect(s.type, opts))
      |> Inspect.Algebra.glue("when" |> Inspect.Algebra.color(:builtin_type, opts))
      |> Inspect.Algebra.glue(Macro.to_string(s.guard) |> Inspect.Algebra.color(:builtin_type, opts))
      |> Inspect.Algebra.concat(")"|> Inspect.Algebra.color(:builtin_type, opts))
      |> Inspect.Algebra.group()
    end
  end

  if Code.ensure_loaded?(StreamData) do
    defimpl TypeCheck.Protocols.ToStreamData do
      def to_gen(s) do
        # check_code = TypeCheck.Protocols.ToCheck.to_check(s, Macro.var(:value, nil))
        TypeCheck.Protocols.ToStreamData.to_gen(s.type)
        |> StreamData.filter(fn value ->
          TypeCheck.dynamic_conforms?(value, s)
        end)
      end
    end
  end
end
