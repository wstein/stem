# SPDX-License-Identifier: Apache-2.0

[
  plugins: [Stem.Formatter],
  inputs: [
    "{mix,.formatter}.exs",
    "{config,lib,test}/**/*.{ex,exs}",
    "examples/**/*.exs",
    "examples/templates/**/*.stem"
  ]
]
