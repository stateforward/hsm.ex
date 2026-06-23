# hsm.ex

<!-- package metadata and public API summary from mix.exs and lib/hsm.ex -->

`hsm.ex` is the Elixir implementation of the StateForward hierarchical state
machine DSL/runtime. It is a native Elixir package, not a wrapper around another
language implementation.

## Status

This repository contains the initial Elixir runtime and tests for the shared HSM
DSL contract. Implemented areas include:

- model definition, redefinition, validators/finalizers, states, final states,
  submachine states, entry/exit points, transitions, initial transitions
- nested state entry/exit ordering
- guards, effects, entry actions, exit actions, operation references and contracts
- typed attributes, runtime type validation, `on_set`, `on_call`, and predicate `when`
- choice, shallow history, deep history, deferral, completion, snapshots with
  visible transition metadata
- deterministic logical-time timers via `HSM.tick/2` and cancellable host-clock timers
- external, internal, local, and self transition kinds
- start, stop, and restart lifecycle behavior
- group dispatch, group snapshots, broadcast dispatch, context helpers, and kind utilities
- runtime `ID`, `Name`, and `QualifiedName` helpers
- runtime event constructors, canonical event constants, wildcard events, and inherited
  event/state/pseudostate/transition kind helpers
- canonical dispatch APIs without processed/deferred status payloads
- per-recipient event metadata ownership for group/broadcast dispatch
- normalized behavior error tracing in the conformance runner
- nested dispatch queue reentrancy with FIFO-after-current ordering
- deterministic async behavior ordering, cancellable activity handles, and activity
  failure message handling
- `Config.Queue`, `Config.Clock`, and `DefaultClock` runtime hooks for the
  immutable Elixir runtime
- finalized runtime indexes for transition candidates, static entry/exit paths,
  default initial transitions, history updates, timers, and active defers

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
machine = HSM.dispatch(machine, "open")

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

## Runtime Finalization

<!-- finalized runtime indexes and dispatch benchmark from lib/hsm/dsl.ex, lib/hsm/instance.ex, and benchmark/traffic_light_bench.exs -->

`HSM.define/2` and `HSM.redefine/2` build and finalize immutable runtime indexes
before an instance starts dispatching. Finalization precomputes active ancestry,
deferred-event lookup, transition candidate ordering, timer transitions, static
transition path plans, default initial transition plans, and history update
entries. Dispatch still evaluates runtime data, guards, effects, generated
events, queues, timers, and dynamic pseudostate/history targets at runtime.

The validation-enabled traffic-light benchmark improved from a baseline median
of `187,715 ops/sec` to a final median of `677,494 ops/sec` on the same
1-second warmup and 5-second measurement settings.

## Development

```sh
mix test
mix hsm.conformance ../conformance/cases/*.json
```

The current suite passes all supported shared JSON conformance cases. Coverage
includes core transition flow, nested initial entry, guard selection, choice
fallback, history defaults, root completion transitions, source-qualified
transitions, deferred replay, `on_call`, timer behavior sources, transition
kinds, lifecycle restart/stop, validation, snapshots, group dispatch, group
snapshots, broadcast dispatch, dispatch-to targeting, event ownership, path
resolution, model-registry redefinition lowering, nested dispatch reentrancy,
normalized behavior errors, custom queue hooks, clock hooks, host-clock timer
cancellation, typed attribute writes, event/kind helpers, deterministic async
ordering, cancellable activity handles, activity failure message handling,
native submachine composition for child state flow, child timers, child defers,
source-qualified child transitions, child attribute/default behavior where
scoped reuse is not required, child operation/on_call binding, cross-cutting
submachine snapshots and async/activity basics, entry-point target lowering,
basic exit-point routing, most submachine event-data/generated-trigger replay
cases, and
submachine/model-registry validation, scoped child-defer cleanup on parent
submachine exit, and deferred replay priority after exit-point handlers and
final-state completion, source-qualified/root exit-point handler lowering, and
exit-point handoff into entry-point targets, completion priority over nested
dispatch, child-model timer/activity/operation all-ops reentrancy, submachine
exit-point boundary ordering, nested boundary ordering, guard fallthrough to an
ancestor handler, self reentry through an entry point, and selected generated
trigger and event-data fallthrough replay cases, submodel/root exit-point
fallthrough routing, and unhandled exit-point errors. The current full shared
suite run is `1390 ok / 0 fail / 0 skip`.

The conformance runner executes supported shared JSON cases and exits `77` when
all requested cases are explicit unsupported-feature skips.
