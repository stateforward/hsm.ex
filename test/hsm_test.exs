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
          HSM.transition([HSM.on("open"), HSM.target("open"), HSM.effect(fn -> push.("effect:open") end)])
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
          HSM.transition([HSM.on("go"), HSM.guard(fn inst, _event -> elem(HSM.get(inst, "ready"), 0) end), HSM.target("done")]),
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
          HSM.transition([HSM.guard(fn inst, _ -> elem(HSM.get(inst, "route"), 0) == "a" end), HSM.target("a")]),
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

    assert snapshot.State == "/Snap/idle"
    assert snapshot.Attributes == %{"/Snap/count" => 1}
    assert snapshot.QueueLen == 0
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
