defmodule HSMTest do
  use ExUnit.Case, async: true

  test "basic transition executes exit, effect, and entry in order" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("Door", [
        HSM.initial(HSM.target("closed")),
        HSM.state("closed", [
          HSM.entry(fn -> push.("enter:closed") end),
          HSM.exit(fn -> push.("exit:closed") end),
          HSM.transition([
            HSM.on("open"),
            HSM.target("open"),
            HSM.effect(fn -> push.("effect:open") end)
          ])
        ]),
        HSM.state("open", [
          HSM.entry(fn -> push.("enter:open") end)
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "open")

    assert HSM.state(machine) == "/Door/open"
    assert Agent.get(log, & &1) == ["enter:closed", "exit:closed", "effect:open", "enter:open"]
  end

  test "nested initial enters parent before child" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("Nested", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.entry(fn -> push.("parent") end),
          HSM.initial([HSM.target("./child"), HSM.effect(fn -> push.("initial") end)]),
          HSM.state("child", [
            HSM.entry(fn -> push.("child") end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/Nested/parent/child"
    assert Agent.get(log, & &1) == ["parent", "initial", "child"]
  end

  test "guarded transitions select the first passing transition" do
    model =
      HSM.define("Guarded", [
        HSM.attribute("ready", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn inst, _event -> elem(HSM.get(inst, "ready"), 0) end),
            HSM.target("done")
          ]),
          HSM.transition([HSM.on("go"), HSM.target("idle")])
        ]),
        HSM.final("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "go")
    assert HSM.state(machine) == "/Guarded/idle"

    machine = HSM.set(machine, "ready", true)
    {machine, :processed} = HSM.dispatch(machine, "go")
    assert HSM.state(machine) == "/Guarded/done"
  end

  test "choice pseudostate evaluates guard order and fallback" do
    model =
      HSM.define("ChoiceModel", [
        HSM.attribute("route", "b"),
        HSM.initial(HSM.target("start")),
        HSM.state("start", [
          HSM.transition([HSM.on("go"), HSM.target("pick")])
        ]),
        HSM.choice("pick", [
          HSM.transition([
            HSM.guard(fn inst, _ -> elem(HSM.get(inst, "route"), 0) == "a" end),
            HSM.target("a")
          ]),
          HSM.transition([HSM.target("b")])
        ]),
        HSM.state("a"),
        HSM.state("b")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "go")
    assert HSM.state(machine) == "/ChoiceModel/b"
  end

  test "snapshot exposes stable state and attributes" do
    model =
      HSM.define("Snap", [
        HSM.attribute("count", 1),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    snapshot = model |> HSM.new() |> HSM.start() |> HSM.take_snapshot()

    assert Map.fetch!(snapshot, :State) == "/Snap/idle"
    assert Map.fetch!(snapshot, :Attributes) == %{"/Snap/count" => 1}
    assert Map.fetch!(snapshot, :QueueLen) == 0
  end

  test "source-qualified parent transition routes from an active child" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("ParentSource", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("./a")),
          HSM.transition([
            HSM.source("parent/a"),
            HSM.on("go"),
            HSM.target("parent/b"),
            HSM.effect(fn -> push.("effect") end)
          ]),
          HSM.state("a", [HSM.entry(fn -> push.("a") end)]),
          HSM.state("b", [HSM.entry(fn -> push.("b") end)])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/ParentSource/parent/b"
    assert Agent.get(log, & &1) == ["a", "effect", "b"]
  end

  test "deferred events replay after exiting the deferring state" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("DeferReplay", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([
            HSM.on("work"),
            HSM.target("done"),
            HSM.effect(fn -> push.("work") end)
          ])
        ]),
        HSM.state("done", [HSM.entry(fn -> push.("done") end)])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :deferred} = HSM.dispatch(machine, "work")
    {machine, :processed} = HSM.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferReplay/done"
    assert Agent.get(log, & &1) == ["work", "done"]
  end

  test "history default transition effects and entry target are honored" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("HistoryDefault", [
        HSM.initial(HSM.target("outside")),
        HSM.state("outside", [
          HSM.transition([HSM.on("enter"), HSM.target("comp/h")])
        ]),
        HSM.state("comp", [
          HSM.state("a", [HSM.entry(fn -> push.("a") end)]),
          HSM.shallow_history("h", [
            HSM.transition([HSM.target("a"), HSM.effect(fn -> push.("default") end)])
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "enter")

    assert HSM.state(machine) == "/HistoryDefault/comp/a"
    assert Agent.get(log, & &1) == ["default", "a"]
  end

  test "root completion transition runs when a final root child is reached" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("FinalCompletion", [
        HSM.initial(HSM.target("work")),
        HSM.state("work", [
          HSM.transition([HSM.on("finish"), HSM.target("done")])
        ]),
        HSM.final("done"),
        HSM.state("complete", [HSM.entry(fn -> push.("complete") end)]),
        HSM.transition([
          HSM.on("FinalEvent"),
          HSM.target("complete"),
          HSM.effect(fn -> push.("completion") end)
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "finish")

    assert HSM.state(machine) == "/FinalCompletion/complete"
    assert Agent.get(log, & &1) == ["completion", "complete"]
  end

  test "on_call transition is processed before operation body" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("OnCallCase", [
        HSM.operation("approve", fn -> push.("operation") end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on_call("approve"),
            HSM.target("approved"),
            HSM.effect(fn -> push.("effect") end)
          ])
        ]),
        HSM.state("approved", [HSM.entry(fn -> push.("entry") end)])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, _result} = HSM.call(machine, "approve")

    assert HSM.state(machine) == "/OnCallCase/approved"
    assert Agent.get(log, & &1) == ["effect", "entry", "operation"]
  end

  test "after timer fires on logical tick and transitions once" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("TimerAfter", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.after_ms(10),
            HSM.target("fired"),
            HSM.effect(fn -> push.("timer") end)
          ])
        ]),
        HSM.state("fired", [HSM.entry(fn -> push.("fired") end)])
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.tick(machine, 9)
    assert HSM.state(machine) == "/TimerAfter/waiting"

    machine = HSM.tick(machine, 1)
    assert HSM.state(machine) == "/TimerAfter/fired"
    assert Agent.get(log, & &1) == ["timer", "fired"]

    machine = HSM.tick(machine, 100)
    assert HSM.state(machine) == "/TimerAfter/fired"
    assert Agent.get(log, & &1) == ["timer", "fired"]
  end

  test "timer is cancelled when source state exits before it fires" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("TimerCancel", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.after_ms(10),
            HSM.target("timeout"),
            HSM.effect(fn -> push.("timeout") end)
          ]),
          HSM.transition([HSM.on("leave"), HSM.target("done")])
        ]),
        HSM.state("timeout"),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "leave")
    machine = HSM.tick(machine, 20)

    assert HSM.state(machine) == "/TimerCancel/done"
    assert Agent.get(log, & &1) == []
  end

  test "activity callbacks run when a state is entered" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("Activity", [
        HSM.initial(HSM.target("active")),
        HSM.state("active", [
          HSM.activity(fn -> push.("activity") end),
          HSM.transition([HSM.on("stop"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert HSM.state(machine) == "/Activity/active"
    assert Agent.get(log, & &1) == ["activity"]
  end

  test "activity handles are cancelled when their state exits" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("ActivityCancel", [
        HSM.initial(HSM.target("active")),
        HSM.state("active", [
          HSM.activity(fn ->
            push.("activity:start")
            {:hsm_activity, fn -> push.("activity:cancel") end}
          end),
          HSM.exit(fn -> push.("exit:active") end),
          HSM.transition([HSM.on("stop"), HSM.target("done")])
        ]),
        HSM.state("done", [HSM.entry(fn -> push.("enter:done") end)])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "stop")

    assert HSM.state(machine) == "/ActivityCancel/done"

    assert Agent.get(log, & &1) == [
             "activity:start",
             "activity:cancel",
             "exit:active",
             "enter:done"
           ]
  end

  test "stop exits the active state and restart re-enters the initial state" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("Lifecycle", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry(fn -> push.("enter:idle") end),
          HSM.exit(fn -> push.("exit:idle") end),
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done", [HSM.entry(fn -> push.("enter:done") end)])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.dispatch(machine, "go")
    assert HSM.state(machine) == "/Lifecycle/done"

    machine = HSM.restart(machine)
    assert HSM.state(machine) == "/Lifecycle/idle"

    machine = HSM.stop(machine)
    assert HSM.state(machine) == ""

    machine = HSM.start(machine)
    assert HSM.state(machine) == "/Lifecycle/idle"

    assert Agent.get(log, & &1) == [
             "enter:idle",
             "exit:idle",
             "enter:done",
             "enter:idle",
             "exit:idle",
             "enter:idle"
           ]
  end

  test "context dispatch_all returns updated immutable machines" do
    model =
      HSM.define("Broadcast", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    one = HSM.start(HSM.new(model, HSM.Config.new(id: "one")))
    two = HSM.start(HSM.new(model, HSM.Config.new(id: "two")))

    ctx =
      %HSM.Context{}
      |> HSM.Context.register(one)
      |> HSM.Context.register(two)
      |> HSM.dispatch_all("go")

    assert HSM.state(ctx.machines["one"]) == "/Broadcast/done"
    assert HSM.state(ctx.machines["two"]) == "/Broadcast/done"
  end

  test "dispatch clones event metadata so caller-owned event is unchanged" do
    model =
      HSM.define("Ownership", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("mutate"),
            HSM.target("done"),
            HSM.effect(fn event ->
              %{event | schema: Map.put(event.schema, "owner", "changed")}
            end)
          ])
        ]),
        HSM.state("done")
      ])

    event = %HSM.Event{name: "mutate", schema: %{"owner" => "caller"}}
    machine = HSM.start(HSM.new(model))
    {machine, :processed} = HSM.dispatch(machine, event)

    assert HSM.state(machine) == "/Ownership/done"
    assert event.schema == %{"owner" => "caller"}
  end

  test "invalid names and unresolved targets fail validation" do
    assert_raise HSM.ValidationError, ~r/cannot contain/, fn ->
      HSM.define("Bad/Name", [])
    end

    assert_raise HSM.ValidationError, ~r/not found/, fn ->
      HSM.define("BadTarget", [
        HSM.initial(HSM.target("missing")),
        HSM.state("idle")
      ])
    end
  end
end
