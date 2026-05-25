# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.DSLTest.Views do
  use Stem.DSL

  deftemplate(
    :welcome_email,
    """
    <h1>Hello {{name}}</h1>
    {{#if is_admin}}
      <p>You have admin access.</p>
    {{else}}
      <p>Standard access.</p>
    {{/if}}
    """,
    [:assigns]
  )

  template_file = Path.join(__DIR__, "../fixtures/stem_template_with_bindings.stem")
  deftemplate_file(:from_file, template_file, [:assigns])
end

defmodule Stem.DSLTest.PrivateViews do
  use Stem.DSL

  deftemplate(:private_hello, "Hello {{name}}", [:assigns], kind: :defp)

  deftemplate_file(
    :private_card,
    Path.join(__DIR__, "../fixtures/stem_template_with_bindings.stem"),
    [:assigns],
    kind: :defp
  )

  def hello(assigns), do: private_hello(assigns)
  def card(assigns), do: private_card(assigns)
end

defmodule Stem.DSLTest.SigilViews do
  import Stem.Sigil

  def hello(assigns), do: ~STEM"Hello {{name}}"
  def upcase(assigns, transformers), do: ~STEM"{{upcase name}}"
end

defmodule Stem.DSLTest.DictionaryViews do
  use Stem.DSL

  defdictionary(:status_map, %{
    "1" => "Active",
    "12" => "Inactive",
    "99" => "Archived"
  })

  deftemplate(
    :render_inline_template,
    "{{lookup status_map current_status | default \"Unknown\"}}",
    [:assigns]
  )

  deftemplate_file(
    :render_file_template,
    Path.join(__DIR__, "../fixtures/stem_dictionary_lookup.stem"),
    [:assigns]
  )

  def render_inline_sigil(assigns) do
    ~STEM"""
    Inline {{lookup status_map current_status | default "Unknown"}}
    """
    |> String.trim()
  end
end

defmodule Stem.DSLTest.UseStemViews do
  use Stem

  deftemplate(:hello, "Hello {{name}}", [:assigns])
  deftemplate(:contract_card, "{{title}}", [:assigns], contract: [required: [:title]])

  def hello_inline(assigns), do: ~STEM"Inline {{name}}"
end

