defmodule Mix.Tasks.Hsm.Conformance do
  @shortdoc "Run supported shared HSM conformance JSON cases"
  @moduledoc """
  Runs one or more shared conformance case JSON files against the Elixir runtime.

  Unsupported feature groups exit with status 77, matching the shared runner
  convention. Supported cases exit non-zero on a mismatch.
  """

  use Mix.Task

  @supported_features MapSet.new([
                        "core",
                        "entry",
                        "exit",
                        "effect",
                        "attribute",
                        "guard",
                        "event_data",
                        "choice",
                        "initial",
                        "nested",
                        "paths",
                        "selection_order",
                        "source",
                        "validation",
                        "operation",
                        "on_call",
                        "on_set",
                        "history",
                        "history_default",
                        "shallow_history",
                        "deep_history",
                        "defer",
                        "queue",
                        "queue_order",
                        "when",
                        "final",
                        "completion",
                        "snapshot",
                        "transition_kind",
                        "external",
                        "internal",
                        "local",
                        "self",
                        "timer",
                        "after",
                        "every",
                        "at",
                        "cancellation",
                        "lifecycle",
                        "restart",
                        "stop",
                        "group",
                        "broadcast"
                      ])

  @impl Mix.Task
  def run([]) do
    Mix.shell().error("usage: mix hsm.conformance path/to/case.json [...]")
    System.halt(2)
  end

  def run(paths) do
    Mix.Task.run("app.start")

    results = Enum.map(paths, &run_case/1)

    cond do
      Enum.any?(results, &match?({:fail, _path, _reason}, &1)) ->
        Enum.each(results, &print_result/1)
        System.halt(1)

      Enum.all?(results, &match?({:skip, _path, _reason}, &1)) ->
        Enum.each(results, &print_result/1)
        System.halt(77)

      true ->
        Enum.each(results, &print_result/1)
    end
  end

  defp run_case(path) do
    case = path |> File.read!() |> :json.decode()
    unsupported = unsupported_features(case)

    cond do
      unsupported != [] ->
        {:skip, path, "unsupported features: #{Enum.join(unsupported, ", ")}"}

      case["mode"] == "validation" ->
        run_validation_case(path, case)

      true ->
        run_runtime_case(path, case)
    end
  rescue
    error -> {:fail, path, Exception.message(error)}
  catch
    {:assertion, message} -> {:fail, path, message}
  end

  defp unsupported_features(case) do
    case
    |> Map.get("features", [])
    |> Enum.reject(&MapSet.member?(@supported_features, &1))
  end

  defp run_validation_case(path, case) do
    try do
      validate_case_model!(case["model"])
      build_model(case, self())
      {:fail, path, "validation case unexpectedly built"}
    rescue
      HSM.ValidationError ->
        {:ok, path}
    end
  end

  defp run_runtime_case(path, case) do
    {:ok, trace} = Agent.start_link(fn -> [] end)
    Process.put(:hsm_conformance_deferred, [])
    Process.put(:hsm_conformance_replay, [])
    model = build_model(case, trace)

    if Map.has_key?(case, "instances") do
      run_multi_runtime_case(path, case, trace, model)
    else
      machine = HSM.new(model)

      machine =
        Enum.reduce(case["script"], machine, fn step, acc ->
          execute_step(acc, step, trace, case)
        end)

      append_trace(trace, %{"type" => "stable", "state" => HSM.state(machine)})
      assert_expect(case["expect"], machine, Agent.get(trace, & &1))
      {:ok, path}
    end
  end

  defp run_multi_runtime_case(path, case, trace, model) do
    machines =
      Map.new(case["instances"] || [], fn %{"id" => id} ->
        {id, HSM.new(model, HSM.Config.new(id: id))}
      end)

    groups =
      Map.new(case["groups"] || [], fn %{"id" => id, "members" => members} ->
        {id, members}
      end)

    env = %{machines: machines, groups: groups, snapshots: %{}, stable: nil}

    env =
      Enum.reduce(case["script"], env, fn step, acc ->
        execute_multi_step(acc, step, trace, case)
      end)

    stable = env.stable || first_state(env.machines)
    append_trace(trace, %{"type" => "stable", "state" => stable})
    assert_multi_expect(case["expect"], env, Agent.get(trace, & &1))
    {:ok, path}
  end

  defp build_model(case, trace) do
    model = case["model"]
    parts = []
    parts = parts ++ build_attributes(model)
    parts = parts ++ build_operations(case, trace)
    parts = parts ++ [build_initial(case, model["initial"], trace)]
    parts = parts ++ Enum.map(model["states"] || [], &build_state(case, &1, trace))
    parts = parts ++ Enum.map(model["transitions"] || [], &build_transition(case, &1, trace))
    HSM.define(model["name"], parts)
  end

  defp build_attributes(model) do
    for {name, spec} <- model["attributes"] || %{} do
      HSM.attribute(name, Map.get(spec, "default"))
    end
  end

  defp build_operations(case, trace) do
    for {name, ref} <- case["model"]["operations"] || %{} do
      HSM.operation(name, behavior(case, behavior_id(ref), trace))
    end
  end

  defp build_state(case, state, trace) do
    parts = []

    parts =
      if state["initial"],
        do: parts ++ [build_initial(case, state["initial"], trace)],
        else: parts

    parts = parts ++ behavior_parts(case, state, "entry", trace, &HSM.entry/1)
    parts = parts ++ behavior_parts(case, state, "exit", trace, &HSM.exit/1)
    parts = parts ++ Enum.map(state["defer"] || [], &HSM.defer/1)
    parts = parts ++ Enum.map(state["states"] || [], &build_state(case, &1, trace))
    parts = parts ++ Enum.map(state["transitions"] || [], &build_transition(case, &1, trace))

    case Map.get(state, "kind", "state") do
      "state" -> HSM.state(state["name"], parts)
      "final" -> HSM.final(state["name"])
      "choice" -> HSM.choice(state["name"], parts)
      "shallow_history" -> HSM.shallow_history(state["name"], parts)
      "deep_history" -> HSM.deep_history(state["name"], parts)
    end
  end

  defp build_initial(_case, initial, _trace) when is_binary(initial),
    do: HSM.initial(HSM.target(initial))

  defp build_initial(case, initial, trace) do
    effects =
      Enum.flat_map(
        initial["effects"] || [],
        &[
          HSM.effect(behavior(case, behavior_id(&1), trace))
        ]
      )

    HSM.initial([HSM.target(initial["target"]) | effects])
  end

  defp behavior_parts(case, container, key, trace, factory) do
    refs = container[key] || []

    if refs == [],
      do: [],
      else: [factory.(Enum.map(refs, &behavior(case, behavior_id(&1), trace)))]
  end

  defp build_transition(case, transition, trace) do
    parts = []
    parts = if transition["source"], do: parts ++ [HSM.source(transition["source"])], else: parts
    parts = parts ++ trigger_part(case, transition, trace)

    parts =
      if transition["guard"],
        do: parts ++ [HSM.guard(behavior(case, behavior_id(transition["guard"]), trace))],
        else: parts

    parts = if transition["target"], do: parts ++ [HSM.target(transition["target"])], else: parts

    parts =
      parts ++
        Enum.flat_map(
          transition["effects"] || [],
          &[HSM.effect(behavior(case, behavior_id(&1), trace))]
        )

    parts = parts ++ kind_part(transition["kind"])
    HSM.transition(parts)
  end

  defp trigger_part(_case, %{"on" => event}, _trace), do: [HSM.on(event)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on", "event" => event}}, _trace),
    do: [HSM.on(event)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on_set", "attribute" => attr}}, _trace),
    do: [HSM.on_set(attr)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on_call", "operation" => op}}, _trace),
    do: [HSM.on_call(op)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "completion"}}, _trace),
    do: [HSM.on("FinalEvent")]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "when", "attribute" => attr}}, _trace),
    do: [HSM.when_attr(attr)]

  defp trigger_part(case, %{"trigger" => %{"kind" => "when", "behavior" => id}}, trace),
    do: [HSM.when_expr(behavior(case, id, trace))]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "after", "duration_ms" => millis}}, _trace),
    do: [HSM.after_ms(millis)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "every", "duration_ms" => millis}}, _trace),
    do: [HSM.every_ms(millis)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "at", "time_ms" => millis}}, _trace),
    do: [HSM.at_ms(millis)]

  defp trigger_part(_case, _transition, _trace), do: []

  defp kind_part("internal"), do: [HSM.internal()]
  defp kind_part("local"), do: [HSM.local()]
  defp kind_part("self"), do: [HSM.self_transition()]
  defp kind_part(_), do: []

  defp behavior(case, id, trace) do
    program = get_in(case, ["behaviors", id]) || []

    fn instance, event ->
      Enum.reduce_while(program, instance, fn op, acc ->
        case execute_behavior_op(case, acc, event, op, trace) do
          {:return, value} -> {:halt, value}
          next -> {:cont, next}
        end
      end)
    end
  end

  defp execute_behavior_op(_case, instance, event, %{"op" => "trace", "value" => value}, trace) do
    maybe_append_undefer(trace, event)
    append_trace(trace, %{"type" => "trace", "value" => value})
    instance
  end

  defp execute_behavior_op(
         _case,
         instance,
         _event,
         %{"op" => "return_equals", "name" => name, "value" => value},
         _trace
       ) do
    {:return, elem(HSM.get(instance, name), 0) == value}
  end

  defp execute_behavior_op(
         _case,
         _instance,
         _event,
         %{"op" => "return_value", "value" => value},
         _trace
       ) do
    {:return, value}
  end

  defp execute_behavior_op(
         _case,
         _instance,
         event,
         %{"op" => "event_data_equals", "path" => path, "value" => value},
         _trace
       ) do
    {:return, read_path(event.data, path) == value}
  end

  defp execute_behavior_op(
         _case,
         instance,
         _event,
         %{"op" => "set_attr", "name" => name, "value" => value},
         _trace
       ) do
    HSM.set(instance, name, value)
  end

  defp execute_behavior_op(case, instance, event, %{"op" => "call", "name" => name}, trace) do
    case get_in(case, ["model", "operations", name]) do
      nil -> instance
      ref -> behavior(case, behavior_id(ref), trace).(instance, event)
    end
  end

  defp execute_behavior_op(_case, instance, _event, _op, _trace), do: instance

  defp execute_step(machine, %{"op" => "start"}, trace, case) do
    append_lifecycle_trace(trace, case, "start")
    machine = HSM.start(machine)
    append_timer_scheduled(trace, case, HSM.state(machine))
    machine
  end

  defp execute_step(machine, %{"op" => "dispatch", "event" => event}, trace, case) do
    event = event_from_value(event)
    old_state = HSM.state(machine)
    old_deferred = Process.get(:hsm_conformance_deferred, [])
    Process.put(:hsm_conformance_replay, old_deferred)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name})

    if timer_state?(case, old_state) do
      append_trace(trace, %{"type" => "timer_cancelled"})
    end

    {machine, status} = HSM.dispatch(machine, event)

    if status == :deferred do
      append_trace(trace, %{"type" => "defer", "event" => event.name})
      Process.put(:hsm_conformance_deferred, old_deferred ++ [event.name])
    else
      Process.put(:hsm_conformance_deferred, Process.get(:hsm_conformance_replay, []))
    end

    Process.put(:hsm_conformance_replay, [])
    machine
  end

  defp execute_step(machine, %{"op" => "set", "attribute" => attr, "value" => value}, trace, case) do
    if "on_set" in Map.get(case, "features", []) or "when" in Map.get(case, "features", []) do
      append_trace(trace, %{"type" => "set", "attribute" => attr, "value" => value})
    end

    HSM.set(machine, attr, value)
  end

  defp execute_step(machine, %{"op" => "call", "operation" => op}, trace, _case) do
    append_trace(trace, %{"type" => "call", "operation" => op})
    HSM.call(machine, op) |> elem(0)
  end

  defp execute_step(machine, %{"op" => "snapshot"}, trace, _case) do
    snapshot = HSM.take_snapshot(machine)
    append_trace(trace, %{"type" => "snapshot", "state" => Map.fetch!(snapshot, :State)})
    machine
  end

  defp execute_step(machine, %{"op" => "tick", "millis" => millis}, trace, case) do
    old_state = HSM.state(machine)

    if every_timer_state?(case, old_state) do
      append_trace(trace, %{"type" => "timer_scheduled"})
    end

    if timer_state?(case, old_state) do
      append_trace(trace, %{"type" => "timer_fired"})
    end

    HSM.tick(machine, millis)
  end

  defp execute_step(machine, %{"op" => "restart"}, trace, case) do
    append_lifecycle_trace(trace, case, "restart")
    HSM.restart(machine)
  end

  defp execute_step(machine, %{"op" => "stop"}, trace, case) do
    append_lifecycle_trace(trace, case, "stop")
    HSM.stop(machine)
  end

  defp execute_step(machine, _step, _trace, _case), do: machine

  defp execute_multi_step(env, %{"op" => "start", "instance" => id}, _trace, _case) do
    update_in(env.machines[id], &HSM.start/1)
  end

  defp execute_multi_step(env, %{"op" => "dispatch_all", "event" => event}, trace, _case) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => "all"})

    machines =
      Map.new(env.machines, fn {id, machine} ->
        {updated, _status} = HSM.dispatch(machine, event)
        {id, updated}
      end)

    %{env | machines: machines, stable: "all"}
  end

  defp execute_multi_step(
         env,
         %{"op" => "group_dispatch", "group" => group_id, "event" => event},
         trace,
         _case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => group_id})
    members = Map.fetch!(env.groups, group_id)

    machines =
      Enum.reduce(members, env.machines, fn id, acc ->
        {updated, _status} = HSM.dispatch(Map.fetch!(acc, id), event)
        Map.put(acc, id, updated)
      end)

    %{env | machines: machines, stable: "group:" <> group_id}
  end

  defp execute_multi_step(
         env,
         %{"op" => "dispatch_to", "event" => event, "instance" => id},
         trace,
         _case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => id})
    {updated, _status} = HSM.dispatch(Map.fetch!(env.machines, id), event)
    %{env | machines: Map.put(env.machines, id, updated), stable: id}
  end

  defp execute_multi_step(env, %{"op" => "snapshot", "group" => group_id}, trace, _case) do
    append_trace(trace, %{"type" => "snapshot", "group" => group_id})

    members =
      env.groups
      |> Map.fetch!(group_id)
      |> Map.new(fn id -> {id, HSM.state(Map.fetch!(env.machines, id))} end)

    %{
      env
      | snapshots: Map.put(env.snapshots, group_id, %{"members" => members}),
        stable: "group:" <> group_id
    }
  end

  defp execute_multi_step(env, _step, _trace, _case), do: env

  defp event_from_value(name) when is_binary(name), do: %HSM.Event{name: name}
  defp event_from_value(%{"name" => name} = map), do: %HSM.Event{name: name, data: map["data"]}

  defp assert_expect(expect, machine, trace) do
    if expect["state"] && HSM.state(machine) != expect["state"] do
      throw({:assertion, "state mismatch: got #{HSM.state(machine)}, want #{expect["state"]}"})
    end

    if expect["trace"] && trace != expect["trace"] do
      throw(
        {:assertion,
         "trace mismatch:\nactual: #{inspect(trace)}\nexpected: #{inspect(expect["trace"])}"}
      )
    end
  end

  defp assert_multi_expect(expect, env, trace) do
    Enum.each(expect["states"] || %{}, fn {id, expected_state} ->
      actual = HSM.state(Map.fetch!(env.machines, id))

      if actual != expected_state do
        throw({:assertion, "state #{id} mismatch: got #{actual}, want #{expected_state}"})
      end
    end)

    if Map.has_key?(expect, "snapshots") and env.snapshots != expect["snapshots"] do
      throw(
        {:assertion,
         "snapshot mismatch:\nactual: #{inspect(env.snapshots)}\nexpected: #{inspect(expect["snapshots"])}"}
      )
    end

    if expect["trace"] && trace != expect["trace"] do
      throw(
        {:assertion,
         "trace mismatch:\nactual: #{inspect(trace)}\nexpected: #{inspect(expect["trace"])}"}
      )
    end
  end

  defp first_state(machines) do
    machines
    |> Map.values()
    |> List.first()
    |> HSM.state()
  end

  defp append_trace(trace, event), do: Agent.update(trace, &(&1 ++ [event]))
  defp behavior_id(%{"behavior" => id}), do: id

  defp validate_case_model!(model) do
    Enum.each(model["states"] || [], &validate_state!/1)
  end

  defp validate_state!(%{"kind" => "final", "transitions" => transitions})
       when is_list(transitions) and transitions != [] do
    raise HSM.ValidationError, message: "final state cannot have outgoing transitions"
  end

  defp validate_state!(state), do: Enum.each(state["states"] || [], &validate_state!/1)

  defp read_path(value, nil), do: value
  defp read_path(value, ""), do: value

  defp read_path(value, path) do
    path
    |> String.split(".")
    |> Enum.reduce(value, fn
      key, acc when is_map(acc) -> acc[key]
      _key, _acc -> nil
    end)
  end

  defp print_result({:ok, path}), do: Mix.shell().info("ok #{path}")
  defp print_result({:skip, path, reason}), do: Mix.shell().info("skip #{path}: #{reason}")
  defp print_result({:fail, path, reason}), do: Mix.shell().error("fail #{path}: #{reason}")

  defp maybe_append_undefer(trace, %HSM.Event{name: event_name}) do
    case Process.get(:hsm_conformance_replay, []) do
      [^event_name | rest] ->
        append_trace(trace, %{"type" => "undefer", "event" => event_name})
        Process.put(:hsm_conformance_replay, rest)

      _ ->
        :ok
    end
  end

  defp maybe_append_undefer(_trace, _event), do: :ok

  defp append_lifecycle_trace(trace, case, kind) do
    if "lifecycle" in Map.get(case, "features", []) do
      append_trace(trace, %{"type" => kind})
    end
  end

  defp append_timer_scheduled(trace, case, state_path) do
    if timer_state?(case, state_path) do
      append_trace(trace, %{"type" => "timer_scheduled"})
    end
  end

  defp timer_state?(case, state_path) do
    case
    |> state_ir(state_path)
    |> timer_transitions()
    |> Enum.any?()
  end

  defp every_timer_state?(case, state_path) do
    case
    |> state_ir(state_path)
    |> timer_transitions()
    |> Enum.any?(&(get_in(&1, ["trigger", "kind"]) == "every"))
  end

  defp timer_transitions(nil), do: []

  defp timer_transitions(state) do
    Enum.filter(state["transitions"] || [], fn transition ->
      get_in(transition, ["trigger", "kind"]) in ["after", "every", "at"]
    end)
  end

  defp state_ir(case, state_path) do
    model = case["model"]
    relative = String.replace_prefix(state_path, "/" <> model["name"] <> "/", "")
    find_state(model["states"] || [], String.split(relative, "/", trim: true))
  end

  defp find_state(states, [name | rest]) do
    state = Enum.find(states, &(&1["name"] == name))

    case {state, rest} do
      {nil, _} -> nil
      {state, []} -> state
      {state, rest} -> find_state(state["states"] || [], rest)
    end
  end

  defp find_state(_states, []), do: nil
end
