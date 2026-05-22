# SPDX-License-Identifier: Apache-2.0

defmodule Stem.DSL do
  @moduledoc """
  Compile-time DSL for defining Stem template functions.

  ## Examples

      defmodule MyViews do
        use Stem.DSL

        defdictionary :status_map, %{"1" => "Active"}
        deftemplate :hello, "Hello {{name}}", [:assigns]
        deftemplate_file :card, "templates/card.stem", [:assigns]
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
          deftemplate: 3,
          deftemplate: 4,
          deftemplate_file: 3,
          deftemplate_file: 4
        ]
    end
  end

  defmacro defdictionary(name, entries) do
    unless is_atom(name) do
      raise ArgumentError, "expected dictionary name to be an atom, got: #{Macro.to_string(name)}"
    end

    {entries_value, _binding} = Code.eval_quoted(entries, [], __CALLER__)

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

      @doc false
      def __stem_dictionary__(unquote(name)), do: unquote(Macro.escape(entries_value))
    end
  end

  defmacro __before_compile__(env) do
    dictionary_assigns = dictionary_assigns_ast(env.module)

    quote do
      @doc false
      def __stem_dictionary_assigns__, do: unquote(Macro.escape(dictionary_assigns))
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

  defp with_dictionary_assigns(module, args, options) when is_list(args) and is_list(options) do
    dictionary_assigns = dictionary_assigns_ast(module)

    case dictionary_assigns do
      dictionary_assigns when dictionary_assigns in [%{}, []] ->
        options

      _non_empty ->
        unless :assigns in args do
          raise ArgumentError, "Stem dictionaries require an :assigns argument"
        end

        [{:dictionary_assigns, dictionary_assigns} | options]
    end
  end
end
