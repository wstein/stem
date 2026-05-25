# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.FuzzTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Stem.Compiler
  alias Stem.Expression
  alias Stem.Parser

  @helpers ~w(trim upcase truncate default wrap format progress link compact uniq)
  @idents ~w(name title user value story item row rows items article body prefix suffix count total)
  @partial_names ~w(shell layout shared leaf)
  @block_kinds ~w(if unless each with)

  property "expression parsing never raises for generated structured expressions" do
    check all(expr <- expression_generator(3), max_runs: 40) do
      result = safe_result(fn -> Expression.parse(expr) end)
      assert match?({:ok, {:ok, _}}, result) or match?({:ok, {:error, _}}, result)
    end
  end

  property "parser handles generated templates and partial expansions without raising" do
    check all(
            template <- template_generator(3, @partial_names),
            partials <- partials_generator(),
            max_runs: 30
          ) do
      result = safe_result(fn -> Parser.parse(template, partials: partials) end)

      assert match?({:ok, {:ok, _}}, result) or match?({:ok, {:error, _, _}}, result)
    end
  end

  property "structured templates compile after parsing" do
    check all(template <- structured_template_generator(3), max_runs: 30) do
      case safe_result(fn -> Parser.parse(template) end) do
        {:ok, {:ok, ast}} ->
          compile_result =
            safe_result(fn ->
              Compiler.compile(ast, file: "fuzz.stem")
            end)

          assert match?({:ok, quoted} when quoted != nil, compile_result)

        {:ok, {:error, _message, _meta}} ->
          :ok
      end
    end
  end

  test "recursive partial expansion returns an error instead of raising" do
    assert {:error, "partial recursion detected for 'loop'", _meta} =
             Parser.parse("{{> loop}}", partials: %{"loop" => "{{> loop}}"})
  end

  defp partials_generator do
    fixed_map(%{
      "leaf" => structured_template_generator(1, []),
      "shared" => structured_template_generator(1, ["leaf"]),
      "layout" => structured_template_generator(1, ["shared", "leaf"]),
      "shell" => structured_template_generator(1, ["layout", "shared", "leaf"])
    })
  end

  defp template_generator(depth, partial_names) do
    one_of([
      structured_template_generator(depth, partial_names),
      string(:printable, max_length: 80)
    ])
  end

  defp structured_template_generator(depth, partial_names \\ @partial_names) do
    fragment_generator(depth, partial_names)
    |> list_of(max_length: 5)
    |> map(&Enum.join/1)
  end

  defp fragment_generator(depth, partial_names) when depth <= 0 do
    one_of([
      text_fragment_generator(),
      expression_tag_generator(0),
      raw_expression_tag_generator(0),
      comment_fragment_generator(),
      partial_fragment_generator(partial_names)
    ])
  end

  defp fragment_generator(depth, partial_names) do
    one_of([
      fragment_generator(0, partial_names),
      block_fragment_generator(depth - 1, partial_names)
    ])
  end

  defp text_fragment_generator do
    string(:alphanumeric, min_length: 0, max_length: 16)
    |> map(fn text -> if text == "", do: " ", else: text end)
  end

  defp comment_fragment_generator do
    one_of([
      constant("{{! note }}"),
      constant("{{!-- block note --}}")
    ])
  end

  defp partial_fragment_generator([]), do: constant("tail")

  defp partial_fragment_generator(partial_names) do
    member_of(partial_names)
    |> map(fn name -> "{{> #{name}}}" end)
  end

  defp expression_tag_generator(depth) do
    bind(trim_marker_generator(), fn left_trim ->
      bind(trim_marker_generator(), fn right_trim ->
        map(expression_generator(depth), fn expr ->
          "{{#{left_trim} #{expr} #{right_trim}}}"
        end)
      end)
    end)
  end

  defp raw_expression_tag_generator(depth) do
    map(expression_generator(depth), fn expr ->
      "{{{ #{expr} }}}"
    end)
  end

  defp block_fragment_generator(depth, partial_names) do
    bind(member_of(@block_kinds), fn kind ->
      bind(expression_generator(max(depth, 0)), fn expr ->
        bind(structured_template_generator(max(depth - 1, 0), partial_names), fn body ->
          bind(boolean(), fn include_else? ->
            bind(structured_template_generator(max(depth - 1, 0), partial_names), fn else_body ->
              map(block_params_generator(kind), fn params ->
                open = "{{##{kind} #{expr}#{params}}}"
                else_section = if include_else?, do: "{{else}}#{else_body}", else: ""
                close = "{{/#{kind}}}"
                open <> body <> else_section <> close
              end)
            end)
          end)
        end)
      end)
    end)
  end

  defp block_params_generator("each") do
    one_of([
      constant(""),
      member_of(@idents)
      |> map(fn item -> " as |#{item}|" end),
      fixed_list([member_of(@idents), member_of(@idents)])
      |> map(fn [item, index] -> " as |#{item} #{index}|" end)
    ])
  end

  defp block_params_generator("with") do
    one_of([
      constant(""),
      member_of(@idents)
      |> map(fn item -> " as |#{item}|" end)
    ])
  end

  defp block_params_generator(_kind), do: constant("")

  defp expression_generator(depth) when depth <= 0 do
    one_of([
      identifier_generator(),
      literal_generator(),
      parent_generator(),
      special_generator(),
      path_generator()
    ])
  end

  defp expression_generator(depth) do
    one_of([
      expression_generator(0),
      helper_expression_generator(depth - 1),
      pipeline_expression_generator(depth - 1)
    ])
  end

  defp helper_expression_generator(depth) do
    child_depth = max(depth - 1, 0)

    bind(helper_argument_list_generator(child_depth), fn args ->
      bind(member_of(@helpers), fn name ->
        constant(Enum.join([name | args], " "))
      end)
    end)
  end

  defp helper_argument_list_generator(depth) do
    child_depth = max(depth - 1, 0)

    one_of([
      constant([]),
      list_of(expression_generator(child_depth), max_length: 3),
      bind(integer(1..3), fn kw_count ->
        list_of(keyword_argument_generator(child_depth),
          min_length: kw_count,
          max_length: kw_count
        )
      end)
    ])
  end

  defp keyword_argument_generator(depth) do
    fixed_list([identifier_generator(), expression_generator(depth)])
    |> map(fn [key, value] -> "#{key}=#{wrap_pipeline_arg(value)}" end)
  end

  defp pipeline_expression_generator(depth) do
    fixed_list([
      expression_generator(0),
      list_of(pipeline_stage_generator(depth), min_length: 1, max_length: 3)
    ])
    |> map(fn [lhs, stages] -> Enum.join([lhs | stages], " |> ") end)
  end

  defp pipeline_stage_generator(depth) do
    child_depth = max(depth - 1, 0)

    one_of([
      member_of(@helpers),
      bind(pipeline_argument_list_generator(child_depth), fn args ->
        bind(member_of(@helpers), fn name ->
          constant("#{name}(#{Enum.join(args, ", ")})")
        end)
      end)
    ])
  end

  defp pipeline_argument_list_generator(depth) do
    child_depth = max(depth - 1, 0)

    one_of([
      constant([]),
      list_of(pipeline_arg_generator(child_depth), max_length: 3),
      bind(integer(1..3), fn kw_count ->
        list_of(keyword_argument_generator(child_depth),
          min_length: kw_count,
          max_length: kw_count
        )
      end)
    ])
  end

  defp pipeline_arg_generator(depth) do
    child_depth = max(depth - 1, 0)

    one_of([
      expression_generator(child_depth),
      keyword_argument_generator(child_depth)
    ])
  end

  defp identifier_generator, do: member_of(@idents)

  defp parent_generator do
    member_of(@idents)
    |> map(fn ident -> "../#{ident}" end)
  end

  defp special_generator do
    member_of(["this", "@index", "@key"])
  end

  defp path_generator do
    fixed_list([member_of(@idents), list_of(member_of(@idents), min_length: 1, max_length: 2)])
    |> map(fn
      ["this", parts] -> Enum.join(["this" | parts], ".")
      [root, parts] -> Enum.join([root | parts], ".")
    end)
  end

  defp literal_generator do
    one_of([
      member_of(["true", "false", "nil", "0", "1", "20", "-3", "2.5"]),
      string(:alphanumeric, max_length: 8)
      |> map(&inspect/1)
    ])
  end

  defp trim_marker_generator, do: member_of(["", "~"])

  defp wrap_pipeline_arg(value) do
    if String.contains?(value, " |>") do
      "(#{value})"
    else
      value
    end
  end

  defp safe_result(fun) do
    try do
      {:ok, fun.()}
    rescue
      error ->
        flunk(Exception.format(:error, error, __STACKTRACE__))
    catch
      kind, reason ->
        flunk(Exception.format(kind, reason, __STACKTRACE__))
    end
  end
end
