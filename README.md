# hsm.ex

<!-- package metadata and public API summary from mix.exs and lib/hsm.ex -->

`hsm.ex` is the Elixir implementation of the StateForward hierarchical state
machine DSL/runtime. It is a native Elixir package, not a wrapper around another
language implementation.

## Status

This repository contains the initial Elixir runtime and tests for the shared HSM
DSL contract. Implemented areas include:

- model definition, states, final states, transitions, initial transitions
- nested state entry/exit ordering
- guards, effects, entry actions, exit actions, operation references
- attributes, `on_set`, `on_call`, and predicate `when`
- choice, shallow history, deep history, deferral, completion, snapshots
- groups, context dispatch helpers, and kind utilities

Timer declarations are represented in the DSL, but deterministic timer
scheduling is not wired to an Elixir clock process yet.

## Usage

```elixir
model =
  HSM.define("Door", [
    HSM.initial(HSM.target("closed")),
    HSM.state("closed", [
      HSM.transition([
        HSM.on("open"),
        HSM.target("open")
      ])
    ]),
    HSM.state("open")
  ])

machine = model |> HSM.new() |> HSM.start()
{machine, :processed} = HSM.dispatch(machine, "open")

HSM.state(machine)
#=> "/Door/open"
```

The shared DSL specifies PascalCase API names. Elixir reserves uppercase
identifiers for aliases in normal call syntax, so this package exposes idiomatic
snake_case functions for ordinary use and PascalCase atom exports for tooling or
generated bindings:

```elixir
model = apply(HSM, :Define, ["Door", [HSM.initial(HSM.target("closed")), HSM.state("closed")]])
```

## Development

```sh
mix test
```

The current authoring environment did not include `elixir`/`mix`, so tests were
written but could not be executed during the initial scaffold.
