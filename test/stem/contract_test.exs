# SPDX-License-Identifier: Apache-2.0

Code.require_file("../test_helper.exs", __DIR__)

defmodule Stem.ContractTest do
  use ExUnit.Case, async: true

  test "normalize handles nil and string keys" do
    assert Stem.Contract.normalize(nil) == nil

    assert Stem.Contract.normalize(required: ["title"], optional: ["subtitle"]) == %{
             required: [:title],
             optional: [:subtitle]
           }
  end

  test "validate! accepts keyword and map assigns with required keys" do
    assert :ok = Stem.Contract.validate!([title: "Spec"], %{required: [:title], optional: []})

    assert :ok =
             Stem.Contract.validate!(%{"title" => "Spec"}, %{required: [:title], optional: []})

    assert :ok = Stem.Contract.validate!(%{title: "Spec"}, %{required: [:title], optional: []})
  end

  test "validate! raises for missing keys" do
    assert_raise ArgumentError, ~r/missing required assigns/, fn ->
      Stem.Contract.validate!([], %{required: [:title], optional: []})
    end
  end
end
