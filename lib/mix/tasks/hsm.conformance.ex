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
                        "when",
                        "final",
                        "completion",
                        "snapshot"
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
    model = build_model(case, trace)
    machine = HSM.new(model)

    machine =
      Enum.reduce(case["script"], machine, fn step, acc ->
        execute_step(acc, step, trace, case)
      end)

    append_trace(trace, %{"type" => "stable", "state" => HSM.state(machine)})
    assert_expect(case["expect"], machine, Agent.get(trace, & &1))
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

  defp execute_behavior_op(_case, instance, _event, %{"op" => "trace", "value" => value}, trace) do
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

  defp execute_step(machine, %{"op" => "start"}, _trace, _case), do: HSM.start(machine)

  defp execute_step(machine, %{"op" => "dispatch", "event" => event}, trace, _case) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name})
    HSM.dispatch(machine, event) |> elem(0)
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

  defp execute_step(machine, _step, _trace, _case), do: machine

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
end
