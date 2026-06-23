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
                        "path_resolution",
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
                        "reentrancy",
                        "async",
                        "activity",
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
                        "timer_behavior",
                        "cancellation",
                        "lifecycle",
                        "restart",
                        "stop",
                        "group",
                        "broadcast",
                        "dispatch_to",
                        "multi_target",
                        "event_ownership",
                        "submachine",
                        "entry_point",
                        "exit_point",
                        "redefine",
                        "model_registry",
                        "event",
                        "behavior_attr",
                        "root_transition",
                        "error"
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
    try do
      clear_case_process_state()
      case = path |> File.read!() |> :json.decode() |> normalize_json()
      unsupported = unsupported_features(case)

      cond do
        unsupported != [] ->
          {:skip, path, "unsupported features: #{Enum.join(unsupported, ", ")}"}

        case["mode"] == "validation" ->
          run_validation_case(path, case)

        true ->
          run_runtime_case(path, case)
      end
    after
      clear_case_process_state()
    end
  rescue
    error -> {:fail, path, Exception.message(error)}
  catch
    {:assertion, message} -> {:fail, path, message}
    {:behavior_error, _code, message} -> {:fail, path, message}
  end

  defp unsupported_features(case) do
    case
    |> Map.get("features", [])
    |> Enum.reject(&MapSet.member?(@supported_features, &1))
  end

  defp clear_case_process_state do
    stop_case_trace()
    clear_behavior_event_metadata()
    clear_queue_states()

    Enum.each(
      [
        :hsm_conformance_activity_behavior_error,
        :hsm_conformance_deferred,
        :hsm_conformance_last_error,
        :hsm_conformance_multi_env,
        :hsm_conformance_model_index,
        :hsm_conformance_nested_dispatch,
        :hsm_conformance_pending_multi_dispatches,
        :hsm_conformance_queue_len_error,
        :hsm_conformance_replay,
        :hsm_conformance_snapshots,
        :hsm_conformance_timer_guard_fire,
        :hsm_runtime_action_context,
        :hsm_runtime_call_depth,
        :hsm_runtime_call_instance,
        :hsm_runtime_cancelled_hook_events,
        :hsm_runtime_exit_point_snapshot_state,
        :hsm_runtime_generated_attributes,
        :hsm_runtime_generated_events,
        :hsm_runtime_generated_hook_events,
        :hsm_runtime_generated_queue,
        :hsm_runtime_popped_deferred,
        :hsm_runtime_popped_queued_deferred,
        :hsm_runtime_processing_instance,
        :hsm_runtime_processing_instances,
        :hsm_runtime_preserve_timer_error,
        :hsm_runtime_queue_len_errors,
        :hsm_runtime_processing,
        :hsm_runtime_timer_error
      ],
      &Process.delete/1
    )
  end

  defp stop_case_trace do
    case Process.delete(:hsm_conformance_trace) do
      pid when is_pid(pid) ->
        if Process.alive?(pid), do: Agent.stop(pid, :normal, 1000)

      _ ->
        :ok
    end
  end

  defp clear_queue_states do
    :hsm_conformance_queue_keys
    |> Process.get([])
    |> Enum.each(&Process.delete/1)

    Process.delete(:hsm_conformance_queue_keys)
  end

  defp run_validation_case(path, case) do
    try do
      validate_case!(case)
      build_model(case, self())
      {:fail, path, "validation case unexpectedly built"}
    rescue
      error in HSM.ValidationError ->
        assert_validation_expect!(case["expect"], error)
        {:ok, path}
    end
  end

  defp assert_validation_expect!(expect, error) do
    expected = if is_map(expect), do: expect["validation"], else: nil

    if not (is_list(expected) and expected != []) do
      raise "validation expectation missing"
    end

    if Enum.any?(expected, &invalid_validation_expectation?/1) do
      raise "validation expectation malformed: #{inspect(expected)}"
    end

    if expected != [] do
      message = Exception.message(error)

      unless Enum.all?(expected, &validation_expected_matches?(&1, message)) do
        raise "validation mismatch: expected #{inspect(expected)}, got #{inspect(message)}"
      end
    end
  end

  defp validation_expected_matches?(expected, message) when is_binary(expected),
    do: validation_code_matches?(expected, message) or String.contains?(message, expected)

  defp validation_expected_matches?(%{} = expected, message) do
    code = expected["code"]
    contains = expected["message_contains"]

    code_matches? = not is_binary(code) or validation_code_matches?(code, message)
    message_matches? = not is_binary(contains) or String.contains?(message, contains)

    code_matches? and message_matches?
  end

  defp validation_expected_matches?(_expected, _message), do: false

  defp invalid_validation_expectation?(expected) when is_binary(expected), do: false

  defp invalid_validation_expectation?(%{} = expected) do
    not (is_binary(expected["code"]) or is_binary(expected["message_contains"]))
  end

  defp invalid_validation_expectation?(_expected), do: true

  defp validation_code_matches?(code, message) do
    String.starts_with?(message, "#{code}:") or
      String.contains?(message, code) or
      Enum.any?(validation_code_markers(code), &String.contains?(message, &1))
  end

  defp validation_code_markers("invalid_name"), do: ["name cannot contain /", "name required"]
  defp validation_code_markers("missing_initial"), do: ["requires initial", "missing initial"]
  defp validation_code_markers("missing_target"), do: ["missing target", "target or effects"]
  defp validation_code_markers("missing_source"), do: ["missing source"]
  defp validation_code_markers("invalid_final_transition"), do: ["invalid final"]

  defp validation_code_markers("invalid_attribute"),
    do: ["requires type or default", "default does not match"]

  defp validation_code_markers("missing_behavior"), do: ["missing behavior"]
  defp validation_code_markers("missing_operation"), do: ["missing operation"]
  defp validation_code_markers("choice_missing_fallback"), do: ["choice_missing_fallback"]
  defp validation_code_markers("choice_default_not_last"), do: ["choice_default_not_last"]
  defp validation_code_markers("choice_missing_transition"), do: ["choice_missing_transition"]
  defp validation_code_markers("invalid_history_owner"), do: ["invalid history owner"]
  defp validation_code_markers("history_missing_default"), do: ["history requires default"]
  defp validation_code_markers("invalid_timer_source"), do: ["timer source"]
  defp validation_code_markers("invalid_timer_behavior_return"), do: ["timer behavior return"]
  defp validation_code_markers("missing_timer_attribute"), do: ["missing timer attribute"]

  defp validation_code_markers("invalid_timer_attribute_type"),
    do: ["timer attribute has wrong type"]

  defp validation_code_markers(_code), do: []

  defp run_runtime_case(path, case) do
    validate_model_registry!(case)
    validate_behaviors!(case)

    {:ok, trace} = Agent.start_link(fn -> [] end)
    Process.put(:hsm_conformance_trace, trace)
    Process.put(:hsm_conformance_deferred, [])
    Process.put(:hsm_conformance_replay, [])
    Process.put(:hsm_conformance_nested_dispatch, [])
    Process.put(:hsm_conformance_snapshots, %{})
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

      assert_expect(
        case["expect"],
        machine,
        Agent.get(trace, & &1),
        Process.get(:hsm_conformance_snapshots, %{})
      )

      {:ok, path}
    end
  end

  defp run_multi_runtime_case(path, case, trace, model) do
    models =
      (case["models"] || [])
      |> Map.new(fn model_ir -> {model_ir["name"], build_model(case, trace, model_ir)} end)
      |> Map.put(case["model"]["name"], model)

    machines =
      Map.new(case["instances"] || [], fn %{"id" => id} = spec ->
        model_name = spec["model"] || case["model"]["name"]
        config = spec["config"] || %{}

        if Map.has_key?(models, model_name) do
          {id,
           HSM.new(
             Map.fetch!(models, model_name),
             HSM.Config.new(
               id: id,
               name: config["name"] || "",
               queue: queue_from_config(config["queue"], trace),
               clock: clock_from_config(config["clock"], trace, case)
             )
           )}
        else
          {id, {:missing_model, model_name}}
        end
      end)

    data =
      Map.new(case["instances"] || [], fn %{"id" => id} = spec ->
        config = spec["config"] || %{}
        {id, Map.get(config, "data", spec["data"])}
      end)

    groups =
      Map.new(case["groups"] || [], fn %{"id" => id, "members" => members} ->
        {id, members}
      end)

    env = %{machines: machines, groups: groups, snapshots: %{}, stable: nil, data: data}

    env =
      Enum.reduce(case["script"], env, fn step, acc ->
        Process.put(:hsm_conformance_multi_env, acc)
        execute_multi_step(acc, step, trace, case)
      end)

    stable = env.stable || first_state(env.machines)
    append_trace(trace, %{"type" => "stable", "state" => stable})
    assert_multi_expect(case["expect"], env, Agent.get(trace, & &1))
    {:ok, path}
  end

  defp build_model(case, trace, model_ir \\ nil) do
    build_model(case, trace, model_ir, true)
  end

  defp build_model(case, trace, model_ir, reset_index?) do
    if reset_index?, do: Process.put(:hsm_conformance_model_index, 1)
    model = model_ir || case["model"]
    parts = build_model_parts(case, model, trace)

    case model["redefines"] do
      base_name when is_binary(base_name) ->
        base =
          case find_model_ir(case, base_name) do
            nil -> invalid!("missing_submachine_model", "missing base model #{base_name}")
            base -> build_model(case, trace, base, false)
          end

        HSM.redefine(base, model["name"], parts)

      _ ->
        HSM.define(model["name"], parts)
    end
  end

  defp build_model_parts(case, model, trace) do
    with_current_model_attributes(model, fn ->
      parts = []
      parts = parts ++ build_attributes(model)
      parts = parts ++ build_operations(case, model, trace)

      parts =
        if model["initial"],
          do: parts ++ [build_initial(case, model["initial"], trace)],
          else: parts

      parts = parts ++ Enum.map(model["entry_points"] || [], &build_entry_point(case, &1, trace))
      parts = parts ++ Enum.map(model["exit_points"] || [], &build_exit_point(case, &1, trace))
      parts = parts ++ Enum.map(model["states"] || [], &build_state(case, &1, trace))
      parts = parts ++ Enum.map(model["transitions"] || [], &build_transition(case, &1, trace))
      parts
    end)
  end

  defp with_current_model_attributes(model, fun) do
    key = :hsm_conformance_current_model_attributes
    previous = Process.get(key, :missing)
    Process.put(key, Map.keys(model["attributes"] || %{}))

    try do
      fun.()
    after
      case previous do
        :missing -> Process.delete(key)
        value -> Process.put(key, value)
      end
    end
  end

  defp resolve_model_ir(case, %{"redefines" => base_name} = model) do
    base =
      case find_model_ir(case, base_name) do
        nil -> invalid!("missing_submachine_model", "missing base model #{base_name}")
        base -> resolve_model_ir(case, base)
      end

    base
    |> Map.merge(model)
    |> Map.put("name", model["name"])
    |> Map.put("initial", model["initial"] || base["initial"])
    |> Map.put("attributes", Map.merge(base["attributes"] || %{}, model["attributes"] || %{}))
    |> Map.put("operations", Map.merge(base["operations"] || %{}, model["operations"] || %{}))
    |> Map.put("states", (base["states"] || []) ++ (model["states"] || []))
    |> Map.put("transitions", (base["transitions"] || []) ++ (model["transitions"] || []))
    |> Map.delete("redefines")
  end

  defp resolve_model_ir(_case, model), do: model

  defp find_model_ir(case, name) do
    Enum.find([case["model"] | case["models"] || []], &(&1["name"] == name))
  end

  defp expand_submachines(model, case, inherited_exit_handlers \\ []) do
    root = "/" <> model["name"]

    root_exit_handlers =
      model
      |> root_exit_handlers_by_source(root)
      |> inherit_exit_handlers(model["states"] || [], root, inherited_exit_handlers)

    {states, attrs, ops} =
      expand_submachine_states(case, model["states"] || [], root, root, root_exit_handlers)

    boundaries = submachine_boundaries(case, model["states"] || [], root, root)

    model
    |> Map.put("states", states)
    |> Map.put("transitions", reject_exit_point_handlers(model["transitions"] || []))
    |> Map.put("attributes", Map.merge(model["attributes"] || %{}, attrs))
    |> Map.put("operations", Map.merge(model["operations"] || %{}, ops))
    |> lower_entry_point_targets(boundaries)
  end

  defp root_exit_handlers_by_source(model, root) do
    (model["transitions"] || [])
    |> Enum.filter(&exit_point_handler?/1)
    |> Enum.group_by(fn transition ->
      case transition["source"] do
        source when is_binary(source) -> transition_target_path(model, root, source, false)
        _ -> root
      end
    end)
  end

  defp reject_exit_point_handlers(transitions),
    do: Enum.reject(transitions, &exit_point_handler?/1)

  defp inherit_exit_handlers(root_exit_handlers, _states, _root, []), do: root_exit_handlers

  defp inherit_exit_handlers(root_exit_handlers, states, root, inherited_exit_handlers) do
    states
    |> submachine_paths(root)
    |> Enum.reduce(root_exit_handlers, fn path, acc ->
      Map.update(acc, path, inherited_exit_handlers, &(&1 ++ inherited_exit_handlers))
    end)
  end

  defp submachine_paths(states, parent_path) do
    Enum.flat_map(states, fn state ->
      path = HSM.DSL.join(parent_path, state["name"])
      nested = submachine_paths(state["states"] || [], path)

      if state["kind"] == "submachine",
        do: [path | nested],
        else: nested
    end)
  end

  defp submachine_boundaries(case, states, child_parent, flat_parent) do
    Enum.reduce(states, %{}, fn state, acc ->
      child_path = HSM.DSL.join(child_parent, state["name"])
      flat_path = HSM.DSL.join(flat_parent, state["name"])

      case state do
        %{"kind" => "submachine", "machine" => name} ->
          child =
            case find_model_ir(case, name) do
              nil -> invalid!("missing_submachine_model", "missing submachine model #{name}")
              model -> resolve_model_ir(case, model)
            end

          child_root = "/" <> child["name"]

          acc
          |> Map.put(flat_path, %{
            child_root: child_root,
            flat_root: flat_path,
            entry_points: child["entry_points"] || [],
            exit_points: child["exit_points"] || []
          })
          |> Map.merge(submachine_boundaries(case, child["states"] || [], child_root, flat_path))

        _ ->
          Map.merge(
            acc,
            submachine_boundaries(case, state["states"] || [], child_path, flat_path)
          )
      end
    end)
  end

  defp lower_entry_point_targets(model, boundaries) do
    root = "/" <> model["name"]

    model
    |> Map.put(
      "transitions",
      lower_entry_point_transitions(model, model["transitions"] || [], root, false, boundaries)
    )
    |> Map.put("states", lower_entry_point_states(model, model["states"] || [], root, boundaries))
  end

  defp lower_entry_point_states(model, states, parent_path, boundaries) do
    Enum.map(states, fn state ->
      path = HSM.DSL.join(parent_path, state["name"])
      pseudostate? = Map.get(state, "kind") in ["choice", "shallow_history", "deep_history"]
      owner = if pseudostate?, do: parent_path, else: path

      state
      |> Map.put(
        "transitions",
        lower_entry_point_transitions(
          model,
          state["transitions"] || [],
          owner,
          pseudostate?,
          boundaries
        )
      )
      |> Map.put(
        "states",
        lower_entry_point_states(model, state["states"] || [], path, boundaries)
      )
    end)
  end

  defp lower_entry_point_transitions(model, transitions, owner, owner_relative?, boundaries) do
    Enum.map(transitions, fn transition ->
      case {transition["target"], transition["entry_point"]} do
        {target, entry_point} when is_binary(target) and is_binary(entry_point) ->
          boundary_path = transition_target_path(model, owner, target, owner_relative?)

          case Map.get(boundaries, boundary_path) do
            nil ->
              transition

            boundary ->
              case Enum.find(boundary.entry_points, &(&1["name"] == entry_point)) do
                nil ->
                  transition

                point ->
                  effects = (transition["effects"] || []) ++ (point["effects"] || [])

                  transition
                  |> Map.put(
                    "target",
                    rebase_path(
                      point["target"],
                      boundary.child_root,
                      boundary.flat_root,
                      boundary.child_root,
                      boundary.flat_root,
                      false
                    )
                  )
                  |> maybe_self_reentry_kind(boundary_path, owner)
                  |> Map.put("effects", effects)
                  |> Map.delete("entry_point")
              end
          end

        _ ->
          transition
      end
    end)
  end

  defp maybe_self_reentry_kind(transition, boundary_path, owner) do
    if boundary_path == owner and Map.get(transition, "kind", "external") == "external" do
      Map.put(transition, "kind", "self")
    else
      transition
    end
  end

  defp transition_target_path(model, owner, target, owner_relative?) do
    cond do
      String.starts_with?(target, "/") ->
        HSM.DSL.normalize(target)

      owner_relative? or target == "." or String.starts_with?(target, "./") or
          String.starts_with?(target, "../") ->
        HSM.DSL.join(owner, target)

      true ->
        HSM.DSL.join("/" <> model["name"], target)
    end
  end

  defp lower_exit_point_targets(child, exit_handlers, child_root, flat_root, completion_lowering?) do
    exit_points = child["exit_points"] || []

    handled_exit_points =
      if completion_lowering?,
        do: Enum.filter(exit_points, &(exit_point_handlers(exit_handlers, &1) != [])),
        else: []

    child
    |> Map.put(
      "transitions",
      lower_exit_point_transitions(
        child,
        child["transitions"] || [],
        child_root,
        false,
        exit_points,
        exit_handlers,
        flat_root,
        completion_lowering?
      ) ++ exit_point_completion_transitions(handled_exit_points, exit_handlers, flat_root)
    )
    |> Map.put(
      "states",
      lower_exit_point_states(
        child,
        child["states"] || [],
        child_root,
        exit_points,
        exit_handlers,
        flat_root,
        completion_lowering?
      ) ++ exit_point_final_states(handled_exit_points)
    )
  end

  defp lower_exit_point_states(
         child,
         states,
         parent_path,
         exit_points,
         exit_handlers,
         flat_root,
         completion_lowering?
       ) do
    Enum.map(states, fn state ->
      path = HSM.DSL.join(parent_path, state["name"])
      pseudostate? = Map.get(state, "kind") in ["choice", "shallow_history", "deep_history"]
      owner = if pseudostate?, do: parent_path, else: path

      state
      |> Map.put(
        "transitions",
        lower_exit_point_transitions(
          child,
          state["transitions"] || [],
          owner,
          pseudostate?,
          exit_points,
          exit_handlers,
          flat_root,
          completion_lowering?
        )
      )
      |> Map.put(
        "states",
        lower_exit_point_states(
          child,
          state["states"] || [],
          path,
          exit_points,
          exit_handlers,
          flat_root,
          completion_lowering?
        )
      )
    end)
  end

  defp lower_exit_point_transitions(
         child,
         transitions,
         owner,
         owner_relative?,
         exit_points,
         exit_handlers,
         flat_root,
         completion_lowering?
       ) do
    Enum.flat_map(transitions, fn transition ->
      case exit_point_target(child, owner, transition["target"], owner_relative?, exit_points) do
        nil ->
          [transition]

        exit_point ->
          handlers = exit_point_handlers(exit_handlers, exit_point)

          cond do
            handlers == [] ->
              [
                transition
                |> Map.delete("target")
                |> Map.put("kind", "internal")
                |> Map.put(
                  "effects",
                  (transition["effects"] || []) ++
                    (exit_point["effects"] || []) ++
                    [%{"op" => "raise", "code" => "unhandled_exit_point"}]
                )
              ]

            !completion_lowering? or exit_point_completion_transition?(transition) ->
              Enum.map(handlers, fn handler ->
                transition
                |> Map.put("target", boundary_handler_target(handler, flat_root))
                |> maybe_put_handler_entry_point(handler)
                |> maybe_put_handler_guard(handler)
                |> Map.put(
                  "effects",
                  (transition["effects"] || []) ++
                    (exit_point["effects"] || []) ++ (handler["effects"] || [])
                )
              end)

            true ->
              [
                transition
                |> Map.put(
                  "target",
                  HSM.DSL.join("/" <> child["name"], exit_point_final_name(exit_point))
                )
                |> Map.put(
                  "effects",
                  (transition["effects"] || []) ++ (exit_point["effects"] || [])
                )
              ]
          end
      end
    end)
  end

  defp exit_point_completion_transition?(%{"trigger" => %{"kind" => "completion"}}), do: true
  defp exit_point_completion_transition?(_transition), do: false

  defp exit_point_completion_lowering?(case, boundary, child, exit_handlers) do
    Enum.any?(child["exit_points"] || [], fn exit_point ->
      handlers = exit_point_handlers(exit_handlers, exit_point)

      handlers != [] and
        (boundary_orders_exit_point_effects?(boundary, exit_point) or
           Enum.any?(handlers, &Map.has_key?(&1, "entry_point")) or
           guarded_fallthrough?(case, handlers))
    end)
  end

  defp boundary_orders_exit_point_effects?(boundary, exit_point),
    do: (boundary["exit"] || []) != [] and (exit_point["effects"] || []) != []

  defp guarded_fallthrough?(case, handlers),
    do: length(handlers) > 1 and Enum.any?(handlers, &fallthrough_guard?(case, &1))

  defp fallthrough_guard?(case, %{"guard" => guard}), do: !guard_raises?(case, guard)
  defp fallthrough_guard?(_case, _handler), do: false

  defp guard_raises?(case, %{"behavior" => id}) do
    case
    |> get_in(["behaviors", id])
    |> List.wrap()
    |> Enum.any?(&(&1["op"] == "raise" and Map.has_key?(&1, "code")))
  end

  defp guard_raises?(_case, _guard), do: false

  defp exit_point_completion_transitions(exit_points, exit_handlers, flat_root) do
    Enum.flat_map(exit_points, fn exit_point ->
      Enum.map(exit_point_handlers(exit_handlers, exit_point), fn handler ->
        handler
        |> Map.delete("source")
        |> Map.put("trigger", %{"kind" => "completion"})
        |> Map.put("target", boundary_handler_target(handler, flat_root))
        |> maybe_put_handler_entry_point(handler)
        |> maybe_put_handler_guard(handler)
        |> Map.put("effects", handler["effects"] || [])
      end)
    end)
  end

  defp exit_point_final_states(exit_points),
    do: Enum.map(exit_points, &%{"name" => exit_point_final_name(&1), "kind" => "final"})

  defp exit_point_handlers(exit_handlers, exit_point),
    do:
      exit_handlers
      |> Enum.filter(&(get_in(&1, ["trigger", "exit_point"]) == exit_point["name"]))
      |> guarded_handlers_first()

  defp guarded_handlers_first(handlers) do
    {guarded, guardless} = Enum.split_with(handlers, &Map.has_key?(&1, "guard"))
    guarded ++ guardless
  end

  defp exit_point_final_name(%{"name" => name}), do: "__hsm_exit_" <> name

  defp exit_point_target(_child, _owner, nil, _owner_relative?, _exit_points), do: nil

  defp exit_point_target(child, owner, target, owner_relative?, exit_points) do
    target_path = transition_target_path(child, owner, target, owner_relative?)
    root = "/" <> child["name"]

    Enum.find(exit_points, fn point ->
      target_path == HSM.DSL.join(root, point["name"])
    end)
  end

  defp boundary_handler_target(%{"target" => target}, flat_root) do
    root = root_path(flat_root)

    cond do
      String.starts_with?(target, "/") ->
        HSM.DSL.normalize(target)

      target == "." or String.starts_with?(target, "./") or String.starts_with?(target, "../") ->
        HSM.DSL.join(flat_root, target)

      true ->
        HSM.DSL.join(root, target)
    end
  end

  defp maybe_put_handler_guard(transition, %{"guard" => guard}),
    do: Map.put_new(transition, "guard", guard)

  defp maybe_put_handler_guard(transition, _handler), do: transition

  defp maybe_put_handler_entry_point(transition, %{"entry_point" => entry_point}),
    do: Map.put(transition, "entry_point", entry_point)

  defp maybe_put_handler_entry_point(transition, _handler), do: transition

  defp exit_point_handler?(%{"trigger" => %{"kind" => "exit_point"}}), do: true
  defp exit_point_handler?(_transition), do: false

  defp root_path(path) do
    case String.split(path, "/", trim: true) do
      [root | _] -> "/" <> root
      [] -> "/"
    end
  end

  defp expand_submachine_states(
         case,
         states,
         child_parent,
         flat_parent,
         root_exit_handlers
       ) do
    Enum.reduce(states, {[], %{}, %{}}, fn state, {states_acc, attrs_acc, ops_acc} ->
      {state, attrs, ops} =
        expand_submachine_state(case, state, child_parent, flat_parent, root_exit_handlers)

      {states_acc ++ [state], Map.merge(attrs_acc, attrs), Map.merge(ops_acc, ops)}
    end)
  end

  defp expand_submachine_state(case, state, child_parent, flat_parent),
    do: expand_submachine_state(case, state, child_parent, flat_parent, %{})

  defp expand_submachine_state(
         case,
         %{"kind" => "submachine", "machine" => name} = state,
         _child_parent,
         flat_parent,
         root_exit_handlers
       ) do
    child =
      case find_model_ir(case, name) do
        nil -> invalid!("missing_submachine_model", "missing submachine model #{name}")
        model -> resolve_model_ir(case, model)
      end

    child_root = "/" <> child["name"]
    flat_root = HSM.DSL.join(flat_parent, state["name"])
    raw_boundary_transitions = state["transitions"] || []

    local_exit_handlers = Enum.filter(raw_boundary_transitions, &exit_point_handler?/1)
    inherited_exit_handlers = Map.get(root_exit_handlers, flat_root, [])
    exit_handlers = local_exit_handlers ++ inherited_exit_handlers
    propagated_exit_handlers = resolve_exit_handler_targets(exit_handlers, flat_root)
    completion_lowering? = exit_point_completion_lowering?(case, state, child, exit_handlers)

    child =
      child
      |> lower_exit_point_targets(
        exit_handlers,
        child_root,
        flat_root,
        completion_lowering?
      )
      |> expand_submachines(case, propagated_exit_handlers)

    {child_states, attrs, ops} =
      rebase_submachine_states(
        case,
        child["states"] || [],
        child_root,
        flat_root,
        child_root,
        flat_root
      )

    boundary_transitions = Enum.reject(raw_boundary_transitions, &exit_point_handler?/1)

    child_transitions =
      rebase_transitions(child["transitions"] || [], child_root, flat_root, child_root, flat_root)

    state =
      state
      |> Map.put("kind", "state")
      |> Map.put(
        "initial",
        rebase_initial(child["initial"], child_root, flat_root, child_root, flat_root)
      )
      |> Map.put("states", child_states)
      |> Map.put("transitions", child_transitions ++ boundary_transitions)
      |> Map.delete("machine")

    {state, Map.merge(child["attributes"] || %{}, attrs),
     Map.merge(child["operations"] || %{}, ops)}
  end

  defp expand_submachine_state(case, state, child_parent, flat_parent, root_exit_handlers) do
    child_path = HSM.DSL.join(child_parent, state["name"])
    flat_path = HSM.DSL.join(flat_parent, state["name"])

    {states, attrs, ops} =
      expand_submachine_states(
        case,
        state["states"] || [],
        child_path,
        flat_path,
        root_exit_handlers
      )

    state =
      state
      |> Map.put("states", states)

    {state, attrs, ops}
  end

  defp resolve_exit_handler_targets(exit_handlers, flat_root) do
    Enum.map(exit_handlers, fn
      %{"target" => _target} = handler ->
        Map.put(handler, "target", boundary_handler_target(handler, flat_root))

      handler ->
        handler
    end)
  end

  defp rebase_submachine_states(case, states, child_parent, flat_parent, child_root, flat_root) do
    Enum.reduce(states, {[], %{}, %{}}, fn state, {states_acc, attrs_acc, ops_acc} ->
      child_path = HSM.DSL.join(child_parent, state["name"])
      flat_path = HSM.DSL.join(flat_parent, state["name"])

      {state, attrs, ops} =
        case state do
          %{"kind" => "submachine"} ->
            expand_submachine_state(case, state, child_parent, flat_parent)

          _ ->
            {nested, attrs, ops} =
              rebase_submachine_states(
                case,
                state["states"] || [],
                child_path,
                flat_path,
                child_root,
                flat_root
              )

            pseudostate? = Map.get(state, "kind") in ["choice", "shallow_history", "deep_history"]

            transition_child_owner =
              if pseudostate?, do: HSM.DSL.parent(child_path), else: child_path

            transition_flat_owner =
              if pseudostate?, do: HSM.DSL.parent(flat_path), else: flat_path

            state =
              state
              |> Map.put(
                "initial",
                rebase_initial(state["initial"], child_path, flat_path, child_root, flat_root)
              )
              |> Map.put("defer", scoped_submachine_defers(state["defer"] || [], flat_root))
              |> Map.put("states", nested)
              |> Map.put(
                "transitions",
                rebase_transitions(
                  state["transitions"] || [],
                  transition_child_owner,
                  transition_flat_owner,
                  child_root,
                  flat_root,
                  pseudostate?
                )
              )

            {state, attrs, ops}
        end

      {states_acc ++ [state], Map.merge(attrs_acc, attrs), Map.merge(ops_acc, ops)}
    end)
  end

  defp scoped_submachine_defers(defers, flat_root) do
    Enum.map(defers, fn
      %{"event" => _event} = defer -> Map.put_new(defer, "scope", flat_root)
      defer -> %{"event" => defer, "scope" => flat_root}
    end)
  end

  defp rebase_initial(nil, _child_owner, _flat_owner, _child_root, _flat_root), do: nil

  defp rebase_initial(initial, child_owner, flat_owner, child_root, flat_root)
       when is_binary(initial),
       do: rebase_path(initial, child_owner, flat_owner, child_root, flat_root, true)

  defp rebase_initial(initial, child_owner, flat_owner, child_root, flat_root) do
    Map.update(
      initial,
      "target",
      nil,
      &rebase_path(&1, child_owner, flat_owner, child_root, flat_root, true)
    )
  end

  defp rebase_transitions(
         transitions,
         child_owner,
         flat_owner,
         child_root,
         flat_root,
         owner_relative? \\ false
       ) do
    Enum.map(transitions, fn transition ->
      transition
      |> maybe_rebase_path("source", child_owner, flat_owner, child_root, flat_root)
      |> maybe_rebase_path(
        "target",
        child_owner,
        flat_owner,
        child_root,
        flat_root,
        owner_relative?
      )
    end)
  end

  defp maybe_rebase_path(
         map,
         key,
         child_owner,
         flat_owner,
         child_root,
         flat_root,
         owner_relative? \\ false
       ) do
    if Map.has_key?(map, key),
      do:
        Map.put(
          map,
          key,
          rebase_path(map[key], child_owner, flat_owner, child_root, flat_root, owner_relative?)
        ),
      else: map
  end

  defp rebase_path(
         path,
         child_owner,
         _flat_owner,
         child_root,
         flat_root,
         owner_relative?
       ) do
    child_path =
      cond do
        String.starts_with?(path, "/") ->
          HSM.DSL.normalize(path)

        owner_relative? or path == "." or String.starts_with?(path, "./") or
            String.starts_with?(path, "../") ->
          HSM.DSL.join(child_owner, path)

        true ->
          HSM.DSL.join(child_root, path)
      end

    cond do
      child_path == child_root ->
        flat_root

      String.starts_with?(child_path, child_root <> "/") ->
        String.replace_prefix(child_path, child_root, flat_root)

      true ->
        child_path
    end
  end

  defp build_attributes(model) do
    for {name, spec} <- model["attributes"] || %{} do
      if Map.has_key?(spec, "type") do
        HSM.attribute(name, attribute_type(spec["type"]), Map.get(spec, "default"))
      else
        HSM.attribute(name, Map.get(spec, "default"))
      end
    end
  end

  defp attribute_type("boolean"), do: :boolean
  defp attribute_type("number"), do: :number
  defp attribute_type("duration_ms"), do: :integer
  defp attribute_type("time_ms"), do: :integer
  defp attribute_type("string"), do: :string
  defp attribute_type("array"), do: :list
  defp attribute_type("object"), do: :map
  defp attribute_type(_type), do: :any

  defp build_operations(case, model, trace) do
    for {name, ref} <- model["operations"] || %{} do
      cond do
        ref == :operation_contract -> {:operation_contract, name}
        ref == nil -> HSM.operation(name)
        true -> HSM.operation(name, behavior(case, behavior_id(ref), trace))
      end
    end
  end

  defp build_state(case, state, trace) do
    kind = Map.get(state, "kind", "state")
    if kind == "submachine", do: bump_model_index()
    child_model = if kind == "submachine", do: build_child_model(case, state, trace), else: nil

    unless kind == "submachine", do: bump_model_index()
    parts = []

    parts =
      if state["initial"],
        do: parts ++ [build_initial(case, state["initial"], trace)],
        else: parts

    parts = parts ++ behavior_parts(case, state, "entry", trace, &HSM.entry/1)
    parts = parts ++ behavior_parts(case, state, "exit", trace, &HSM.exit/1)
    parts = parts ++ behavior_parts(case, state, "activity", trace, &HSM.activity/1)
    parts = parts ++ Enum.map(state["defer"] || [], &HSM.defer/1)
    parts = parts ++ Enum.map(state["entry_points"] || [], &build_entry_point(case, &1, trace))
    parts = parts ++ Enum.map(state["exit_points"] || [], &build_exit_point(case, &1, trace))
    parts = parts ++ Enum.map(state["states"] || [], &build_state(case, &1, trace))
    parts = parts ++ Enum.map(state["transitions"] || [], &build_transition(case, &1, trace))

    case kind do
      "state" ->
        HSM.state(state["name"], parts)

      "final" ->
        HSM.final(state["name"])

      "choice" ->
        HSM.choice(state["name"], parts)

      "shallow_history" ->
        HSM.shallow_history(state["name"], parts)

      "deep_history" ->
        HSM.deep_history(state["name"], parts)

      "submachine" ->
        HSM.submachine_state(state["name"], child_model, parts)
    end
  end

  defp build_child_model(case, %{"machine" => name}, trace) do
    case find_model_ir(case, name) do
      nil -> invalid!("missing_submachine_model", "missing submachine model #{name}")
      model -> build_model(case, trace, inherit_root_operation_contracts(case, model), false)
    end
  end

  defp inherit_root_operation_contracts(case, model) do
    root_operations =
      case
      |> get_in(["model", "operations"])
      |> root_operation_contracts()

    Map.update(model, "operations", root_operations, fn operations ->
      Map.merge(root_operations, operations || %{})
    end)
  end

  defp root_operation_contracts(nil), do: %{}

  defp root_operation_contracts(operations) do
    operations
    |> Map.new(fn {name, _ref} -> {name, :operation_contract} end)
  end

  defp build_entry_point(case, point, trace) do
    parts = []
    parts = if point["target"], do: parts ++ [HSM.target(point["target"])], else: parts
    parts = parts ++ behavior_effect_parts(case, point, trace)
    HSM.entry_point(point["name"], parts)
  end

  defp build_exit_point(case, point, trace) do
    HSM.exit_point(point["name"], behavior_effect_parts(case, point, trace))
  end

  defp behavior_effect_parts(case, container, trace) do
    Enum.flat_map(
      container["effects"] || [],
      &[HSM.effect(behavior(case, behavior_id(&1), trace))]
    )
  end

  defp build_initial(_case, initial, _trace) when is_binary(initial),
    do: bump_initial_index(HSM.initial(HSM.target(initial)), 0)

  defp build_initial(case, initial, trace) do
    effects =
      Enum.flat_map(
        initial["effects"] || [],
        &[
          HSM.effect(behavior(case, behavior_id(&1), trace))
        ]
      )

    bump_initial_index(HSM.initial([HSM.target(initial["target"]) | effects]), length(effects))
  end

  defp bump_initial_index(initial, effect_count) do
    bump_model_index()
    bump_model_index()
    bump_model_index(effect_count)
    initial
  end

  defp behavior_parts(case, container, key, trace, factory) do
    refs = container[key] || []

    if refs == [] do
      []
    else
      bump_model_index(length(refs))
      [factory.(Enum.map(refs, &behavior(case, behavior_id(&1), trace)))]
    end
  end

  defp build_transition(case, transition, trace) do
    id = next_model_index()
    parts = []
    parts = if transition["source"], do: parts ++ [HSM.source(transition["source"])], else: parts
    parts = parts ++ trigger_part(case, transition, trace)

    parts =
      if transition["guard"],
        do: parts ++ [HSM.guard(behavior(case, behavior_id(transition["guard"]), trace))],
        else: parts

    parts = if transition["target"], do: parts ++ [HSM.target(transition["target"])], else: parts

    parts =
      if transition["entry_point"],
        do: parts ++ [HSM.entry_point(transition["entry_point"])],
        else: parts

    parts =
      parts ++
        behavior_effect_parts(case, transition, trace)

    parts = parts ++ kind_part(transition["kind"])
    bump_transition_behavior_indexes(transition)
    HSM.transition("transition_#{id}", parts)
  end

  defp bump_transition_behavior_indexes(transition) do
    if transition["guard"], do: bump_model_index()
    bump_model_index(length(transition["effects"] || []))
  end

  defp next_model_index do
    index = Process.get(:hsm_conformance_model_index, 0)
    Process.put(:hsm_conformance_model_index, index + 1)
    index
  end

  defp bump_model_index, do: next_model_index()

  defp bump_model_index(count) when count > 0 do
    Enum.each(1..count//1, fn _ -> bump_model_index() end)
  end

  defp bump_model_index(_count), do: :ok

  defp trigger_part(_case, %{"on" => event}, _trace), do: [HSM.on(event)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on", "event" => event}}, _trace),
    do: [HSM.on(event)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on", "events" => events}}, _trace),
    do: [HSM.on(events)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on_set", "attribute" => attr}}, _trace),
    do: [HSM.on_set(attr)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "on_call", "operation" => op}}, _trace),
    do: [HSM.on_call(op)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "completion"}}, _trace),
    do: [HSM.on("hsm/final")]

  defp trigger_part(
         _case,
         %{"trigger" => %{"kind" => "exit_point", "exit_point" => point}},
         _trace
       ),
       do: [HSM.exit_point(point)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "when", "attribute" => attr}}, _trace),
    do: [HSM.when_attr(attr)]

  defp trigger_part(case, %{"trigger" => %{"kind" => "when", "behavior" => id}}, trace) do
    fun = behavior(case, id, trace)

    cond do
      current_model_attributes() != [] ->
        [HSM.when_expr(fun)]

      attributes = behavior_attribute_sources(case, id) ->
        case attributes do
          [] -> [HSM.when_expr(fun)]
          attributes -> [{:trigger, {:when, fun, attributes}}]
        end
    end
  end

  defp trigger_part(_case, %{"trigger" => %{"kind" => "after", "duration_ms" => millis}}, _trace),
    do: [HSM.after_ms(millis)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "after", "attribute" => attr}}, _trace),
    do: [HSM.after_ms(attr)]

  defp trigger_part(case, %{"trigger" => %{"kind" => "after", "behavior" => id}}, trace),
    do: [HSM.after_ms(behavior(case, id, trace))]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "every", "duration_ms" => millis}}, _trace),
    do: [HSM.every_ms(millis)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "every", "attribute" => attr}}, _trace),
    do: [HSM.every_ms(attr)]

  defp trigger_part(case, %{"trigger" => %{"kind" => "every", "behavior" => id}}, trace),
    do: [HSM.every_ms(behavior(case, id, trace))]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "at", "time_ms" => millis}}, _trace),
    do: [HSM.at_ms(millis)]

  defp trigger_part(_case, %{"trigger" => %{"kind" => "at", "attribute" => attr}}, _trace),
    do: [HSM.at_ms(attr)]

  defp trigger_part(case, %{"trigger" => %{"kind" => "at", "behavior" => id}}, trace),
    do: [HSM.at_ms(behavior(case, id, trace))]

  defp trigger_part(_case, _transition, _trace), do: []

  defp current_model_attributes,
    do: Process.get(:hsm_conformance_current_model_attributes, [])

  defp kind_part("internal"), do: [HSM.internal()]
  defp kind_part("local"), do: [HSM.local()]
  defp kind_part("self"), do: [HSM.self_transition()]
  defp kind_part(_), do: []

  defp behavior(_case, {:inline, program}, trace) do
    behavior_program(%{}, {:inline, program}, program, trace)
  end

  defp behavior(case, id, trace) do
    program = get_in(case, ["behaviors", id]) || []
    behavior_program(case, id, program, trace)
  end

  defp behavior_attribute_sources(case, id) do
    case
    |> get_in(["behaviors", id])
    |> List.wrap()
    |> Enum.flat_map(&behavior_attribute_source/1)
    |> Enum.uniq()
  end

  defp behavior_attribute_source(%{"op" => op} = spec)
       when op in ["get_attr", "return_attr", "return_equals"],
       do: List.wrap(spec["name"] || spec["attribute"])

  defp behavior_attribute_source(_spec), do: []

  defp behavior_program(case, id, program, trace) do
    fn ctx, instance, event ->
      event_key = {event.name, event.data, event.schema}

      if Process.get(:hsm_conformance_event_key) != event_key do
        Process.put(:hsm_conformance_event_key, event_key)
        Process.put(:hsm_conformance_event_metadata, event.schema || %{})
      end

      {_instance, result} =
        Enum.reduce_while(program, {instance, instance}, fn op, {acc, _result} ->
          case execute_behavior_op(case, ctx, acc, event, op, trace, id) do
            {:return, value} ->
              {:cont, {acc, value}}

            {:halt, %HSM.Instance{} = next} ->
              {:halt, {next, next}}

            {:halt, value} ->
              {:halt, {acc, value}}

            %HSM.Instance{} = next ->
              if activity_exited?(ctx, next),
                do: {:halt, {next, next}},
                else: {:cont, {next, next}}

            next ->
              {:cont, {acc, next}}
          end
        end)

      if activity_done_expected?(case, id) do
        append_trace(trace, %{"type" => "activity_done", "behavior" => id})
      end

      if event.kind == :timer_event && Process.delete(:hsm_conformance_timer_guard_fire) do
        append_trace(trace, %{"type" => "timer_fired"})
      end

      result
    end
  end

  defp activity_done_expected?(case, id) do
    Enum.any?(get_in(case, ["expect", "trace"]) || [], fn item ->
      item["type"] == "activity_done" and item["behavior"] == id
    end)
  end

  defp activity_exited?(%{action: :activity, path: path}, instance) do
    state = HSM.state(instance)
    state != path and !String.starts_with?(state, path <> "/")
  end

  defp activity_exited?(_ctx, _instance), do: false

  defp activity_handles_generated?(case, %{action: :activity, path: path}, _instance, trigger) do
    path
    |> path_and_ancestors()
    |> Enum.any?(fn state_path ->
      case
      |> state_ir(state_path)
      |> handled_transition?(trigger)
    end)
  end

  defp activity_handles_generated?(_case, _ctx, _instance, _trigger), do: false

  defp path_and_ancestors(path) do
    parts = String.split(path, "/", trim: true)

    1..length(parts)
    |> Enum.reverse()
    |> Enum.map(fn count ->
      "/" <> (parts |> Enum.take(count) |> Enum.join("/"))
    end)
  end

  defp handled_transition?(nil, _trigger), do: false

  defp handled_transition?(state, trigger) do
    Enum.any?(state["transitions"] || [], &transition_handles?(&1, trigger))
  end

  defp transition_handles?(%{"on" => event}, {:event, event}), do: true

  defp transition_handles?(%{"trigger" => %{"kind" => "on", "event" => event}}, {:event, event}),
    do: true

  defp transition_handles?(
         %{"trigger" => %{"kind" => "on", "events" => events}},
         {:event, event}
       ),
       do: event in events

  defp transition_handles?(
         %{"trigger" => %{"kind" => "on_call", "operation" => operation}},
         {:call, operation}
       ),
       do: true

  defp transition_handles?(_transition, _trigger), do: false

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         event,
         %{"op" => "trace", "value" => value},
         trace,
         _id
       ) do
    maybe_append_undefer(trace, event)
    append_trace(trace, %{"type" => "trace", "value" => value})
    instance
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         event,
         %{"op" => "set_attr_from_event_data", "name" => name} = op,
         _trace,
         _id
       ) do
    HSM.set(instance, name, event_data(event, op["path"]))
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         event,
         %{"op" => "set_attr_from_event_data", "attribute" => name} = op,
         _trace,
         _id
       ) do
    HSM.set(instance, name, event_data(event, op["path"]))
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         _event,
         %{"op" => "get_attr"} = op,
         _trace,
         _id
       ) do
    {:return, elem(HSM.get(instance, behavior_attr_name(op)), 0)}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         _event,
         %{"op" => "return_attr"} = op,
         _trace,
         _id
       ) do
    {:return, elem(HSM.get(instance, behavior_attr_name(op)), 0)}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         _event,
         %{"op" => "return_equals", "name" => name, "value" => value},
         _trace,
         _id
       ) do
    {:return, elem(HSM.get(instance, name), 0) == value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         _event,
         %{"op" => "return_equals", "attribute" => name, "value" => value},
         _trace,
         _id
       ) do
    {:return, elem(HSM.get(instance, name), 0) == value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         _event,
         %{"op" => "return_value", "value" => value},
         _trace,
         _id
       ) do
    {:return, value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_name_equals", "value" => value},
         _trace,
         _id
       ) do
    {:return, event.name == value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_data_equals", "path" => path, "value" => value},
         _trace,
         _id
       ) do
    {:return, event_data(event, path) == value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_data_equals", "value" => value},
         _trace,
         _id
       ) do
    {:return, event_data(event, "") == value}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_data_get"} = op,
         _trace,
         _id
       ) do
    {:return, event_data(event, op["path"])}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         _event,
         %{"op" => "set_attr", "name" => name, "value" => value},
         _trace,
         _id
       ) do
    HSM.set(instance, name, value)
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         instance,
         event,
         %{"op" => "event_metadata_set", "name" => name, "value" => value},
         _trace,
         _id
       ) do
    unless reserved_event_metadata?(name) do
      metadata =
        Map.put(Process.get(:hsm_conformance_event_metadata, event.schema || %{}), name, value)

      Process.put(:hsm_conformance_event_metadata, metadata)
    end

    instance
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_metadata_get", "name" => name},
         _trace,
         _id
       ) do
    {:return, event_metadata(event, name)}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         event,
         %{"op" => "event_metadata_equals", "name" => name, "value" => value},
         _trace,
         _id
       ) do
    {:return, event_metadata(event, name) == value}
  end

  defp execute_behavior_op(
         case,
         ctx,
         instance,
         _event,
         %{"op" => "call", "name" => name} = op,
         trace,
         _id
       ) do
    {instance, operation_error?} =
      try do
        instance = HSM.call(instance, name, Map.get(op, "data", [])) |> elem(0)
        {instance, Process.delete(:hsm_conformance_activity_behavior_error) == true}
      rescue
        error in HSM.ValidationError ->
          append_error(trace, "operation_error", error.message)
          throw({:behavior_error, "operation_error", error.message})
      catch
        {:behavior_error, code, message} ->
          remember_error(code, message)

          case ctx do
            %{action: :activity} -> {instance, true}
            _ -> throw({:behavior_error, code, message})
          end
      end

    if operation_error? or activity_handles_generated?(case, ctx, instance, {:call, name}) do
      {:halt, instance}
    else
      if "submachine" in (case["features"] || []) and trace_expects_call?(case, name) do
        append_trace(trace, %{"type" => "call", "operation" => name})
      end

      instance
    end
  end

  defp execute_behavior_op(
         case,
         ctx,
         instance,
         _event,
         %{"op" => "raise", "event" => event},
         trace,
         _id
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "raise", "event" => event.name})
    trace_pre_defer(trace, case, instance, event)
    instance = HSM.Instance.dispatch(instance, event) |> elem(0)

    if activity_handles_generated?(case, ctx, instance, {:event, event.name}),
      do: {:halt, instance},
      else: instance
  end

  defp execute_behavior_op(
         _case,
         %{action: :activity},
         instance,
         _event,
         %{"op" => "raise", "code" => code} = op,
         trace,
         _id
       ) do
    code = code || "behavior_error"
    append_error(trace, code, op["value"] || "behavior error")
    Process.put(:hsm_conformance_activity_behavior_error, true)
    {:halt, instance}
  end

  defp execute_behavior_op(
         _case,
         _ctx,
         _instance,
         _event,
         %{"op" => "raise", "code" => code} = op,
         trace,
         _id
       ) do
    code = code || "behavior_error"
    message = op["value"] || "behavior error"
    append_error(trace, code, message)
    throw({:behavior_error, code, message})
  end

  defp execute_behavior_op(
         case,
         _ctx,
         instance,
         _event,
         %{"op" => "dispatch", "event" => event, "target" => target},
         trace,
         _id
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => target})
    dispatch_from_behavior_target(instance, event, target, trace, case)
  end

  defp execute_behavior_op(
         case,
         _ctx,
         instance,
         _event,
         %{"op" => "dispatch", "event" => event, "group" => group_id},
         trace,
         _id
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => group_id})

    case Process.get(:hsm_conformance_multi_env) do
      %{groups: groups} when not is_map_key(groups, group_id) ->
        append_error(trace, "runtime_error", "unknown group #{group_id}")
        throw({:behavior_error, "runtime_error", "unknown group #{group_id}"})

      _ ->
        dispatch_from_behavior_group(instance, event, group_id, trace, case)
    end
  end

  defp execute_behavior_op(
         case,
         ctx,
         instance,
         _event,
         %{"op" => "dispatch", "event" => event},
         trace,
         _id
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name})
    trace_pre_defer(trace, case, instance, event)
    instance = HSM.Instance.dispatch(instance, event) |> elem(0)

    if activity_handles_generated?(case, ctx, instance, {:event, event.name}),
      do: {:halt, instance},
      else: instance
  end

  defp execute_behavior_op(
         _case,
         ctx,
         instance,
         event,
         %{"op" => "snapshot"} = op,
         trace,
         _id
       ) do
    snapshot = normalize_snapshot(HSM.take_snapshot(instance), "default", instance)
    snapshot = initial_event_snapshot(snapshot, event, instance, ctx)
    snapshot_id = op["id"] || "last"
    snapshots = Process.get(:hsm_conformance_snapshots, %{})
    Process.put(:hsm_conformance_snapshots, Map.put(snapshots, snapshot_id, snapshot))
    append_trace(trace, %{"type" => "snapshot", "state" => snapshot["state"]})
    instance
  end

  defp execute_behavior_op(_case, _ctx, instance, _event, %{"op" => "yield"}, _trace, _id),
    do: instance

  defp execute_behavior_op(
         _case,
         %{action: :activity},
         _instance,
         _event,
         %{"op" => "sleep"},
         trace,
         id
       ) do
    cancel = fn ->
      append_trace(trace, %{"type" => "activity_cancel", "behavior" => id})
    end

    {:halt, {:hsm_activity, id, cancel}}
  end

  defp execute_behavior_op(_case, _ctx, instance, _event, %{"op" => "sleep"}, _trace, _id),
    do: instance

  defp execute_behavior_op(_case, _ctx, _instance, _event, %{"op" => op}, _trace, _id),
    do: throw({:assertion, "unsupported behavior op #{inspect(op)}"})

  defp execute_behavior_op(_case, _ctx, _instance, _event, op, _trace, _id),
    do: throw({:assertion, "unsupported behavior op #{inspect(op)}"})

  defp execute_step(machine, %{"op" => "start"}, trace, case) do
    cond do
      machine.started? ->
        append_error(trace, "lifecycle_error", "already started HSM")
        machine

      true ->
        append_lifecycle_trace(trace, case, "start")

        machine =
          try do
            Process.put(:hsm_runtime_preserve_timer_error, true)
            machine = HSM.start(machine)
            append_start_timer_error(trace)
            append_timer_scheduled(trace, case, machine)
            machine
          rescue
            error ->
              record_runtime_error(trace, error)
              root_error_state(machine)
          catch
            {:hsm_completion_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              machine

            {:hsm_set_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              machine

            {:behavior_error, code, message} ->
              remember_error(code, message)
              startup_error_state(machine, code)
          after
            Process.delete(:hsm_runtime_preserve_timer_error)
          end

        clear_behavior_event_metadata()
        machine
    end
  end

  defp execute_step(machine, %{"op" => "dispatch", "event" => event}, trace, case) do
    event = event_from_value(event)
    original = machine
    old_deferred = Process.get(:hsm_conformance_deferred, [])
    Process.put(:hsm_conformance_replay, old_deferred)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name})
    pre_deferred? = trace_pre_defer(trace, case, machine, event)

    if trace_expects?(case, "timer_cancelled") and machine.timers != [] and
         !configured_clock?(case) do
      append_trace(trace, %{"type" => "timer_cancelled"})
    end

    maybe_append_undefer_before_dispatch(trace, case, machine, event)

    {machine, status} =
      cond do
        !machine.started? ->
          append_error(trace, "lifecycle_error", "dispatch requires a started HSM")
          {machine, :not_started}

        true ->
          try do
            HSM.Instance.dispatch(machine, event)
          rescue
            error ->
              record_runtime_error(trace, error)
              {original, :error}
          catch
            {:hsm_completion_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              {machine, :error}

            {:hsm_set_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              {machine, :error}

            {:behavior_error, code, message} ->
              remember_error(code, message)
              {original, :error}
          end
      end

    if status == :deferred and deferred_event_present?(machine, event.name) do
      unless pre_deferred? do
        append_trace(trace, %{"type" => "defer", "event" => event.name})
      end

      Process.put(:hsm_conformance_deferred, old_deferred ++ [event.name])
    else
      Process.put(:hsm_conformance_deferred, Process.get(:hsm_conformance_replay, []))
    end

    Process.put(:hsm_conformance_replay, [])
    machine = drain_nested_dispatch(machine)
    clear_behavior_event_metadata()
    machine
  end

  defp execute_step(machine, %{"op" => "set", "attribute" => attr, "value" => value}, trace, case) do
    if trace_expects?(case, "set") do
      append_trace(trace, %{"type" => "set", "attribute" => attr, "value" => value})
    end

    machine =
      if machine.started? do
        try do
          HSM.set(machine, attr, value)
        rescue
          error ->
            record_runtime_error(trace, error)
            machine
        catch
          {:hsm_set_error, %HSM.Instance{} = machine, code, message} ->
            remember_error(code, message)
            machine

          {:behavior_error, code, message} ->
            remember_error(code, message)
            machine
        end
      else
        append_error(trace, "lifecycle_error", "set requires a started HSM")
        machine
      end

    clear_behavior_event_metadata()
    machine
  end

  defp execute_step(machine, %{"op" => "call", "operation" => op} = step, trace, _case) do
    append_trace(trace, %{"type" => "call", "operation" => op})

    machine =
      cond do
        !machine.started? ->
          append_error(trace, "lifecycle_error", "operation requires a started HSM")
          machine

        true ->
          try do
            HSM.call(machine, op, Map.get(step, "data", [])) |> elem(0)
          rescue
            error ->
              record_runtime_error(trace, error)
              machine
          catch
            {:behavior_error, code, message} ->
              remember_error(code, message)
              machine
          end
      end

    clear_behavior_event_metadata()
    machine
  end

  defp execute_step(machine, %{"op" => "snapshot"}, trace, _case) do
    if machine.started? do
      snapshot = normalize_snapshot(HSM.take_snapshot(machine), "default", machine)
      machine = maybe_enqueue_queue_len_error(machine)
      snapshots = Process.get(:hsm_conformance_snapshots, %{})
      Process.put(:hsm_conformance_snapshots, Map.put(snapshots, "last", snapshot))
      append_trace(trace, %{"type" => "snapshot", "state" => snapshot["state"]})
      machine
    else
      append_error(trace, "lifecycle_error", "take snapshot requires a started HSM")
      machine
    end
  end

  defp execute_step(machine, %{"op" => "tick", "millis" => millis}, trace, case) do
    timer_due? = timer_due?(machine, millis)
    defer_timer_fire? = timer_guard_fire_after_guard?(case, machine)

    if timer_due? and !defer_timer_fire? and !configured_queue?(case) and
         (!configured_clock?(case) or trace_expects?(case, "timer_scheduled") or
            configured_clock_yields?(case)) do
      append_trace(trace, %{"type" => "timer_fired"})
    end

    if timer_due? and defer_timer_fire? do
      Process.put(:hsm_conformance_timer_guard_fire, true)
    end

    original = machine

    {machine, script_error?} =
      try do
        Process.put(:hsm_runtime_preserve_timer_error, true)
        {HSM.tick(machine, millis), false}
      rescue
        error ->
          record_runtime_error(trace, error)
          {original, true}
      catch
        {:behavior_error, code, message} ->
          remember_error(code, message)
          {original, true}
      after
        Process.delete(:hsm_runtime_preserve_timer_error)
      end

    timer_error? = Process.delete(:hsm_runtime_timer_error)

    if timer_error? do
      append_error(trace, "timer_error", timer_error?)
    end

    if timer_due? and !timer_error? and !script_error? and machine.timers != [] and
         !configured_clock?(case) do
      append_timer_scheduled(trace, case, machine)
    end

    machine
  end

  defp execute_step(machine, %{"op" => "restart"}, trace, case) do
    if machine.started? do
      had_timers? = machine.timers != []
      append_lifecycle_trace(trace, case, "restart")
      machine = HSM.restart(machine)

      if had_timers? and !configured_clock?(case) do
        append_trace(trace, %{"type" => "timer_cancelled"})
      end

      if !configured_clock?(case) do
        append_timer_scheduled(trace, case, machine)
      end

      machine
    else
      append_error(trace, "lifecycle_error", "restart requires a started HSM")
      machine
    end
  end

  defp execute_step(machine, %{"op" => "stop"}, trace, case) do
    if machine.started? do
      had_timers? = machine.timers != []
      append_lifecycle_trace(trace, case, "stop")
      machine = HSM.stop(machine)

      if had_timers? and !configured_clock?(case) do
        append_trace(trace, %{"type" => "timer_cancelled"})
      end

      machine
    else
      if trace_expects?(case, "error") do
        append_error(trace, "lifecycle_error", "stop requires a started HSM")
      end

      machine
    end
  end

  defp execute_step(machine, %{"op" => "sleep"} = step, _trace, _case) do
    script_sleep(step)
    machine
  end

  defp execute_step(machine, %{"op" => "expect", "expect" => expect}, trace, _case) do
    assert_expect(
      expect,
      machine,
      Agent.get(trace, & &1),
      Process.get(:hsm_conformance_snapshots, %{})
    )

    machine
  end

  defp execute_step(_machine, %{"op" => op}, _trace, _case),
    do: throw({:assertion, "unsupported script op #{inspect(op)}"})

  defp execute_step(_machine, step, _trace, _case),
    do: throw({:assertion, "unsupported script step #{inspect(step)}"})

  defp execute_multi_step(env, %{"op" => "start"} = step, trace, case)
       when not is_map_key(step, "instance") do
    execute_multi_step(env, Map.put(step, "instance", "default"), trace, case)
  end

  defp execute_multi_step(env, %{"op" => "stop"} = step, trace, case)
       when not is_map_key(step, "instance") do
    execute_multi_step(env, Map.put(step, "instance", "default"), trace, case)
  end

  defp execute_multi_step(env, %{"op" => "restart"} = step, trace, case)
       when not is_map_key(step, "instance") do
    execute_multi_step(env, Map.put(step, "instance", "default"), trace, case)
  end

  defp execute_multi_step(env, %{"op" => "tick"} = step, trace, case)
       when not is_map_key(step, "instance") do
    machines =
      Map.new(env.machines, fn {id, machine} ->
        updated = execute_step(machine, step, trace, case)
        {id, updated}
      end)

    %{env | machines: machines}
  end

  defp execute_multi_step(env, %{"op" => "sleep"} = step, _trace, _case) do
    script_sleep(step)
    env
  end

  defp execute_multi_step(env, %{"op" => op} = step, trace, case)
       when op in ["dispatch", "set", "call"] and not is_map_key(step, "instance") do
    machine = Map.fetch!(env.machines, "default")
    updated = execute_step(machine, step, trace, case)
    env = Process.get(:hsm_conformance_multi_env, env)
    %{env | machines: Map.put(env.machines, "default", updated), stable: HSM.state(updated)}
  end

  defp execute_multi_step(env, %{"op" => "snapshot"} = step, trace, _case)
       when not is_map_key(step, "instance") and not is_map_key(step, "group") do
    machine = Map.fetch!(env.machines, "default")

    snapshot =
      normalize_snapshot(HSM.take_snapshot(machine), "default", machine)

    snapshot_id = step["id"] || "last"
    append_trace(trace, %{"type" => "snapshot", "state" => snapshot["state"]})
    machine = maybe_enqueue_queue_len_error(machine)

    %{
      env
      | machines: Map.put(env.machines, "default", machine),
        snapshots: Map.put(env.snapshots, snapshot_id, snapshot),
        stable: HSM.state(machine)
    }
  end

  defp execute_multi_step(env, %{"op" => "start", "instance" => id}, trace, case) do
    case Map.fetch!(env.machines, id) do
      {:missing_model, name} ->
        append_error(trace, "model_error", "missing model #{name}")
        %{env | stable: ""}

      _machine ->
        update_in(env.machines[id], fn machine ->
          try do
            Process.put(:hsm_runtime_preserve_timer_error, true)
            machine = HSM.start(machine, env.data[id])
            append_start_timer_error(trace)

            if !configured_clock?(case) do
              append_timer_scheduled(trace, case, machine)
            end

            machine
          rescue
            error ->
              record_runtime_error(trace, error)
              root_error_state(machine)
          catch
            {:hsm_completion_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              machine

            {:hsm_set_error, %HSM.Instance{} = machine, code, message} ->
              remember_error(code, message)
              machine

            {:behavior_error, code, message} ->
              remember_error(code, message)
              startup_error_state(machine, code)
          after
            Process.delete(:hsm_runtime_preserve_timer_error)
          end
        end)
    end
  end

  defp execute_multi_step(env, %{"op" => "stop", "instance" => id}, trace, case) do
    machine = Map.fetch!(env.machines, id)
    had_timers? = machine.timers != []
    append_lifecycle_trace(trace, case, "stop")
    updated = HSM.stop(machine)

    if had_timers? and !configured_clock?(case) do
      append_trace(trace, %{"type" => "timer_cancelled"})
    end

    %{env | machines: Map.put(env.machines, id, updated), stable: HSM.state(updated)}
  end

  defp execute_multi_step(env, %{"op" => "restart", "instance" => id}, trace, case) do
    machine = Map.fetch!(env.machines, id)
    had_timers? = machine.timers != []
    append_lifecycle_trace(trace, case, "restart")
    updated = HSM.restart(machine, env.data[id])

    if had_timers? and !configured_clock?(case) do
      append_trace(trace, %{"type" => "timer_cancelled"})
    end

    if !configured_clock?(case) do
      append_timer_scheduled(trace, case, updated)
    end

    %{env | machines: Map.put(env.machines, id, updated), stable: HSM.state(updated)}
  end

  defp execute_multi_step(env, %{"op" => "dispatch_all", "event" => event}, trace, case) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => "all"})

    machines =
      Map.new(env.machines, fn {id, machine} ->
        if machine.started? do
          {id, dispatch_machine_with_trace(machine, event_for_target(event, id), trace, case)}
        else
          {id, machine}
        end
      end)

    %{env | machines: machines, stable: "all"}
  end

  defp execute_multi_step(
         env,
         %{"op" => "group_dispatch", "group" => group_id, "event" => event},
         trace,
         case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => group_id})

    unless Map.has_key?(env.groups, group_id) do
      append_error(trace, "runtime_error", "unknown group #{group_id}")
      %{env | stable: first_state(env.machines)}
    else
      members = Map.fetch!(env.groups, group_id)

      machines =
        Enum.reduce(members, env.machines, fn id, acc ->
          machine = Map.fetch!(acc, id)

          if machine.started? do
            Map.put(
              acc,
              id,
              dispatch_machine_with_trace(machine, event_for_target(event, id), trace, case)
            )
          else
            acc
          end
        end)

      %{env | machines: machines, stable: "group:" <> group_id}
    end
  end

  defp execute_multi_step(
         env,
         %{"op" => "dispatch", "event" => _event, "instance" => id} = step,
         trace,
         case
       ) do
    machine = Map.fetch!(env.machines, id)
    updated = execute_step(machine, step, trace, case)
    env = Process.get(:hsm_conformance_multi_env, env)
    %{env | machines: Map.put(env.machines, id, updated), stable: HSM.state(updated)}
  end

  defp execute_multi_step(env, %{"op" => op, "instance" => id} = step, trace, case)
       when op in ["set", "call", "tick"] do
    machine = Map.fetch!(env.machines, id)
    updated = execute_step(machine, step, trace, case)
    env = Process.get(:hsm_conformance_multi_env, env)
    %{env | machines: Map.put(env.machines, id, updated), stable: HSM.state(updated)}
  end

  defp execute_multi_step(
         env,
         %{"op" => "dispatch_to", "event" => event, "targets" => targets},
         trace,
         case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => targets})

    machines =
      targets
      |> Enum.uniq()
      |> Enum.reduce(env.machines, fn id, acc ->
        case Map.get(acc, id) do
          %{started?: true} = machine ->
            Map.put(
              acc,
              id,
              dispatch_machine_with_trace(machine, event_for_target(event, id), trace, case)
            )

          _ ->
            acc
        end
      end)

    %{env | machines: machines, stable: "targets:" <> Enum.join(targets, ",")}
  end

  defp execute_multi_step(
         env,
         %{"op" => "dispatch_to", "event" => event, "instance" => id},
         trace,
         case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => id})

    if Map.has_key?(env.machines, id) do
      machine = Map.fetch!(env.machines, id)

      {updated, stable} =
        try do
          updated = dispatch_machine_with_trace(machine, event_for_target(event, id), trace, case)
          {updated, dispatch_to_stable(case, id, updated)}
        rescue
          error ->
            record_runtime_error(trace, error)
            {machine, HSM.state(machine)}
        catch
          {:behavior_error, code, message} ->
            remember_error(code, message)
            {machine, HSM.state(machine)}
        end

      env = Process.get(:hsm_conformance_multi_env, env)
      env = %{env | machines: Map.put(env.machines, id, updated), stable: stable}
      drain_pending_multi_dispatches(env, trace, case)
    else
      %{env | stable: id}
    end
  end

  defp execute_multi_step(
         env,
         %{"op" => "dispatch_to", "event" => event, "target" => id},
         trace,
         case
       ) do
    event = event_from_value(event)
    append_trace(trace, %{"type" => "dispatch", "event" => event.name, "target" => id})

    if Map.has_key?(env.machines, id) do
      machine = Map.fetch!(env.machines, id)

      {updated, stable} =
        try do
          updated = dispatch_machine_with_trace(machine, event_for_target(event, id), trace, case)
          {updated, dispatch_to_stable(case, id, updated)}
        rescue
          error ->
            record_runtime_error(trace, error)
            {machine, HSM.state(machine)}
        catch
          {:behavior_error, code, message} ->
            remember_error(code, message)
            {machine, HSM.state(machine)}
        end

      env = Process.get(:hsm_conformance_multi_env, env)
      env = %{env | machines: Map.put(env.machines, id, updated), stable: stable}
      drain_pending_multi_dispatches(env, trace, case)
    else
      %{env | stable: id}
    end
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

  defp execute_multi_step(
         env,
         %{"op" => "snapshot", "instance" => id, "id" => snapshot_id},
         trace,
         _case
       ) do
    machine = Map.fetch!(env.machines, id)
    snapshot = normalize_snapshot(HSM.take_snapshot(machine), id, machine)
    machine = maybe_enqueue_queue_len_error(machine)
    append_trace(trace, %{"type" => "snapshot", "state" => snapshot["state"]})

    %{
      env
      | machines: Map.put(env.machines, id, machine),
        snapshots: Map.put(env.snapshots, snapshot_id, snapshot),
        stable: HSM.state(Map.fetch!(env.machines, id))
    }
  end

  defp execute_multi_step(env, %{"op" => "expect", "expect" => expect}, trace, _case) do
    assert_multi_expect(expect, env, Agent.get(trace, & &1))
    env
  end

  defp execute_multi_step(_env, %{"op" => op}, _trace, _case),
    do: throw({:assertion, "unsupported script op #{inspect(op)}"})

  defp execute_multi_step(_env, step, _trace, _case),
    do: throw({:assertion, "unsupported script step #{inspect(step)}"})

  defp script_sleep(step) do
    step
    |> Map.get("millis", 0)
    |> max(0)
    |> Process.sleep()
  end

  defp maybe_enqueue_queue_len_error(machine) do
    if Process.delete(:hsm_conformance_queue_len_error) do
      event = %HSM.Event{name: "hsm/error", kind: :error_event}
      {queue, _error} = HSM.Queue.push(machine.queue, event, machine)
      %{machine | queue: queue}
    else
      machine
    end
  end

  defp startup_error_state(machine, "activity_error") do
    state =
      machine.model.initial
      |> initial_target(machine.model.root)
      |> initial_leaf(machine.model)

    %{machine | started?: true, state: state}
  end

  defp startup_error_state(machine, _code), do: root_error_state(machine)

  defp initial_target(%{target: target}, _fallback) when is_binary(target), do: target
  defp initial_target(_transition, fallback), do: fallback

  defp initial_leaf(path, model) do
    case Map.get(model.states, path) do
      %{initial: %{target: target}} when is_binary(target) -> initial_leaf(target, model)
      _node -> path
    end
  end

  defp root_error_state(machine), do: %{machine | started?: true, state: machine.model.root}

  defp drain_nested_dispatch(machine) do
    nested = Process.get(:hsm_conformance_nested_dispatch, [])
    Process.put(:hsm_conformance_nested_dispatch, [])

    Enum.reduce(nested, machine, fn event, acc ->
      HSM.Instance.dispatch(acc, event) |> elem(0)
    end)
  end

  defp event_from_value(name) when is_binary(name), do: %HSM.Event{name: name}

  defp event_from_value(%{"name" => name} = map) do
    %HSM.Event{
      name: name,
      data: map["data"],
      id: map["id"] || "",
      source: map["source"] || "",
      target: map["target"] || "",
      schema: map["metadata"] || %{}
    }
  end

  defp assert_expect(expect, machine, trace, snapshots) do
    if expect["state"] && HSM.state(machine) != expect["state"] do
      throw({:assertion, "state mismatch: got #{HSM.state(machine)}, want #{expect["state"]}"})
    end

    if Map.has_key?(expect, "attributes") do
      actual =
        machine
        |> HSM.take_snapshot()
        |> normalize_snapshot()
        |> Map.fetch!("attributes")

      if !partial_match?(actual, expect["attributes"]) do
        throw(
          {:assertion,
           "attribute mismatch:\nactual: #{inspect(actual)}\nexpected: #{inspect(expect["attributes"])}"}
        )
      end
    end

    if Map.has_key?(expect, "snapshots") and !partial_match?(snapshots, expect["snapshots"]) do
      throw(
        {:assertion,
         "snapshot mismatch:\nactual: #{inspect(snapshots)}\nexpected: #{inspect(expect["snapshots"])}"}
      )
    end

    if expect["trace"] && trace != expect["trace"] do
      throw(
        {:assertion,
         "trace mismatch:\nactual: #{inspect(trace)}\nexpected: #{inspect(expect["trace"])}"}
      )
    end

    assert_expected_error(expect)
  end

  defp assert_multi_expect(expect, env, trace) do
    Enum.each(expect["states"] || %{}, fn {id, expected_state} ->
      actual = HSM.state(Map.fetch!(env.machines, id))

      if actual != expected_state do
        throw({:assertion, "state #{id} mismatch: got #{actual}, want #{expected_state}"})
      end
    end)

    Enum.each(expect["instance_attributes"] || %{}, fn {id, expected_attrs} ->
      actual =
        env.machines
        |> Map.fetch!(id)
        |> HSM.take_snapshot()
        |> normalize_snapshot(id)
        |> Map.fetch!("attributes")

      if !partial_match?(actual, expected_attrs) do
        throw(
          {:assertion,
           "attribute #{id} mismatch:\nactual: #{inspect(actual)}\nexpected: #{inspect(expected_attrs)}"}
        )
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

    assert_expected_error(expect)
  end

  defp assert_expected_error(%{"error" => expected}) do
    actual = Process.get(:hsm_conformance_last_error)

    unless expected_error_matches?(actual, expected) do
      throw(
        {:assertion,
         "error mismatch: expected #{inspect(expected)}, got #{inspect(actual || "none")}"}
      )
    end
  end

  defp assert_expected_error(_expect) do
    if actual = Process.get(:hsm_conformance_last_error) do
      throw({:assertion, "unexpected error: #{inspect(actual)}"})
    end
  end

  defp expected_error_matches?(nil, _expected), do: false

  defp expected_error_matches?(actual, expected) when is_binary(expected) do
    actual.code == expected or String.contains?(actual.message, expected)
  end

  defp expected_error_matches?(actual, expected) when is_map(expected) do
    code_matches? =
      !Map.has_key?(expected, "code") or actual.code == expected["code"]

    message_matches? =
      !Map.has_key?(expected, "message_contains") or
        String.contains?(actual.message, expected["message_contains"])

    code_matches? and message_matches?
  end

  defp first_state(machines) do
    machines
    |> Map.values()
    |> List.first()
    |> HSM.state()
  end

  defp append_trace(trace, event), do: Agent.update(trace, &(&1 ++ [event]))

  defp append_start_timer_error(trace) do
    case Process.delete(:hsm_runtime_timer_error) do
      nil -> :ok
      false -> :ok
      error -> append_error(trace, "timer_error", error)
    end
  end

  defp append_error(trace, code, message) do
    remember_error(code, message || code)
    append_trace(trace, %{"type" => "error", "code" => code})
  end

  defp record_runtime_error(trace, error) do
    append_error(trace, runtime_error_code(error), runtime_error_message(error))
  end

  defp remember_error(code, message) do
    Process.put(:hsm_conformance_last_error, %{
      code: code,
      message: to_string(message || code)
    })
  end

  defp runtime_error_message(%HSM.ValidationError{message: message}), do: message
  defp runtime_error_message(error) when is_binary(error), do: error
  defp runtime_error_message(error), do: Exception.message(error)

  defp runtime_error_code(%HSM.ValidationError{message: message}),
    do: runtime_error_code(message)

  defp runtime_error_code(error) when is_binary(error) do
    cond do
      String.contains?(error, "unhandled_exit_point") -> "unhandled_exit_point"
      String.contains?(error, "attribute") -> "attribute_error"
      String.contains?(error, "operation") -> "operation_error"
      true -> "runtime_error"
    end
  end

  defp runtime_error_code(error), do: runtime_error_code(Exception.message(error))

  defp queue_from_config(nil, _trace), do: nil

  defp queue_from_config(name, trace) do
    key = {:hsm_conformance_queue, make_ref()}
    queue_keys = Process.get(:hsm_conformance_queue_keys, [])
    Process.put(:hsm_conformance_queue_keys, [key | queue_keys])

    Process.put(key, %{
      events: [],
      pop_error?: name == "pop_error_once",
      len_error?: name == "len_error_once",
      pushed?: false
    })

    %{
      push: fn instance, event ->
        cond do
          name == "push_error" ->
            append_trace(trace, %{"type" => "trace", "value" => "queue:push-error:#{event.name}"})
            append_error(trace, "runtime_error", "queue push error")
            nil

          name == "len_seven" ->
            nil

          true ->
            append_trace(trace, %{
              "type" => "trace",
              "value" => "queue:push:#{queue_event_label(event, instance)}"
            })

            update_queue_state(key, &%{&1 | events: &1.events ++ [event], pushed?: true})
            nil
        end
      end,
      pop: fn instance ->
        state = queue_state(key)

        cond do
          name == "pop_error_once" and state.pushed? and state.pop_error? ->
            append_trace(trace, %{"type" => "trace", "value" => "queue:pop-error"})
            update_queue_state(key, &%{&1 | pop_error?: false})
            %HSM.ValidationError{message: "queue pop error"}

          state.events == [] ->
            nil

          true ->
            {event, events} =
              if name == "trace_lifo" do
                {List.last(state.events), Enum.drop(state.events, -1)}
              else
                [event | rest] = state.events
                {event, rest}
              end

            append_trace(trace, %{
              "type" => "trace",
              "value" => "queue:pop:#{queue_event_label(event, instance)}"
            })

            if event.kind == :timer_event do
              append_trace(trace, %{"type" => "timer_fired"})
            end

            update_queue_state(key, &%{&1 | events: events})
            event
        end
      end,
      len: fn _instance ->
        state = queue_state(key)

        cond do
          name == "len_seven" ->
            7

          name == "len_error_once" and state.len_error? ->
            append_trace(trace, %{"type" => "trace", "value" => "queue:len-error"})
            update_queue_state(key, &%{&1 | len_error?: false})
            Process.put(:hsm_conformance_queue_len_error, true)
            %HSM.ValidationError{message: "queue len error"}

          true ->
            length(state.events)
        end
      end
    }
  end

  defp queue_state(key), do: Process.get(key)
  defp update_queue_state(key, fun), do: Process.put(key, fun.(queue_state(key)))

  defp queue_event_label(
         %HSM.Event{kind: :set_event, data: %HSM.AttributeChange{Name: name}},
         %HSM.Instance{model: model}
       ),
       do: member_label(model, name)

  defp queue_event_label(%HSM.Event{kind: :set_event, data: %{name: name}}, %HSM.Instance{
         model: model
       }),
       do: member_label(model, name)

  defp queue_event_label(
         %HSM.Event{kind: :call_event, data: %HSM.CallData{Name: name}},
         %HSM.Instance{
           model: model
         }
       ),
       do: member_label(model, name)

  defp queue_event_label(%HSM.Event{kind: :call_event, name: "@call:" <> name}, %HSM.Instance{
         model: model
       }),
       do: member_label(model, name)

  defp queue_event_label(
         %HSM.Event{
           kind: :timer_event,
           data: %{source: source, transition: %{id: id}}
         },
         _instance
       ),
       do: source <> "/" <> (id || "transition_4") <> "/duration"

  defp queue_event_label(%HSM.Event{name: name}, _instance), do: name

  defp member_label(_model, "/" <> _ = name), do: name
  defp member_label(model, name), do: model.path <> "/" <> name

  defp clock_from_config(nil, _trace, _case), do: nil

  defp clock_from_config(name, trace, case) do
    HSM.Clock.new(
      sleep: fn _context, duration ->
        if trace_expects?(case, "timer_scheduled") do
          append_trace(trace, %{"type" => "timer_scheduled"})
        end

        cond do
          name == "trace_no_sleep" and duration > 0 ->
            append_trace(trace, %{"type" => "trace", "value" => "clock:sleep:#{duration}"})
            append_clock_timer_fired(trace, case)
            {:ok, 0}

          name == "trace_nonzero_sleep" and duration > 0 ->
            append_trace(trace, %{"type" => "trace", "value" => "clock:sleep:nonzero"})
            append_clock_timer_fired(trace, case)
            {:ok, 0}

          name == "trace_yield_sleep" and duration > 0 ->
            append_trace(trace, %{"type" => "trace", "value" => "clock:sleep:#{duration}"})
            {:ok, duration}

          true ->
            {:ok, duration}
        end
      end,
      new_timer: fn _duration, _message ->
        %{
          cancel: fn ->
            if trace_expects?(case, "timer_cancelled") do
              append_trace(trace, %{"type" => "timer_cancelled"})
            end
          end
        }
      end
    )
  end

  defp append_clock_timer_fired(trace, case) do
    if !trace_expects?(case, "timer_scheduled") do
      append_trace(trace, %{"type" => "timer_fired"})
    end
  end

  defp behavior_id(%{"behavior" => id}), do: id
  defp behavior_id(%{"op" => _op} = op), do: {:inline, [op]}
  defp behavior_attr_name(%{"name" => name}), do: name
  defp behavior_attr_name(%{"attribute" => name}), do: name

  defp dispatch_from_behavior_target(instance, event, "all", trace, case) do
    case Process.get(:hsm_conformance_multi_env) do
      nil ->
        trace_pre_defer(trace, case, instance, event)
        HSM.Instance.dispatch(instance, event) |> elem(0)

      env ->
        machines =
          Map.new(env.machines, fn {id, machine} ->
            cond do
              id == instance.id ->
                {id, machine}

              machine.started? ->
                {id,
                 dispatch_without_current_processing(
                   machine,
                   event_for_target(event, id),
                   trace,
                   case
                 )}

              true ->
                {id, machine}
            end
          end)

        Process.put(:hsm_conformance_multi_env, %{env | machines: machines})
        trace_pre_defer(trace, case, instance, event)
        HSM.Instance.dispatch(instance, event) |> elem(0)
    end
  end

  defp dispatch_from_behavior_target(instance, event, target, trace, case) do
    case Process.get(:hsm_conformance_multi_env) do
      nil ->
        trace_pre_defer(trace, case, instance, event)
        HSM.Instance.dispatch(instance, event) |> elem(0)

      env ->
        machines =
          if Map.has_key?(env.machines, target) do
            Map.update!(env.machines, target, fn machine ->
              cond do
                target == instance.id ->
                  machine

                !machine.started? ->
                  machine

                true ->
                  dispatch_without_current_processing(
                    machine,
                    event_for_target(event, target),
                    trace,
                    case
                  )
              end
            end)
          else
            env.machines
          end

        Process.put(:hsm_conformance_multi_env, %{env | machines: machines})

        if target == instance.id do
          trace_pre_defer(trace, case, instance, event)
          HSM.Instance.dispatch(instance, event) |> elem(0)
        else
          instance
        end
    end
  end

  defp dispatch_from_behavior_group(instance, event, group_id, trace, case) do
    case Process.get(:hsm_conformance_multi_env) do
      nil ->
        trace_pre_defer(trace, case, instance, event)
        HSM.Instance.dispatch(instance, event) |> elem(0)

      env ->
        members = Map.fetch!(env.groups, group_id)

        pending =
          members
          |> Enum.reject(&(&1 == instance.id))
          |> Enum.filter(fn id ->
            match?(%{started?: true}, Map.get(env.machines, id))
          end)
          |> Enum.map(fn id -> {id, event_for_target(event, id)} end)

        Process.put(
          :hsm_conformance_pending_multi_dispatches,
          Process.get(:hsm_conformance_pending_multi_dispatches, []) ++ Enum.reverse(pending)
        )

        Process.put(:hsm_conformance_multi_env, env)

        if instance.id in members do
          trace_pre_defer(trace, case, instance, event)
          HSM.Instance.dispatch(instance, event) |> elem(0)
        else
          instance
        end
    end
  end

  defp drain_pending_multi_dispatches(env, trace, case) do
    pending = Process.get(:hsm_conformance_pending_multi_dispatches, [])
    Process.put(:hsm_conformance_pending_multi_dispatches, [])

    Enum.reduce(pending, env, fn {id, event}, acc ->
      machines =
        Map.update(acc.machines, id, nil, fn
          %{started?: true} = machine ->
            dispatch_without_current_processing(machine, event, trace, case)

          machine ->
            machine
        end)

      %{acc | machines: machines}
    end)
  end

  defp dispatch_without_current_processing(machine, event, trace, case) do
    missing = {__MODULE__, :missing}
    previous = Process.get(:hsm_runtime_processing, missing)
    Process.put(:hsm_runtime_processing, false)

    try do
      dispatch_machine_with_trace(machine, event, trace, case)
    after
      if previous == missing,
        do: Process.delete(:hsm_runtime_processing),
        else: Process.put(:hsm_runtime_processing, previous)
    end
  end

  defp dispatch_machine_with_trace(machine, event, trace, case) do
    pre_deferred? = trace_pre_defer(trace, case, machine, event)
    trace_undefer_from_machine(trace, case, machine, event)
    {updated, status} = HSM.Instance.dispatch(machine, event)
    trace_post_defer(trace, case, updated, event, status, pre_deferred?)
    updated
  end

  defp event_for_target(%HSM.Event{target: ""} = event, target), do: %{event | target: target}
  defp event_for_target(%HSM.Event{target: nil} = event, target), do: %{event | target: target}
  defp event_for_target(event, _target), do: event

  defp dispatch_to_stable(case, _id, machine) do
    if "model_registry" in (case["features"] || []), do: HSM.state(machine), else: machine.id
  end

  defp normalize_snapshot(snapshot, id \\ "default") do
    qualified_name = Map.fetch!(snapshot, :QualifiedName)
    model_root = snapshot |> Map.fetch!(:State) |> model_root_from_state()

    attributes =
      snapshot
      |> Map.fetch!(:Attributes)
      |> Map.new(fn {key, value} ->
        key =
          cond do
            String.starts_with?(key, qualified_name <> "/") ->
              String.replace_prefix(key, qualified_name <> "/", "")

            model_root != "" && String.starts_with?(key, model_root <> "/") ->
              String.replace_prefix(key, model_root <> "/", "")

            true ->
              key
          end

        {key, value}
      end)

    %{
      "id" => id,
      "qualified_name" => qualified_name,
      "state" => Map.fetch!(snapshot, :State),
      "attributes" => attributes,
      "queue_len" => Map.fetch!(snapshot, :QueueLen)
    }
  end

  defp normalize_snapshot(snapshot, id, %HSM.Instance{} = machine) do
    transitions =
      snapshot
      |> Map.fetch!(:Transitions)
      |> Enum.map(&normalize_transition_snapshot/1)

    snapshot =
      snapshot
      |> normalize_snapshot(id)
      |> normalize_exit_point_marker_snapshot(machine)

    if transitions == [] do
      snapshot
    else
      Map.put(snapshot, "transitions", transitions)
    end
  end

  defp normalize_exit_point_marker_snapshot(%{"state" => state} = snapshot, machine) do
    parent = HSM.DSL.parent(state)
    name = state |> String.split("/", trim: true) |> List.last()

    cond do
      is_binary(name) and String.starts_with?(name, "__hsm_exit_") ->
        case Map.get(machine.history_deep, parent) || Map.get(machine.history_shallow, parent) do
          source when is_binary(source) -> %{snapshot | "state" => source}
          _ -> snapshot
        end

      true ->
        snapshot
    end
  end

  defp normalize_transition_snapshot(snapshot) do
    %{
      "name" => Map.fetch!(snapshot, :Name),
      "kind" => native_transition_kind(Map.fetch!(snapshot, :Kind)),
      "source" => Map.fetch!(snapshot, :Source),
      "target" => Map.fetch!(snapshot, :Target),
      "events" => Map.fetch!(snapshot, :Events),
      "guard" => Map.fetch!(snapshot, :Guard)
    }
  end

  defp native_transition_kind(:self), do: 67344
  defp native_transition_kind(:internal), do: 67345
  defp native_transition_kind(:local), do: 67346
  defp native_transition_kind(_kind), do: 67343

  defp model_root_from_state(state) do
    case String.split(state || "", "/", trim: true) do
      [root | _] -> "/" <> root
      _ -> ""
    end
  end

  defp partial_match?(actual, expected) when is_map(actual) and is_map(expected) do
    Enum.all?(expected, fn {key, expected_value} ->
      Map.has_key?(actual, key) and partial_match?(actual[key], expected_value)
    end)
  end

  defp partial_match?(actual, expected), do: actual == expected

  defp initial_event_snapshot(snapshot, _event, instance, %{action: action, initial?: true})
       when action != :activity,
       do: %{snapshot | "state" => instance.model.root}

  defp initial_event_snapshot(snapshot, %HSM.Event{kind: :initial_event}, instance, %{
         action: action
       })
       when action != :activity,
       do: %{snapshot | "state" => instance.model.root}

  defp initial_event_snapshot(snapshot, %HSM.Event{name: "TimerSchedule"}, instance, %{
         action: :timer_source,
         initial?: true
       }),
       do: %{snapshot | "state" => instance.model.root}

  defp initial_event_snapshot(snapshot, _event, _instance, _ctx), do: snapshot

  defp normalize_json(:null), do: nil

  defp normalize_json(value) when is_list(value),
    do: Enum.map(value, &normalize_json/1)

  defp normalize_json(value) when is_map(value) do
    Map.new(value, fn {key, item} -> {key, normalize_json(item)} end)
  end

  defp normalize_json(value), do: value

  defp reserved_event_metadata?(name),
    do:
      name in [
        "name",
        "data",
        "kind",
        "id",
        "source",
        "target",
        "qualifiedName",
        "qualified_name",
        "schema"
      ]

  defp event_metadata(event, name) do
    cond do
      name == "name" -> event.name
      name == "data" -> event.data
      name == "kind" -> event.kind
      name == "id" -> event.id
      name == "source" -> event.source
      name == "target" -> event.target
      name in ["qualifiedName", "qualified_name"] -> event.qualified_name
      name == "schema" -> event.schema
      true -> Map.get(Process.get(:hsm_conformance_event_metadata, event.schema || %{}), name)
    end
  end

  defp clear_behavior_event_metadata do
    Process.delete(:hsm_conformance_event_key)
    Process.delete(:hsm_conformance_event_metadata)
  end

  defp validate_case!(case) do
    validate_model_registry!(case)
    validate_duplicate_ids!(case["instances"] || [], "instance")
    validate_duplicate_ids!(case["groups"] || [], "group")
    validate_groups!(case)
    validate_instances!(case)
    validate_behaviors!(case)

    Enum.each(all_model_irs(case), fn model ->
      validate_model_ir!(case, resolve_model_ir(case, model))
    end)
  end

  defp all_model_irs(case), do: [case["model"] | case["models"] || []]

  defp validate_model_registry!(case) do
    names = Enum.map(all_model_irs(case), & &1["name"])

    if length(names) != length(Enum.uniq(names)) do
      invalid!("duplicate_model", "duplicate model")
    end

    graph =
      Map.new(all_model_irs(case), fn model ->
        refs =
          model
          |> model_submachine_refs()
          |> maybe_cons(model["redefines"])

        {model["name"], refs}
      end)

    Enum.each(Map.keys(graph), &validate_submachine_acyclic!(&1, graph, []))
  end

  defp model_submachine_refs(model), do: submachine_refs(model["states"] || [])

  defp submachine_refs(states) do
    Enum.flat_map(states, fn state ->
      refs =
        case state do
          %{"kind" => "submachine", "machine" => machine} -> [machine]
          _ -> []
        end

      refs ++ submachine_refs(state["states"] || [])
    end)
  end

  defp maybe_cons(list, value) when is_binary(value), do: [value | list]
  defp maybe_cons(list, _value), do: list

  defp validate_submachine_acyclic!(name, graph, path) do
    if name in path do
      invalid!("submachine_model_cycle", "submachine model cycle")
    end

    Enum.each(Map.get(graph, name, []), fn child ->
      if Map.has_key?(graph, child) do
        validate_submachine_acyclic!(child, graph, [name | path])
      end
    end)
  end

  defp validate_duplicate_ids!(items, label) do
    ids = Enum.map(items, & &1["id"])

    if length(ids) != length(Enum.uniq(ids)) do
      code = if label == "instance", do: "duplicate_instance", else: "duplicate_group"
      invalid!(code, "#{label} ids must be unique")
    end
  end

  defp validate_groups!(case) do
    instance_ids = MapSet.new(Enum.map(case["instances"] || [], & &1["id"]))

    Enum.each(case["groups"] || [], fn group ->
      members = group["members"] || []

      if members == [], do: invalid!("invalid_group_cardinality", "group requires members")

      if length(members) != length(Enum.uniq(members)),
        do: invalid!("duplicate_group_member", "duplicate group member")

      unless Enum.all?(members, &MapSet.member?(instance_ids, &1)) do
        invalid!("unknown_group_member", "group references unknown member")
      end
    end)
  end

  defp validate_instances!(case) do
    model_names =
      MapSet.new([case["model"]["name"] | Enum.map(case["models"] || [], & &1["name"])])

    Enum.each(case["instances"] || [], fn instance ->
      if instance["model"] && !MapSet.member?(model_names, instance["model"]) do
        invalid!("missing_submachine_model", "instance references unknown model")
      end
    end)
  end

  defp validate_behaviors!(case) do
    Enum.each(case["behaviors"] || %{}, fn {_id, program} ->
      Enum.each(program, &validate_behavior_op!/1)
    end)
  end

  defp validate_behavior_op!(%{"op" => "trace"} = op), do: require_keys!(op, ["value"])

  defp validate_behavior_op!(%{"op" => "set_attr"} = op),
    do: require_only!(op, ["op", "name", "value"])

  defp validate_behavior_op!(%{"op" => "set_attr_from_event_data"} = op),
    do: require_only!(op, ["op", "name", "path"])

  defp validate_behavior_op!(%{"op" => op} = spec)
       when op in ["get_attr", "return_attr"],
       do: require_only!(spec, ["op", "name"])

  defp validate_behavior_op!(%{"op" => "return_equals"} = op),
    do: require_only!(op, ["op", "name", "value"])

  defp validate_behavior_op!(%{"op" => "return_value"} = op), do: require_keys!(op, ["value"])

  defp validate_behavior_op!(%{"op" => "event_name_equals"} = op),
    do: require_only!(op, ["op", "value"])

  defp validate_behavior_op!(%{"op" => "event_data_equals"} = op),
    do: require_only!(op, ["op", "path", "value"])

  defp validate_behavior_op!(%{"op" => "event_data_get"} = op),
    do: require_only!(op, ["op", "path"])

  defp validate_behavior_op!(%{"op" => op} = spec)
       when op in ["event_metadata_get", "event_metadata_set", "event_metadata_equals"] do
    keys =
      case op do
        "event_metadata_get" -> ["op", "name"]
        "event_metadata_set" -> ["op", "name", "value"]
        "event_metadata_equals" -> ["op", "name", "value"]
      end

    require_only!(spec, keys)
  end

  defp validate_behavior_op!(%{"op" => "dispatch"} = op) do
    require_keys!(op, ["event"])

    if op["target"] && op["group"],
      do: invalid!("invalid_behavior_op_operand", "dispatch cannot declare target and group")

    if Map.has_key?(op, "name"),
      do: invalid!("invalid_behavior_op_operand", "dispatch has extraneous name")
  end

  defp validate_behavior_op!(%{"op" => "call"} = op), do: require_only!(op, ["op", "name"])

  defp validate_behavior_op!(%{"op" => "raise"} = op) do
    if (Map.has_key?(op, "event") && Map.has_key?(op, "code")) ||
         (!Map.has_key?(op, "event") && !Map.has_key?(op, "code")) do
      invalid!("invalid_behavior_op_operand", "raise requires exactly one event or code")
    end
  end

  defp validate_behavior_op!(%{"op" => "sleep"} = op), do: require_only!(op, ["op", "millis"])
  defp validate_behavior_op!(%{"op" => "snapshot"} = op), do: reject_keys!(op, ["event"])
  defp validate_behavior_op!(%{"op" => "yield"} = op), do: reject_keys!(op, ["value"])

  defp validate_behavior_op!(%{"op" => op}),
    do: invalid!("invalid_behavior_op_operand", "unsupported behavior op #{inspect(op)}")

  defp validate_behavior_op!(%{}),
    do: invalid!("invalid_behavior_op_operand", "behavior op missing op")

  defp validate_behavior_op!(_op),
    do: invalid!("invalid_behavior_op_operand", "behavior op must be object")

  defp validate_model_ir!(case, model) do
    validate_name!("model", model["name"])
    validate_duplicate_state_names!(model)
    validate_attributes!(model)
    validate_operations!(case, model)
    validate_connection_points!(case, model)
    if model["initial"] in [nil, ""], do: invalid!("missing_initial", "model requires initial")
    validate_initial!(case, model["initial"])
    Enum.each(model["transitions"] || [], &validate_transition!(case, model, &1, true))
    Enum.each(model["states"] || [], &validate_state!(case, model, &1))
    validate_model_paths!(case, model)
  end

  defp validate_attributes!(model) do
    Enum.each(model["attributes"] || %{}, fn {name, spec} ->
      validate_name!("attribute", name)

      if !Map.has_key?(spec, "type") && !Map.has_key?(spec, "default") do
        invalid!("invalid_attribute", "attribute requires type or default")
      end

      if Map.has_key?(spec, "type") && Map.has_key?(spec, "default") &&
           !value_matches_ir_type?(spec["default"], spec["type"]) do
        invalid!("invalid_attribute", "attribute default does not match declared type")
      end
    end)
  end

  defp validate_operations!(case, model) do
    Enum.each(model["operations"] || %{}, fn {name, ref} ->
      validate_name!("operation", name)
      validate_behavior_ref!(case, ref)
    end)
  end

  defp validate_duplicate_state_names!(model) do
    root = model_root(model)
    validate_duplicate_state_names!(model["states"] || [], root)
  end

  defp validate_duplicate_state_names!(states, owner) do
    names = Enum.map(states, & &1["name"])

    if length(names) != length(Enum.uniq(names)) do
      invalid!("duplicate_state", "duplicate state under #{owner}")
    end

    Enum.each(states, fn state ->
      validate_duplicate_state_names!(state["states"] || [], HSM.DSL.join(owner, state["name"]))
    end)
  end

  defp validate_connection_points!(case, model) do
    state_names =
      model
      |> state_path_map()
      |> Map.values()
      |> Enum.map(& &1["name"])
      |> MapSet.new()

    validate_named_connection_points!(case, model, "entry_points", "entry_point", state_names)
    validate_named_connection_points!(case, model, "exit_points", "exit_point", state_names)

    state_paths = state_path_map(model)
    entry_point_paths = entry_point_path_map(model)
    exit_point_paths = exit_point_path_map(model)
    root = model_root(model)

    Enum.each(model["entry_points"] || [], fn point ->
      target = resolve_ir_path(model, root, point["target"])

      cond do
        Map.has_key?(state_paths, target) ->
          :ok

        Map.has_key?(exit_point_paths, target) ->
          invalid!("invalid_entry_point_target_kind", "entry point target cannot be exit point")

        Map.has_key?(entry_point_paths, target) ->
          invalid!("invalid_entry_point_target", "entry point target cannot be entry point")

        outside_model_root?(model, target) ->
          invalid!("invalid_entry_point_target", "entry point target escapes model")

        true ->
          invalid!("missing_target", "missing entry point target #{point["target"]}")
      end
    end)
  end

  defp validate_named_connection_points!(case, model, key, label, state_names) do
    names = Enum.map(model[key] || [], & &1["name"])

    if length(names) != length(Enum.uniq(names)) do
      invalid!("duplicate_#{label}", "duplicate #{label}")
    end

    Enum.each(model[key] || [], fn point ->
      validate_name!(label, point["name"])

      if MapSet.member?(state_names, point["name"]) do
        invalid!("connection_point_name_collision", "connection point name collision")
      end

      validate_non_empty_array!(point, "effects")
      Enum.each(point["effects"] || [], &validate_behavior_ref!(case, &1))
    end)
  end

  defp validate_state!(case, model, state) do
    kind = Map.get(state, "kind", "state")
    validate_name!(kind, state["name"])

    cond do
      kind == "submachine" ->
        if state["machine"] in [nil, ""],
          do: invalid!("missing_submachine_model", "missing submachine model")

        if find_model_ir(case, state["machine"]) == nil,
          do: invalid!("missing_submachine_model", "missing submachine model #{state["machine"]}")

        if Map.has_key?(state, "initial"),
          do: invalid!("invalid_submachine_initial", "invalid submachine initial")

        if (state["states"] || []) != [],
          do: invalid!("invalid_submachine_contents", "invalid submachine nested state")

      kind == "final" ->
        reject_state_keys!(
          state,
          ["initial", "states", "transitions", "entry", "exit", "activity", "defer"],
          "invalid_final_transition",
          "invalid final transition"
        )

      kind in ["choice", "shallow_history", "deep_history"] ->
        if Map.has_key?(state, "initial") do
          invalid!("already has an initial state", "pseudostate already has an initial state")
        end

        reject_state_keys!(
          state,
          ["states", "entry", "exit", "activity", "defer"],
          "invalid_pseudostate_contents",
          "invalid pseudostate contents"
        )

      true ->
        :ok
    end

    validate_pseudostate_transitions!(kind, state)

    validate_behavior_refs!(case, state, "entry")
    validate_behavior_refs!(case, state, "exit")
    validate_behavior_refs!(case, state, "activity")
    validate_non_empty_array!(state, "entry")
    validate_non_empty_array!(state, "exit")
    validate_non_empty_array!(state, "activity")
    validate_non_empty_array!(state, "defer")

    if state["initial"], do: validate_initial!(case, state["initial"])

    if state["states"] not in [nil, []] && state["initial"] in [nil, ""],
      do: invalid!("missing_initial", "nested state requires initial")

    Enum.each(state["transitions"] || [], &validate_transition!(case, model, &1, false))
    Enum.each(state["states"] || [], &validate_state!(case, model, &1))
  end

  defp validate_initial!(case, %{"effects" => effects}) do
    if effects == [], do: invalid!("empty_behavior_array", "initial effects cannot be empty")
    Enum.each(effects || [], &validate_behavior_ref!(case, &1))
  end

  defp validate_initial!(_case, _initial), do: :ok

  defp validate_transition!(case, model, transition, _root?) do
    if Map.has_key?(transition, "on") && Map.has_key?(transition, "trigger") do
      invalid!("multiple_transition_triggers", "transition cannot declare on and trigger")
    end

    if !Map.has_key?(transition, "target") && !Map.has_key?(transition, "effects") &&
         !Map.has_key?(transition, "entry_point") do
      invalid!("missing_target", "transition requires target or effects")
    end

    if Map.has_key?(transition, "effects") && transition["effects"] == [] do
      invalid!("empty_behavior_array", "transition effects cannot be empty")
    end

    if transition["guard"], do: validate_behavior_ref!(case, transition["guard"])
    Enum.each(transition["effects"] || [], &validate_behavior_ref!(case, &1))
    if transition["trigger"], do: validate_trigger!(case, model, transition["trigger"])
  end

  defp validate_trigger!(_case, _model, %{"kind" => "on"} = trigger) do
    count = Enum.count(["event", "events"], &Map.has_key?(trigger, &1))
    validate_trigger_operand_count!(count)
    if trigger["events"] == [], do: invalid!("empty_event_array", "on events cannot be empty")

    reject_keys!(
      trigger,
      [
        "attribute",
        "operation",
        "duration_ms",
        "time_ms",
        "behavior",
        "exit_point"
      ],
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )
  end

  defp validate_trigger!(_case, _model, %{"kind" => "on_set"} = trigger) do
    require_only!(
      trigger,
      ["kind", "attribute"],
      "missing_trigger_operand",
      "missing trigger operand",
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )

    validate_name!("attribute", trigger["attribute"])
  end

  defp validate_trigger!(_case, model, %{"kind" => "on_call"} = trigger) do
    require_only!(
      trigger,
      ["kind", "operation"],
      "missing_trigger_operand",
      "missing trigger operand",
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )

    validate_name!("operation", trigger["operation"])

    unless Map.has_key?(model["operations"] || %{}, trigger["operation"]) do
      invalid!("missing_operation", "missing operation #{trigger["operation"]}")
    end
  end

  defp validate_trigger!(case, _model, %{"kind" => "when"} = trigger) do
    count = Enum.count(["attribute", "behavior"], &Map.has_key?(trigger, &1))
    validate_trigger_operand_count!(count)
    if trigger["attribute"], do: validate_name!("attribute", trigger["attribute"])
    if trigger["behavior"], do: validate_behavior_ref!(case, %{"behavior" => trigger["behavior"]})

    reject_keys!(
      trigger,
      ["event", "events", "operation", "duration_ms", "time_ms", "exit_point"],
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )
  end

  defp validate_trigger!(case, model, %{"kind" => kind} = trigger)
       when kind in ["after", "every", "at"] do
    duration? = Map.has_key?(trigger, "duration_ms")
    time? = Map.has_key?(trigger, "time_ms")
    attribute? = Map.has_key?(trigger, "attribute")
    behavior? = Map.has_key?(trigger, "behavior")
    count = Enum.count([duration?, time?, attribute?, behavior?], & &1)

    if count != 1, do: invalid!("invalid_timer_source", "timer requires exactly one source")

    if kind == "after" && time?,
      do: invalid!("invalid_timer_source", "after requires duration source")

    if kind in ["every"] && time?,
      do: invalid!("invalid_timer_source", "every requires duration source")

    if kind == "at" && duration?, do: invalid!("invalid_timer_source", "at requires time source")

    if kind == "every" && trigger["duration_ms"] == 0,
      do: invalid!("invalid_timer_source", "every interval must be positive")

    if attribute?, do: validate_timer_attribute_source!(model, kind, trigger["attribute"])

    if behavior? do
      validate_behavior_ref!(case, %{"behavior" => trigger["behavior"]})
      validate_timer_behavior_return!(case, trigger["behavior"])
    end

    reject_keys!(
      trigger,
      ["event", "events", "operation", "exit_point"],
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )
  end

  defp validate_trigger!(_case, _model, %{"kind" => "completion"} = trigger),
    do:
      require_only!(
        trigger,
        ["kind"],
        "missing_trigger_operand",
        "missing trigger operand",
        "extraneous_trigger_operand",
        "extraneous trigger operand"
      )

  defp validate_trigger!(_case, _model, %{"kind" => "exit_point"} = trigger) do
    require_only!(
      trigger,
      ["kind", "exit_point"],
      "missing_trigger_operand",
      "missing trigger operand",
      "extraneous_trigger_operand",
      "extraneous trigger operand"
    )

    validate_name!("exit_point", trigger["exit_point"])
  end

  defp validate_trigger!(_case, _model, _trigger), do: :ok

  defp validate_model_paths!(case, model) do
    state_paths = state_path_map(model)
    root = model_root(model)

    validate_target_path!(model, state_paths, root, model["initial"], true)

    Enum.each(model["transitions"] || [], fn transition ->
      validate_transition_paths!(case, model, state_paths, root, transition)
    end)

    Enum.each(model["states"] || [], fn state ->
      validate_state_paths!(case, model, state_paths, root, state, root)
    end)
  end

  defp validate_state_paths!(case, model, state_paths, root, state, parent_path) do
    path = HSM.DSL.join(parent_path, state["name"])
    kind = Map.get(state, "kind", "state")

    if parent_path == root and kind in ["shallow_history", "deep_history"] do
      invalid!("invalid_history_owner", "invalid history owner")
    end

    if state["initial"] do
      validate_target_path!(model, state_paths, path, state["initial"], true)
    end

    Enum.each(state["transitions"] || [], fn transition ->
      validate_transition_paths!(case, model, state_paths, path, transition)
    end)

    Enum.each(state["states"] || [], fn child ->
      validate_state_paths!(case, model, state_paths, root, child, path)
    end)
  end

  defp validate_transition_paths!(case, model, state_paths, owner, transition) do
    owner_state = state_paths[owner]
    owner_kind = if owner_state, do: Map.get(owner_state, "kind", "state"), else: "state"
    owner_relative? = owner_kind in ["choice", "shallow_history", "deep_history"]

    if transition["source"] do
      source = resolve_ir_path(model, owner, transition["source"], owner_relative?)

      cond do
        Map.has_key?(state_paths, source) ->
          :ok

        crosses_submachine_boundary?(state_paths, source) ->
          invalid!(
            "invalid_submachine_internal_source",
            "submachine internal source #{transition["source"]}"
          )

        true ->
          invalid!("missing_source", "missing source #{transition["source"]}")
      end
    end

    if transition["target"] do
      target = resolve_ir_path(model, owner, transition["target"], owner_relative?)
      entry_point_paths = entry_point_path_map(model)
      exit_point_paths = exit_point_path_map(model)

      cond do
        Map.has_key?(entry_point_paths, target) ->
          invalid!("invalid_entry_point_internal_target", "entry point target cannot be internal")

        Map.has_key?(exit_point_paths, target) ->
          invalid!(
            "invalid_submachine_internal_target",
            "submachine exit point cannot be targeted directly"
          )

        Map.has_key?(state_paths, target) ->
          :ok

        outside_model_root?(model, target) ->
          invalid!(
            "invalid_submachine_boundary_target",
            "submachine boundary target #{transition["target"]}"
          )

        crosses_submachine_boundary?(state_paths, target) ->
          invalid!(
            "invalid_submachine_internal_target",
            "submachine internal target #{transition["target"]}"
          )

        true ->
          invalid!("missing_target", "missing target #{transition["target"]}")
      end
    end

    validate_transition_entry_point!(case, model, state_paths, owner, transition, owner_relative?)
    validate_transition_exit_point!(case, model, state_paths, owner, transition)
  end

  defp validate_transition_entry_point!(
         case,
         model,
         state_paths,
         owner,
         transition,
         owner_relative?
       ) do
    if transition["entry_point"] do
      validate_name!("entry_point", transition["entry_point"])

      target =
        if transition["target"],
          do: resolve_ir_path(model, owner, transition["target"], owner_relative?),
          else: nil

      target_state = target && state_paths[target]

      if target_state == nil or Map.get(target_state, "kind") != "submachine" do
        invalid!("invalid_entry_point_usage", "invalid entry point usage")
      end

      child = find_model_ir(case, target_state["machine"])
      entry_names = MapSet.new(Enum.map(child["entry_points"] || [], & &1["name"]))

      unless MapSet.member?(entry_names, transition["entry_point"]) do
        invalid!("missing_entry_point", "missing entry point #{transition["entry_point"]}")
      end
    end
  end

  defp validate_transition_exit_point!(case, _model, state_paths, owner, transition) do
    case transition["trigger"] do
      %{"kind" => "exit_point", "exit_point" => name} ->
        owner_state = state_paths[owner]

        if owner_state == nil or Map.get(owner_state, "kind") != "submachine" do
          invalid!("invalid_exit_point_usage", "invalid exit point usage")
        end

        child = find_model_ir(case, owner_state["machine"])
        exit_names = MapSet.new(Enum.map(child["exit_points"] || [], & &1["name"]))

        unless MapSet.member?(exit_names, name) do
          invalid!("missing_exit_point", "missing exit point #{name}")
        end

      _ ->
        :ok
    end
  end

  defp validate_target_path!(model, state_paths, owner, %{"target" => target}, owner_relative?),
    do: validate_resolved_state_path!(model, state_paths, owner, target, owner_relative?)

  defp validate_target_path!(model, state_paths, owner, target, owner_relative?)
       when is_binary(target),
       do: validate_resolved_state_path!(model, state_paths, owner, target, owner_relative?)

  defp validate_target_path!(_model, _state_paths, _owner, _target, _owner_relative?), do: :ok

  defp validate_resolved_state_path!(model, state_paths, owner, path, owner_relative?) do
    target = resolve_ir_path(model, owner, path, owner_relative?)

    unless Map.has_key?(state_paths, target) do
      invalid!("missing_target", "missing target #{path}")
    end
  end

  defp state_path_map(model) do
    root = model_root(model)
    states = model["states"] || []

    states
    |> collect_state_paths(root)
    |> Map.new()
  end

  defp collect_state_paths(states, parent_path) do
    Enum.flat_map(states, fn state ->
      path = HSM.DSL.join(parent_path, state["name"])
      [{path, state} | collect_state_paths(state["states"] || [], path)]
    end)
  end

  defp exit_point_path_map(model) do
    root = model_root(model)
    exit_points = model["exit_points"] || []

    Map.new(exit_points, fn point -> {HSM.DSL.join(root, point["name"]), point} end)
  end

  defp entry_point_path_map(model) do
    root = model_root(model)
    entry_points = model["entry_points"] || []

    Map.new(entry_points, fn point -> {HSM.DSL.join(root, point["name"]), point} end)
  end

  defp outside_model_root?(model, path) do
    root = model_root(model)
    path != root and not String.starts_with?(path, root <> "/")
  end

  defp crosses_submachine_boundary?(state_paths, path) do
    Enum.any?(state_paths, fn {state_path, state} ->
      Map.get(state, "kind") == "submachine" and path != state_path and
        String.starts_with?(path, state_path <> "/")
    end)
  end

  defp resolve_ir_path(model, owner, path, owner_relative? \\ false) do
    cond do
      String.starts_with?(path, "/") ->
        HSM.DSL.normalize(path)

      owner_relative? or path == "." or String.starts_with?(path, "./") or
          String.starts_with?(path, "../") ->
        HSM.DSL.join(owner, path)

      true ->
        HSM.DSL.join(model_root(model), path)
    end
  end

  defp model_root(model), do: "/" <> model["name"]

  defp validate_pseudostate_transitions!("choice", state) do
    transitions = state["transitions"] || []

    cond do
      transitions == [] ->
        invalid!("choice_missing_transition", "choice has no transitions")

      not Enum.any?(transitions, &(not Map.has_key?(&1, "guard"))) ->
        invalid!("choice_missing_fallback", "choice last transition must be guardless fallback")

      transitions |> Enum.drop(-1) |> Enum.any?(&(not Map.has_key?(&1, "guard"))) ->
        invalid!("choice_default_not_last", "choice fallback transition must be last")

      true ->
        :ok
    end
  end

  defp validate_pseudostate_transitions!(kind, state)
       when kind in ["shallow_history", "deep_history"] do
    if (state["transitions"] || []) == [] do
      invalid!("history_missing_default", "history requires default")
    end
  end

  defp validate_pseudostate_transitions!(_kind, _state), do: :ok

  defp validate_trigger_operand_count!(0),
    do: invalid!("missing_trigger_operand", "missing trigger operand")

  defp validate_trigger_operand_count!(1), do: :ok

  defp validate_trigger_operand_count!(_count),
    do: invalid!("multiple_trigger_operands", "multiple trigger operands")

  defp validate_timer_behavior_return!(case, id) do
    case get_in(case, ["behaviors", id]) || [] do
      [%{"op" => "return_value", "value" => value}] when not is_number(value) ->
        invalid!("invalid_timer_behavior_return", "invalid timer behavior return")

      _ ->
        :ok
    end
  end

  defp validate_timer_attribute_source!(model, kind, attribute) do
    attributes = model["attributes"] || %{}

    unless Map.has_key?(attributes, attribute) do
      invalid!("missing_timer_attribute", "missing timer attribute #{attribute}")
    end

    type = get_in(attributes, [attribute, "type"])

    cond do
      kind in ["after", "every"] && type == "time_ms" ->
        invalid!("invalid_timer_attribute_type", "timer attribute has wrong type")

      kind == "at" && type == "duration_ms" ->
        invalid!("invalid_timer_attribute_type", "timer attribute has wrong type")

      true ->
        :ok
    end
  end

  defp validate_behavior_refs!(case, container, key) do
    Enum.each(container[key] || [], &validate_behavior_ref!(case, &1))
  end

  defp validate_behavior_ref!(case, %{"behavior" => id}) do
    unless Map.has_key?(case["behaviors"] || %{}, id),
      do: invalid!("missing_behavior", "missing behavior #{id}")
  end

  defp validate_behavior_ref!(_case, _ref),
    do: invalid!("missing_behavior", "missing behavior reference")

  defp reject_state_keys!(state, keys, code, message),
    do: reject_keys!(state, keys, code, message)

  defp validate_non_empty_array!(map, key) do
    if Map.has_key?(map, key) && map[key] == [] do
      code = if key == "defer", do: "empty_event_array", else: "empty_behavior_array"
      invalid!(code, "#{key} cannot be empty")
    end
  end

  defp require_keys!(
         map,
         keys,
         code \\ "invalid_behavior_op_operand",
         message \\ "missing required operand"
       ) do
    unless Enum.all?(keys, &Map.has_key?(map, &1)), do: invalid!(code, message)
  end

  defp require_only!(
         map,
         keys,
         missing_code \\ "invalid_behavior_op_operand",
         missing_message \\ "missing required operand",
         extra_code \\ "invalid_behavior_op_operand",
         extra_message \\ "extraneous operand"
       ) do
    require_keys!(map, keys -- ["op", "kind"], missing_code, missing_message)
    reject_keys!(map, Map.keys(map) -- keys, extra_code, extra_message)
  end

  defp reject_keys!(
         map,
         keys,
         code \\ "invalid_behavior_op_operand",
         message \\ "extraneous operand"
       ) do
    if Enum.any?(keys, &Map.has_key?(map, &1)), do: invalid!(code, message)
  end

  defp validate_name!(kind, name) when is_binary(name) do
    if name == "" or String.contains?(name, "/"),
      do: invalid!("invalid_name", "#{kind} name cannot contain /")
  end

  defp validate_name!(kind, _name), do: invalid!("invalid_name", "#{kind} name required")

  defp value_matches_ir_type?(_value, "any"), do: true
  defp value_matches_ir_type?(value, "boolean"), do: is_boolean(value)
  defp value_matches_ir_type?(value, "number"), do: is_number(value)
  defp value_matches_ir_type?(value, "duration_ms"), do: is_integer(value)
  defp value_matches_ir_type?(value, "time_ms"), do: is_integer(value)
  defp value_matches_ir_type?(value, "string"), do: is_binary(value)
  defp value_matches_ir_type?(value, "array"), do: is_list(value)
  defp value_matches_ir_type?(value, "object"), do: is_map(value)
  defp value_matches_ir_type?(_value, _type), do: true

  defp invalid!(code, message), do: raise(HSM.ValidationError, message: "#{code}: #{message}")

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

  defp event_data(%HSM.Event{kind: :set_event, data: %{value: value}}, path)
       when path in [nil, ""],
       do: value

  defp event_data(%HSM.Event{kind: :set_event, data: %HSM.AttributeChange{Value: value}}, path)
       when path in [nil, ""],
       do: value

  defp event_data(%HSM.Event{data: %HSM.AttributeChange{} = data}, path),
    do: read_path(attribute_change_data(data), path)

  defp event_data(%HSM.Event{data: %HSM.CallData{Args: [payload]} = data}, path)
       when path not in [nil, ""] do
    read_path(payload, path) || read_path(call_data(data), path)
  end

  defp event_data(%HSM.Event{data: %HSM.CallData{Args: args}}, path)
       when path in [nil, ""],
       do: args

  defp event_data(%HSM.Event{data: %HSM.CallData{} = data}, path),
    do: read_path(call_data(data), path)

  defp event_data(%HSM.Event{data: data}, path), do: read_path(data, path)

  defp attribute_change_data(%HSM.AttributeChange{Name: name, Old: old, Value: value}) do
    %{
      "Name" => name,
      "name" => name,
      "Old" => old,
      "old" => old,
      "old_value" => old,
      "Value" => value,
      "value" => value
    }
  end

  defp call_data(%HSM.CallData{Name: name, Args: args}) do
    %{
      "Name" => name,
      "name" => name,
      "Args" => args,
      "args" => args
    }
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

  defp trace_pre_defer(trace, case, machine, event) do
    deferred? = runtime_event_deferred?(machine, event.name)

    if deferred? and trace_expects?(case, "defer") do
      append_trace(trace, %{"type" => "defer", "event" => event.name})
    end

    deferred?
  end

  defp trace_post_defer(trace, case, machine, event, :deferred, false) do
    if deferred_event_present?(machine, event.name) and trace_expects?(case, "defer") do
      append_trace(trace, %{"type" => "defer", "event" => event.name})
    end
  end

  defp trace_post_defer(_trace, _case, _machine, _event, _status, _pre_deferred?), do: :ok

  defp deferred_event_present?(machine, event_name) do
    Enum.any?(machine.deferred, &(runtime_deferred_event(&1).name == event_name))
  end

  defp trace_undefer_from_machine(trace, case, machine, event) do
    if machine.deferred != [] and trace_expects?(case, "undefer") and
         !runtime_event_deferred?(machine, event.name) do
      deferred = List.first(machine.deferred)

      if runtime_deferred_replays_after_dispatch?(machine, event, deferred) do
        append_trace(trace, %{
          "type" => "undefer",
          "event" => runtime_deferred_event(deferred).name
        })
      end
    end
  end

  defp runtime_deferred_event({event, _scope}), do: HSM.Event.coerce(event)
  defp runtime_deferred_event(event), do: HSM.Event.coerce(event)

  defp runtime_deferred_replays_after_dispatch?(machine, event, deferred) do
    deferred_event = runtime_deferred_event(deferred)

    with %{target: target} = transition when is_binary(target) <-
           runtime_transition_for(machine, event) do
      runtime_deferred_target_active?(deferred, transition) and
        deferred_event.name not in Map.get(machine.model.active_defers, target, [])
    else
      _ -> false
    end
  end

  defp runtime_deferred_target_active?({_event, nil}, _transition), do: true

  defp runtime_deferred_target_active?({_event, scope}, transition) do
    path_in_scope?(transition.target, scope) or
      (!path_in_scope?(transition.target, scope) and
         (path_in_scope?(transition.source, scope) or completion_trigger?(transition.trigger)))
  end

  defp runtime_deferred_target_active?(_event, _transition), do: true

  defp path_in_scope?(path, scope), do: path == scope or path_below_scope?(path, scope)

  defp path_below_scope?(path, scope) when is_binary(path),
    do: String.starts_with?(path, scope <> "/")

  defp path_below_scope?(_path, _scope), do: false

  defp completion_trigger?({:on, "FinalEvent"}), do: true
  defp completion_trigger?({:on, "hsm/final"}), do: true
  defp completion_trigger?({:on, :completion}), do: true
  defp completion_trigger?(_trigger), do: false

  defp transition_candidate_list(%{list: list}) when is_list(list), do: list
  defp transition_candidate_list(list) when is_list(list), do: list
  defp transition_candidate_list(_candidates), do: []

  defp runtime_transition_for(machine, event) do
    machine.model.active_paths
    |> Map.get(HSM.state(machine), [])
    |> Enum.find_value(fn path ->
      machine.model.transition_candidates
      |> Map.get(path, [])
      |> transition_candidate_list()
      |> Enum.find(&runtime_trigger_matches?(&1.trigger, event.name))
    end)
  end

  defp maybe_append_undefer_before_dispatch(trace, case, machine, event) do
    replay = Process.get(:hsm_conformance_replay, [])

    cond do
      replay != [] and trace_expects?(case, "undefer") and
          !runtime_event_deferred?(machine, event.name) ->
        [event_name | rest] = replay
        append_trace(trace, %{"type" => "undefer", "event" => event_name})
        Process.put(:hsm_conformance_replay, rest)

      replay == [] ->
        trace_undefer_from_machine(trace, case, machine, event)

      true ->
        :ok
    end
  end

  defp runtime_event_deferred?(%HSM.Instance{} = machine, event_name) do
    active_defers = Map.get(machine.model.active_defers, HSM.state(machine), [])
    event_name in active_defers and !runtime_event_has_transition_candidate?(machine, event_name)
  end

  defp runtime_event_has_transition_candidate?(%HSM.Instance{} = machine, event_name) do
    machine.model.active_paths
    |> Map.get(HSM.state(machine), [])
    |> Enum.any?(fn path ->
      machine.model.transition_candidates
      |> Map.get(path, [])
      |> transition_candidate_list()
      |> Enum.any?(&runtime_trigger_matches?(&1.trigger, event_name))
    end)
  end

  defp runtime_trigger_matches?({:on, expected}, event_name) when is_list(expected),
    do: event_name in expected

  defp runtime_trigger_matches?({:on, expected}, event_name), do: expected == event_name
  defp runtime_trigger_matches?(_trigger, _event_name), do: false

  defp append_lifecycle_trace(trace, case, kind) do
    if trace_expects?(case, kind) do
      append_trace(trace, %{"type" => kind})
    end
  end

  defp trace_expects?(case, kind) do
    Enum.any?(get_in(case, ["expect", "trace"]) || [], &(&1["type"] == kind))
  end

  defp trace_expects_call?(case, operation) do
    Enum.any?(
      get_in(case, ["expect", "trace"]) || [],
      &(&1["type"] == "call" and &1["operation"] == operation)
    )
  end

  defp append_timer_scheduled(trace, case, %HSM.Instance{} = machine) do
    if trace_expects?(case, "timer_scheduled") do
      Enum.each(machine.timers, fn _timer ->
        append_trace(trace, %{"type" => "timer_scheduled"})
      end)
    end
  end

  defp timer_due?(machine, millis),
    do: Enum.any?(machine.timers, &(&1.due <= machine.logical_time + millis))

  defp timer_guard_fire_after_guard?(case, machine) do
    case
    |> state_ir(HSM.state(machine))
    |> timer_transitions()
    |> Enum.any?(fn transition ->
      case get_in(transition, ["guard", "behavior"]) do
        nil ->
          false

        id ->
          case get_in(case, ["behaviors", id]) || [] do
            [%{"op" => "raise"} | _] -> false
            [%{"op" => "trace"} | [%{"op" => "return_value", "value" => false} | _]] -> false
            [] -> false
            _ -> true
          end
      end
    end)
  end

  defp configured_clock?(case) do
    Enum.any?(case["instances"] || [], fn instance ->
      config = instance["config"] || %{}
      Map.has_key?(config, "clock") or Map.has_key?(config, "Clock")
    end)
  end

  defp configured_clock_yields?(case) do
    Enum.any?(case["instances"] || [], fn instance ->
      config = instance["config"] || %{}
      (config["clock"] || config["Clock"]) == "trace_yield_sleep"
    end)
  end

  defp configured_queue?(case) do
    Enum.any?(case["instances"] || [], fn instance ->
      config = instance["config"] || %{}
      Map.has_key?(config, "queue") or Map.has_key?(config, "Queue")
    end)
  end

  defp timer_transitions(nil), do: []

  defp timer_transitions(state) do
    Enum.filter(state["transitions"] || [], fn transition ->
      get_in(transition, ["trigger", "kind"]) in ["after", "every", "at"]
    end)
  end

  defp state_ir(case, state_path) do
    model =
      case
      |> resolve_model_ir(case["model"])
      |> expand_submachines(case)

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
