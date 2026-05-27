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
- deterministic logical-time timers via `HSM.tick/2`
- external, internal, local, and self transition kinds
- start, stop, and restart lifecycle behavior
- group dispatch, group snapshots, broadcast dispatch, context helpers, and kind utilities
- per-recipient event metadata ownership for group/broadcast dispatch
- normalized behavior error tracing in the conformance runner
- nested dispatch queue reentrancy with FIFO-after-current ordering

Async activity cancellation and custom runtime queues/clocks are still incomplete.

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
mix hsm.conformance ../hsm/conformance/cases/*.json
```

The current suite covers core transition flow, nested initial entry, guard
selection, choice fallback, source-qualified parent transitions, deferral
replay/FIFO ordering, history defaults, root completion transitions, `on_call`, timer
behavior, transition kinds, lifecycle restart/stop, validation, and snapshots.
Shared conformance also covers group dispatch, group snapshots, broadcast
dispatch, event ownership, nested dispatch reentrancy, and normalized behavior
errors for the supported immutable instance API.

The conformance runner executes supported shared JSON cases and exits `77` when
all requested cases are explicit unsupported-feature skips.