defmodule Stem.DSLTest do
  use ExUnit.Case, async: true

  test "deftemplate defines compile-time function from heredoc template" do
    assert Stem.DSLTest.Views.welcome_email(name: "Nina", is_admin: true) ==
             "<h1>Hello Nina</h1>\n\n  <p>You have admin access.</p>\n\n"
  end

  test "deftemplate_file defines compile-time function from file" do
    assert Stem.DSLTest.Views.from_file(bar: 7) == "foo 7\n"
  end

  test "kind: :defp creates private functions for deftemplate and deftemplate_file" do
    assert Stem.DSLTest.PrivateViews.hello(name: "Nina") == "Hello Nina"
    assert Stem.DSLTest.PrivateViews.card(bar: 11) == "foo 11\n"
  end

  test "~STEM renders inline templates with surrounding assigns" do
    assert Stem.DSLTest.SigilViews.hello(name: "Nina") == "Hello Nina"
  end

  test "~STEM can resolve transformers from surrounding scope" do
    transformers = %{"upcase" => fn [value], _ctx -> String.upcase(to_string(value)) end}

    assert Stem.DSLTest.SigilViews.upcase([name: "Nina"], transformers) == "NINA"
  end

  test "use Stem imports the DSL and sigil" do
    assert Stem.DSLTest.UseStemViews.hello(name: "Nina") == "Hello Nina"
    assert Stem.DSLTest.UseStemViews.hello_inline(name: "Nina") == "Inline Nina"
  end

  test "defdictionary injects assigns into deftemplate, deftemplate_file, and ~STEM" do
    assert Stem.DSLTest.DictionaryViews.render_inline_template(current_status: "12") == "Inactive"

    assert Stem.DSLTest.DictionaryViews.render_file_template(current_status: "99") ==
             "File Status: Archived\n"

    assert Stem.DSLTest.DictionaryViews.render_inline_sigil(current_status: "1") ==
             "Inline Active"
  end

  test "explicit assigns override injected dictionaries" do
    assert Stem.DSLTest.DictionaryViews.render_inline_template(
             current_status: "12",
             status_map: %{"12" => "Overridden"}
           ) == "Overridden"
  end

  test "defdictionary requires :assigns in generated template functions" do
    assert_raise ArgumentError, ~r/Stem dictionaries require an :assigns argument/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidDictionaryArgs do
        use Stem.DSL

        defdictionary :status_map, %{"1" => "Active"}
        deftemplate :broken, "{{lookup status_map current_status}}", [:transformers]
      end
      """)
    end
  end

  test "defdictionary requires an atom name" do
    assert_raise ArgumentError, ~r/expected dictionary name to be an atom/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidDictionaryName do
        use Stem.DSL
        defdictionary "status_map", %{"1" => "Active"}
      end
      """)
    end
  end

  test "template contracts validate required assigns" do
    assert Stem.DSLTest.UseStemViews.contract_card(title: "Spec") == "Spec"

    assert_raise ArgumentError, ~r/missing required assigns/, fn ->
      Stem.DSLTest.UseStemViews.contract_card([])
    end
  end

  test "invalid :kind raises argument error" do
    assert_raise ArgumentError, ~r/expected :kind to be :def or :defp/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidKind do
        use Stem.DSL
        deftemplate :broken, "Hello {{name}}", [:assigns], kind: :oops
      end
      """)
    end
  end

  test "non-keyword options raises argument error" do
    assert_raise ArgumentError, ~r/expected options to be a keyword list/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.InvalidOptions do
        use Stem.DSL
        deftemplate :broken, "Hello {{name}}", [:assigns], :oops
      end
      """)
    end
  end

  # ---------------------------------------------------------------------------
  # Static-dictionary tests
  # ---------------------------------------------------------------------------

  test "defdictionary rejects function calls (non-literal expression)" do
    assert_raise ArgumentError, ~r/must be a literal/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.NonLiteralDict do
        use Stem.DSL
        defdictionary :bad, File.read!("mymap.yaml")
      end
      """)
    end
  end

  test "defdictionary rejects variable references (non-literal expression)" do
    assert_raise ArgumentError, ~r/must be a literal/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.NonLiteralDictVar do
        use Stem.DSL
        some_var = %{"k" => "v"}
        defdictionary :bad, some_var
      end
      """)
    end
  end

  test "defdictionary rejects nested side-effectful expressions inside literals" do
    assert_raise ArgumentError, ~r/must be a literal/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.NonLiteralNested do
        use Stem.DSL
        defdictionary :bad, %{"now" => DateTime.utc_now()}
      end
      """)
    end
  end

  test "defdictionary rejects tuple literals" do
    assert_raise ArgumentError, ~r/must be a literal/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.TupleDict do
        use Stem.DSL
        defdictionary :bad, {:ok, 1}
      end
      """)
    end
  end

  test "defdictionary accepts a module attribute whose value is a literal map" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.AttrDictOk do
        use Stem.DSL
        @my_data %{"a" => "Alpha"}
        defdictionary :letters, @my_data
        deftemplate :render, "{{lookup letters k}}", [:assigns]
      end
      """)

    assert mod.render(k: "a") == "Alpha"
  end

  test "defdictionary rejects a module attribute whose value is not a literal" do
    # self() stores a PID at attribute-set time — a PID is not a literal value.
    assert_raise ArgumentError, ~r/must be a literal/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.AttrDictBad do
        use Stem.DSL
        @bad_data self()
        defdictionary :data, @bad_data
      end
      """)
    end
  end

  test "defdictionary rejects a module attribute that is not yet set" do
    assert_raise ArgumentError, ~r/is not set/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.AttrNotSet do
        use Stem.DSL
        defdictionary :data, @undefined_attr
      end
      """)
    end
  end

  test "declaration order: template before dictionary sees no injection" do
    # A deftemplate declared BEFORE defdictionary must NOT receive the dictionary.
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.OrderCheck do
        use Stem.DSL
        deftemplate :before_dict, "{{lookup status_map s}}", [:assigns]
        defdictionary :status_map, %{"1" => "Active"}
        deftemplate :after_dict, "{{lookup status_map s}}", [:assigns]
      end
      """)

    # Declared after: injection present, lookup finds the value
    assert mod.after_dict(s: "1") == "Active"
    # Declared before: no injection; caller must supply the map manually
    assert mod.before_dict(s: "1", status_map: %{"1" => "Manual"}) == "Manual"
  end

  test "duplicate defdictionary names: last one wins" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.DuplicateDict do
        use Stem.DSL
        defdictionary :map, %{"k" => "first"}
        defdictionary :map, %{"k" => "second"}
        deftemplate :render, "{{lookup map k}}", [:assigns]
      end
      """)

    assert mod.render(k: "k") == "second"
  end

  test "defdictionary_merge combines two dictionaries in declaration order" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.MergeDict do
        use Stem.DSL
        defdictionary :base,  %{"a" => "Alpha", "c" => "Base-C"}
        defdictionary :extra, %{"b" => "Beta",  "c" => "Extra-C"}
        defdictionary_merge :combined, [:base, :extra]
        deftemplate :render, "{{lookup combined k}}", [:assigns]
      end
      """)

    assert mod.render(k: "a") == "Alpha"
    assert mod.render(k: "b") == "Beta"
    # extra wins on conflict
    assert mod.render(k: "c") == "Extra-C"
  end

  test "defdictionary_merge raises when source is not declared" do
    assert_raise ArgumentError, ~r/unknown dictionary/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.MergeMissing do
        use Stem.DSL
        defdictionary :base, %{"a" => "A"}
        defdictionary_merge :combined, [:base, :ghost]
      end
      """)
    end
  end

  test "defdictionary_merge raises when source name is not an atom" do
    assert_raise ArgumentError, ~r/expected source names to be atoms/, fn ->
      Code.compile_string("""
      defmodule Stem.DSLTest.MergeNonAtom do
        use Stem.DSL
        defdictionary :base, %{"a" => "A"}
        defdictionary_merge :combined, [:base, "ghost"]
      end
      """)
    end
  end

  test "multiple dictionaries are all injected" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.MultiDict do
        use Stem.DSL
        defdictionary :colors, %{"r" => "Red", "g" => "Green"}
        defdictionary :sizes,  %{"s" => "Small", "l" => "Large"}
        deftemplate :render, "{{lookup colors c}} / {{lookup sizes z}}", [:assigns]
      end
      """)

    assert mod.render(c: "r", z: "l") == "Red / Large"
  end

  test "defdictionary with empty map is accepted and injects nothing useful" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.EmptyDict do
        use Stem.DSL
        defdictionary :empty_map, %{}
        deftemplate :render, "{{name}}", [:assigns]
      end
      """)

    # Empty dictionary should not break rendering; assigns still work normally
    assert mod.render(name: "ok") == "ok"
  end

  test "defdictionary accepts numbers, booleans, nil, and list literals" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.MixedLiteralDict do
        use Stem.DSL
        defdictionary :data, %{
          "n" => 42,
          "t" => true,
          "f" => false,
          "z" => nil,
          "list" => [1, 2, 3]
        }
        deftemplate :render, "{{lookup data k}}", [:assigns]
      end
      """)

    assert mod.render(k: "n") == "42"
    assert mod.render(k: "t") == "true"
    assert mod.render(k: "f") == "false"
  end

  test "defdictionary accepts a module attribute with mixed literal types" do
    [{mod, _}] =
      Code.compile_string("""
      defmodule Stem.DSLTest.AttrMixedDict do
        use Stem.DSL
        @data %{"n" => 7, "t" => true, "f" => false, "z" => nil, "list" => [1, 2]}
        defdictionary :data, @data
        deftemplate :render, "{{lookup data k}}", [:assigns]
      end
      """)

    assert mod.render(k: "n") == "7"
    assert mod.render(k: "t") == "true"
  end

  test "defdictionary compilation produces no unused-variable warnings" do
    # Compile with the same capture mechanism as ExUnit warning checks:
    # if the compile emits warnings they would surface via Erlang logger or
    # via the :stderr redirect below.
    captured =
      ExUnit.CaptureIO.capture_io(:stderr, fn ->
        Code.compile_string("""
        defmodule Stem.DSLTest.WarnFreeDict do
          use Stem.DSL
          defdictionary :m, %{"a" => "A"}
          deftemplate :render, "{{lookup m k}}", [:assigns]
          def sigil_render(assigns), do: ~STEM"{{lookup m k}}"
        end
        """)
      end)

    refute captured =~ "unused variable"
  end
end
