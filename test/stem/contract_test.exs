# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ContractTest.SampleContract do
  @moduledoc false
  def contract, do: [required: [title: :string], optional: [count: :integer]]
end

defmodule Stem.ContractTest do
  use ExUnit.Case, async: true

  alias Stem.ContractTest.SampleContract

  # ── normalize/1 ────────────────────────────────────────────────────────────

  test "normalize returns nil for nil input" do
    assert Stem.Contract.normalize(nil) == nil
  end

  test "normalize converts atom keys to {key, :any} tuples" do
    result = Stem.Contract.normalize(required: [:title], optional: [:subtitle])
    assert result.required == [{:title, :any}]
    assert result.optional == [{:subtitle, :any}]
  end

  test "normalize converts string keys to atoms" do
    result = Stem.Contract.normalize(required: ["title"], optional: ["subtitle"])
    assert result.required == [{:title, :any}]
    assert result.optional == [{:subtitle, :any}]
  end

  test "normalize preserves type annotations" do
    result = Stem.Contract.normalize(required: [title: :string, count: :integer])
    assert result.required == [{:title, :string}, {:count, :integer}]
  end

  test "normalize loads contract from module exporting contract/0" do
    defmodule TestContractModule do
      def contract, do: [required: [:title], optional: [:body]]
    end

    result = Stem.Contract.normalize(TestContractModule)
    assert result.required == [{:title, :any}]
    assert result.optional == [{:body, :any}]
  end

  test "normalize raises for module without contract/0" do
    defmodule NoContractModule do
    end

    assert_raise ArgumentError, ~r/must export contract\/0/, fn ->
      Stem.Contract.normalize(NoContractModule)
    end
  end

  # ── validate!/2 ────────────────────────────────────────────────────────────

  test "validate! accepts keyword assigns with required keys" do
    contract = Stem.Contract.normalize(required: [:title], optional: [])
    assert :ok = Stem.Contract.validate!([title: "Spec"], contract)
  end

  test "validate! accepts map assigns with atom keys" do
    contract = Stem.Contract.normalize(required: [:title], optional: [])
    assert :ok = Stem.Contract.validate!(%{title: "Spec"}, contract)
  end

  test "validate! accepts map assigns with string keys" do
    contract = Stem.Contract.normalize(required: [:title], optional: [])
    assert :ok = Stem.Contract.validate!(%{"title" => "Spec"}, contract)
  end

  test "validate! raises for missing required keys" do
    contract = Stem.Contract.normalize(required: [:title], optional: [])

    assert_raise ArgumentError, ~r/missing required assigns/, fn ->
      Stem.Contract.validate!([], contract)
    end
  end

  test "validate! accepts typed assigns when type matches" do
    contract = Stem.Contract.normalize(required: [title: :string, count: :integer])
    assert :ok = Stem.Contract.validate!([title: "Spec", count: 3], contract)
  end

  test "validate! raises when typed assign has wrong type" do
    contract = Stem.Contract.normalize(required: [count: :integer])

    assert_raise ArgumentError, ~r/type mismatch.*count.*must be integer/, fn ->
      Stem.Contract.validate!([count: "oops"], contract)
    end
  end

  test "validate! checks optional typed assigns when present" do
    contract = Stem.Contract.normalize(required: [], optional: [score: :float])

    assert_raise ArgumentError, ~r/type mismatch.*score.*must be float/, fn ->
      Stem.Contract.validate!([score: 42], contract)
    end
  end

  # ── validate_types!/1 (compile-time check) ────────────────────────────────

  test "validate_types! accepts nil" do
    assert :ok = Stem.Contract.validate_types!(nil)
  end

  test "validate_types! accepts known types" do
    assert :ok =
             Stem.Contract.validate_types!(required: [title: :string], optional: [n: :integer])
  end

  test "validate_types! raises for unknown types" do
    assert_raise ArgumentError, ~r/unknown type :widget/, fn ->
      Stem.Contract.validate_types!(required: [title: :widget])
    end
  end

  test "validate_types! follows a module reference exporting contract/0" do
    assert :ok = Stem.Contract.validate_types!(SampleContract)
  end

  test "validate_types! raises for a malformed entry" do
    assert_raise ArgumentError, ~r/expected atom or \{atom, type\} entry/, fn ->
      Stem.Contract.validate_types!(required: ["not-a-valid-entry"])
    end
  end

  # ── validate!/2 (runtime type checks) ─────────────────────────────────────

  test "normalize converts binary keys with type annotations" do
    result = Stem.Contract.normalize(required: [{"title", :string}])
    assert result.required == [title: :string]
  end

  test "validate! accepts every annotated type when the value matches" do
    contract =
      Stem.Contract.normalize(
        required: [
          s: :string,
          bin: :binary,
          i: :integer,
          f: :float,
          n: :number,
          b: :boolean,
          a: :atom,
          l: :list,
          m: :map
        ]
      )

    assigns = [s: "x", bin: "y", i: 1, f: 1.5, n: 2, b: true, a: :ok, l: [1], m: %{}]

    assert :ok = Stem.Contract.validate!(assigns, contract)
  end

  test "validate! skips type checks for absent optional assigns" do
    contract = Stem.Contract.normalize(optional: [subtitle: :string])
    assert :ok = Stem.Contract.validate!([], contract)
  end
end
