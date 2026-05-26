// SPDX-License-Identifier: Apache-2.0
//
// A two-stage pipeline: JSONata preprocesses raw data into a view model, then
// Stem renders it. This mirrors the playground's "Transform tab" idea — keep the
// template logic-less by doing aggregation/derivation in a declarative transform
// first, then render with capability-gated transformers for presentation.
//
//   stage 1 (jsonata-core): raw orders -> { title, products: [{name, revenue}], total }
//   stage 2 (stem_native):  view model -> a report, using Strings + Collections +
//                           Predicates built-ins and a custom transformer
//
//   cargo run --example jsonata_pipeline

use serde_json::{json, Value};

// Stage 1. Group orders by product, sum revenue, rank descending, and total —
// all declaratively in JSONata, so the template never has to.
const TRANSFORM: &str = r#"
(
  $lines := orders.{ "product": product, "revenue": qty * price };
  $byProduct := $lines{ product: $sum(revenue) };
  {
    "title": "Revenue by product",
    "currency": currency,
    "products": $sort(
      $each($byProduct, function($revenue, $name) { { "name": $name, "revenue": $revenue } }),
      function($l, $r) { $l.revenue < $r.revenue }
    ),
    "total": $sum($lines.revenue)
  }
)
"#;

// Stage 2. A logic-less report over the view model. `upcase`/`capitalize` are
// Strings built-ins; `map`/`take`/`join` are Collections/Minimum; `contains` is
// a Predicate; `shout` is the custom host transformer from `src/lib.rs`.
const TEMPLATE: &str = "\
{{ title | upcase }} ({{ currency }})

Top sellers: {{ products | map \"name\" | take 2 | join \", \" }}

{{#each products}}\
- {{ name | capitalize }}: {{ revenue }} {{ @root.currency }}{{#if name | contains \"w\"}} (stock item){{/if}}
{{/each}}\
Total: {{ total }} {{ currency }}
{{ title | shout }}
";

fn raw_data() -> Value {
    json!({
        "currency": "EUR",
        "orders": [
            { "product": "widget",   "qty": 3, "price": 10 },
            { "product": "gadget",   "qty": 1, "price": 50 },
            { "product": "widget",   "qty": 2, "price": 10 },
            { "product": "sprocket", "qty": 5, "price": 4  }
        ]
    })
}

fn main() {
    // Stage 1: JSONata preprocessing (see `stem_examples::jsonata`).
    let view_model = match stem_examples::jsonata(TRANSFORM, &raw_data()) {
        Ok(model) => model,
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    };

    // Stage 2: Stem rendering, with the example's loaded capability groups and
    // custom transformers.
    match stem_examples::render_template(TEMPLATE, &view_model) {
        Ok(rendered) => print!("{rendered}"),
        Err(err) => {
            eprintln!("{err}");
            std::process::exit(1);
        }
    }
}
