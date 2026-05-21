# SPDX-License-Identifier: Apache-2.0

defmodule Stem.DSL do
  @moduledoc """
  Compile-time DSL for defining Handlebars-backed functions.

  ## Examples

      defmodule MyViews do
        use Stem.DSL

        handlebars :hello, "Hello {{name}}", [:assigns]
        handlebars_file :card, "templates/card.stem", [:assigns]
      end
  """

  defmacro __using__(_opts) do
    quote do
      require Stem

      import Stem.DSL,
        only: [handlebars: 3, handlebars: 4, handlebars_file: 3, handlebars_file: 4]
    end
  end

  defmacro handlebars(name, template, args, options \\ []) do
    {kind, compile_options} = extract_kind_option(options)

    quote do
      Stem.function_from_string(
        unquote(kind),
        unquote(name),
        unquote(template),
        unquote(args),
        unquote(compile_options)
      )
    end
  end

  defmacro handlebars_file(name, file, args, options \\ []) do
    {kind, compile_options} = extract_kind_option(options)

    quote do
      Stem.function_from_file(
        unquote(kind),
        unquote(name),
        unquote(file),
        unquote(args),
        unquote(compile_options)
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
end
