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

    machine = HSM.new(model)
    assert HSM.state(machine) == ""

    machine = HSM.start(machine)
    {machine, :processed} = HSM.Instance.dispatch(machine, "open")

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
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")
    assert HSM.state(machine) == "/Guarded/idle"

    machine = HSM.set(machine, "ready", true)
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")
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
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")
    assert HSM.state(machine) == "/ChoiceModel/b"
  end

  test "pseudostates reject non-transition partials" do
    assert_raise HSM.ValidationError, ~r/unsupported choice partial/, fn ->
      HSM.define("BadChoiceChild", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("pick")])
        ]),
        HSM.choice("pick", [
          HSM.state("child"),
          HSM.transition([HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/unsupported deep_history partial/, fn ->
      HSM.define("BadHistoryInitial", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("h")),
          HSM.deep_history("h", [
            HSM.initial(HSM.target("leaf")),
            HSM.target("leaf")
          ]),
          HSM.state("leaf")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/pseudostate transition requires target/, fn ->
      HSM.define("BadChoiceEffectOnly", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("pick")])
        ]),
        HSM.choice("pick", [
          HSM.transition([HSM.effect(fn -> :ok end)])
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/pseudostate transition requires target/, fn ->
      HSM.define("BadHistoryEffectOnly", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("h")),
          HSM.shallow_history("h", [
            HSM.effect(fn -> :ok end)
          ]),
          HSM.state("leaf")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/pseudostate transition cannot have trigger/, fn ->
      HSM.define("BadChoiceTrigger", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("pick")])
        ]),
        HSM.choice("pick", [
          HSM.transition([HSM.on("never"), HSM.target("wrong")]),
          HSM.transition([HSM.target("done")])
        ]),
        HSM.state("wrong"),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/pseudostate transition cannot have trigger/, fn ->
      HSM.define("BadHistoryTrigger", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("h")),
          HSM.shallow_history("h", [
            HSM.transition([HSM.on("never"), HSM.target("leaf")])
          ]),
          HSM.state("leaf")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/guardless fallback must be last/, fn ->
      HSM.define("BadChoiceDefaultOrder", [
        HSM.initial(HSM.target("pick")),
        HSM.choice("pick", [
          HSM.transition([HSM.target("fallback")]),
          HSM.transition([HSM.guard(fn -> true end), HSM.target("done")]),
          HSM.transition([HSM.target("other")])
        ]),
        HSM.state("fallback"),
        HSM.state("done"),
        HSM.state("other")
      ])
    end

    assert_raise HSM.ValidationError, ~r/multiple fallback transitions/, fn ->
      HSM.define("BadHistoryMultipleTransitions", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("h")),
          HSM.shallow_history("h", [
            HSM.transition([HSM.target("a")]),
            HSM.transition([HSM.target("b")])
          ]),
          HSM.state("a"),
          HSM.state("b")
        ])
      ])
    end
  end

  test "snapshot exposes stable state and attributes" do
    model =
      HSM.define("Snap", [
        HSM.attribute("count", 1),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition("finish", [HSM.on("done"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    snapshot = model |> HSM.new() |> HSM.start() |> HSM.take_snapshot()

    assert Map.fetch!(snapshot, :State) == "/Snap/idle"
    assert Map.fetch!(snapshot, :Attributes) == %{"/Snap/count" => 1}
    assert Map.fetch!(snapshot, :QueueLen) == 0
    assert [%HSM.TransitionSnapshot{} = transition] = Map.fetch!(snapshot, :Transitions)
    assert Map.fetch!(transition, :Name) == "/Snap/idle/finish"
    assert Map.fetch!(transition, :Kind) == :external
    assert HSM.is_kind(Map.fetch!(transition, :Kind), HSM.transition_kind())
    assert Map.fetch!(transition, :Events) == ["done"]
  end

  test "snapshots expose queued event details with shared schema names" do
    model =
      HSM.define("SnapshotEvents", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.defer("pending")])
      ])

    event = HSM.event("pending", Target: "worker", Schema: %{payload: :string})

    machine = model |> HSM.new() |> HSM.start()
    {queue, nil} = HSM.Queue.push(machine.queue, event)
    machine = %{machine | queue: queue}

    assert [
             %{
               Event: "pending",
               Target: "worker",
               Guard: false,
               Schema: %{payload: :string}
             }
           ] = Map.fetch!(HSM.take_snapshot(machine), :Events)
  end

  test "typed attributes validate runtime writes" do
    model =
      HSM.define("TypedAttributes", [
        HSM.attribute("count", :integer, 1),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.set(machine, "count", 2)

    assert HSM.get(machine, "count") == {2, true}

    assert_raise HSM.ValidationError, ~r/expected :integer/, fn ->
      HSM.set(machine, "count", "two")
    end
  end

  test "generated events are cleared when a processing step raises" do
    model =
      HSM.define("GeneratedLeak", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("boom"),
            HSM.target("idle"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, "leak")
              raise "boom"
            end)
          ]),
          HSM.transition([HSM.on("next"), HSM.target("clean")])
        ]),
        HSM.state("clean", [
          HSM.transition([HSM.on("leak"), HSM.target("leaked")])
        ]),
        HSM.state("leaked")
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert_raise RuntimeError, ~r/boom/, fn ->
      HSM.Instance.dispatch(machine, "boom")
    end

    {machine, :processed} = HSM.Instance.dispatch(machine, "next")

    assert HSM.state(machine) == "/GeneratedLeak/clean"
  end

  test "hooked queues do not commit generated events when processing raises" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("HookedGeneratedLeak", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("boom"),
            HSM.target("idle"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, "leak")
              raise "boom"
            end)
          ]),
          HSM.transition([HSM.on("next"), HSM.target("clean")])
        ]),
        HSM.state("clean", [
          HSM.transition([HSM.on("leak"), HSM.target("leaked")])
        ]),
        HSM.state("leaked")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()

    assert_raise RuntimeError, ~r/boom/, fn ->
      HSM.Instance.dispatch(machine, "boom")
    end

    {machine, :processed} = HSM.Instance.dispatch(machine, "next")

    assert HSM.state(machine) == "/HookedGeneratedLeak/clean"
    refute Enum.any?(Agent.get(queue, & &1), &(&1.name == "leak"))
  end

  test "generated events are cleared when processing defers" do
    Process.delete(:hsm_runtime_generated_events)

    model =
      HSM.define("DeferredGuardLeak", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("go"),
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn instance, _event ->
              HSM.Instance.dispatch(instance, "leak")
              false
            end),
            HSM.target("done")
          ]),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("leak"), HSM.target("leaked")])
        ]),
        HSM.state("done"),
        HSM.state("leaked")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "go")

    assert Process.get(:hsm_runtime_generated_events, :missing) == :missing

    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferredGuardLeak/ready"
  end

  test "hooked queues do not commit generated events when processing defers" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("HookedDeferredGuardLeak", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("go"),
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn instance, _event ->
              HSM.Instance.dispatch(instance, "leak")
              false
            end),
            HSM.target("done")
          ]),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("leak"), HSM.target("leaked")])
        ]),
        HSM.state("done"),
        HSM.state("leaked")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "go")
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/HookedDeferredGuardLeak/ready"
    refute Enum.any?(Agent.get(queue, & &1), &(&1.name == "leak"))
  end

  test "generated priority events survive configured queue processing" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("GeneratedPriorityHookQueue", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, HSM.completion_event("complete"))
            end)
          ]),
          HSM.transition([HSM.on("complete"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, _status} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/GeneratedPriorityHookQueue/done"
  end

  test "generated priority survives a later generated regular event in configured queues" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("GeneratedPriorityBeforeRegular", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, HSM.completion_event("complete"))
              HSM.Instance.dispatch(instance, "audit")
            end)
          ]),
          HSM.transition([HSM.on("audit"), HSM.target("wrong")]),
          HSM.transition([HSM.on("complete"), HSM.target("complete")])
        ]),
        HSM.state("complete", [
          HSM.transition([HSM.on("audit"), HSM.target("audited")])
        ]),
        HSM.state("audited"),
        HSM.state("wrong")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/GeneratedPriorityBeforeRegular/audited"
  end

  test "generated priority events preserve FIFO order" do
    model =
      HSM.define("PriorityOrder", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, HSM.completion_event("first"))
              HSM.Instance.dispatch(instance, HSM.completion_event("second"))
            end)
          ]),
          HSM.transition([HSM.on("first"), HSM.target("first_seen")]),
          HSM.transition([HSM.on("second"), HSM.target("second_seen")])
        ]),
        HSM.state("first_seen", [
          HSM.transition([HSM.on("second"), HSM.target("both_seen")])
        ]),
        HSM.state("second_seen"),
        HSM.state("both_seen")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/PriorityOrder/both_seen"
  end

  test "generated priority events survive after an earlier deferred generated priority" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("DeferredGeneratedPriority", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("go"),
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn instance, _event ->
              HSM.Instance.dispatch(instance, HSM.completion_event("done"))
              false
            end),
            HSM.target("wrong")
          ]),
          HSM.transition([
            HSM.on("release"),
            HSM.target("ready"),
            HSM.effect(fn instance, _event ->
              HSM.Instance.dispatch(instance, HSM.completion_event("done"))
            end)
          ])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("done"), HSM.target("done")])
        ]),
        HSM.state("done"),
        HSM.state("wrong")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "go")
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferredGeneratedPriority/done"
  end

  test "nested dispatch to another instance is not captured by current processing" do
    other_model =
      HSM.define("OtherDispatchTarget", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.transition([HSM.on("audit"), HSM.target("done")])]),
        HSM.state("done")
      ])

    other = other_model |> HSM.new(HSM.Config.new(id: "other")) |> HSM.start()
    {:ok, other_ref} = Agent.start_link(fn -> other end)

    main_model =
      HSM.define("CrossInstanceDispatch", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(fn ->
              other = Agent.get(other_ref, & &1)
              {other, :processed} = HSM.Instance.dispatch(other, "audit")
              Agent.update(other_ref, fn _ -> other end)
            end)
          ]),
          HSM.transition([HSM.on("audit"), HSM.target("wrong")])
        ]),
        HSM.state("done"),
        HSM.state("wrong")
      ])

    machine = main_model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/CrossInstanceDispatch/done"
    assert HSM.state(Agent.get(other_ref, & &1)) == "/OtherDispatchTarget/done"
  end

  test "nested dispatch to another hooked queue does not replace the current queue" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    other_model =
      HSM.define("OtherHookedTarget", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.transition([HSM.on("audit"), HSM.target("done")])]),
        HSM.state("done")
      ])

    other =
      other_model
      |> HSM.new(HSM.Config.new(id: "other", queue: HSM.queue(hooks)))
      |> HSM.start()

    {:ok, other_ref} = Agent.start_link(fn -> other end)

    main_model =
      HSM.define("CrossHookedDispatch", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(fn ->
              other = Agent.get(other_ref, & &1)
              {other, :processed} = HSM.Instance.dispatch(other, "audit")
              Agent.update(other_ref, fn _ -> other end)
            end)
          ])
        ]),
        HSM.state("done")
      ])

    machine = main_model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert machine.queue.hooks == nil
    assert HSM.state(machine) == "/CrossHookedDispatch/done"
    assert HSM.state(Agent.get(other_ref, & &1)) == "/OtherHookedTarget/done"
  end

  test "nested dispatch back to an in-flight instance remains generated work" do
    {:ok, a_ref} = Agent.start_link(fn -> nil end)
    {:ok, b_ref} = Agent.start_link(fn -> nil end)
    {:ok, nested_status} = Agent.start_link(fn -> nil end)

    a_model =
      HSM.define("ReentrantA", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.target("ready"),
            HSM.effect(fn ->
              b = Agent.get(b_ref, & &1)
              {b, :processed} = HSM.Instance.dispatch(b, "ping")
              Agent.update(b_ref, fn _ -> b end)
            end)
          ]),
          HSM.transition([HSM.on("back"), HSM.target("wrong")])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("back"), HSM.target("audited")])
        ]),
        HSM.state("audited"),
        HSM.state("wrong")
      ])

    b_model =
      HSM.define("ReentrantB", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("ping"),
            HSM.target("done"),
            HSM.effect(fn ->
              a = Agent.get(a_ref, & &1)
              {_a, status} = HSM.Instance.dispatch(a, "back")
              Agent.update(nested_status, fn _ -> status end)
            end)
          ])
        ]),
        HSM.state("done")
      ])

    a = a_model |> HSM.new(HSM.Config.new(id: "a")) |> HSM.start()
    b = b_model |> HSM.new(HSM.Config.new(id: "b")) |> HSM.start()
    Agent.update(a_ref, fn _ -> a end)
    Agent.update(b_ref, fn _ -> b end)

    {a, :processed} = HSM.Instance.dispatch(a, "go")

    assert Agent.get(nested_status, & &1) == :queued
    assert HSM.state(a) == "/ReentrantA/audited"
  end

  test "event constructors and runtime kind helpers match runtime atoms" do
    event = HSM.event("go", Data: %{ok: true}, Kind: HSM.event_kind(), ID: "evt-1")
    completion = HSM.completion_event()

    assert event.name == "go"
    assert event.data == %{ok: true}
    assert event.kind == :event
    assert event.id == "evt-1"
    assert completion.kind == :completion_event
    assert apply(HSM, :EventKind, []) == :event
    assert apply(HSM, :CompletionEventKind, []) == :completion_event
    assert apply(HSM, :ChangeEventKind, []) == :set_event
    assert apply(HSM, :StateKind, []) == :state
    assert apply(HSM, :FinalStateKind, []) == :final
    assert apply(HSM, :SubmachineStateKind, []) == :submachine
    assert apply(HSM, :ChoiceKind, []) == :choice
    assert apply(HSM, :EntryPointKind, []) == :entry_point
    assert apply(HSM, :ExitPointKind, []) == :exit_point
    assert apply(HSM, :AttributeKind, []) == :attribute
    assert HSM.any_event().kind == HSM.event_kind()
    assert HSM.is_kind(HSM.final_state_kind(), HSM.state_kind())
    assert HSM.is_kind(HSM.submachine_state_kind(), HSM.state_kind())
    assert HSM.is_kind(HSM.any_event().kind, HSM.event_kind())
    assert HSM.is_kind(HSM.error_event_kind(), HSM.completion_event_kind())
    assert HSM.is_kind(HSM.choice_kind(), HSM.pseudostate_kind())
    assert HSM.is_kind(HSM.entry_point_kind(), HSM.pseudostate_kind())
    assert HSM.is_kind(HSM.exit_point_kind(), HSM.pseudostate_kind())

    custom_event = HSM.make_kind(HSM.event_kind())
    custom_named = HSM.make_kind("Custom")

    assert is_integer(custom_event)
    assert HSM.is_kind(custom_event, HSM.event_kind())
    refute HSM.is_kind(custom_named, "Custom")
  end

  test "generated custom kind ids do not wrap into built-in kind inheritance" do
    bare_custom_id_past_8_bit_boundary = 260

    refute HSM.is_kind(bare_custom_id_past_8_bit_boundary, HSM.state_kind())
    refute HSM.is_kind(bare_custom_id_past_8_bit_boundary, HSM.event_kind())
  end

  test "exit point hidden completion state does not reserve sibling names" do
    child =
      HSM.define("ExitPointNamespaceChild", [
        HSM.exit_point("done"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("finish"), HSM.target("done")])
        ]),
        HSM.state("__hsm_exit_done")
      ])

    model =
      HSM.define("ExitPointNamespaceParent", [
        HSM.initial(HSM.target("drive")),
        HSM.submachine_state("drive", child, [
          HSM.transition([HSM.exit_point("done"), HSM.target("complete")])
        ]),
        HSM.state("complete")
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.dispatch("finish")

    assert HSM.state(machine) == "/ExitPointNamespaceParent/complete"
  end

  test "user state names containing old exit marker do not affect ancestry" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("ExitMarkerName", [
        HSM.initial(HSM.target("a#__hsm_exit__:b")),
        HSM.state("a", [
          HSM.exit(fn -> Agent.update(log, &(&1 ++ [:a_exit])) end)
        ]),
        HSM.state("a#__hsm_exit__:b", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert HSM.state(machine) == "/ExitMarkerName/done"
    assert Agent.get(log, & &1) == []
  end

  test "canonical New binds a model to an instance shape" do
    model =
      HSM.define("CanonicalNew", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    assert function_exported?(HSM, :New, 3)

    machine =
      apply(HSM, :New, [
        %HSM.Instance{},
        model,
        HSM.Config.new(ID: "canonical")
      ])

    assert %HSM.Instance{id: "canonical", model: ^model} = machine
    assert HSM.state(machine) == ""
  end

  test "canonical submachine and connection point constructors build native models" do
    child =
      apply(HSM, :Define, [
        "Child",
        [
          apply(HSM, :EntryPoint, ["fast", [HSM.target("running")]]),
          apply(HSM, :ExitPoint, ["done"]),
          HSM.initial(HSM.target("idle")),
          HSM.state("idle"),
          HSM.state("running", [
            HSM.transition([HSM.on("finish"), HSM.target("done")])
          ])
        ]
      ])

    model =
      apply(HSM, :Define, [
        "Parent",
        [
          HSM.initial(HSM.target("idle")),
          HSM.state("idle", [
            HSM.transition([HSM.on("start"), HSM.target("child"), HSM.entry_point("fast")])
          ]),
          apply(HSM, :SubmachineState, [
            "child",
            child,
            [
              HSM.transition([HSM.exit_point("done"), HSM.target("complete")])
            ]
          ]),
          HSM.state("complete")
        ]
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "start")

    assert HSM.state(machine) == "/Parent/child/running"

    {machine, :processed} = HSM.Instance.dispatch(machine, "finish")

    assert HSM.state(machine) == "/Parent/complete"

    model =
      HSM.redefine(model, "ParentAgain", [
        HSM.state("extra")
      ])

    assert model.root == "/ParentAgain"
    assert Map.has_key?(model.states, "/ParentAgain/extra")
  end

  test "redefine replays hooks and rebases generated transition ids" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    validator = fn model ->
      Agent.update(log, &(&1 ++ [{:validator, model.root}]))
      model
    end

    finalizer = fn model ->
      Agent.update(log, &(&1 ++ [{:finalizer, model.root}]))
      model
    end

    base =
      HSM.define("HookBase", [
        HSM.validator(validator),
        HSM.finalizer(finalizer),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    renamed = HSM.redefine(base, "HookRenamed", [])
    snapshot = renamed |> HSM.new() |> HSM.start() |> HSM.take_snapshot()

    assert Agent.get(log, & &1) == [
             {:validator, "/HookBase"},
             {:finalizer, "/HookBase"},
             {:validator, "/HookRenamed"},
             {:finalizer, "/HookRenamed"}
           ]

    transition_names = Enum.map(Map.fetch!(snapshot, :Transitions), &Map.fetch!(&1, :Name))
    assert renamed.initial.id == "/HookRenamed#initial"
    assert "/HookRenamed/idle#transition:0" in transition_names
    refute Enum.any?(transition_names, &String.starts_with?(&1, "/HookBase"))

    {:ok, collision_log} = Agent.start_link(fn -> [] end)

    validator_one = fn model ->
      Agent.update(collision_log, &(&1 ++ [:one]))
      model
    end

    validator_two = fn model ->
      Agent.update(collision_log, &(&1 ++ [:two]))
      model
    end

    parts = [
      HSM.initial(HSM.target("idle")),
      HSM.state("idle")
    ]

    same_one = HSM.define("SameHooks", [HSM.validator(validator_one) | parts])
    _same_two = HSM.define("SameHooks", [HSM.validator(validator_two) | parts])
    _same_one_again = HSM.redefine(same_one, [])

    assert Agent.get(collision_log, & &1) == [:one, :two, :one]
  end

  test "redefine replays inherited finalizer from source definitions" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    finalizer = fn model ->
      update_in(model.states[model.root <> "/idle"].entry, fn actions ->
        (actions || []) ++ [fn -> Agent.update(log, &(&1 ++ [:entry])) end]
      end)
    end

    base =
      HSM.define("FinalizerReplayBase", [
        HSM.finalizer(finalizer),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    derived = HSM.redefine(base, "FinalizerReplayDerived", [])

    base |> HSM.new() |> HSM.start()
    derived |> HSM.new() |> HSM.start()

    assert Agent.get(log, & &1) == [:entry, :entry]
  end

  test "native paths resolve bare child names from containing state" do
    model =
      HSM.define("RelativePath", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.initial(HSM.target("idle")),
          HSM.state("idle"),
          HSM.state("child"),
          HSM.transition([
            HSM.source("idle"),
            HSM.on("go"),
            HSM.target("child")
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/RelativePath/parent/child"
  end

  test "native submachine API rejects child declarations and internal parent targets" do
    child =
      HSM.define("EncapsulatedChild", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle"),
        HSM.state("running")
      ])

    assert_raise HSM.ValidationError, ~r/submachine state cannot contain state/, fn ->
      HSM.define("BadSubmachineParts", [
        HSM.initial(HSM.target("sub")),
        HSM.submachine_state("sub", child, [HSM.state("extra")])
      ])
    end

    assert_raise HSM.ValidationError,
                 ~r/parent transition cannot target submachine internal state/,
                 fn ->
                   HSM.define("BadSubmachineTarget", [
                     HSM.initial(HSM.target("sub/running")),
                     HSM.submachine_state("sub", child)
                   ])
                 end

    assert_raise HSM.ValidationError,
                 ~r/submachine transition target/,
                 fn ->
                   HSM.define("BadEntryPointSelector", [
                     HSM.initial(HSM.target("plain")),
                     HSM.state("plain", [
                       HSM.transition([
                         HSM.on("go"),
                         HSM.target("other"),
                         HSM.entry_point("resume")
                       ])
                     ]),
                     HSM.state("other", [
                       HSM.entry_point("resume", [HSM.target("leaf")]),
                       HSM.state("leaf")
                     ])
                   ])
                 end

    child_with_entry =
      HSM.define("ChildWithEntry", [
        HSM.entry_point("resume", [HSM.target("running")]),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle"),
        HSM.state("running")
      ])

    assert_raise HSM.ValidationError, ~r/entry point target cannot be internal/, fn ->
      HSM.define("BadInternalEntryPointTarget", [
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child_with_entry, [
          HSM.transition([
            HSM.source("idle"),
            HSM.on("resume"),
            HSM.target("resume")
          ])
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/unsupported entry point partial/, fn ->
      HSM.define("BadGuardedEntryPoint", [
        HSM.entry_point("resume", [
          HSM.target("running"),
          HSM.guard(fn _instance, _event -> false end)
        ]),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle"),
        HSM.state("running")
      ])
    end

    assert_raise HSM.ValidationError, ~r/unsupported exit point partial/, fn ->
      HSM.define("BadGuardedExitPoint", [
        HSM.exit_point("done", [
          HSM.guard(fn _instance, _event -> false end)
        ]),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])
    end

    source_child =
      HSM.define("SourceChild", [
        HSM.initial(HSM.target("inside")),
        HSM.state("inside")
      ])

    assert_raise HSM.ValidationError, ~r/submachine internal source/, fn ->
      HSM.define("BadInternalSource", [
        HSM.initial(HSM.target("drive")),
        HSM.submachine_state("drive", source_child),
        HSM.state("outside"),
        HSM.transition([
          HSM.source("drive/inside"),
          HSM.on("leave"),
          HSM.target("outside")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/submachine boundary target/, fn ->
      HSM.define("BadBoundaryOwnedInternalSource", [
        HSM.initial(HSM.target("drive")),
        HSM.submachine_state("drive", source_child, [
          HSM.transition([
            HSM.source("drive/inside"),
            HSM.on("leave"),
            HSM.target("outside")
          ])
        ]),
        HSM.state("outside")
      ])
    end

    child_with_boundary_entry =
      HSM.define("BoundaryEntryChild", [
        HSM.entry_point("resume", [HSM.target("running")]),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle"),
        HSM.state("running")
      ])

    assert_raise HSM.ValidationError,
                 ~r/parent transition cannot target submachine internal state/,
                 fn ->
                   HSM.define("BadBoundaryToInternal", [
                     HSM.initial(HSM.target("child")),
                     HSM.submachine_state("child", child_with_boundary_entry),
                     HSM.transition([
                       HSM.source("child"),
                       HSM.on("jump"),
                       HSM.target("child/running")
                     ])
                   ])
                 end

    HSM.define("BoundaryToEntryPoint", [
      HSM.initial(HSM.target("child")),
      HSM.submachine_state("child", child_with_boundary_entry),
      HSM.transition([
        HSM.source("child"),
        HSM.on("resume"),
        HSM.target("child/resume")
      ])
    ])

    assert_raise HSM.ValidationError, ~r/exit point handler requires a submachine owner/, fn ->
      HSM.define("BadExitPointHandler", [
        HSM.initial(HSM.target("plain")),
        HSM.state("plain", [
          HSM.transition([HSM.exit_point("done"), HSM.target("other")])
        ]),
        HSM.state("other")
      ])
    end

    child_without_exit =
      HSM.define("ChildWithoutExit", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    assert_raise HSM.ValidationError, ~r/missing exit point "missing"/, fn ->
      HSM.define("BadMissingExitPointHandler", [
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child_without_exit, [
          HSM.transition([HSM.exit_point("missing"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/cannot target exit point/, fn ->
      HSM.define("BadEntryPointTarget", [
        HSM.entry_point("bad", [HSM.target("done")]),
        HSM.exit_point("done"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])
    end
  end

  test "operations cannot be called before the instance is started" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("UnstartedCall", [
        HSM.operation("audit", fn -> Agent.update(log, &(&1 ++ [:called])) end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = HSM.new(model)

    assert_raise HSM.ValidationError, ~r/operation requires a started HSM/, fn ->
      HSM.call(machine, "audit")
    end

    assert Agent.get(log, & &1) == []
  end

  test "named behavior references require declared operations" do
    assert_raise HSM.ValidationError, ~r/entry references unknown operation "missing"/, fn ->
      HSM.define("MissingEntryOperation", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.entry("missing")])
      ])
    end

    assert_raise HSM.ValidationError, ~r/guard references unknown operation "missing"/, fn ->
      HSM.define("MissingGuardOperation", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.guard("missing"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end
  end

  test "trigger member names reject path separators" do
    assert_raise HSM.ValidationError, ~r/operation name cannot contain \//, fn ->
      HSM.define("InvalidOnCallName", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("bad/op"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute name cannot contain \//, fn ->
      HSM.define("InvalidOnSetName", [
        HSM.attribute("flag", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_set("bad/op"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute name cannot contain \//, fn ->
      HSM.define("InvalidWhenAttrName", [
        HSM.attribute("flag", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.when_attr("bad/op"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute name cannot contain \//, fn ->
      HSM.define("InvalidStringWhenName", [
        HSM.attribute("flag", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([{:trigger, {:when, "bad/op"}}, HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end
  end

  test "trigger member names reject non-string operands" do
    assert_raise HSM.ValidationError, ~r/operation name must be a string/, fn ->
      HSM.on_call(:audit)
    end

    assert_raise HSM.ValidationError, ~r/attribute name must be a string/, fn ->
      HSM.on_set(:flag)
    end

    assert_raise HSM.ValidationError, ~r/attribute name must be a string/, fn ->
      HSM.when_attr(:flag)
    end

    assert_raise HSM.ValidationError, ~r/operation name must be a string/, fn ->
      HSM.define("InvalidOnCallAtomName", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([{:trigger, {:on_call, :audit}}, HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute name must be a string/, fn ->
      HSM.define("InvalidOnSetAtomName", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([{:trigger, {:on_set, :flag}}, HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute name must be a string/, fn ->
      HSM.define("InvalidWhenAtomName", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([{:trigger, {:when, :flag}}, HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end
  end

  test "model members share a qualified namespace" do
    assert_raise HSM.ValidationError, ~r/attribute "idle" conflicts with state "idle"/, fn ->
      HSM.define("AttrStateConflict", [
        HSM.attribute("idle", :integer, 0),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])
    end

    assert_raise HSM.ValidationError, ~r/operation "idle" conflicts with state "idle"/, fn ->
      HSM.define("OpStateConflict", [
        HSM.operation("idle", fn -> :ok end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])
    end

    assert_raise HSM.ValidationError,
                 ~r/operation "audit" conflicts with attribute "audit"/,
                 fn ->
                   HSM.define("AttrOpConflict", [
                     HSM.attribute("audit", :integer, 0),
                     HSM.operation("audit", fn -> :ok end),
                     HSM.initial(HSM.target("idle")),
                     HSM.state("idle")
                   ])
                 end

    assert_raise HSM.ValidationError, ~r/operation "audit" conflicts with state "audit"/, fn ->
      HSM.define("ImplicitOpStateConflict", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("audit")])
        ]),
        HSM.state("audit")
      ])
    end

    assert_raise HSM.ValidationError, ~r/attribute "flag" conflicts with state "flag"/, fn ->
      HSM.define("ImplicitAttrStateConflict", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_set("flag"), HSM.target("flag")])
        ]),
        HSM.state("flag")
      ])
    end

    assert_raise HSM.ValidationError, ~r/operation "flag" conflicts with attribute "flag"/, fn ->
      HSM.define("ImplicitAttrOpConflict", [
        HSM.operation("flag", fn -> :ok end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_set("flag"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])
    end
  end

  test "runtime set fails before the instance is started" do
    model =
      HSM.define("UnstartedSet", [
        HSM.attribute("count", :integer, 0),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = HSM.new(model)

    assert HSM.get(machine, "count") == {nil, false}

    assert_raise HSM.ValidationError, ~r/set requires a started HSM/, fn ->
      HSM.set(machine, "count", 1)
    end
  end

  test "set behavior errors surface with committed attribute" do
    model =
      HSM.define("SetErrorSurface", [
        HSM.attribute("flag", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on_set("flag"),
            HSM.effect(fn -> throw({:behavior_error, "boom", "set boom"}) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert {:hsm_set_error, updated, "boom", "set boom"} =
             catch_throw(HSM.set(machine, "flag", true))

    assert HSM.get(updated, "flag") == {true, true}
    assert HSM.state(updated) == "/SetErrorSurface/idle"
  end

  test "snapshots fail before the instance is started" do
    model =
      HSM.define("UnstartedSnapshot", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = HSM.new(model)

    assert_raise HSM.ValidationError, ~r/take snapshot requires a started HSM/, fn ->
      HSM.take_snapshot(machine)
    end
  end

  test "canonical Dispatch returns updated instance without status payload" do
    model =
      HSM.define("CanonicalDispatch", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.transition([HSM.on("go"), HSM.target("done")])]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    updated = apply(HSM, :Dispatch, [machine, "go"])

    assert %HSM.Instance{} = updated
    assert HSM.state(updated) == "/CanonicalDispatch/done"

    machine = model |> HSM.new() |> HSM.start()
    updated = HSM.dispatch(machine, "go")

    assert %HSM.Instance{} = updated
    assert HSM.state(updated) == "/CanonicalDispatch/done"
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
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

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
    {machine, :deferred} = HSM.Instance.dispatch(machine, "work")
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferReplay/done"
    assert Agent.get(log, & &1) == ["work", "done"]
  end

  test "deferred requeue push errors dispatch hsm error" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, pushes} = Agent.start_link(fn -> %{} end)

    hooks = %{
      push: fn _instance, event ->
        count =
          Agent.get_and_update(pushes, fn counts ->
            count = Map.get(counts, event.name, 0) + 1
            {count, Map.put(counts, event.name, count)}
          end)

        if event.name == "work" and count == 2 do
          %HSM.ValidationError{message: "queue push error"}
        else
          Agent.update(queue, &(&1 ++ [event]))
        end
      end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("DeferredRequeueError", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")])
        ]),
        HSM.state("error")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "work")

    assert HSM.state(machine) == "/DeferredRequeueError/error"
  end

  test "deferred replay push errors dispatch hsm error" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, pushes} = Agent.start_link(fn -> %{} end)

    hooks = %{
      push: fn _instance, event ->
        count =
          Agent.get_and_update(pushes, fn counts ->
            count = Map.get(counts, event.name, 0) + 1
            {count, Map.put(counts, event.name, count)}
          end)

        if event.name == "work" and count == 3 do
          %HSM.ValidationError{message: "queue push error"}
        else
          Agent.update(queue, &(&1 ++ [event]))
        end
      end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("DeferredReplayError", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("work"), HSM.target("done")]),
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")])
        ]),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "work")
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferredReplayError/error"
  end

  test "configured queues requeue deferred events after ignored queued work" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, log} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("DeferredIgnoredQueueWork", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([
            HSM.on("work"),
            HSM.target("done"),
            HSM.effect(fn -> Agent.update(log, &(&1 ++ ["work"])) end)
          ])
        ]),
        HSM.state("done")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "work")
    {machine, _status} = HSM.Instance.dispatch(machine, "noop")

    assert Enum.map(Agent.get(queue, & &1), & &1.name) == ["work"]

    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferredIgnoredQueueWork/done"
    assert Agent.get(log, & &1) == ["work"]
  end

  test "nested configured queues keep popped deferred bookkeeping separate" do
    {:ok, a_queue} = Agent.start_link(fn -> [] end)
    {:ok, b_queue} = Agent.start_link(fn -> [] end)
    {:ok, b_ref} = Agent.start_link(fn -> nil end)

    hooks = fn queue ->
      %{
        push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
        pop: fn _instance ->
          Agent.get_and_update(queue, fn
            [event | rest] -> {event, rest}
            [] -> {nil, []}
          end)
        end,
        len: fn _instance -> Agent.get(queue, &length/1) end
      }
    end

    queue_names = fn queue ->
      queue
      |> Agent.get(& &1)
      |> Enum.map(& &1.name)
    end

    a_model =
      HSM.define("DeferredQueueA", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([
            HSM.on("side"),
            HSM.effect(fn ->
              b = Agent.get(b_ref, & &1)
              {b, :deferred} = HSM.Instance.dispatch(b, "work")
              Agent.update(b_ref, fn _ -> b end)
            end)
          ]),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([HSM.on("work"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    b_model =
      HSM.define("DeferredQueueB", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [HSM.defer("work")])
      ])

    a =
      a_model
      |> HSM.new(HSM.Config.new(id: "a", queue: HSM.queue(hooks.(a_queue))))
      |> HSM.start()

    b =
      b_model
      |> HSM.new(HSM.Config.new(id: "b", queue: HSM.queue(hooks.(b_queue))))
      |> HSM.start()

    Agent.update(b_ref, fn _ -> b end)

    {a, :deferred} = HSM.Instance.dispatch(a, "work")

    assert queue_names.(a_queue) == ["work"]

    {a, :processed} = HSM.Instance.dispatch(a, "side")

    assert queue_names.(a_queue) == ["work"]
    assert queue_names.(b_queue) == ["work"]

    {a, :processed} = HSM.Instance.dispatch(a, "release")

    assert HSM.state(a) == "/DeferredQueueA/done"
  end

  test "deferred events preserve distinct payloads" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("DeferPayloads", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([
            HSM.on("work"),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [event.data])) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, HSM.event("work", data: 1))
    {machine, :deferred} = HSM.Instance.dispatch(machine, HSM.event("work", data: 2))
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferPayloads/ready"
    assert Agent.get(log, & &1) == [1, 2]
  end

  test "deferred events preserve identical payload occurrences" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("DeferIdenticalPayloads", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer("work"),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready", [
          HSM.transition([
            HSM.on("work"),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [event.data])) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, HSM.event("work", data: 1))
    {machine, :deferred} = HSM.Instance.dispatch(machine, HSM.event("work", data: 1))
    {machine, :processed} = HSM.Instance.dispatch(machine, "release")

    assert HSM.state(machine) == "/DeferIdenticalPayloads/ready"
    assert Agent.get(log, & &1) == [1, 1]
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
          HSM.initial(HSM.target("a")),
          HSM.state("a", [HSM.entry(fn -> push.("a") end)]),
          HSM.shallow_history("h", [
            HSM.target("a"),
            HSM.effect(fn -> push.("default") end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "enter")

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
          HSM.on("hsm/final"),
          HSM.target("complete"),
          HSM.effect(fn -> push.("completion") end)
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "finish")

    assert HSM.state(machine) == "/FinalCompletion/complete"
    assert Agent.get(log, & &1) == ["completion", "complete"]
  end

  test "completion behavior errors surface with completed source state" do
    model =
      HSM.define("CompletionErrorSurface", [
        HSM.initial(HSM.target("work")),
        HSM.state("work", [
          HSM.transition([HSM.on("finish"), HSM.target("done")])
        ]),
        HSM.final("done"),
        HSM.state("complete"),
        HSM.transition([
          HSM.on("hsm/final"),
          HSM.target("complete"),
          HSM.effect(fn -> throw({:behavior_error, "boom", "completion boom"}) end)
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert {:hsm_completion_error, updated, "boom", "completion boom"} =
             catch_throw(HSM.Instance.dispatch(machine, "finish"))

    assert HSM.state(updated) == "/CompletionErrorSurface/done"
  end

  test "on_call transition is processed after operation body" do
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
    assert Agent.get(log, & &1) == ["operation", "effect", "entry"]
  end

  test "generated set and call events use canonical names and data" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("GeneratedEventShape", [
        HSM.attribute("flag", false),
        HSM.operation("approve", fn event ->
          Agent.update(log, &(&1 ++ [{event.name, event.data}]))
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on_set("flag"),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [{event.name, event.data}])) end)
          ]),
          HSM.transition([
            HSM.on_call("approve"),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [{event.name, event.data}])) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.set(machine, "flag", true)
    {machine, _result} = HSM.call(machine, "approve")

    assert HSM.state(machine) == "/GeneratedEventShape/idle"

    assert [
             {"/GeneratedEventShape/flag",
              %HSM.AttributeChange{Name: "/GeneratedEventShape/flag", Old: false, Value: true}},
             {"/GeneratedEventShape/approve",
              %HSM.CallData{Name: "/GeneratedEventShape/approve", Args: []}},
             {"/GeneratedEventShape/approve",
              %HSM.CallData{Name: "/GeneratedEventShape/approve", Args: []}}
           ] = Agent.get(log, & &1)
  end

  test "generated call events are cleared when a top-level operation raises" do
    model =
      HSM.define("CallLeak", [
        HSM.operation("inner", fn -> :ok end),
        HSM.operation("outer", fn instance, _event ->
          HSM.call(instance, "inner")
          raise "boom"
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("outer"), HSM.target("after_outer")]),
          HSM.transition([HSM.on("next"), HSM.target("clean")])
        ]),
        HSM.state("clean", [
          HSM.transition([HSM.on_call("inner"), HSM.target("leaked")])
        ]),
        HSM.state("after_outer"),
        HSM.state("leaked")
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert_raise RuntimeError, ~r/boom/, fn ->
      HSM.call(machine, "outer")
    end

    {machine, :processed} = HSM.Instance.dispatch(machine, "next")

    assert HSM.state(machine) == "/CallLeak/clean"
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

  test "timer events are matched by timer identity, not ordinary event name" do
    model =
      HSM.define("TimerKeyCollision", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.on("__timer_after__"), HSM.target("bad")]),
          HSM.transition([HSM.after_ms(1), HSM.target("good")])
        ]),
        HSM.state("bad"),
        HSM.state("good")
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.tick(1)

    assert HSM.state(machine) == "/TimerKeyCollision/good"
  end

  test "logical tick drains already delivered native timer messages" do
    model =
      HSM.define("TickNativeTimerDrain", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(1), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    [%{id: timer_id}] = machine.timers
    Process.sleep(20)

    machine = HSM.tick(machine, 1)

    assert HSM.state(machine) == "/TickNativeTimerDrain/done"
    refute_receive {:hsm_timer, ^timer_id}, 0
  end

  test "logical tick processes all due timers" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    hit = fn -> Agent.update(hits, &(&1 + 1)) end

    transitions =
      Enum.map(1..101//1, fn _ ->
        HSM.transition([HSM.after_ms(1), HSM.effect(hit)])
      end)

    model =
      HSM.define("ManyDueTimers", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", transitions)
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.tick(1)

    assert Agent.get(hits, & &1) == 101
    assert machine.timers == []
  end

  test "timer queue push errors dispatch hsm error" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event ->
        if event.kind == :timer_event do
          %HSM.ValidationError{message: "queue push error"}
        else
          Agent.update(queue, &(&1 ++ [event]))
        end
      end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("TimerQueuePushError", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(1), HSM.target("done")]),
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")])
        ]),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    machine = HSM.tick(machine, 1)

    assert HSM.state(machine) == "/TimerQueuePushError/error"
  end

  test "timers fire by due time before declaration order" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("TimerDueOrder", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.after_ms(10),
            HSM.target("waiting"),
            HSM.self_transition(),
            HSM.effect(fn -> push.("late") end)
          ]),
          HSM.transition([
            HSM.after_ms(5),
            HSM.effect(fn -> push.("early") end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.tick(10)

    assert HSM.state(machine) == "/TimerDueOrder/waiting"
    assert Agent.get(log, & &1) == ["early", "late"]
  end

  test "root timer transitions are armed" do
    model =
      HSM.define("RootTimer", [
        HSM.initial(HSM.target("idle")),
        HSM.transition([HSM.after_ms(1), HSM.target("done")]),
        HSM.state("idle"),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert length(machine.timers) == 1

    machine = HSM.tick(machine, 1)

    assert HSM.state(machine) == "/RootTimer/done"
  end

  test "root timer source errors dispatch hsm error after initial entry" do
    model =
      HSM.define("RootTimerSourceError", [
        HSM.initial(HSM.target("waiting")),
        HSM.transition([HSM.after_ms(fn -> "bad" end), HSM.target("done")]),
        HSM.transition([HSM.on("hsm/error"), HSM.target("error")]),
        HSM.state("waiting"),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/RootTimerSourceError/error"
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
    {machine, :processed} = HSM.Instance.dispatch(machine, "leave")
    machine = HSM.tick(machine, 20)

    assert HSM.state(machine) == "/TimerCancel/done"
    assert Agent.get(log, & &1) == []
  end

  test "state exit drains already delivered native timer messages" do
    model =
      HSM.define("ExitNativeTimerDrain", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(1), HSM.target("timeout")]),
          HSM.transition([HSM.on("leave"), HSM.target("done")])
        ]),
        HSM.state("timeout"),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    [%{id: timer_id}] = machine.timers
    Process.sleep(20)

    {machine, :processed} = HSM.Instance.dispatch(machine, "leave")

    assert HSM.state(machine) == "/ExitNativeTimerDrain/done"
    refute_receive {:hsm_timer, ^timer_id}, 0
  end

  test "logical tick does not deliver due after timers cancelled by reentry" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("DueAfterReentryCancel", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.after_ms(1),
            HSM.target("waiting"),
            HSM.self_transition(),
            HSM.effect(fn -> push.("first") end)
          ]),
          HSM.transition([
            HSM.after_ms(1),
            HSM.effect(fn -> push.("second") end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.tick(1)

    assert HSM.state(machine) == "/DueAfterReentryCancel/waiting"
    assert Agent.get(log, & &1) == ["first"]
  end

  test "every timer interval must be positive" do
    assert_raise HSM.ValidationError, ~r/every interval must be positive/, fn ->
      HSM.every_ms(0)
    end
  end

  test "timer source strings require declared attributes" do
    assert_raise HSM.ValidationError, ~r/timer source attribute "delay" not found/, fn ->
      HSM.define("MissingTimerAttribute", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.every_ms("delay"),
            HSM.target("idle")
          ])
        ])
      ])
    end
  end

  test "invalid timer source values dispatch hsm error" do
    model =
      HSM.define("InvalidTimerSourceError", [
        HSM.attribute("delay", "bad"),
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms("delay"), HSM.target("done")]),
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")])
        ]),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/InvalidTimerSourceError/error"
  end

  test "timer source exceptions dispatch hsm error" do
    model =
      HSM.define("TimerSourceRaiseError", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(fn -> raise "timer boom" end), HSM.target("done")]),
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")])
        ]),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/TimerSourceRaiseError/error"
  end

  test "duplicate timer transition ids fail validation" do
    assert_raise HSM.ValidationError, ~r/duplicate timer transition id/, fn ->
      HSM.define("DuplicateTimerIds", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition("same", [HSM.after_ms(1)]),
          HSM.transition("same", [HSM.after_ms(2)])
        ])
      ])
    end
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
    {machine, :processed} = HSM.Instance.dispatch(machine, "stop")

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
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")
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

  test "restart cleans up previous timers before resetting a started instance" do
    model =
      HSM.define("StartCleanup", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(40), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    [%{id: first_id}] = machine.timers

    machine = HSM.restart(machine)
    [%{id: second_id}] = machine.timers

    refute first_id == second_id
    refute_receive {:hsm_timer, ^first_id}, 80
    assert_receive {:hsm_timer, ^second_id}, 80
  end

  test "native lifecycle rejects double start and restart before start" do
    model =
      HSM.define("LifecycleErrors", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = HSM.new(model)

    assert_raise HSM.ValidationError, ~r/requires a started HSM/, fn ->
      HSM.restart(machine)
    end

    machine = HSM.start(machine)

    assert_raise HSM.ValidationError, ~r/already started HSM/, fn ->
      HSM.start(machine)
    end

    assert HSM.state(machine) == "/LifecycleErrors/idle"
  end

  test "native lifecycle returns failed dispatch status before start and after stop" do
    model =
      HSM.define("DispatchLifecycleErrors", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = HSM.new(model)

    assert {^machine, {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}}} =
             HSM.dispatch(machine, "go")

    assert {^machine, {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}}} =
             apply(HSM, :Dispatch, [machine, "go"])

    assert {^machine, {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}}} =
             HSM.Instance.dispatch(machine, "go")

    stopped = machine |> HSM.start() |> HSM.stop()

    assert {^stopped, {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}}} =
             HSM.dispatch(stopped, "go")

    assert {^stopped, {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}}} =
             HSM.Instance.dispatch(stopped, "go")

    assert {:error, %HSM.ValidationError{message: "dispatch requires a started HSM"}} =
             apply(HSM, :Dispatch, [HSM.make_context(), nil, "go"])
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

  test "context dispatch_to stamps empty event target per recipient" do
    model =
      HSM.define("TargetedContext", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn event -> event.target == "one" end),
            HSM.target("selected")
          ]),
          HSM.transition([HSM.on("go"), HSM.target("wrong")])
        ]),
        HSM.state("selected"),
        HSM.state("wrong")
      ])

    one = HSM.start(HSM.new(model, HSM.Config.new(id: "one")))
    two = HSM.start(HSM.new(model, HSM.Config.new(id: "two")))

    ctx =
      %HSM.Context{}
      |> HSM.Context.register(one)
      |> HSM.Context.register(two)
      |> HSM.dispatch_to("go", ["one"])

    assert HSM.state(ctx.machines["one"]) == "/TargetedContext/selected"
    assert HSM.state(ctx.machines["two"]) == "/TargetedContext/idle"
  end

  test "top-level group helpers flatten and fan out" do
    model =
      HSM.define("GroupedPublic", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [HSM.transition([HSM.on("go"), HSM.target("done")])]),
        HSM.state("done")
      ])

    one = HSM.start(HSM.new(model, HSM.Config.new(id: "one")))
    two = HSM.start(HSM.new(model, HSM.Config.new(id: "two")))

    group = HSM.make_group("both", [HSM.make_group("inner", [one]), two])

    assert HSM.id(group) == "both"
    assert HSM.name(group) == "both"
    assert HSM.qualified_name(group) == "both"
    assert HSM.state(group) == ["/GroupedPublic/idle", "/GroupedPublic/idle"]
    assert length(group.machines) == 2

    group = HSM.dispatch(group, "go")

    assert HSM.state(group) == ["/GroupedPublic/done", "/GroupedPublic/done"]

    assert Enum.map(HSM.take_snapshot(group), &Map.fetch!(&1, :State)) == [
             "/GroupedPublic/done",
             "/GroupedPublic/done"
           ]

    assert Enum.map(apply(HSM, :TakeSnapshot, [nil, group]), &Map.fetch!(&1, :QualifiedName)) == [
             "/GroupedPublic",
             "/GroupedPublic"
           ]

    updated = apply(HSM, :Dispatch, [HSM.make_group("both", [one, two]), "go"])
    assert %HSM.Group{} = updated

    group = HSM.restart(group)
    assert HSM.state(group) == ["/GroupedPublic/idle", "/GroupedPublic/idle"]

    group = HSM.stop(group)
    assert HSM.state(group) == ["", ""]

    assert apply(HSM, :MakeGroup, []) == %HSM.Group{id: "", machines: []}
  end

  test "groups used as behavior values receive the current event" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    member_model =
      HSM.define("GroupBehaviorMember", [
        HSM.initial(HSM.target("listening")),
        HSM.state("listening", [
          HSM.transition([
            HSM.on(["hsm/initial", "go"]),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [event.name])) end)
          ])
        ])
      ])

    group =
      HSM.make_group([
        member_model |> HSM.new(HSM.Config.new(id: "entry")) |> HSM.start(),
        member_model |> HSM.new(HSM.Config.new(id: "exit")) |> HSM.start()
      ])

    model =
      HSM.define("GroupBehaviorOwner", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry(group),
          HSM.activity(group),
          HSM.exit(group),
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(group)
          ])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert Agent.get(log, & &1) == [
             "hsm/initial",
             "hsm/initial",
             "hsm/initial",
             "hsm/initial",
             "go",
             "go",
             "go",
             "go"
           ]
  end

  test "custom queue hooks receive regular dispatch events" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, log} = Agent.start_link(fn -> [] end)
    {:ok, pushed} = Agent.start_link(fn -> [] end)

    hooks = %{
      Push: fn _context, event ->
        Agent.update(pushed, &(&1 ++ [event.name]))
        Agent.update(queue, &(&1 ++ [event]))
      end,
      Pop: fn _context ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      Len: fn _context -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("Queued", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done", [HSM.entry(fn -> Agent.update(log, &(&1 ++ ["done"])) end)])
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/Queued/done"
    assert Agent.get(pushed, & &1) == ["go"]
    assert Agent.get(log, & &1) == ["done"]
    assert Map.fetch!(HSM.take_snapshot(machine), :QueueLen) == 0
  end

  test "queue len hook errors from snapshot do not affect later dispatch" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, fail_len?} = Agent.start_link(fn -> false end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance ->
        if Agent.get_and_update(fail_len?, &{&1, false}) do
          %HSM.ValidationError{message: "queue len error"}
        else
          Agent.get(queue, &length/1)
        end
      end
    }

    model =
      HSM.define("LenSnapshotReadOnly", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("hsm/error"), HSM.target("failed")]),
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("failed"),
        HSM.state("done")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    Agent.update(fail_len?, fn _ -> true end)

    assert Map.fetch!(HSM.take_snapshot(machine), :QueueLen) == 0

    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/LenSnapshotReadOnly/done"
  end

  test "pending queue len errors are cleared by stop start" do
    {:ok, queue} = Agent.start_link(fn -> [] end)
    {:ok, fail_len?} = Agent.start_link(fn -> false end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance ->
        if Agent.get_and_update(fail_len?, &{&1, false}) do
          %HSM.ValidationError{message: "queue len error"}
        else
          Agent.get(queue, &length/1)
        end
      end
    }

    model =
      HSM.define("LenPoison", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("hsm/error"), HSM.target("error")]),
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done"),
        HSM.state("error")
      ])

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    Agent.update(fail_len?, fn _ -> true end)
    assert Map.fetch!(HSM.take_snapshot(machine), :QueueLen) == 0

    machine = machine |> HSM.stop() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert HSM.state(machine) == "/LenPoison/done"
  end

  test "queue keeps runtime priority events out of custom regular hooks" do
    {:ok, pushed} = Agent.start_link(fn -> [] end)

    queue =
      HSM.queue(%{
        push: fn event -> Agent.update(pushed, &(&1 ++ [event.name])) end,
        pop: fn -> nil end,
        len: fn -> 0 end
      })

    {queue, nil} = HSM.Queue.push(queue, %HSM.Event{name: "complete", kind: :completion_event})
    assert HSM.Queue.len(queue) == 1
    assert Agent.get(pushed, & &1) == []

    {queue, event} = HSM.Queue.pop(queue)
    assert event.name == "complete"
    assert HSM.Queue.len(queue) == 0
  end

  test "default queue preserves FIFO regular events" do
    queue = HSM.queue()
    {queue, nil} = HSM.Queue.push(queue, "one")
    {queue, nil} = HSM.Queue.push(queue, "two")

    assert HSM.Queue.len(queue) == 2

    {queue, first} = HSM.Queue.pop(queue)
    {queue, second} = HSM.Queue.pop(queue)

    assert first.name == "one"
    assert second.name == "two"
    assert HSM.Queue.len(queue) == 0
  end

  test "queue rejects async hook results" do
    queue =
      HSM.queue(%{
        push: fn _event -> Task.async(fn -> :ok end) end,
        pop: fn -> nil end,
        len: fn -> 0 end
      })

    {_queue, error} = HSM.Queue.push(queue, "go")

    assert %HSM.ValidationError{} = error
    assert error.message =~ "must be synchronous"
  end

  test "clock hooks are applied when timers are scheduled" do
    {:ok, sleeps} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("Clocked", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(25), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    clock = HSM.clock(sleep: fn duration -> Agent.update(sleeps, &(&1 ++ [duration])) end)
    machine = HSM.new(model, HSM.Config.new(clock: clock)) |> HSM.start()

    assert Agent.get(sleeps, & &1) == [25]

    machine = HSM.tick(machine, 25)
    assert HSM.state(machine) == "/Clocked/done"
  end

  test "default clock schedules cancellable host timer messages" do
    model =
      HSM.define("HostClock", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(5), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert HSM.state(machine) == "/HostClock/waiting"

    assert_receive {:hsm_timer, timer_id}, 50

    machine = HSM.handle_timer(machine, timer_id)
    assert HSM.state(machine) == "/HostClock/done"
  end

  test "default clock timer is cancelled when source state exits" do
    model =
      HSM.define("HostClockCancel", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.after_ms(40), HSM.target("timeout")]),
          HSM.transition([HSM.on("leave"), HSM.target("done")])
        ]),
        HSM.state("timeout"),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :processed} = HSM.Instance.dispatch(machine, "leave")

    assert HSM.state(machine) == "/HostClockCancel/done"
    refute_receive {:hsm_timer, _timer_id}, 80
  end

  test "default clock reschedules every timers after host messages" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    model =
      HSM.define("HostEvery", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.every_ms(5),
            HSM.effect(fn -> Agent.update(hits, &(&1 + 1)) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert_receive {:hsm_timer, first}, 50
    machine = HSM.handle_timer(machine, first)
    assert_receive {:hsm_timer, second}, 50
    machine = HSM.handle_timer(machine, second)

    assert HSM.state(machine) == "/HostEvery/waiting"
    assert Agent.get(hits, & &1) == 2
  end

  test "logical tick cancels consumed host timers and every timers get fresh ids" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    model =
      HSM.define("LogicalEveryHostCleanup", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.every_ms(40),
            HSM.effect(fn -> Agent.update(hits, &(&1 + 1)) end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    [%{id: first_id}] = machine.timers

    machine = HSM.tick(machine, 40)
    [%{id: second_id}] = machine.timers

    refute first_id == second_id
    assert Agent.get(hits, & &1) == 1

    machine = HSM.handle_timer(machine, first_id)

    assert Agent.get(hits, & &1) == 1
    assert HSM.state(machine) == "/LogicalEveryHostCleanup/waiting"
    refute_receive {:hsm_timer, ^first_id}, 80
  end

  test "zero wait clock every reschedule advances logical due time" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)

    model =
      HSM.define("ZeroWaitEvery", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.every_ms(1),
            HSM.effect(fn -> Agent.update(hits, &(&1 + 1)) end)
          ])
        ])
      ])

    clock =
      HSM.clock(sleep: fn _duration -> {:ok, 0} end)

    machine = HSM.new(model, HSM.Config.new(clock: clock)) |> HSM.start() |> HSM.tick(0)

    assert Agent.get(hits, & &1) == 1
    assert [%{due: 1, duration: 1, id: timer_id}] = machine.timers
    refute_receive {:hsm_timer, ^timer_id}, 0
  end

  test "logical tick does not deliver due every timers cancelled by reentry" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    push = fn value -> Agent.update(log, &(&1 ++ [value])) end

    model =
      HSM.define("DueEveryReentryCancel", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.every_ms(1),
            HSM.target("waiting"),
            HSM.self_transition(),
            HSM.effect(fn -> push.("first") end)
          ]),
          HSM.transition([
            HSM.every_ms(1),
            HSM.effect(fn -> push.("second") end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start() |> HSM.tick(1)

    assert HSM.state(machine) == "/DueEveryReentryCancel/waiting"
    assert Agent.get(log, & &1) == ["first"]
  end

  test "duplicate every transitions remain distinct after reschedule" do
    {:ok, hits} = Agent.start_link(fn -> 0 end)
    hit = fn -> Agent.update(hits, &(&1 + 1)) end

    model =
      HSM.define("DuplicateEvery", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.every_ms(1), HSM.effect(hit)]),
          HSM.transition([HSM.every_ms(1), HSM.effect(hit)])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert length(machine.timers) == 2

    machine = HSM.tick(machine, 1)
    assert length(machine.timers) == 2
    assert Agent.get(hits, & &1) == 2

    machine = HSM.tick(machine, 1)
    assert length(machine.timers) == 2
    assert Agent.get(hits, & &1) == 4
  end

  test "invalid timer source does not poison a later every timer" do
    invalid =
      HSM.define("InvalidTimerSource", [
        HSM.attribute("delay", "bad"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.every_ms("delay"),
            HSM.target("idle")
          ])
        ])
      ])

    HSM.start(HSM.new(invalid))

    valid =
      HSM.define("ValidEveryAfterInvalid", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.every_ms(1),
            HSM.target("waiting")
          ])
        ])
      ])

    machine = valid |> HSM.new() |> HSM.start()
    assert length(machine.timers) == 1

    machine = HSM.tick(machine, 1)

    assert HSM.state(machine) == "/ValidEveryAfterInvalid/waiting"
    assert length(machine.timers) == 1
  end

  test "popped deferred bookkeeping is cleared after hooked queue dispatch" do
    {:ok, queue} = Agent.start_link(fn -> [] end)

    hooks = %{
      push: fn _instance, event -> Agent.update(queue, &(&1 ++ [event])) end,
      pop: fn _instance ->
        Agent.get_and_update(queue, fn
          [event | rest] -> {event, rest}
          [] -> {nil, []}
        end)
      end,
      len: fn _instance -> Agent.get(queue, &length/1) end
    }

    model =
      HSM.define("DeferredProcessCleanup", [
        HSM.initial(HSM.target("blocked")),
        HSM.state("blocked", [
          HSM.defer(["low", "high"]),
          HSM.transition([HSM.on("release"), HSM.target("ready")])
        ]),
        HSM.state("ready")
      ])

    Process.delete(:hsm_runtime_popped_deferred)

    machine = HSM.new(model, HSM.Config.new(queue: HSM.queue(hooks))) |> HSM.start()
    {machine, :deferred} = HSM.Instance.dispatch(machine, "low")
    {_machine, :deferred} = HSM.Instance.dispatch(machine, "high")

    assert Process.get(:hsm_runtime_popped_deferred, :missing) == :missing
  end

  test "config id and name are observable through runtime helpers" do
    model =
      HSM.define("Named", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine =
      HSM.new(model, HSM.Config.new(ID: "alpha", Name: "/RuntimeName"))
      |> HSM.start()

    assert HSM.id(machine) == "alpha"
    assert HSM.name(machine) == "RuntimeName"
    assert HSM.qualified_name(machine) == "/RuntimeName"
    assert apply(HSM, :ID, [machine]) == "alpha"
    assert apply(HSM, :Name, [machine]) == "RuntimeName"
    assert apply(HSM, :QualifiedName, [machine]) == "/RuntimeName"
  end

  test "canonical context-first runtime helpers are exported" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    assert Code.ensure_loaded?(HSM)
    assert function_exported?(HSM, :Start, 3)
    assert function_exported?(HSM, :Started, 4)
    assert function_exported?(HSM, :Dispatch, 3)
    assert function_exported?(HSM, :Get, 3)
    assert function_exported?(HSM, :Set, 4)
    assert function_exported?(HSM, :Call, 4)

    model =
      HSM.define("ContextFirst", [
        HSM.attribute("count", :integer, 0),
        HSM.operation("bump", fn ctx, instance, _event ->
          {current, true} = HSM.from_context(ctx)
          {instances, true} = HSM.instances_from_context(ctx)
          owner = if ctx.owner, do: HSM.id(ctx.owner), else: nil

          Agent.update(
            log,
            &(&1 ++ [{:call, HSM.id(current), owner, Map.has_key?(instances, "ctx-one")}])
          )

          {count, true} = HSM.get(instance, "count")
          HSM.set(instance, "count", count + 1)
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry(fn ctx, _instance, _event ->
            {current, true} = HSM.from_context(ctx)
            {instances, true} = HSM.instances_from_context(ctx)
            owner = if ctx.owner, do: HSM.id(ctx.owner), else: nil

            Agent.update(
              log,
              &(&1 ++ [{:entry, HSM.id(current), owner, Map.has_key?(instances, "ctx-one")}])
            )
          end),
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(fn ctx, _instance, event ->
              {current, true} = HSM.from_context(ctx)
              owner = if ctx.owner, do: HSM.id(ctx.owner), else: nil

              Agent.update(
                log,
                &(&1 ++ [{:dispatch, HSM.id(current), owner, event.source, event.target}])
              )
            end)
          ])
        ]),
        HSM.state("done", [
          HSM.entry(fn ctx, instance, _event ->
            {current, true} = HSM.from_context(ctx)

            Agent.update(
              log,
              &(&1 ++ [{:done_entry, HSM.state(current), HSM.state(instance)}])
            )
          end)
        ])
      ])

    ctx = HSM.make_context()

    machine =
      apply(HSM, :Started, [ctx, nil, model, HSM.Config.new(ID: "ctx-one", Data: %{boot: true})])

    ctx = HSM.Context.register(ctx, machine)
    {machine, _result} = apply(HSM, :Call, [ctx, machine, "bump", []])
    assert apply(HSM, :Get, [ctx, machine, "count"]) == {1, true}

    machine = apply(HSM, :Set, [ctx, machine, "count", 2])
    assert apply(HSM, :Get, [ctx, machine, "count"]) == {2, true}

    machine = apply(HSM, :Dispatch, [ctx, machine, "go"])
    assert HSM.state(machine) == "/ContextFirst/done"

    assert Agent.get(log, & &1) == [
             {:entry, "ctx-one", nil, true},
             {:call, "ctx-one", nil, true},
             {:dispatch, "ctx-one", nil, "ctx-one", "ctx-one"},
             {:done_entry, "/ContextFirst/done", "/ContextFirst/done"}
           ]
  end

  test "context dispatch refreshes current machine" do
    model =
      HSM.define("CtxStale", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new(HSM.Config.new(ID: "one"))
      |> HSM.start()

    ctx =
      HSM.make_context()
      |> HSM.Context.register(machine)
      |> HSM.Context.dispatch_to("go", ["one"])

    {current, true} = HSM.from_context(ctx)
    {machines, true} = HSM.instances_from_context(ctx)

    assert HSM.state(Map.fetch!(machines, "one")) == "/CtxStale/done"
    assert HSM.state(current) == "/CtxStale/done"
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
    {machine, :processed} = HSM.Instance.dispatch(machine, event)

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

  test "nil attribute defaults infer any type" do
    model =
      HSM.define("NilAttribute", [
        HSM.attribute("maybe"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.set(machine, "maybe", "value")

    assert HSM.get(machine, "maybe") == {"value", true}
  end

  test "attribute triggers declare implicit any attributes" do
    model =
      HSM.define("ImplicitOnSetAttribute", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_set("flag"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    assert model.attributes["flag"] == nil
    assert model.attribute_types["flag"] == :any

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.set("flag", true)

    assert HSM.state(machine) == "/ImplicitOnSetAttribute/done"
    assert HSM.get(machine, "flag") == {true, true}

    model =
      HSM.define("ImplicitWhenAttribute", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([{:trigger, {:when, "ready"}}, HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.set("ready", "value")

    assert HSM.state(machine) == "/ImplicitWhenAttribute/done"
    assert HSM.get(machine, "ready") == {"value", true}
  end

  test "predicate when transitions without attributes match ordinary events" do
    model =
      HSM.define("PredicateWhenAnyEvent", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.when_expr(fn _instance, event -> event.name == "go" end),
            HSM.target("done")
          ])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "skip")

    assert HSM.state(machine) == "/PredicateWhenAnyEvent/idle"

    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/PredicateWhenAnyEvent/done"
  end

  test "predicate when wildcard does not run after a guarded specific event misses" do
    model =
      HSM.define("PredicateWhenGuardedSpecific", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn -> false end),
            HSM.target("specific")
          ]),
          HSM.transition([
            HSM.when_expr(fn _instance, _event -> true end),
            HSM.target("wildcard")
          ])
        ]),
        HSM.state("specific"),
        HSM.state("wildcard")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/PredicateWhenGuardedSpecific/idle"

    machine = HSM.dispatch(machine, "other")

    assert HSM.state(machine) == "/PredicateWhenGuardedSpecific/wildcard"
  end

  test "multi-key event candidates preserve transition order" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    record_false = fn name ->
      fn _ctx, _instance, _event ->
        Agent.update(log, &(&1 ++ [name]))
        false
      end
    end

    model =
      HSM.define("MultiKeyCandidateOrder", [
        HSM.attribute("flag", :boolean, false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on_set("flag"),
            HSM.guard(record_false.("on_set")),
            HSM.target("set_seen")
          ]),
          HSM.transition([
            HSM.on("/MultiKeyCandidateOrder/flag"),
            HSM.guard(record_false.("on")),
            HSM.target("on_seen")
          ])
        ]),
        HSM.state("set_seen"),
        HSM.state("on_seen")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.set("flag", true)

    assert HSM.state(machine) == "/MultiKeyCandidateOrder/idle"
    assert Agent.get(log, & &1) == ["on_set", "on"]
  end

  test "duplicate trigger keys consider one transition once" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("DuplicateListCandidate", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on(["go", "go"]),
            HSM.guard(fn _ctx, _instance, _event ->
              Agent.update(log, &(&1 ++ [:guard]))
              false
            end),
            HSM.target("done")
          ])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.dispatch("go")

    assert HSM.state(machine) == "/DuplicateListCandidate/idle"
    assert Agent.get(log, & &1) == [:guard]
  end

  test "finalizer updates rebuild dispatch indexes" do
    finalizer = fn model ->
      update_in(model.states["/FinalizerIndex/idle"].transitions, fn [transition] ->
        [%{transition | target: "/FinalizerIndex/done2"}]
      end)
    end

    model =
      HSM.define("FinalizerIndex", [
        HSM.finalizer(finalizer),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done1")])
        ]),
        HSM.state("done1"),
        HSM.state("done2")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.dispatch("go")

    assert HSM.state(machine) == "/FinalizerIndex/done2"
  end

  test "predicate when transitions with attributes wait for attribute events" do
    model =
      HSM.define("PredicateWhenAttributeEvents", [
        HSM.attribute("ready", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.when_expr(fn _instance, _event -> true end),
            HSM.target("done")
          ])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/PredicateWhenAttributeEvents/idle"

    machine = HSM.set(machine, "ready", true)

    assert HSM.state(machine) == "/PredicateWhenAttributeEvents/done"
  end

  test "predicate when sees earlier implicit on_set attributes" do
    model =
      HSM.define("PredicateWhenEarlierImplicitAttribute", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_set("flag"), HSM.target("seen")]),
          HSM.transition([
            HSM.when_expr(fn _instance, _event -> true end),
            HSM.target("wrong")
          ])
        ]),
        HSM.state("seen"),
        HSM.state("wrong")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/PredicateWhenEarlierImplicitAttribute/idle"

    machine = HSM.set(machine, "flag", true)

    assert HSM.state(machine) == "/PredicateWhenEarlierImplicitAttribute/seen"
  end

  test "predicate when defined before a child submachine keeps wildcard events" do
    child =
      HSM.define("PredicateWhenLaterChildAttributesChild", [
        HSM.attribute("flag", false),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    model =
      HSM.define("PredicateWhenLaterChildAttributes", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.when_expr(fn _instance, event -> event.name == "go" end),
            HSM.target("done")
          ])
        ]),
        HSM.state("done"),
        HSM.submachine_state("child", child)
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/PredicateWhenLaterChildAttributes/done"
  end

  test "nil schema events coerce without cloning" do
    event = HSM.event("go")

    assert HSM.Event.coerce(event) === event
  end

  test "runtime event constants and wildcard transitions use canonical names" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("CanonicalEvents", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry(fn event -> Agent.update(log, &(&1 ++ [event.name])) end),
          HSM.transition([HSM.on("*"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert Agent.get(log, & &1) == ["hsm/initial"]
    assert HSM.state(machine) == "/CanonicalEvents/done"
    assert apply(HSM, :InitialEvent, []).name == "hsm/initial"
    assert apply(HSM, :FinalEvent, []).name == "hsm/final"
    assert apply(HSM, :ErrorEvent, []).name == "hsm/error"
    assert apply(HSM, :AnyEvent, []).name == "*"
  end

  test "wildcard event lists match ordinary events" do
    model =
      HSM.define("WildcardListEvents", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on([HSM.any_event()]), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.dispatch(machine, "go")

    assert HSM.state(machine) == "/WildcardListEvents/done"
  end

  test "config data is delivered to the initial event" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("InitialData", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry(fn event -> Agent.update(log, &(&1 ++ [event.data])) end)
        ])
      ])

    model
    |> HSM.new(HSM.Config.new(Data: %{boot: true}))
    |> HSM.start()

    assert Agent.get(log, & &1) == [%{boot: true}]
  end

  test "operation contracts resolve callables from runtime data" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("OperationContract", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new(
        HSM.Config.new(
          Data: %{
            "audit" => fn ->
              Agent.update(log, &(&1 ++ [:audit]))
              :ok
            end
          }
        )
      )
      |> HSM.start()

    {machine, result} = HSM.call(machine, "audit")

    assert result == :ok
    assert Agent.get(log, & &1) == [:audit]
    assert HSM.state(machine) == "/OperationContract/done"
    assert apply(HSM, :Operation, ["audit"]) == HSM.operation("audit")
  end

  test "start data updates runtime data for operation contracts" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("StartDataOperationContract", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start(%{
        "audit" => fn ->
          Agent.update(log, &(&1 ++ [:audit]))
          :ok
        end
      })

    {machine, result} = HSM.call(machine, "audit")

    assert result == :ok
    assert Agent.get(log, & &1) == [:audit]
    assert HSM.state(machine) == "/StartDataOperationContract/done"
  end

  test "operation contracts resolve qualified runtime data keys" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("RuntimeQualifiedOps", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new(
        HSM.Config.new(
          Data: %{
            "audit" => fn ->
              Agent.update(log, &(&1 ++ [:bare]))
              :ok
            end,
            "/RuntimeQualifiedOps/audit" => fn ->
              Agent.update(log, &(&1 ++ [:qualified]))
              :ok
            end
          }
        )
      )
      |> HSM.start()

    {machine, result} = HSM.call(machine, "/RuntimeQualifiedOps/audit")

    assert result == :ok
    assert Agent.get(log, & &1) == [:qualified]
    assert HSM.state(machine) == "/RuntimeQualifiedOps/done"
  end

  test "operation contracts prefer nested qualified runtime data over top-level bare data" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("RuntimeNestedQualifiedOps", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new(
        HSM.Config.new(
          Data: %{
            "audit" => fn ->
              Agent.update(log, &(&1 ++ [:bare]))
              :ok
            end,
            "operations" => %{
              "/RuntimeNestedQualifiedOps/audit" => fn ->
                Agent.update(log, &(&1 ++ [:qualified]))
                :ok
              end
            }
          }
        )
      )
      |> HSM.start()

    {machine, result} = HSM.call(machine, "audit")

    assert result == :ok
    assert Agent.get(log, & &1) == [:qualified]
    assert HSM.state(machine) == "/RuntimeNestedQualifiedOps/done"
  end

  test "operation contracts resolve runtime data for named behaviors" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("OperationBehaviorContract", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry("audit")
        ])
      ])

    model
    |> HSM.new(
      HSM.Config.new(
        Data: %{
          "audit" => fn _ctx, _instance ->
            Agent.update(log, &(&1 ++ [:audit]))
          end
        }
      )
    )
    |> HSM.start()

    assert Agent.get(log, & &1) == [:audit]
  end

  test "submachine nil operation contracts shadow parent callbacks and use runtime data" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("OperationFallbackChild", [
        HSM.operation("audit"),
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.on_call("audit"),
            HSM.target("approved"),
            HSM.effect(fn -> Agent.update(log, &(&1 ++ [:child])) end)
          ])
        ]),
        HSM.state("approved")
      ])

    model =
      HSM.define("OperationFallbackParent", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [event.name]))
          :ok
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    {machine, result} =
      model
      |> HSM.new(
        HSM.Config.new(
          Data: %{
            "audit" => fn ->
              Agent.update(log, &(&1 ++ [:runtime]))
              :ok
            end
          }
        )
      )
      |> HSM.start()
      |> HSM.call("audit")

    assert result == :ok
    assert HSM.state(machine) == "/OperationFallbackParent/child/approved"
    assert Agent.get(log, & &1) == [:runtime, :child]
  end

  test "submachine implicit on_call contracts can be provided by the parent model" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("ImplicitCallContractChild", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([
            HSM.on_call("audit"),
            HSM.target("approved"),
            HSM.effect(fn -> Agent.update(log, &(&1 ++ [:child])) end)
          ])
        ]),
        HSM.state("approved")
      ])

    model =
      HSM.define("ImplicitCallContractParent", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:parent]))
          :ok
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    {machine, result} =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.call("audit")

    assert result == :ok
    assert HSM.state(machine) == "/ImplicitCallContractParent/child/approved"
    assert Agent.get(log, & &1) == [:parent, :child]
  end

  test "submachine on_call snapshots use resolved child operation events" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("SnapshotCallChild", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [event.name]))
          :ok
        end),
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.on_call("audit"), HSM.target("approved")])
        ]),
        HSM.state("approved")
      ])

    model =
      HSM.define("SnapshotCallParent", [
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert [%HSM.TransitionSnapshot{} = transition] =
             Map.fetch!(HSM.take_snapshot(machine), :Transitions)

    assert Map.fetch!(transition, :Events) == ["/SnapshotCallParent/audit"]

    {machine, :ok} = HSM.call(machine, "audit")

    assert HSM.state(machine) == "/SnapshotCallParent/child/approved"
    assert Agent.get(log, & &1) == ["/SnapshotCallParent/audit"]
  end

  test "submachine nil on_call snapshots use top-level operation events" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("SnapshotFallbackCallChild", [
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.on_call("audit"), HSM.target("approved")])
        ]),
        HSM.state("approved")
      ])

    model =
      HSM.define("SnapshotFallbackCallParent", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [event.name]))
          :ok
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()

    assert [%HSM.TransitionSnapshot{} = transition] =
             Map.fetch!(HSM.take_snapshot(machine), :Transitions)

    assert Map.fetch!(transition, :Events) == ["/SnapshotFallbackCallParent/audit"]

    {machine, :ok} = HSM.call(machine, "audit")

    assert HSM.state(machine) == "/SnapshotFallbackCallParent/child/approved"
    assert Agent.get(log, & &1) == ["/SnapshotFallbackCallParent/audit"]
  end

  test "submachine operations replace parent operations in the top-level namespace" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("AbsoluteParentCallChild", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:child, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.on_call("audit"), HSM.target("approved")])
        ]),
        HSM.state("approved")
      ])

    model =
      HSM.define("AbsoluteParentCallParent", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:parent, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert [%HSM.TransitionSnapshot{} = transition] =
             Map.fetch!(HSM.take_snapshot(machine), :Transitions)

    assert Map.fetch!(transition, :Events) == ["/AbsoluteParentCallParent/audit"]

    {machine, :ok} = HSM.call(machine, "/AbsoluteParentCallParent/audit")

    assert HSM.state(machine) == "/AbsoluteParentCallParent/child/approved"
    assert Agent.get(log, & &1) == [{:child, "/AbsoluteParentCallParent/audit"}]
  end

  test "top-level submachine operation calls trigger child on_call transitions" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("AbsoluteParentCallWildcardChild", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:child, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("waiting")),
        HSM.state("waiting", [
          HSM.transition([HSM.on_call("audit"), HSM.target("approved")]),
          HSM.transition([HSM.on(HSM.any_event()), HSM.target("wildcard")])
        ]),
        HSM.state("approved"),
        HSM.state("wildcard")
      ])

    model =
      HSM.define("AbsoluteParentCallWildcardParent", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:parent, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child)
      ])

    machine = model |> HSM.new() |> HSM.start()
    {machine, :ok} = HSM.call(machine, "/AbsoluteParentCallWildcardParent/audit")

    assert HSM.state(machine) == "/AbsoluteParentCallWildcardParent/child/approved"
    assert Agent.get(log, & &1) == [{:child, "/AbsoluteParentCallWildcardParent/audit"}]
  end

  test "operation calls from entry point effects use entry point scope" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("EntryPointCallScopeChild", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:operation, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("cold")),
        HSM.entry_point("warm", [
          HSM.target("running"),
          HSM.effect(fn instance, _event ->
            {instance, :ok} = HSM.call(instance, "audit")
            instance
          end)
        ]),
        HSM.state("cold"),
        HSM.state("running", [
          HSM.transition([HSM.on_call("audit"), HSM.target("handled")])
        ]),
        HSM.state("handled")
      ])

    model =
      HSM.define("EntryPointCallScopeParent", [
        HSM.operation("audit", fn event ->
          Agent.update(log, &(&1 ++ [{:parent, event.name}]))
          :ok
        end),
        HSM.initial(HSM.target("outside")),
        HSM.state("outside", [
          HSM.transition([HSM.on("go"), HSM.target("child"), HSM.entry_point("warm")])
        ]),
        HSM.submachine_state("child", child)
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.dispatch("go")

    assert HSM.state(machine) == "/EntryPointCallScopeParent/child/handled"
    assert Agent.get(log, & &1) == [{:operation, "/EntryPointCallScopeParent/audit"}]
  end

  test "parent owned behavior uses child operation that replaces earlier parent operation" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("ParentBehaviorShadowChild", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:child]))
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    model =
      HSM.define("ParentBehaviorShadowParent", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:parent]))
        end),
        HSM.initial([
          HSM.target("child"),
          HSM.effect("audit")
        ]),
        HSM.submachine_state("child", child)
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/ParentBehaviorShadowParent/child/idle"
    assert Agent.get(log, & &1) == [:child]
  end

  test "later parent operation replaces child operation" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("ParentAfterChildShadowChild", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:child]))
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    model =
      HSM.define("ParentAfterChildShadowParent", [
        HSM.initial([
          HSM.target("child"),
          HSM.effect("audit")
        ]),
        HSM.submachine_state("child", child),
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:parent]))
        end)
      ])

    machine = model |> HSM.new() |> HSM.start()

    assert HSM.state(machine) == "/ParentAfterChildShadowParent/child/idle"
    assert Agent.get(log, & &1) == [:parent]
  end

  test "parent owned source guards use child operation that replaces earlier parent operation" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("ParentGuardShadowChild", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:child]))
          true
        end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle")
      ])

    model =
      HSM.define("ParentGuardShadowParent", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:parent]))
          true
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child),
        HSM.transition([
          HSM.source("child"),
          HSM.on("go"),
          HSM.guard("audit"),
          HSM.target("done")
        ]),
        HSM.state("done")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.dispatch("go")

    assert HSM.state(machine) == "/ParentGuardShadowParent/done"
    assert Agent.get(log, & &1) == [:child]
  end

  test "parent exit point guards use child operation that replaces earlier parent operation" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    child =
      HSM.define("BoundaryGuardShadowChild", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:child]))
          true
        end),
        HSM.initial(HSM.target("active")),
        HSM.exit_point("done"),
        HSM.state("active", [
          HSM.transition([HSM.on("finish"), HSM.target("done")])
        ])
      ])

    model =
      HSM.define("BoundaryGuardShadowParent", [
        HSM.operation("audit", fn ->
          Agent.update(log, &(&1 ++ [:parent]))
          true
        end),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child, [
          HSM.transition([
            HSM.exit_point("done"),
            HSM.guard("audit"),
            HSM.effect("audit"),
            HSM.target("complete")
          ])
        ]),
        HSM.state("complete")
      ])

    machine =
      model
      |> HSM.new()
      |> HSM.start()
      |> HSM.dispatch("finish")

    assert HSM.state(machine) == "/BoundaryGuardShadowParent/complete"
    assert Agent.get(log, & &1) == [:child, :child]
  end

  test "operation contracts resolve runtime data for exit point guards" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    target = "/ExitGuardContract/allow"

    child =
      HSM.define("ExitGuardChild", [
        HSM.initial(HSM.target("active")),
        HSM.exit_point("done"),
        HSM.state("active", [
          HSM.transition([HSM.on("finish"), HSM.target("done")])
        ])
      ])

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [{:observe, event.source, Map.fetch!(event.data, :Occurrence)}]))
    end

    model =
      HSM.define("ExitGuardContract", [
        HSM.operation("allow"),
        HSM.observe(observer, target),
        HSM.initial(HSM.target("child")),
        HSM.submachine_state("child", child, [
          HSM.transition([
            HSM.exit_point("done"),
            HSM.guard("allow"),
            HSM.target("complete")
          ])
        ]),
        HSM.state("complete")
      ])

    machine =
      model
      |> HSM.new(
        HSM.Config.new(
          Data: %{
            "allow" => fn ->
              Agent.update(log, &(&1 ++ [:guard]))
              true
            end
          }
        )
      )
      |> HSM.start()
      |> HSM.dispatch("finish")

    assert HSM.state(machine) == "/ExitGuardContract/complete"
    assert Agent.get(log, & &1) == [{:observe, target, "behavior"}, :guard]
  end

  test "runtime get set and call accept absolute model member names" do
    model =
      HSM.define("AbsoluteMembers", [
        HSM.attribute("count", :integer, 0),
        HSM.operation("audit", fn -> :ok end),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on_call("audit"), HSM.target("called")]),
          HSM.transition([HSM.on_set("count"), HSM.target("set_seen")])
        ]),
        HSM.state("called"),
        HSM.state("set_seen")
      ])

    machine = model |> HSM.new() |> HSM.start()
    machine = HSM.set(machine, "/AbsoluteMembers/count", 1)

    assert HSM.get(machine, "/AbsoluteMembers/count") == {1, true}
    assert HSM.state(machine) == "/AbsoluteMembers/set_seen"

    machine = model |> HSM.new() |> HSM.start()
    {machine, _result} = HSM.call(machine, "/AbsoluteMembers/audit")

    assert HSM.get(machine, "/AbsoluteMembers/count") == {0, true}
    assert HSM.state(machine) == "/AbsoluteMembers/called"
  end

  test "observers receive observation events" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [event]))
    end

    model =
      HSM.define("Observed", [
        HSM.observe(observer),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(fn _event -> :ok end)
          ])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    observations = Agent.get(log, & &1)

    assert Enum.any?(observations, fn event ->
             match?(
               %HSM.Event{
                 name: "hsm/observation",
                 data: %HSM.Observation{Event: %HSM.Event{name: "go"}}
               },
               event
             )
           end)
  end

  test "observers match qualified transition member names" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    target = "/ObservedQualified/idle/transition_0"

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [event]))
    end

    model =
      HSM.define("ObservedQualified", [
        HSM.observe(observer, target),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition("transition_0", [HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert [
             %HSM.Event{
               name: "hsm/observation",
               source: ^target,
               data: %HSM.Observation{
                 Occurrence: "event",
                 Event: %HSM.Event{name: "go"}
               }
             }
           ] = Agent.get(log, & &1)
  end

  test "observers receive selected pseudostate transition observations" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [{event.source, Map.fetch!(event.data, :Occurrence)}]))
    end

    model =
      HSM.define("ObservedPseudostates", [
        HSM.observe(observer),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition("to_choice", [HSM.on("choose"), HSM.target("pick")]),
          HSM.transition("to_history", [HSM.on("history"), HSM.target("comp/h")])
        ]),
        HSM.choice("pick", [
          HSM.transition("selected", [HSM.guard(fn -> true end), HSM.target("done")]),
          HSM.transition("fallback", [HSM.target("idle")])
        ]),
        HSM.state("comp", [
          HSM.state("leaf"),
          HSM.shallow_history("h", [
            HSM.target("leaf")
          ])
        ]),
        HSM.state("done")
      ])

    HSM.new(model)
    |> HSM.start()
    |> HSM.dispatch("choose")

    HSM.new(model)
    |> HSM.start()
    |> HSM.dispatch("history")

    assert {"/ObservedPseudostates/pick/selected", "event"} in Agent.get(log, & &1)
    assert {"/ObservedPseudostates/comp/h#transition:0", "event"} in Agent.get(log, & &1)
  end

  test "observer transition targets require qualified member names" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [event]))
    end

    model =
      HSM.define("ObservedBareTransition", [
        HSM.observe(observer, "transition_0"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition("transition_0", [HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert Agent.get(log, & &1) == []
  end

  test "event-name observers do not match behavior observations" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [{event.source, Map.fetch!(event.data, :Occurrence)}]))
    end

    model =
      HSM.define("ObservedEventOnly", [
        HSM.observe(observer, "go"),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.exit(fn _event -> :ok end),
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect(fn _event -> :ok end)
          ])
        ]),
        HSM.state("done", [
          HSM.entry(fn _event -> :ok end)
        ])
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert Agent.get(log, & &1) == [{"/ObservedEventOnly/idle#transition:0", "event"}]
  end

  test "observers match named guard behavior" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    target = "/ObservedGuard/allow"

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [{event.source, Map.fetch!(event.data, :Occurrence)}]))
    end

    model =
      HSM.define("ObservedGuard", [
        HSM.operation("allow", fn -> true end),
        HSM.observe(observer, target),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.guard("allow"),
            HSM.target("done")
          ])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert Agent.get(log, & &1) == [{target, "behavior"}]
  end

  test "observers match named operation actions" do
    {:ok, log} = Agent.start_link(fn -> [] end)
    target = "/ObservedOperationActions/audit"

    observer = fn _ctx, _instance, event ->
      Agent.update(log, &(&1 ++ [{event.source, Map.fetch!(event.data, :Occurrence)}]))
    end

    audit = fn ->
      Agent.update(log, &(&1 ++ [:audit]))
      :ok
    end

    model =
      HSM.define("ObservedOperationActions", [
        HSM.operation("audit", audit),
        HSM.observe(observer, target),
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.entry("audit"),
          HSM.activity("audit"),
          HSM.exit("audit"),
          HSM.transition([
            HSM.on("go"),
            HSM.target("done"),
            HSM.effect("audit")
          ])
        ]),
        HSM.state("done")
      ])

    model |> HSM.new() |> HSM.start() |> HSM.dispatch("go")

    assert Agent.get(log, & &1) == [
             {target, "behavior"},
             :audit,
             {target, "behavior"},
             :audit,
             {target, "behavior"},
             :audit,
             {target, "behavior"},
             :audit
           ]
  end

  test "context helpers expose current machine and fill source and target" do
    {:ok, log} = Agent.start_link(fn -> [] end)

    model =
      HSM.define("ContextTarget", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("ping"),
            HSM.target("done"),
            HSM.effect(fn event -> Agent.update(log, &(&1 ++ [{event.source, event.target}])) end)
          ])
        ]),
        HSM.state("done")
      ])

    owner = HSM.start(HSM.new(model, HSM.Config.new(ID: "owner")))
    target = HSM.start(HSM.new(model, HSM.Config.new(ID: "target")))
    ctx = HSM.make_context() |> HSM.Context.register(owner) |> HSM.Context.register(target)
    {current, true} = HSM.from_context(ctx)
    {instances, true} = HSM.instances_from_context(ctx)

    assert HSM.id(current) == "target"
    assert Map.keys(instances) |> Enum.sort() == ["owner", "target"]

    ctx = HSM.dispatch_to(ctx, "ping", ["owner"])

    assert HSM.state(ctx.machines["owner"]) == "/ContextTarget/done"
    assert HSM.state(ctx.machines["target"]) == "/ContextTarget/idle"
    assert Agent.get(log, & &1) == [{"target", "owner"}]
    assert apply(HSM.Keys, :HSM, []) == :hsm
    assert apply(HSM.Keys, :Owner, []) == :owner
    assert apply(HSM.Keys, :Instances, []) == :instances
  end

  test "schema-bearing dispatch isolates caller metadata once" do
    event = HSM.event("go", schema: %{items: []})

    model =
      HSM.define("SchemaIsolation", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.effect(fn received ->
              received.schema.items ++ [:runtime]
            end)
          ])
        ])
      ])

    machine = model |> HSM.new() |> HSM.start()
    {_machine, :processed} = HSM.Instance.dispatch(machine, event)

    assert event.schema == %{items: []}
  end

  test "anonymous transition snapshots use their qualified id once" do
    model =
      HSM.define("AnonymousSnapshot", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    snapshot = model |> HSM.new() |> HSM.start() |> HSM.take_snapshot()

    assert [%HSM.TransitionSnapshot{} = transition] = Map.fetch!(snapshot, :Transitions)
    assert Map.fetch!(transition, :Name) == "/AnonymousSnapshot/idle#transition:0"
    refute String.contains?(Map.fetch!(transition, :Name), "/idle//")
  end

  test "native DSL rejects targetless initial and no-op transitions" do
    assert_raise HSM.ValidationError, ~r/model requires initial transition/, fn ->
      HSM.define("MissingModelInitial", [
        HSM.state("idle")
      ])
    end

    assert_raise HSM.ValidationError, ~r/composite state .* requires initial transition/, fn ->
      HSM.define("MissingCompositeInitial", [
        HSM.initial(HSM.target("parent")),
        HSM.state("parent", [
          HSM.state("a"),
          HSM.state("b")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/initial transition requires target/, fn ->
      HSM.define("MissingInitialTarget", [
        HSM.initial([])
      ])
    end

    assert_raise HSM.ValidationError, ~r/unsupported initial partial/, fn ->
      HSM.define("BadInitialGuard", [
        HSM.initial([
          HSM.on("go"),
          HSM.guard(fn -> false end),
          HSM.target("idle")
        ]),
        HSM.state("idle")
      ])
    end

    assert_raise HSM.ValidationError, ~r/transition requires target or effects/, fn ->
      HSM.define("NoopTransition", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([HSM.on("go"), HSM.guard(fn -> true end)])
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/defer requires at least one event/, fn ->
      HSM.define("BadEmptyDefer", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.defer([])
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/final state .* cannot have outgoing transitions/, fn ->
      HSM.define("BadFinalSourceTransition", [
        HSM.initial(HSM.target("done")),
        HSM.final("done"),
        HSM.state("other"),
        HSM.transition([
          HSM.source("done"),
          HSM.on("again"),
          HSM.target("other")
        ])
      ])
    end

    assert_raise HSM.ValidationError, ~r/sequential behavior must not return Task/, fn ->
      HSM.define("AsyncGuard", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.guard(fn -> Task.async(fn -> true end) end),
            HSM.target("done")
          ])
        ]),
        HSM.state("done")
      ])
      |> HSM.new()
      |> HSM.start()
      |> HSM.Instance.dispatch("go")
    end
  end

  test "activity tasks are remembered and cancelled on state exit" do
    parent = self()

    model =
      HSM.define("TaskActivity", [
        HSM.initial(HSM.target("active")),
        HSM.state("active", [
          HSM.activity(fn ->
            task = Task.async(fn -> Process.sleep(:infinity) end)
            send(parent, {:activity_task, task.pid})
            task
          end),
          HSM.transition([HSM.on("leave"), HSM.target("done")])
        ]),
        HSM.state("done")
      ])

    machine = model |> HSM.new() |> HSM.start()
    assert_receive {:activity_task, pid}, 500
    assert Process.alive?(pid)
    assert length(machine.active_activities) == 1

    {machine, :processed} = HSM.Instance.dispatch(machine, "leave")

    refute Process.alive?(pid)
    assert machine.active_activities == []
  end

  test "failed activity tasks dispatch hsm error when handled" do
    model =
      HSM.define("ActivityFailure", [
        HSM.initial(HSM.target("active")),
        HSM.state("active", [
          HSM.activity(fn ->
            Task.async(fn ->
              Process.sleep(10)
              raise "boom"
            end)
          end),
          HSM.transition([HSM.on("hsm/error"), HSM.target("errored")])
        ]),
        HSM.state("errored")
      ])

    ExUnit.CaptureLog.capture_log(fn ->
      machine = model |> HSM.new() |> HSM.start()
      assert [%HSM.ActivityHandle{metadata: %{ref: ref}}] = machine.active_activities
      assert_receive {:DOWN, ^ref, :process, _pid, _reason} = down, 500
      send(self(), {:machine_and_down, machine, down})
    end)

    {machine, down} =
      receive do
        {:machine_and_down, machine, down} -> {machine, down}
      end

    machine = HSM.handle_activity(machine, down)

    assert HSM.state(machine) == "/ActivityFailure/errored"
    assert machine.active_activities == []
    assert apply(HSM, :HandleActivity, [machine, :ignored]) == machine
  end

  test "successful dispatch clears runtime process keys" do
    keys = [
      :hsm_runtime_call_depth,
      :hsm_runtime_call_instance,
      :hsm_runtime_cancelled_hook_events,
      :hsm_runtime_generated_attributes,
      :hsm_runtime_generated_events,
      :hsm_runtime_generated_hook_events,
      :hsm_runtime_generated_queue,
      :hsm_runtime_popped_deferred,
      :hsm_runtime_popped_queued_deferred,
      :hsm_runtime_processing_instance,
      :hsm_runtime_processing_instances,
      :hsm_runtime_queue_len_errors,
      :hsm_runtime_processing
    ]

    Enum.each(keys, &Process.delete/1)

    model =
      HSM.define("ProcessCleanup", [
        HSM.initial(HSM.target("idle")),
        HSM.state("idle", [
          HSM.transition([
            HSM.on("go"),
            HSM.effect(fn instance, _event -> HSM.call(instance, "noop") end)
          ])
        ]),
        HSM.operation("noop", fn -> :ok end)
      ])

    machine = model |> HSM.new() |> HSM.start()
    {_machine, :processed} = HSM.Instance.dispatch(machine, "go")

    assert Enum.all?(keys, &(Process.get(&1, :missing) == :missing))
  end

  test "conformance runner rejects wrong validation expectations" do
    source = Path.expand("../../conformance/cases/invalid_top_level_history.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_wrong_validation_#{System.unique_integer([:positive])}.json"
      )

    source
    |> File.read!()
    |> String.replace("invalid_history_owner", "definitely_wrong_expected_code")
    |> then(&File.write!(tmp, &1))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "validation mismatch"
      assert output =~ "definitely_wrong_expected_code"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects missing validation expectations" do
    source = Path.expand("../../conformance/cases/invalid_top_level_history.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_missing_validation_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> Map.update!("expect", &Map.delete(&1, "validation"))

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "validation expectation missing"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects malformed validation expectations" do
    source = Path.expand("../../conformance/cases/invalid_top_level_history.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_malformed_validation_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> Map.update!("expect", &Map.put(&1, "validation", [123]))

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "validation expectation malformed"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects unexpected runtime errors" do
    source =
      Path.expand("../../conformance/cases/lifecycle_snapshot_before_start_error.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_unexpected_runtime_error_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> Map.update!("expect", &Map.take(&1, ["state"]))

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "unexpected error"
      assert output =~ "lifecycle_error"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner enforces script expect steps" do
    source = Path.expand("../../conformance/cases/script_expect_mid_run.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_script_expect_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> update_in(["script"], fn steps ->
        Enum.map(steps, fn
          %{"op" => "expect", "expect" => expect} = step ->
            put_in(step, ["expect", "state"], expect["state"] <> "/wrong")

          step ->
            step
        end)
      end)

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "state mismatch"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects unsupported script ops" do
    source = Path.expand("../../conformance/cases/script_expect_mid_run.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_unsupported_script_op_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> update_in(["script"], &(&1 ++ [%{"op" => "definitely_unknown"}]))

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "unsupported script op"
      assert output =~ "definitely_unknown"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects unsupported behavior ops" do
    source = Path.expand("../../conformance/cases/event_object_shorthand_on.json", __DIR__)

    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_unsupported_behavior_op_#{System.unique_integer([:positive])}.json"
      )

    case_data =
      source
      |> File.read!()
      |> :json.decode()
      |> update_in(["behaviors"], fn behaviors ->
        Map.update!(behaviors, "effect_accept", fn ops ->
          ops ++ [%{"op" => "definitely_unknown_behavior_op"}]
        end)
      end)

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "unsupported behavior op"
      assert output =~ "definitely_unknown_behavior_op"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects self redefine cycles" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_self_redefine_cycle_#{System.unique_integer([:positive])}.json"
      )

    case_data = %{
      "version" => "hsm-conformance-v1",
      "name" => "self_redefine_cycle",
      "mode" => "validation",
      "features" => ["redefine", "validation"],
      "model" => %{
        "name" => "SelfRedefine",
        "redefines" => "SelfRedefine",
        "initial" => "idle",
        "states" => [%{"name" => "idle"}]
      },
      "expect" => %{"validation" => [%{"code" => "submachine_model_cycle"}]}
    }

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 0
      assert output =~ "ok "
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects indirect redefine cycles" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_indirect_redefine_cycle_#{System.unique_integer([:positive])}.json"
      )

    case_data = %{
      "version" => "hsm-conformance-v1",
      "name" => "indirect_redefine_cycle",
      "mode" => "validation",
      "features" => ["redefine", "validation"],
      "model" => %{
        "name" => "A",
        "redefines" => "B",
        "initial" => "idle",
        "states" => [%{"name" => "idle"}]
      },
      "models" => [
        %{
          "name" => "B",
          "redefines" => "A",
          "initial" => "idle",
          "states" => [%{"name" => "idle"}]
        }
      ],
      "expect" => %{"validation" => [%{"code" => "submachine_model_cycle"}]}
    }

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 0
      assert output =~ "ok "
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects runtime self redefine cycles" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_runtime_self_redefine_cycle_#{System.unique_integer([:positive])}.json"
      )

    case_data = %{
      "version" => "hsm-conformance-v1",
      "name" => "runtime_self_redefine_cycle",
      "features" => ["redefine"],
      "model" => %{
        "name" => "SelfRedefine",
        "redefines" => "SelfRedefine",
        "initial" => "idle",
        "states" => [%{"name" => "idle"}]
      },
      "script" => [%{"op" => "start"}],
      "expect" => %{"state" => "/SelfRedefine/idle"}
    }

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "submachine_model_cycle"
    after
      File.rm(tmp)
    end
  end

  test "conformance runner rejects runtime indirect redefine cycles" do
    tmp =
      Path.join(
        System.tmp_dir!(),
        "hsm_runtime_indirect_redefine_cycle_#{System.unique_integer([:positive])}.json"
      )

    case_data = %{
      "version" => "hsm-conformance-v1",
      "name" => "runtime_indirect_redefine_cycle",
      "features" => ["redefine"],
      "model" => %{
        "name" => "A",
        "redefines" => "B",
        "initial" => "idle",
        "states" => [%{"name" => "idle"}]
      },
      "models" => [
        %{
          "name" => "B",
          "redefines" => "A",
          "initial" => "idle",
          "states" => [%{"name" => "idle"}]
        }
      ],
      "script" => [%{"op" => "start"}],
      "expect" => %{"state" => "/A/idle"}
    }

    File.write!(tmp, :json.encode(case_data))

    try do
      {output, status} =
        System.cmd("mix", ["hsm.conformance", tmp],
          cd: Path.expand("..", __DIR__),
          stderr_to_stdout: true
        )

      assert status == 1
      assert output =~ "submachine_model_cycle"
    after
      File.rm(tmp)
    end
  end
end
