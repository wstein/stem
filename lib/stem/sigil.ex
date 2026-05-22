# SPDX-License-Identifier: Apache-2.0

defmodule Stem.Sigil do
  @moduledoc ~S"""
  Compile literal Stem templates inline with the `~STEM` sigil.

  The sigil compiles the template at compile time and renders it against the
  surrounding `assigns` and `transformers` variables when the generated code runs.

  ## Examples

      defmodule Greeting do
        import Stem.Sigil

        def render(assigns) do
          ~STEM"Hello {{name}}"
        end
      end

      Greeting.render(name: "Nina")
      #=> "Hello Nina"
  """

  defmacro sigil_STEM(template_ast, modifiers) do
    if modifiers != [] do
      raise ArgumentError, "~STEM does not accept modifiers"
    end

    template = extract_literal!(template_ast)
    compiled = Stem.__compile_string__(template, file: __CALLER__.file, line: __CALLER__.line)

    # Resolve dictionaries at macro-expansion time using the same
    # __stem_dictionary_assigns__/0 snapshot produced by @before_compile
    # in Stem.DSL. If the module has no dictionary (e.g. plain import of
    # Stem.Sigil), the merge is a no-op at runtime.
    dictionaries = Stem.DSL.dictionary_assigns_ast(__CALLER__.module)
    escaped_dicts = Macro.escape(dictionaries)

    if map_size(dictionaries) == 0 do
      quote do
        var!(transformers) = Keyword.get(binding(), :transformers, %{})
        _ = var!(transformers)
        unquote(compiled)
      end
    else
      quote do
        var!(transformers) = Keyword.get(binding(), :transformers, %{})
        _ = var!(transformers)

        var!(assigns) =
          Stem.merge_dictionary_assigns(
            var!(assigns),
            Stem.__resolve_dict_refs__(__MODULE__, unquote(escaped_dicts))
          )

        unquote(compiled)
      end
    end
  end

  @doc false
  @deprecated "Use Stem.DSL.__before_compile__ snapshot; kept for runtime reflection only."
  def dictionary_assigns(module) when is_atom(module) do
    if function_exported?(module, :__stem_dictionary_assigns__, 0) do
      module.__stem_dictionary_assigns__()
    else
      %{}
    end
  end

  defp extract_literal!({:<<>>, _meta, [template]}) when is_binary(template), do: template

  defp extract_literal!(template) when is_binary(template), do: template

  defp extract_literal!(template_ast) do
    raise ArgumentError,
          "~STEM expects a literal template string, got: #{Macro.to_string(template_ast)}"
  end
end
