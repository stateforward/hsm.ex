# hsm.ex

<!-- package metadata and public API summary from mix.exs and lib/hsm.ex -->

`hsm.ex` is the Elixir implementation of the StateForward hierarchical state
machine DSL/runtime. It is a native Elixir package, not a wrapper around another
language implementation.

## Status

This package is fully conformant with the current shared HSM JSON IR suite and
DSL contract. The current full shared suite run is `1390 ok / 0 fail / 0 skip`.
Implemented areas include:

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

This example uses the regular Elixir snake_case API and shows the main dispatch
surfaces together: direct events, event objects with data, generated `on_set`
and `on_call` events, deferred events, logical-time timers, snapshots, contexts,
`dispatch_all`, and `dispatch_to`.

```elixir
model =
  HSM.define("Checkout", [
    HSM.attribute("payment_received", :boolean, false),
    HSM.attribute("attempts", :integer, 0),
    HSM.operation("ship", fn _ctx, _instance, event ->
      [%{carrier: carrier}] = Map.fetch!(event.data, :Args)
      {:tracking, carrier}
    end),
    HSM.initial(HSM.target("cart")),
    HSM.state("cart", [
      HSM.transition([HSM.on("checkout"), HSM.target("authorizing")]),
      HSM.transition([HSM.on("cancel"), HSM.target("cancelled")])
    ]),
    HSM.state("authorizing", [
      HSM.entry(fn instance, _event ->
        {attempts, true} = HSM.get(instance, "attempts")
        HSM.set(instance, "attempts", attempts + 1)
      end),
      HSM.defer("cancel"),
      HSM.transition([HSM.after_ms(30), HSM.target("expired")]),
      HSM.transition([
        HSM.on_set("payment_received"),
        HSM.guard(fn instance, _event ->
          HSM.get(instance, "payment_received") == {true, true}
        end),
        HSM.target("paid")
      ])
    ]),
    HSM.state("paid", [
      HSM.transition([HSM.on_call("ship"), HSM.target("shipped")]),
      HSM.transition([HSM.on("cancel"), HSM.target("cancelled")])
    ]),
    HSM.final("shipped"),
    HSM.final("expired"),
    HSM.final("cancelled")
  ])

machine =
  model
  |> HSM.new(HSM.Config.new(id: "order-1"))
  |> HSM.start()
  |> HSM.dispatch(HSM.event("checkout", data: %{cart_id: "A-100"}))

machine = HSM.set(machine, "payment_received", true)
{machine, tracking} = HSM.call(machine, "ship", [%{carrier: "UPS"}])
snapshot = HSM.take_snapshot(machine)

HSM.state(machine)
#=> "/Checkout/shipped"

tracking
#=> {:tracking, "UPS"}

Map.fetch!(snapshot, :Attributes)
#=> %{"/Checkout/attempts" => 1, "/Checkout/payment_received" => true}

expired =
  model
  |> HSM.new(HSM.Config.new(id: "order-2"))
  |> HSM.start()
  |> HSM.dispatch("checkout")
  |> HSM.tick(30)

HSM.state(expired)
#=> "/Checkout/expired"

cancelled =
  model
  |> HSM.new(HSM.Config.new(id: "order-3"))
  |> HSM.start()
  |> HSM.dispatch("checkout")
  |> HSM.dispatch("cancel")
  |> HSM.set("payment_received", true)

HSM.state(cancelled)
#=> "/Checkout/cancelled"

one = model |> HSM.new(HSM.Config.new(id: "one")) |> HSM.start()
two = model |> HSM.new(HSM.Config.new(id: "two")) |> HSM.start()

ctx =
  HSM.make_context()
  |> HSM.Context.register(one)
  |> HSM.Context.register(two)
  |> HSM.dispatch_to("checkout", ["one"])
  |> HSM.dispatch_all("cancel")

HSM.state(ctx.machines["one"])
#=> "/Checkout/authorizing"

HSM.state(ctx.machines["two"])
#=> "/Checkout/cancelled"
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

The Elixir runtime passes the current full shared JSON conformance suite:
`1390 ok / 0 fail / 0 skip`. Coverage includes core transition flow, nested
initial entry, guard selection, choice fallback, history defaults, root
completion transitions, source-qualified transitions, deferred replay, `on_call`,
timer behavior sources, transition kinds, lifecycle restart/stop, validation,
snapshots, group dispatch, group snapshots, broadcast dispatch, dispatch-to
targeting, event ownership, path resolution, model-registry redefinition
lowering, nested dispatch reentrancy, normalized behavior errors, custom queue
hooks, clock hooks, host-clock timer cancellation, typed attribute writes,
event/kind helpers, deterministic async ordering, cancellable activity handles,
activity failure message handling, native submachine composition, child timers,
child defers, source-qualified child transitions, child attribute/default
behavior, child operation/on_call binding, cross-cutting submachine snapshots,
entry-point target lowering, exit-point routing, submachine event-data and
generated-trigger replay, submachine/model-registry validation, scoped
child-defer cleanup on parent submachine exit, deferred replay priority after
exit-point handlers and final-state completion, source-qualified/root exit-point
handler lowering, exit-point handoff into entry-point targets, completion
priority over nested dispatch, child-model timer/activity/operation all-ops
reentrancy, submachine exit-point boundary ordering, nested boundary ordering,
guard fallthrough to an ancestor handler, self reentry through an entry point,
submodel/root exit-point fallthrough routing, and unhandled exit-point errors.

The conformance runner retains exit `77` for forward-compatible explicit
unsupported-feature skips in future suites; the current suite has no skips.
