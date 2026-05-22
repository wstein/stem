# SPDX-License-Identifier: Apache-2.0

defmodule Stem.DSL do
  @moduledoc """
  Compile-time DSL for defining Stem template functions.

  ## Presentation-only static dictionaries

  `defdictionary/2` registers a **presentation-only static dictionary** on the
  current module. Every `deftemplate`, `deftemplate_file`, and `~STEM`
  definition that appears **after** the declaration automatically receives the
  dictionary's entries merged into `assigns` at render time, with explicit
  caller-supplied assigns taking precedence (right-wins merge).

  ### Rules and restrictions

  - Dictionary values must be *pure literals*: maps, lists, strings, numbers,
    booleans, or `nil`. No function calls, variables, tuples, or I/O
    expressions are allowed. This is a deliberate security boundary: template
    modules must not execute host-side code while defining presentation data.
  - A module attribute that resolves to one of those literals (for example,
    `@my_attr`) is also accepted. If the attribute is unset or expands to a
    non-literal value, compilation stops immediately.
  - Multiple dictionaries in the same module are merged in declaration order
    (later declarations win on conflicting keys). Use `defdictionary_merge/2`
    to compose named dictionaries explicitly.
  - Calling `defdictionary/2` twice with the same name replaces the earlier
    definition silently.
  - The three template forms (`deftemplate`, `deftemplate_file`, and `~STEM`)
    all read from the same static dictionary model, so the security boundary is
    consistent regardless of how the template is declared.

  ## Examples

      defmodule MyViews do
        use Stem.DSL

        defdictionary :status_map, %{"1" => "Active", "2" => "Inactive"}
        defdictionary :label_map, %{"en" => "English", "de" => "German"}

        deftemplate :badge, "{{lookup status_map s}}", [:assigns]
        deftemplate_file :card, "templates/card.stem", [:assigns]

        def render_sigil(assigns) do
          ~STEM"{{lookup label_map lang}}"
        end
      end
  """

  @dictionary_attribute :stem_dictionaries

  defmacro __using__(_opts) do
    quote do
      Module.register_attribute(__MODULE__, unquote(@dictionary_attribute), accumulate: false)
      Module.put_attribute(__MODULE__, unquote(@dictionary_attribute), %{})
      @before_compile Stem.DSL

      require Stem
      import Stem.Sigil

      import Stem.DSL,
        only: [
          defdictionary: 2,
          defdictionary_merge: 2,
          deftemplate: 3,
          deftemplate: 4,
          deftemplate_file: 3,
          deftemplate_file: 4
        ]
    end
  end

  @doc """
  Registers a presentation-only static dictionary on the current module.

  The dictionary is automatically injected into all `deftemplate`,
  `deftemplate_file`, and `~STEM` template functions declared **after** this
  call. Caller-supplied assigns override dictionary entries at render time.

  Only presentation-only static literals are accepted as values: maps, lists,
  strings, numbers, booleans, and `nil`. Module attributes are allowed only
  when they expand to those literal forms. Use `defdictionary_merge/2` to
  compose multiple dictionaries into a single name in a predictable order.

  ## Raises

  - `ArgumentError` if `name` is not an atom.
  - `ArgumentError` if `entries` contains any non-literal expression (function
    calls, variables, tuples, I/O, etc.).
  - `ArgumentError` if `entries` is a module attribute whose value is not a
    literal presentation structure.
  """
  defmacro defdictionary(name, {:@, _, [{attr_name, _, _}]})
           when is_atom(name) and is_atom(attr_name) do
    # For @attr arguments: we cannot reliably read the attribute value from
    # inside the macro body (Module.get_attribute / Macro.expand both return
    # stale/nil values in some compilation contexts). The correct approach
    # is to emit Module.get_attribute in the MODULE BODY as generated code,
    # where it runs at module compilation time and sees the live attribute state.
    attr_name_str = to_string(attr_name)
    dict_attribute = @dictionary_attribute

    # Register the name at macro-expansion time so a later deftemplate picks it
    # up in declaration order. The value cannot be read here, so store a
    # sentinel; Stem.__resolve_dict_refs__/2 resolves it to the real value at
    # render time via the module's compiled __stem_dictionary__/1.
    put_dictionary(__CALLER__.module, name, {:__stem_attr_ref__, attr_name})

    quote do
      # This runs as part of the module body at compile time.
      # Module.get_attribute is called here (not in the macro body), where it
      # reliably reads the attribute that was set earlier in the module body.
      _stem_dict_val__ = Module.get_attribute(__MODULE__, unquote(attr_name))

      if is_nil(_stem_dict_val__) do
        raise ArgumentError,
              "defdictionary: module attribute @" <>
                unquote(attr_name_str) <>
                " is not set at the point of the defdictionary declaration"
      end

      unless Stem.DSL.literal_value?(_stem_dict_val__) do
        raise ArgumentError,
              "defdictionary: module attribute @" <>
                unquote(attr_name_str) <>
                " must be a literal map/list/string/number/boolean/nil structure, got: " <>
                inspect(_stem_dict_val__)
      end

      Stem.DSL.put_dictionary(__MODULE__, unquote(name), _stem_dict_val__)

      Module.put_attribute(
        __MODULE__,
        unquote(dict_attribute),
        Map.put(
          Module.get_attribute(__MODULE__, unquote(dict_attribute)) || %{},
          unquote(name),
          _stem_dict_val__
        )
      )
    end
  end

  defmacro defdictionary(name, entries) do
    unless is_atom(name) do
      raise ArgumentError, "expected dictionary name to be an atom, got: #{Macro.to_string(name)}"
    end

    entries_value = resolve_literal_entries!(entries, __CALLER__)
    put_dictionary(__CALLER__.module, name, entries_value)

    quote do
      Module.put_attribute(
        __MODULE__,
        unquote(@dictionary_attribute),
        Map.put(
          Module.get_attribute(__MODULE__, unquote(@dictionary_attribute)) || %{},
          unquote(name),
          unquote(Macro.escape(entries_value))
        )
      )
    end
  end

  @doc """
  Merges multiple named dictionaries into a single new named dictionary.

  `sources` is a list of atom names that must already have been declared with
  `defdictionary/2` in the same module. Entries are merged left-to-right, so
  the rightmost source wins on key conflict.

  ## Example

      defdictionary :base, %{"a" => 1}
      defdictionary :extra, %{"b" => 2}
      defdictionary_merge :all, [:base, :extra]
      # :all => %{"a" => 1, "b" => 2}
  """
  defmacro defdictionary_merge(name, sources) when is_atom(name) and is_list(sources) do
    module = __CALLER__.module
    existing = put_dictionary_get(module)

    Enum.each(sources, fn source ->
      unless is_atom(source) do
        raise ArgumentError,
              "defdictionary_merge: expected source names to be atoms, got: #{inspect(source)}"
      end

      unless Map.has_key?(existing, source) do
        raise ArgumentError,
              "defdictionary_merge: unknown dictionary :#{source}. " <>
                "Declare it with defdictionary/2 before merging."
      end
    end)

    merged =
      Enum.reduce(sources, %{}, fn source, acc ->
        Map.merge(acc, existing[source] || %{})
      end)

    put_dictionary(module, name, merged)

    quote do
      Module.put_attribute(
        __MODULE__,
        unquote(@dictionary_attribute),
        Map.put(
          Module.get_attribute(__MODULE__, unquote(@dictionary_attribute)) || %{},
          unquote(name),
          unquote(Macro.escape(merged))
        )
      )
    end
  end

  defmacro __before_compile__(env) do
    # Single source of truth: snapshot the entire dictionary map into one
    # module function so that deftemplate, deftemplate_file, and ~STEM all
    # read the identical compiled value.
    dictionaries = dictionary_assigns_ast(env.module)

    individual_funcs =
      Enum.map(dictionaries, fn {name, value} ->
        quote do
          @doc false
          def __stem_dictionary__(unquote(name)), do: unquote(Macro.escape(value))
        end
      end)

    quote do
      unquote_splicing(individual_funcs)

      @doc false
      def __stem_dictionary_assigns__, do: unquote(Macro.escape(dictionaries))
    end
  end

  defmacro deftemplate(name, template, args, options \\ []) do
    {kind, compile_options} = extract_kind_option(options)
    compile_options = with_dictionary_assigns(__CALLER__.module, args, compile_options)

    quote do
      Stem.function_from_string(
        unquote(kind),
        unquote(name),
        unquote(template),
        unquote(args),
        unquote(Macro.escape(compile_options))
      )
    end
  end

  defmacro deftemplate_file(name, file, args, options \\ []) do
    {kind, compile_options} = extract_kind_option(options)
    compile_options = with_dictionary_assigns(__CALLER__.module, args, compile_options)

    quote do
      Stem.function_from_file(
        unquote(kind),
        unquote(name),
        unquote(file),
        unquote(args),
        unquote(Macro.escape(compile_options))
      )
    end
  end

  defp extract_kind_option(options) when is_list(options) do
    kind = Keyword.get(options, :kind, :def)

    unless kind in [:def, :defp] do
      raise ArgumentError, "expected :kind to be :def or :defp, got: #{inspect(kind)}"
    end

    {kind, Keyword.delete(options, :kind)}
  end

  defp extract_kind_option(options) do
    raise ArgumentError, "expected options to be a keyword list, got: #{inspect(options)}"
  end

  @doc false
  def dictionary_assigns_ast(module) when is_atom(module) do
    Module.get_attribute(module, @dictionary_attribute) || %{}
  end

  @doc false
  def put_dictionary(module, name, entries) when is_atom(module) and is_atom(name) do
    dictionaries = Module.get_attribute(module, @dictionary_attribute) || %{}
    Module.put_attribute(module, @dictionary_attribute, Map.put(dictionaries, name, entries))
  end

  @doc false
  def put_dictionary_get(module) when is_atom(module) do
    Module.get_attribute(module, @dictionary_attribute) || %{}
  end

  defp with_dictionary_assigns(module, args, options) when is_list(args) and is_list(options) do
    dictionary_assigns = dictionary_assigns_ast(module)

    case dictionary_assigns do
      da when da in [%{}, []] ->
        options

      _non_empty ->
        unless :assigns in args do
          raise ArgumentError, "Stem dictionaries require an :assigns argument"
        end

        [{:dictionary_assigns, dictionary_assigns} | options]
    end
  end

  # ---------------------------------------------------------------------------
  # Literal-AST validator (compile-time linter)
  # ---------------------------------------------------------------------------
  #
  # Walks the quoted AST and accepts only structures that reduce to a known
  # static value without executing any code. Side-effectful calls,
  # variable references, and Elixir function invocations are all rejected.
  #
  # Module attributes (@attr) are resolved at macro-expansion time and their
  # value is validated with the same rules.

  @doc false
  def resolve_literal_entries!(ast, caller) do
    unless literal_ast?(ast) do
      raise ArgumentError,
            "defdictionary: entries must be a literal map/list/string/number/boolean/" <>
              "nil expression. No function calls, variables, tuples, or I/O are allowed. " <>
              "Got: #{Macro.to_string(ast)}"
    end

    literal_ast_to_value!(ast, caller)
  end

  # Returns true when the AST is a purely structural literal (no calls).
  defp literal_ast?(ast)

  defp literal_ast?(value) when is_binary(value), do: true
  defp literal_ast?(value) when is_number(value), do: true
  defp literal_ast?(true), do: true
  defp literal_ast?(false), do: true
  defp literal_ast?(nil), do: true

  # Map literal: %{...}
  defp literal_ast?({:%{}, _meta, pairs}) when is_list(pairs) do
    Enum.all?(pairs, fn
      {k, v} -> literal_ast?(k) and literal_ast?(v)
      _ -> false
    end)
  end

  # List literal: [...]
  defp literal_ast?(list) when is_list(list) do
    Enum.all?(list, &literal_ast?/1)
  end

  # Anything else (function calls, variables, pipes, etc.) is rejected.
  defp literal_ast?(_), do: false

  defp literal_ast_to_value!(value, _caller) when is_binary(value), do: value
  defp literal_ast_to_value!(value, _caller) when is_number(value), do: value
  defp literal_ast_to_value!(true, _caller), do: true
  defp literal_ast_to_value!(false, _caller), do: false
  defp literal_ast_to_value!(nil, _caller), do: nil

  defp literal_ast_to_value!({:%{}, _meta, pairs}, caller) when is_list(pairs) do
    Map.new(pairs, fn {k, v} ->
      {literal_ast_to_value!(k, caller), literal_ast_to_value!(v, caller)}
    end)
  end

  defp literal_ast_to_value!(list, caller) when is_list(list) do
    Enum.map(list, &literal_ast_to_value!(&1, caller))
  end

  defp literal_ast_to_value!(ast, _caller) do
    raise ArgumentError,
          "defdictionary: expected a literal map/list/string/number/boolean/nil, got: " <>
            Macro.to_string(ast)
  end

  # Returns true when an already-evaluated *value* is a pure literal type.
  @doc false
  def literal_value?(value) when is_binary(value), do: true
  def literal_value?(value) when is_number(value), do: true
  def literal_value?(value) when is_boolean(value), do: true
  def literal_value?(nil), do: true

  def literal_value?(value) when is_map(value) do
    Enum.all?(value, fn {k, v} -> literal_value?(k) and literal_value?(v) end)
  end

  def literal_value?(value) when is_list(value) do
    Enum.all?(value, &literal_value?/1)
  end

  def literal_value?(_), do: false
end
