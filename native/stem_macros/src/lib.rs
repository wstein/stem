// SPDX-License-Identifier: Apache-2.0
//
// Compile-time macros for Stem. `stem!("…")` runs the Stem compiler at Rust
// build time: a template syntax error becomes a Rust compile error, and the
// bytecode is embedded in the binary, so no Stem-syntax parsing happens at
// runtime — only the cheap wire deserialize in `Program::from_wire`.

use quote::quote;
use syn::{parse_macro_input, LitStr};

/// Compiles a Stem template **literal** to bytecode at compile time, expanding
/// to an expression of type `stem_native::Program`.
///
/// A template syntax error is reported as a compile error pointing at the
/// literal. The compiled bytecode is embedded as a string and reconstructed once
/// with [`stem_native::Program::from_wire`] when the expression is evaluated, so
/// bind it once and render many times:
///
/// ```ignore
/// let program = stem_macros::stem!("Hello {{ name }}!");
/// let out = program.render(&data, &stem_native::RenderOptions::new())?;
/// ```
#[proc_macro]
pub fn stem(input: proc_macro::TokenStream) -> proc_macro::TokenStream {
    let literal = parse_macro_input!(input as LitStr);
    match stem_compile::compile_to_wire_string(&literal.value()) {
        Ok(wire) => quote! {
            stem_native::Program::from_wire(#wire)
                .expect("stem!: embedded a valid wire program at compile time")
        }
        .into(),
        Err(error) => syn::Error::new_spanned(&literal, format!("stem! template error: {error}"))
            .to_compile_error()
            .into(),
    }
}
