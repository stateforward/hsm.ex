defmodule HSM.Instance do
  @moduledoc false

  alias HSM.{
    ActivityHandle,
    Config,
    Clock,
    DSL,
    Event,
    Model,
    Node,
    Queue,
    Snapshot,
    Transition,
    TransitionSnapshot,
    ValidationError
  }

  @exit_point_final_marker "//__hsm_exit__/"
  @missing {__MODULE__, :missing}
  @operation_contract {HSM.DSL, :operation_contract}
  @transition_paths_key {HSM.DSL, :transition_paths}

  defstruct id: "",
            name: "",
            model: nil,
            state: "",
            attributes: %{},
            data: nil,
            queue: nil,
            clock: nil,
            deferred: [],
            active_activities: [],
            history_shallow: %{},
            history_deep: %{},
            logical_time: 0,
            timers: [],
            started?: false,
            done?: false,
            events: []

  def new(%Model{} = model, %Config{} = config \\ %Config{}) do
    id = config.id || ""

    %__MODULE__{
      id: if(id == "", do: unique_id(), else: id),
      name: if(config.name in [nil, ""], do: model.path, else: config.name),
      model: model,
      attributes: model.attributes,
      data: config.data,
      queue: Queue.new(config.queue),
      clock: Clock.new(config.clock)
    }
  end

  def start(instance, data \\ @missing)

  def start(%__MODULE__{started?: true}, _data) do
    raise ValidationError, message: "already started HSM"
  end

  def start(%__MODULE__{} = instance, data) do
    data = if data == @missing, do: instance.data, else: data
    event = Event.initial(data)

    instance
    |> reset_runtime(data)
    |> enter_initial(event)
    |> elem(0)
    |> schedule_timers(instance.model.root, event)
    |> flush_generated_events()
    |> drain_queue()
    |> clear_timer_error()
  end

  def stop(%__MODULE__{started?: false} = instance), do: instance

  def stop(%__MODULE__{} = instance) do
    clear_queue_len_error(instance)

    exit_paths =
      instance.model
      |> active_path(instance.state)
      |> Enum.reject(&(&1 == instance.model.root))

    instance
    |> exit_states(exit_paths, %Event{name: "StopEvent", kind: :stop_event})
    |> cancel_all_timers()
    |> Map.merge(%{
      started?: false,
      state: instance.model.root,
      queue: reset_queue(instance.queue),
      deferred: [],
      active_activities: [],
      timers: []
    })
  end

  def restart(instance, data \\ @missing)

  def restart(%__MODULE__{started?: false}, _data) do
    raise ValidationError, message: "restart requires a started HSM"
  end

  def restart(%__MODULE__{} = instance, data), do: instance |> stop() |> start(data)
  def state(%__MODULE__{state: state}), do: state

  def get(%__MODULE__{started?: false}, _name), do: {nil, false}

  def get(%__MODULE__{} = instance, name) do
    case Map.fetch(instance.attributes, attribute_key(instance, name)) do
      {:ok, value} -> {value, true}
      :error -> {nil, false}
    end
  end

  def set(%__MODULE__{started?: false}, _name, _value) do
    raise ValidationError, message: "set requires a started HSM"
  end

  def set(%__MODULE__{} = instance, name, value) when is_binary(name) do
    key = attribute_key(instance, name)

    unless Map.has_key?(instance.model.attributes, key) do
      raise ValidationError, message: "unknown attribute #{inspect(name)}"
    end

    type = Map.get(instance.model.attribute_types, key, :any)

    unless value_matches_type?(value, type) do
      raise ValidationError,
        message: "attribute #{inspect(name)} expected #{inspect(type)}, got #{inspect(value)}"
    end

    old = Map.get(instance.attributes, key)
    instance = %{instance | attributes: Map.put(instance.attributes, key, value)}

    if old == value do
      instance
    else
      if processing?(instance), do: put_generated_attribute(instance, key, value)

      try do
        dispatch(instance, Event.set(qualified_member_name(instance, key), old, value)) |> elem(0)
      catch
        {:behavior_error, code, message} ->
          throw({:hsm_set_error, instance, code, message})
      end
    end
  end

  def call(instance, name, args \\ [])

  def call(%__MODULE__{started?: false}, _name, _args) do
    raise ValidationError, message: "operation requires a started HSM"
  end

  def call(%__MODULE__{} = instance, name, args) do
    depth = call_depth(instance)

    with_generated_cleanup(instance, processing?(instance) or depth > 0, fn ->
      do_call(instance, name, args, depth)
    end)
  end

  defp do_call(instance, name, args, depth) do
    context = Process.get(:hsm_runtime_action_context, %{action: :operation})
    {key, callback} = operation_callback(instance, name, context)

    unless is_function(callback) do
      raise ValidationError, message: "unknown operation #{inspect(name)}"
    end

    qualified_name = qualified_member_name(instance, key)
    event = Event.call(qualified_name, args)

    instance = observe(instance, "behavior", qualified_name, event)

    result =
      with_call_body(instance, fn -> invoke_with_context(callback, instance, event, context) end)

    reject_async_result!(result)

    instance =
      case result do
        %__MODULE__{} = updated -> updated
        {%__MODULE__{} = updated, _status} -> updated
        _ -> instance
      end

    cond do
      processing?(instance) or depth > 0 ->
        put_generated_event(instance, event)
        {instance, result}

      true ->
        instance = flush_generated_events(instance)
        {instance, _} = dispatch(instance, event)
        {instance, result}
    end
  end

  def dispatch(%__MODULE__{started?: false} = instance, _event),
    do: {instance, {:error, %ValidationError{message: "dispatch requires a started HSM"}}}

  def dispatch(%__MODULE__{} = instance, %Event{schema: nil} = event),
    do: dispatch_event(instance, event)

  def dispatch(%__MODULE__{} = instance, %Event{} = event) do
    dispatch_event(instance, %{event | schema: clone(event.schema)})
  end

  def dispatch(%__MODULE__{} = instance, event), do: dispatch(instance, Event.coerce(event))

  defp dispatch_event(instance, event) do
    top_level? = !processing?(instance)

    result =
      cond do
        processing?(instance) and hooked_queue?(instance.queue) ->
          instance =
            case generated_queue(instance) do
              nil -> instance
              queue -> %{instance | queue: queue}
            end

          case enqueue_event(instance, event) do
            {%__MODULE__{} = queued, nil} ->
              put_generated_queue(instance, queued.queue)
              if hook_regular_event?(event), do: put_generated_hook_event(instance, event)

            {%__MODULE__{}, error} ->
              put_generated_event(instance, error_event(error))
          end

          {instance, :queued}

        processing?(instance) ->
          put_generated_event(instance, event)
          {instance, :queued}

        default_queue_empty?(instance.queue) ->
          process_popped_event(instance, event)

        true ->
          case enqueue_event(instance, event) do
            {%__MODULE__{} = instance, nil} -> process_event(instance)
            {%__MODULE__{} = instance, error} -> handle_runtime_error(instance, error)
          end
      end

    result
    |> clear_timer_error_result()
    |> clear_deferred_generated_result(top_level?)
    |> clear_popped_deferred_result(top_level?)
  end

  def tick(%__MODULE__{} = instance, millis) when is_integer(millis) and millis >= 0 do
    try do
      instance = %{instance | logical_time: instance.logical_time + millis}
      fire_due_timers(instance)
    after
      unless Process.get(:hsm_runtime_preserve_timer_error), do: take_timer_error()
    end
  end

  def handle_timer(%__MODULE__{} = instance, {:hsm_timer, timer_id}),
    do: handle_timer(instance, timer_id)

  def handle_timer(%__MODULE__{} = instance, timer_id) do
    case Enum.split_with(instance.timers, &(&1.id == timer_id)) do
      {[], _timers} ->
        instance

      {[timer | _], rest} ->
        instance = %{instance | timers: rest}

        {instance, _status} = dispatch_timer(instance, timer)

        instance
        |> maybe_reschedule_every_timer(timer)
        |> clear_timer_error()
    end
  end

  def handle_activity(%__MODULE__{} = instance, {:DOWN, ref, :process, pid, reason})
      when is_reference(ref) and is_pid(pid) do
    case pop_activity(instance, ref, pid) do
      {%__MODULE__{} = instance, nil} ->
        instance

      {%__MODULE__{} = instance, %ActivityHandle{path: path}} ->
        cond do
          normal_activity_reason?(reason) ->
            instance

          not instance.started? or path not in active_path(instance.model, instance.state) ->
            instance

          true ->
            instance
            |> dispatch(error_event(activity_error(reason)))
            |> elem(0)
        end
    end
  end

  def handle_activity(%__MODULE__{} = instance, _message), do: instance

  def snapshot(%__MODULE__{} = instance) do
    if !instance.started? do
      raise ValidationError, message: "take snapshot requires a started HSM"
    end

    %Snapshot{
      ID: unique_id(),
      QualifiedName: instance.name,
      State: snapshot_state(instance),
      Attributes: qualify_attributes(instance),
      QueueLen: snapshot_queue_len(instance),
      Transitions: transition_snapshots(instance),
      Events: Enum.map(Queue.events(instance.queue), &event_detail/1)
    }
  end

  defp reset_runtime(instance, data) do
    clear_queue_len_error(instance)

    %{
      instance
      | state: instance.model.root,
        attributes: instance.model.attributes,
        data: data,
        queue: reset_queue(instance.queue),
        deferred: [],
        active_activities: [],
        history_shallow: %{},
        history_deep: %{},
        logical_time: 0,
        timers: [],
        started?: true,
        done?: false,
        events: []
    }
  end

  defp enter_initial(instance, event) do
    case instance.model.initial do
      nil -> {instance, :stable}
      transition -> take_transition(instance, transition, event)
    end
  end

  defp process_event(%__MODULE__{} = instance) do
    case pop_event(instance) do
      {%__MODULE__{} = instance, nil} ->
        {instance, :ignored}

      {%__MODULE__{} = instance, %Event{} = event} ->
        process_popped_event(instance, event)

      {%__MODULE__{} = instance, error} ->
        handle_runtime_error(instance, error)
    end
  end

  defp process_popped_event(instance, event) do
    {instance, status} =
      with_processing(instance, fn ->
        case select_transition(instance, event) do
          {:defer, path, defer} ->
            {defer_popped_event(instance, event, path, defer), :deferred}

          nil ->
            {instance, :processed}

          transition ->
            instance = carry_deferred_across_child_exit(instance, transition)
            {elem(take_transition(instance, transition, event), 0), :processed}
        end
      end)

    if status == :deferred do
      instance = cancel_generated_hook_events(instance)
      clear_deferred_generated_work(instance)

      if hooked_queue?(instance.queue) do
        case queue_empty(instance) do
          {true, nil} -> requeue_popped_deferred(instance)
          {false, nil} -> process_deferred_queue(instance)
          {_empty?, error} -> handle_runtime_error(instance, error)
        end
      else
        {instance, :deferred}
      end
    else
      instance = flush_generated_events(instance)
      instance = replay_deferred(instance)

      case queue_empty(instance) do
        {true, nil} -> {instance, :processed}
        {false, nil} -> process_event(instance)
        {_empty?, error} -> handle_runtime_error(instance, error)
      end
    end
  end

  defp defer_popped_event(instance, event, path, defer) do
    entry = deferred_entry(event, path, defer)
    replayed? = take_popped_queued_deferred(instance, event)

    instance =
      if replayed? and deferred_entry?(instance.deferred, entry) do
        instance
      else
        %{instance | deferred: instance.deferred ++ [entry]}
      end

    if hooked_queue?(instance.queue) do
      put_popped_deferred(instance, entry)
    end

    instance
  end

  defp process_deferred_queue(instance) do
    case process_event(instance) do
      {%__MODULE__{} = instance, :ignored} ->
        requeue_after_deferred_queue_drain(instance, :deferred)

      {%__MODULE__{} = instance, :processed} ->
        requeue_after_deferred_queue_drain(instance, :processed)

      result ->
        result
    end
  end

  defp requeue_after_deferred_queue_drain(instance, status) do
    case queue_empty(instance) do
      {true, nil} ->
        {instance, _status} = requeue_popped_deferred(instance)
        {instance, status}

      {false, nil} ->
        process_deferred_queue(instance)

      {_empty?, error} ->
        handle_runtime_error(instance, error)
    end
  end

  defp replay_deferred(%__MODULE__{deferred: []} = instance), do: instance

  defp replay_deferred(instance) do
    active_defer = active_deferred_events(instance)

    {scoped, _discarded} =
      Enum.split_with(instance.deferred, &deferred_scope_active?(instance, &1))

    {still_deferred, ready} =
      Enum.split_with(scoped, &(deferred_event(&1).name in active_defer))

    drop_popped_deferred(instance, ready)

    instance = %{instance | deferred: still_deferred}

    Enum.reduce_while(ready, instance, fn event, acc ->
      {acc, queued?} = pop_queued_deferred(acc, event)

      cond do
        queued? ->
          {:cont, acc}

        true ->
          case enqueue_event(acc, deferred_event_value(event)) do
            {queued, nil} -> {:cont, queued}
            {queued, error} -> {:halt, handle_runtime_error(queued, error) |> elem(0)}
          end
      end
    end)
  end

  defp select_transition(instance, event) do
    active_paths = active_path(instance.model, instance.state)

    active_paths
    |> Enum.find_value(fn path ->
      candidates = transition_candidates(instance, path)

      local_transition =
        candidates
        |> candidate_transitions(instance, :local, event)
        |> matching_transition(instance, event)

      parent_transition =
        candidates
        |> candidate_transitions(instance, :parent, event)
        |> matching_transition(instance, event)

      defer = deferred_trigger(instance.model.states[path].defer, event.name)

      cond do
        local_transition ->
          local_transition

        parent_transition &&
            (defer == nil ||
               transition_handles_at_or_below?(parent_transition, path, instance.model.root)) ->
          parent_transition

        defer ->
          {:defer, path, defer}

        true ->
          nil
      end
    end)
  end

  defp matching_transition(transitions, instance, event) do
    Enum.find(transitions, fn transition ->
      trigger_matches?(instance, transition, event) and guard_passes?(instance, transition, event)
    end)
  end

  defp transition_handles_at_or_below?(%Transition{} = transition, owner, model_root) do
    (transition.source == owner and DSL.parent(owner) == model_root) or
      path_below_scope?(transition.source, owner) or
      transition_declared_at_or_below?(transition, owner)
  end

  defp transition_declared_at_or_below?(%Transition{} = transition, owner),
    do: transition.owner == owner or path_below_scope?(transition.owner, owner)

  defp transition_candidates(instance, path) do
    Map.fetch!(instance.model.transition_candidates, path)
  end

  defp candidate_transitions(candidates, instance, scope, event) do
    index = Map.fetch!(candidates, scope)

    {wildcard_keys, specific_keys} = Enum.split_with(event_keys(event), &(&1 == {:on, "*"}))
    specific = keyed_candidates(index, specific_keys)

    case Enum.any?(specific, &trigger_event_matches?(instance, &1, event)) do
      true -> specific
      false -> keyed_candidates(index, wildcard_keys)
    end
  end

  defp keyed_candidates(index, keys) do
    case keys do
      [] ->
        []

      [key] ->
        Map.get(index.by_key, key, [])

      keys ->
        key_set = MapSet.new(keys)

        for {transition_keys, transition} <- index.ordered,
            Enum.any?(transition_keys, &MapSet.member?(key_set, &1)),
            do: transition
    end
  end

  defp event_keys(%Event{kind: :completion_event, name: name})
       when name in ["hsm/final", "FinalEvent"],
       do: [{:on, "hsm/final"}, {:on, "FinalEvent"}] ++ any_event_key(name)

  defp event_keys(%Event{kind: :set_event, name: name} = event),
    do:
      [{:on, name} | Enum.map(event_member_names(event), &{:on_set, &1})] ++
        [:dynamic_set] ++ any_event_key(name)

  defp event_keys(%Event{kind: :call_event, name: name} = event),
    do:
      [{:on, name} | Enum.map(event_member_names(event), &{:on_call, &1})] ++ any_event_key(name)

  defp event_keys(%Event{
         name: name,
         kind: :timer_event,
         data: %{transition: %{id: transition_id}}
       }),
       do: [{:timer, transition_id}] ++ any_event_key(name)

  defp event_keys(%Event{name: name}), do: [{:on, name}] ++ any_event_key(name)

  defp any_event_key("*"), do: []
  defp any_event_key(_name), do: [{:on, "*"}]

  defp trigger_event_matches?(_instance, %Transition{trigger: nil}, _event), do: false

  defp trigger_event_matches?(
         _instance,
         %Transition{trigger: {:on, expected}},
         %Event{name: actual}
       ),
       do: on_event_matches?(expected, actual)

  defp trigger_event_matches?(
         _instance,
         %Transition{trigger: {:on_set, expected}},
         %Event{kind: :set_event} = event
       ),
       do: expected in event_member_names(event)

  defp trigger_event_matches?(
         instance,
         %Transition{trigger: {:on_call, _expected}} = transition,
         %Event{kind: :call_event} = event
       ),
       do:
         Enum.any?(
           transition_snapshot_events(instance, transition),
           &(&1 in call_event_names(event))
         )

  defp trigger_event_matches?(_instance, %Transition{trigger: {:when, _fun}}, %Event{}),
    do: true

  defp trigger_event_matches?(
         _instance,
         %Transition{trigger: {:when, _fun, _attributes}},
         %Event{}
       ),
       do: true

  defp trigger_event_matches?(_instance, %Transition{trigger: {kind, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: %{id: transition_id}}
       })
       when kind in [:after, :every, :at],
       do: current.id == transition_id

  defp trigger_event_matches?(_instance, _transition, _event), do: false

  defp on_event_matches?(expected, actual) when is_list(expected),
    do: actual in expected or ("*" in expected and actual != "*")

  defp on_event_matches?("*", actual), do: actual != "*"
  defp on_event_matches?(expected, actual), do: expected == actual

  defp trigger_matches?(_instance, %Transition{trigger: nil}, _event), do: false

  defp trigger_matches?(_instance, %Transition{trigger: {:on, expected}}, %Event{
         name: actual
       }),
       do: on_event_matches?(expected, actual)

  defp trigger_matches?(
         _instance,
         %Transition{trigger: {:on_set, expected}},
         %Event{
           kind: :set_event
         } = event
       ),
       do: expected in event_member_names(event)

  defp trigger_matches?(
         instance,
         %Transition{trigger: {:on_call, _expected}} = transition,
         %Event{
           kind: :call_event
         } = event
       ),
       do:
         Enum.any?(
           transition_snapshot_events(instance, transition),
           &(&1 in call_event_names(event))
         )

  defp trigger_matches?(instance, %Transition{trigger: {:when, fun}}, %Event{} = event),
    do: truthy_result!(invoke(fun, instance, event))

  defp trigger_matches?(
         instance,
         %Transition{trigger: {:when, fun, _attributes}},
         %Event{} = event
       ),
       do: truthy_result!(invoke(fun, instance, event))

  defp trigger_matches?(_instance, %Transition{trigger: {:after, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: %{id: transition_id}}
       }),
       do: current.id == transition_id

  defp trigger_matches?(_instance, %Transition{trigger: {:every, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: %{id: transition_id}}
       }),
       do: current.id == transition_id

  defp trigger_matches?(_instance, %Transition{trigger: {:at, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: %{id: transition_id}}
       }),
       do: current.id == transition_id

  defp trigger_matches?(_instance, _transition, _event), do: false

  defp guard_passes?(_instance, %Transition{guard: nil}, _event), do: true

  defp guard_passes?(
         instance,
         %Transition{guard: {:exit_point, name, _guarded?, user_guard, _final_name}} = transition,
         event
       ) do
    exit_point_final_path?(instance.state) and
      exit_point_name_from_final_path(instance.state) == name and
      exit_point_guard_passes?(instance, user_guard, event, %{
        path: transition_operation_scope(transition)
      })
  end

  defp guard_passes?(instance, %Transition{guard: guard} = transition, event)
       when is_binary(guard) do
    named_guard_passes?(instance, guard, event, %{path: transition_operation_scope(transition)})
  end

  defp guard_passes?(instance, %Transition{guard: guard}, event),
    do: truthy_result!(invoke(guard, instance, event))

  defp exit_point_guard_passes?(_instance, nil, _event, _context), do: true

  defp exit_point_guard_passes?(instance, guard, event, context) when is_binary(guard) do
    named_guard_passes?(instance, guard, event, context)
  end

  defp exit_point_guard_passes?(instance, guard, event, _context),
    do: truthy_result!(invoke(guard, instance, event))

  defp transition_operation_scope(%Transition{
         guard: {:exit_point, _name, _guarded?, _user_guard, _guard},
         owner: owner,
         source: source
       })
       when owner == source,
       do: DSL.parent(owner) || owner

  defp transition_operation_scope(%Transition{owner: owner, source: source}), do: owner || source

  defp named_guard_passes?(instance, guard, event, context) do
    {key, callback} = operation_callback!(instance, guard, context)
    observe(instance, "behavior", qualified_member_name(instance, key), event)
    truthy_result!(invoke(callback, instance, event))
  end

  defp take_transition(instance, %Transition{target: nil} = transition, event) do
    with_transition_processing(instance, fn ->
      observation_source = transition_observation_source(transition)

      instance =
        instance
        |> observe("event", observation_source, event)
        |> run_actions(transition.effects, event, %{
          action: :effect,
          source: observation_source,
          path: transition_operation_scope(transition)
        })

      {instance, :internal}
    end)
  end

  defp take_transition(instance, %Transition{} = transition, event) do
    with_transition_processing(instance, fn ->
      observation_source = transition_observation_source(transition)
      snapshot_source = exit_point_snapshot_state(instance) || instance.state
      source = transition.source || instance.state
      target_node = instance.model.states[transition.target]
      dynamic? = dynamic_target?(instance, transition.target)

      skip_history_owner =
        case target_node do
          %Node{kind: kind, parent: parent} when kind in [:shallow_history, :deep_history] ->
            parent

          _ ->
            nil
        end

      path_target = transition.target

      {exit_paths, path_lca, static_enter_paths, history_entries} =
        case transition_path_plan(instance, transition) do
          %{exit: exit_paths, lca: path_lca, enter: enter_paths, history: history_entries} ->
            {exit_paths, path_lca, enter_paths, history_entries}

          nil ->
            {exit_paths, path_lca} =
              transition_paths(
                instance.model,
                source,
                path_target,
                transition.kind,
                transition.trigger,
                instance.state
              )

            {exit_paths, path_lca, nil, nil}
        end

      instance =
        instance
        |> remember_history(exit_paths, skip_history_owner, history_entries)
        |> exit_states(exit_paths, event)
        |> observe("event", observation_source, event)
        |> run_actions(transition.effects, event, %{
          action: :effect,
          source: observation_source,
          path: transition_operation_scope(transition)
        })

      {instance, target} =
        if dynamic?,
          do: resolve_dynamic_target(instance, transition.target, event),
          else: {instance, path_target}

      enter_paths =
        if is_list(static_enter_paths) and target == path_target do
          static_enter_paths
        else
          enter_lca =
            cond do
              transition.kind == :self -> path_lca
              reentering_source?(source, path_target, path_lca) -> path_lca
              target == path_target -> path_lca
              true -> DSL.lca(source, target)
            end

          path_from_lca(instance.model, target, enter_lca)
        end

      instance =
        instance
        |> enter_states(enter_paths, event)
        |> maybe_set_target_state(target, enter_paths)
        |> maybe_enter_default(target, event)
        |> maybe_completion_with_exit_point_snapshot(event, snapshot_source)

      {instance, :transitioned}
    end)
  end

  defp maybe_completion_with_exit_point_snapshot(instance, event, snapshot_source) do
    if exit_point_final?(instance) do
      with_exit_point_snapshot_state(instance, snapshot_source, fn ->
        maybe_completion(instance, event)
      end)
    else
      maybe_completion(instance, event)
    end
  end

  defp resolve_dynamic_target(instance, target, event) do
    case instance.model.states[target] do
      %Node{kind: kind} = node when kind in [:choice, :entry_point, :exit_point] ->
        choice_target(instance, node, event)

      %Node{kind: :shallow_history} = node ->
        history_target(instance, node, event, :shallow)

      %Node{kind: :deep_history} = node ->
        history_target(instance, node, event, :deep)

      _ ->
        {instance, target}
    end
  end

  defp dynamic_target?(instance, target) do
    case instance.model.states[target] do
      %Node{kind: kind}
      when kind in [:choice, :shallow_history, :deep_history, :entry_point, :exit_point] ->
        true

      _ ->
        false
    end
  end

  defp maybe_set_target_state(instance, target, []), do: %{instance | state: target}
  defp maybe_set_target_state(instance, _target, _enter_paths), do: instance

  defp choice_target(instance, node, event) do
    transition =
      Enum.find(node.transitions, fn transition ->
        guard_passes?(instance, transition, event)
      end)

    if transition do
      observation_source = transition_observation_source(transition)

      instance
      |> observe("event", observation_source, event)
      |> run_actions(transition.effects, event, %{
        action: :effect,
        source: observation_source,
        path: transition_operation_scope(transition)
      })
      |> resolve_dynamic_target(transition.target, event)
    else
      {instance, node.path}
    end
  end

  defp history_target(instance, node, event, kind) do
    remembered =
      case kind do
        :shallow -> Map.get(instance.history_shallow, node.parent)
        :deep -> Map.get(instance.history_deep, node.parent)
      end

    if remembered do
      {instance, remembered}
    else
      transition =
        Enum.find(node.transitions, fn transition ->
          guard_passes?(instance, transition, event)
        end)

      if transition do
        observation_source = transition_observation_source(transition)

        instance
        |> observe("event", observation_source, event)
        |> run_actions(transition.effects, event, %{
          action: :effect,
          source: observation_source,
          path: transition_operation_scope(transition)
        })
        |> resolve_dynamic_target(transition.target, event)
      else
        {instance, node.parent}
      end
    end
  end

  defp transition_paths(model, source, target, kind, trigger, active_leaf) do
    cond do
      kind == :internal ->
        {[], source}

      kind == :self ->
        lca = DSL.parent(source)

        exit_paths =
          active_path(model, active_leaf)
          |> Enum.take_while(&(&1 != lca))

        {exit_paths, lca}

      true ->
        lca = external_lca(model, source, target, kind, trigger)

        exit_paths =
          active_path(model, active_leaf)
          |> Enum.take_while(&(&1 != lca))

        {exit_paths, lca}
    end
  end

  defp external_lca(model, source, target, :external, trigger) do
    if trigger != nil and source != model.root and path_below_scope?(target, source),
      do: DSL.parent(source),
      else: DSL.lca(source, target)
  end

  defp external_lca(_model, source, target, _kind, _trigger), do: DSL.lca(source, target)

  defp reentering_source?(source, path_target, path_lca),
    do: path_lca == DSL.parent(source) and path_below_scope?(path_target, source)

  defp path_from_lca(model, target, lca) do
    model
    |> active_path(target)
    |> Enum.take_while(&(&1 != lca))
    |> Enum.reverse()
  end

  defp transition_path_plan(instance, transition) do
    instance.model.transition_candidates
    |> Map.get(@transition_paths_key, %{})
    |> Map.get({instance.state, transition})
  end

  defp enter_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]
      acc = %{acc | state: path}

      acc
      |> run_actions(node.entry, event, %{action: :entry, path: path})
      |> run_activity_actions(path, node.activity, event)
      |> schedule_timers(path, event)
    end)
  end

  defp exit_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]

      acc
      |> cancel_activities(path, event)
      |> cancel_timers(path)
      |> run_actions(node.exit, event, %{action: :exit, path: path})
    end)
  end

  defp maybe_enter_default(instance, target, event) do
    node = instance.model.states[target]

    cond do
      node == nil ->
        instance

      node.initial != nil ->
        elem(take_transition(instance, node.initial, event), 0)

      true ->
        instance
    end
  end

  defp maybe_completion(instance, cause_event) do
    case instance.model.states[instance.state] do
      %Node{kind: :final, parent: parent} ->
        instance = %{instance | done?: parent == instance.model.root}
        event = Event.completion("hsm/final", cause_event.data)

        try do
          parent_transition = completion_transition(instance, parent, event)

          if parent_transition do
            instance = carry_deferred_across_child_exit(instance, parent_transition)
            elem(take_transition(instance, parent_transition, event), 0)
          else
            maybe_raise_unhandled_exit_point!(instance)
          end
        catch
          {:behavior_error, code, message} = error ->
            if exit_point_final?(instance) do
              throw(error)
            else
              clear_generated_runtime(instance)
              throw({:hsm_completion_error, instance, code, message})
            end
        end

      _ ->
        instance
    end
  end

  defp completion_transition(instance, parent, event) do
    instance
    |> completion_candidates(parent, event)
    |> Enum.find(fn transition ->
      completion_trigger?(transition.trigger) and guard_passes?(instance, transition, event)
    end)
  end

  defp completion_candidates(instance, parent, event) do
    if exit_point_final?(instance) do
      parents =
        Stream.iterate(parent, &DSL.parent/1)
        |> Enum.take_while(&(&1 not in [nil, "", "."]))
        |> Enum.filter(&Map.has_key?(instance.model.states, &1))

      [local_parent | ancestors] = parents

      ancestor_candidates =
        Enum.flat_map(ancestors, &completion_candidates_for(instance, &1, event))

      {source_handlers, broader_handlers} =
        Enum.split_with(ancestor_candidates, &(&1.source == parent))

      local_candidates = completion_candidates_for(instance, local_parent, event)
      owner_parent = DSL.parent(parent)

      {inherited_source_handlers, other_local_handlers} =
        Enum.split_with(
          local_candidates,
          &(&1.owner == owner_parent and &1.source == parent)
        )

      {guarded_local_handlers, local_handlers} =
        Enum.split_with(other_local_handlers, &(&1.owner == parent and user_guarded?(&1)))

      source_handlers ++
        guarded_local_handlers ++ inherited_source_handlers ++ local_handlers ++ broader_handlers
    else
      completion_candidates_for(instance, parent, event)
    end
  end

  defp completion_candidates_for(instance, parent, event) do
    instance
    |> transition_candidates(parent)
    |> candidate_transitions(instance, :all, event)
    |> prioritize_exit_point_handlers(instance)
  end

  defp prioritize_exit_point_handlers(transitions, instance) do
    case instance.model.states[instance.state] do
      %Node{} = node ->
        if exit_point_final_node?(node),
          do: Enum.sort_by(transitions, &is_nil(&1.guard)),
          else: transitions

      _ ->
        transitions
    end
  end

  defp user_guarded?(%Transition{guard: {:exit_point, _name, guarded?, _user_guard, _guard}}),
    do: guarded?

  defp user_guarded?(%Transition{guard: guard}), do: guard != nil

  defp maybe_raise_unhandled_exit_point!(instance) do
    case instance.model.states[instance.state] do
      %Node{path: path} = node ->
        if exit_point_final_node?(node) do
          raise ValidationError,
            message: "unhandled_exit_point #{exit_point_name_from_final_path(path)}"
        else
          instance
        end

      _ ->
        instance
    end
  end

  defp exit_point_final?(instance) do
    case instance.model.states[instance.state] do
      %Node{} = node -> exit_point_final_node?(node)
      _node -> false
    end
  end

  defp exit_point_final_node?(%Node{kind: :final, name: "__hsm_exit_" <> _, path: path}),
    do: exit_point_final_path?(path)

  defp exit_point_final_node?(_node), do: false

  defp exit_point_final_path?(path) when is_binary(path),
    do: String.contains?(path, @exit_point_final_marker)

  defp exit_point_name_from_final_path(path) do
    path
    |> String.split(@exit_point_final_marker, parts: 2)
    |> List.last()
  end

  defp completion_trigger?({:on, "FinalEvent"}), do: true
  defp completion_trigger?({:on, "hsm/final"}), do: true
  defp completion_trigger?({:on, :completion}), do: true
  defp completion_trigger?(_trigger), do: false

  defp remember_history(instance, [], _skip_owner, _history_entries), do: instance

  defp remember_history(instance, _exit_paths, skip_owner, history_entries)
       when is_list(history_entries) do
    Enum.reduce(history_entries, instance, fn
      {parent, _path, _leaf}, acc when parent == skip_owner ->
        acc

      {parent, path, leaf}, acc ->
        %{
          acc
          | history_shallow: Map.put(acc.history_shallow, parent, path),
            history_deep: Map.put(acc.history_deep, parent, leaf)
        }
    end)
  end

  defp remember_history(instance, exit_paths, skip_owner, nil) do
    leaf = List.first(exit_paths)

    Enum.reduce(exit_paths, instance, fn path, acc ->
      case DSL.parent(path) do
        nil ->
          acc

        parent when parent == skip_owner ->
          acc

        parent ->
          %{
            acc
            | history_shallow: Map.put(acc.history_shallow, parent, path),
              history_deep: Map.put(acc.history_deep, parent, leaf)
          }
      end
    end)
  end

  defp active_path(model, leaf), do: Map.fetch!(model.active_paths, leaf)

  defp active_deferred_events(instance),
    do: active_deferred_events(instance, instance.state)

  defp active_deferred_events(instance, state) do
    Map.fetch!(instance.model.active_defers, state)
  end

  defp schedule_timers(instance, path, event) do
    case timer_transitions(instance, path) do
      [] ->
        instance

      timer_transitions ->
        {instance, timers} =
          Enum.reduce(timer_transitions, {instance, []}, fn transition, {acc, timers} ->
            {kind, value} = transition.trigger

            case timer_interval(acc, kind, value, path, event) do
              {:ok, interval} ->
                duration = timer_duration(acc.logical_time, kind, interval)

                clock_wait =
                  Clock.wait(acc.clock, duration, %{instance: acc, path: path})

                wait_duration = clock_wait_duration(clock_wait, duration)
                timer_id = unique_id()

                timer =
                  %{
                    id: timer_id,
                    ref: nil,
                    source: path,
                    transition: transition,
                    kind: kind,
                    interval: interval,
                    duration: wait_duration,
                    clock_wait: clock_wait,
                    due: acc.logical_time + wait_duration
                  }

                {acc, [arm_timer(timer, acc) | timers]}

              {:error, error} ->
                {handle_timer_error(acc, error, true), timers}

              {:behavior_error, _code, message} ->
                {handle_timer_error(acc, message, false), timers}
            end
          end)

        %{instance | timers: put_timers(instance.timers, Enum.reverse(timers))}
    end
  end

  defp timer_transitions(instance, path) do
    Map.fetch!(instance.model.timer_transitions, path)
  end

  defp arm_timer(timer, instance) do
    ref =
      Clock.new_timer(
        instance.clock,
        timer.duration,
        {:hsm_timer, timer.id}
      )

    %{timer | ref: ref}
  end

  defp cancel_timers(instance, path) do
    {cancelled, active} = Enum.split_with(instance.timers, &(&1.source == path))
    Enum.each(cancelled, &cancel_timer/1)
    %{instance | timers: active}
  end

  defp cancel_all_timers(instance) do
    Enum.each(instance.timers, &cancel_timer/1)
    %{instance | timers: []}
  end

  defp fire_due_timers(instance) do
    case pop_due_timer(instance.timers, instance.logical_time) do
      nil ->
        instance

      {timer, timers} ->
        cancel_consumed_host_timer(timer)

        instance
        |> Map.put(:timers, timers)
        |> dispatch_timer(timer)
        |> elem(0)
        |> maybe_reschedule_every_timer(timer)
        |> fire_due_timers()
    end
  end

  defp dispatch_timer(instance, timer) do
    case enqueue_event(instance, timer_event(timer)) do
      {queued, nil} -> process_event(queued)
      {queued, error} -> handle_runtime_error(queued, error)
    end
  end

  defp pop_due_timer(timers, now) do
    case timers do
      [%{due: due} = timer | rest] when due <= now -> {timer, rest}
      _ -> nil
    end
  end

  defp put_timers(timers, new_timers) do
    Enum.reduce(new_timers, timers, &insert_timer(&2, &1))
  end

  defp insert_timer(timers, timer) do
    {before, after_} = Enum.split_while(timers, &(&1.due <= timer.due))
    before ++ [timer | after_]
  end

  defp timer_event(timer) do
    %Event{
      name: "__timer_#{timer.kind}__",
      kind: :timer_event,
      data: %{source: timer.source, transition: timer.transition, timer: timer.id}
    }
  end

  defp cancel_consumed_host_timer(%{id: id, ref: {:hsm_timer, ref}}) when is_reference(ref),
    do: cancel_native_timer(ref, id)

  defp cancel_consumed_host_timer(%{id: id, ref: ref}) when is_reference(ref),
    do: cancel_native_timer(ref, id)

  defp cancel_consumed_host_timer(_timer), do: false

  defp cancel_timer(%{id: id, ref: {:hsm_timer, ref}}) when is_reference(ref),
    do: cancel_native_timer(ref, id)

  defp cancel_timer(%{id: id, ref: ref}) when is_reference(ref), do: cancel_native_timer(ref, id)
  defp cancel_timer(%{ref: ref}), do: Clock.cancel_timer(ref)

  defp cancel_native_timer(ref, id) do
    case Process.cancel_timer(ref) do
      false -> drain_timer_message(id)
      result -> result
    end
  end

  defp drain_timer_message(nil), do: false

  defp drain_timer_message(timer_id) do
    receive do
      {:hsm_timer, ^timer_id} -> true
    after
      0 -> false
    end
  end

  defp timer_value(_instance, value, _path, _event) when is_integer(value), do: value

  defp timer_value(instance, value, _path, _event) when is_binary(value),
    do: Map.fetch!(instance.attributes, value)

  defp timer_value(instance, fun, path, event) when is_function(fun) do
    invoke_with_context(fun, instance, %Event{name: "TimerSchedule"}, %{
      action: :timer_source,
      path: path,
      initial?: event.kind == :initial_event
    })
  end

  defp timer_interval(instance, kind, value, path, event) do
    try do
      interval = timer_value(instance, value, path, event)

      if valid_timer_interval?(kind, interval) do
        {:ok, interval}
      else
        {:error, "invalid interval"}
      end
    rescue
      error -> {:error, Exception.message(error)}
    catch
      {:behavior_error, code, message} -> {:behavior_error, code, message}
      kind, reason -> :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp valid_timer_interval?(:every, interval), do: is_integer(interval) and interval > 0
  defp valid_timer_interval?(_kind, interval), do: is_integer(interval) and interval >= 0

  defp timer_duration(now, :at, value), do: max(value - now, 0)
  defp timer_duration(_now, _kind, value), do: value

  defp reschedule_every_timer(timer, instance) do
    {_kind, value} = timer.transition.trigger

    with {:ok, interval} <-
           timer_interval(instance, :every, value, timer.source, %Event{name: "TimerSchedule"}) do
      clock_wait =
        Clock.wait(instance.clock, interval, %{instance: instance, path: timer.source})

      wait_duration = clock_wait_duration(clock_wait, interval)
      duration = max(wait_duration, interval)

      {:ok,
       timer
       |> Map.put(:id, unique_id())
       |> Map.put(:interval, interval)
       |> Map.put(:due, instance.logical_time + duration)
       |> Map.put(:duration, duration)
       |> Map.put(:clock_wait, clock_wait)
       |> Map.put(:ref, nil)}
    end
  end

  defp maybe_reschedule_every_timer(instance, %{kind: :every} = timer) do
    cond do
      timer.source not in active_path(instance.model, instance.state) ->
        instance

      Process.get(:hsm_runtime_timer_error) ->
        instance

      timer_scheduled?(instance, timer) ->
        instance

      true ->
        case reschedule_every_timer(timer, instance) do
          {:ok, timer} ->
            %{instance | timers: put_timers(instance.timers, [arm_timer(timer, instance)])}

          {:error, error} ->
            handle_timer_error(instance, error, true)

          {:behavior_error, _code, message} ->
            handle_timer_error(instance, message, false)
        end
    end
  end

  defp maybe_reschedule_every_timer(instance, _timer), do: instance

  defp handle_timer_error(instance, error, trace?) do
    if trace?, do: put_timer_error(error)
    dispatch(instance, error_event(error)) |> elem(0)
  end

  defp timer_scheduled?(instance, timer) do
    Enum.any?(
      instance.timers,
      &(&1.source == timer.source and &1.transition.id == timer.transition.id)
    )
  end

  defp put_timer_error(error), do: Process.put(:hsm_runtime_timer_error, error)
  defp take_timer_error, do: Process.delete(:hsm_runtime_timer_error)

  defp clear_timer_error(instance) do
    unless Process.get(:hsm_runtime_preserve_timer_error), do: take_timer_error()
    instance
  end

  defp clear_timer_error_result({%__MODULE__{} = instance, status}),
    do: {clear_timer_error(instance), status}

  defp clear_timer_error_result(other), do: other

  defp clear_deferred_generated_result({%__MODULE__{} = instance, :deferred} = result, true) do
    clear_deferred_generated_work(instance)
    result
  end

  defp clear_deferred_generated_result(result, _top_level?), do: result

  defp clear_deferred_generated_work(instance) do
    delete_generated_value(:hsm_runtime_generated_attributes, instance)
    delete_generated_value(:hsm_runtime_generated_events, instance)
    delete_generated_value(:hsm_runtime_generated_hook_events, instance)
    delete_generated_value(:hsm_runtime_generated_queue, instance)
  end

  defp clear_popped_deferred_result({%__MODULE__{} = instance, _status} = result, true) do
    delete_generated_value(:hsm_runtime_popped_deferred, instance)
    delete_generated_value(:hsm_runtime_popped_queued_deferred, instance)
    result
  end

  defp clear_popped_deferred_result(result, true), do: result
  defp clear_popped_deferred_result(result, false), do: result

  defp clock_wait_duration({:ok, duration}, _default) when is_integer(duration), do: duration
  defp clock_wait_duration(duration, _default) when is_integer(duration), do: duration
  defp clock_wait_duration(_wait, default), do: default

  defp cancel_activities(instance, path, event) do
    {cancelled, active} =
      Enum.split_with(instance.active_activities, fn %ActivityHandle{path: active_path} ->
        active_path == path
      end)

    instance = %{instance | active_activities: active}

    Enum.reduce(cancelled, instance, fn %ActivityHandle{cancel: cancel}, acc ->
      case cancel do
        fun when is_function(fun) ->
          case invoke_with_context(fun, acc, event, %{action: :activity_cancel, path: path}) do
            %__MODULE__{} = updated -> updated
            {%__MODULE__{} = updated, _status} -> updated
            _ -> acc
          end

        _ ->
          acc
      end
    end)
  end

  defp run_activity_actions(instance, path, actions, event) do
    run_actions(instance, actions, event, %{action: :activity, path: path})
  end

  defp run_actions(instance, [], _event, _context), do: instance

  defp run_actions(instance, actions, event, context) do
    context = Map.put(context, :initial?, event.kind == :initial_event)

    Enum.reduce(actions, instance, fn action, acc ->
      acc = observe(acc, "behavior", action_source(acc, context, action), event)

      result =
        with_action_context(context, fn ->
          case action do
            name when is_binary(name) ->
              {_key, callback} = operation_callback!(acc, name, context)
              invoke_with_context(callback, acc, event, context)

            fun when is_function(fun) ->
              invoke_with_context(fun, acc, event, context)

            %{__struct__: HSM.Group} = group ->
              HSM.Group.dispatch(group, event)

            _ ->
              acc
          end
        end)

      if context.action == :activity, do: :ok, else: reject_async_result!(result)

      case result do
        %__MODULE__{} = updated ->
          updated

        {%__MODULE__{} = updated, _status} ->
          updated

        %Task{} = task when context.action == :activity ->
          remember_activity(acc, task_activity_handle(task), context)

        %ActivityHandle{} = handle ->
          remember_activity(acc, handle, context)

        {:hsm_activity, cancel} ->
          remember_activity(acc, %ActivityHandle{cancel: cancel}, context)

        {:hsm_activity, metadata, cancel} ->
          remember_activity(acc, %ActivityHandle{metadata: metadata, cancel: cancel}, context)

        _ ->
          acc
      end
    end)
  end

  defp with_action_context(context, fun) do
    previous = Process.get(:hsm_runtime_action_context, @missing)
    Process.put(:hsm_runtime_action_context, context)

    try do
      fun.()
    after
      restore_process_key(:hsm_runtime_action_context, previous)
    end
  end

  defp remember_activity(instance, handle, %{action: :activity, path: path}) do
    %{instance | active_activities: instance.active_activities ++ [%{handle | path: path}]}
  end

  defp remember_activity(instance, _handle, _context), do: instance

  defp task_activity_handle(%Task{} = task) do
    Task.ignore(task)
    ref = Process.monitor(task.pid)

    %ActivityHandle{
      metadata: %{task: task, ref: ref},
      cancel: fn ->
        Process.demonitor(ref, [:flush])
        Task.shutdown(task, :brutal_kill)
      end
    }
  end

  defp pop_activity(instance, ref, pid) do
    {matches, active} =
      Enum.split_with(
        instance.active_activities,
        &activity_monitor_matches?(&1, ref, pid)
      )

    {%{instance | active_activities: active}, List.first(matches)}
  end

  defp activity_monitor_matches?(
         %ActivityHandle{metadata: %{ref: ref, task: %Task{pid: pid}}},
         ref,
         pid
       ),
       do: true

  defp activity_monitor_matches?(_handle, _ref, _pid), do: false

  defp normal_activity_reason?(:normal), do: true
  defp normal_activity_reason?(:shutdown), do: true
  defp normal_activity_reason?({:shutdown, _reason}), do: true
  defp normal_activity_reason?(_reason), do: false

  defp activity_error({%{__struct__: _} = error, _stack}) do
    if is_exception(error), do: Exception.message(error), else: inspect(error)
  end

  defp activity_error(reason), do: reason

  defp observe(%__MODULE__{model: %{observers: []}} = instance, _occurrence, _source, _event),
    do: instance

  defp observe(instance, occurrence, source, event) do
    observation = Event.observation(source, occurrence, event, instance.logical_time)

    Enum.each(instance.model.observers, fn {observer, targets} ->
      if observer_matches?(targets, source, observation, event) do
        result =
          invoke_with_context(observer, instance, observation, %{
            action: :observer,
            source: source
          })

        reject_async_result!(result)
      end
    end)

    instance
  end

  defp observer_matches?([], _source, _observation, _event), do: true

  defp observer_matches?(targets, source, observation, event) do
    member_names = [source, observation.name]

    event_names =
      if Map.fetch!(observation.data, :Occurrence) == "event",
        do: [event.name, event.source],
        else: []

    names = member_names ++ event_names

    Enum.any?(targets, &(observer_target_name(&1) in names))
  end

  defp observer_target_name(%Event{name: name}), do: name
  defp observer_target_name(%{name: name}) when is_binary(name), do: name
  defp observer_target_name(name) when is_binary(name), do: name
  defp observer_target_name(other), do: other

  defp action_source(instance, context, name) when is_binary(name),
    do: qualified_member_name(instance, operation_source_key(instance, name, context))

  defp action_source(_instance, %{source: source}, _action) when is_binary(source), do: source
  defp action_source(_instance, %{path: path, action: action}, _action), do: "#{path}/#{action}"

  defp action_source(instance, %{action: action}, _action), do: "#{instance.state}/#{action}"
  defp action_source(instance, _context, _action), do: instance.state

  defp invoke_with_context(fun, instance, event, context) when is_function(fun, 3),
    do: fun.(callback_context(instance, context), instance, event)

  defp invoke_with_context(fun, instance, event, _context), do: invoke(fun, instance, event)

  defp callback_context(instance, fallback) do
    case Process.get(:hsm_runtime_context, @missing) do
      %HSM.Context{} = ctx -> HSM.Context.extend_current(ctx, instance)
      _missing -> fallback
    end
  end

  defp operation_callback(instance, name, context) do
    instance
    |> operation_candidate_keys(name, context)
    |> Enum.find_value(fn key ->
      case operation_callback_for_key(instance, key) do
        callback when is_function(callback) -> {key, callback}
        _missing -> nil
      end
    end) || {operation_key(instance, name), nil}
  end

  defp operation_callback!(instance, name, context) do
    case operation_callback(instance, name, context) do
      {key, fun} when is_function(fun) -> {key, fun}
      _missing -> raise ValidationError, message: "unknown operation #{inspect(name)}"
    end
  end

  defp operation_source_key(instance, name, context) do
    instance
    |> operation_candidate_keys(name, context)
    |> Enum.find(&Map.has_key?(instance.model.operations, &1))
    |> Kernel.||(operation_key(instance, name))
  end

  defp operation_callback_for_key(instance, key) do
    case Map.fetch(instance.model.operations, key) do
      {:ok, callback} when is_function(callback) -> callback
      {:ok, @operation_contract} -> runtime_operation_callback(instance, key)
      {:ok, nil} -> runtime_operation_callback(instance, key)
      :error -> nil
    end
  end

  defp runtime_operation_callback(instance, key) do
    with callback when is_function(callback) <-
           runtime_operation_fun(instance.data, runtime_operation_names(instance, key)) do
      fn ctx, current, event ->
        args =
          case event.data do
            %HSM.CallData{Args: args} -> args
            _data -> []
          end

        invoke_runtime_operation(callback, ctx, current, List.wrap(args))
      end
    end
  end

  defp runtime_operation_names(instance, key) do
    [qualified_member_name(instance, key), key, basename(key)]
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end

  defp runtime_operation_fun(data, names) do
    case find_runtime_operation(data, names) do
      fun when is_function(fun) -> fun
      _other -> nil
    end
  end

  defp find_runtime_operation(data, names) when is_map(data) do
    operations = Map.get(data, :operations, Map.get(data, "operations"))

    Enum.find_value(names, fn name ->
      map_operation(data, name) || find_runtime_operation(operations, [name])
    end)
  end

  defp find_runtime_operation(data, names) when is_list(data),
    do: Enum.find_value(names, &keyword_operation(data, &1))

  defp find_runtime_operation(_data, _keys), do: nil

  defp map_operation(data, name) do
    Map.get(data, name) || (existing_atom(name) && Map.get(data, existing_atom(name)))
  end

  defp keyword_operation(data, name) do
    atom_name = existing_atom(name)
    (atom_name && Keyword.get(data, atom_name)) || Keyword.get(data, name)
  end

  defp existing_atom(nil), do: nil

  defp existing_atom(name) do
    String.to_existing_atom(name)
  rescue
    ArgumentError -> nil
  end

  defp invoke_runtime_operation(fun, ctx, instance, args) do
    arity = fun_arity(fun)

    cond do
      arity == length(args) ->
        apply(fun, args)

      arity == length(args) + 2 ->
        apply(fun, [ctx, instance | args])

      arity == length(args) + 1 ->
        apply(fun, [instance | args])

      true ->
        apply(fun, args)
    end
  end

  defp fun_arity(fun) do
    {:arity, arity} = :erlang.fun_info(fun, :arity)
    arity
  end

  defp invoke(fun, instance, event) when is_function(fun, 3), do: fun.(nil, instance, event)
  defp invoke(fun, instance, event) when is_function(fun, 2), do: fun.(instance, event)
  defp invoke(fun, _instance, event) when is_function(fun, 1), do: fun.(event)
  defp invoke(fun, _instance, _event) when is_function(fun, 0), do: fun.()

  defp attribute_key(instance, name), do: member_key(instance, name)
  defp operation_key(instance, name), do: member_key(instance, name)

  defp operation_candidate_keys(instance, "/" <> _ = name, _context),
    do: [operation_key(instance, name)]

  defp operation_candidate_keys(instance, name, context) do
    key = operation_key(instance, name)

    instance
    |> operation_scope(context)
    |> operation_scope_candidates()
    |> Enum.map(&scoped_operation_key(instance, &1, key))
    |> Kernel.++([key])
    |> Enum.uniq()
  end

  defp operation_scope(_instance, %{path: path}) when is_binary(path), do: path
  defp operation_scope(instance, _context), do: instance.state

  defp operation_scope_candidates(nil), do: []

  defp operation_scope_candidates(path) do
    Stream.iterate(path, &DSL.parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", "."]))
  end

  defp scoped_operation_key(instance, path, key),
    do: [relative_scope(instance, path), key] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")

  defp relative_scope(%__MODULE__{model: %{path: root}}, path) when is_binary(path) do
    cond do
      path == root -> ""
      String.starts_with?(path, root <> "/") -> String.replace_prefix(path, root <> "/", "")
      true -> path
    end
  end

  defp relative_scope(_instance, _path), do: ""

  defp member_key(instance, "/" <> _ = name) do
    if String.starts_with?(name, instance.model.path <> "/"),
      do: String.replace_prefix(name, instance.model.path <> "/", ""),
      else: name
  end

  defp member_key(_instance, name), do: name

  defp qualified_member_name(_instance, "/" <> _ = name), do: name
  defp qualified_member_name(instance, name), do: instance.model.path <> "/" <> name

  defp event_member_names(%Event{name: name, data: %HSM.AttributeChange{Name: data_name}}),
    do: member_name_variants(name, data_name)

  defp event_member_names(%Event{name: name, data: %HSM.CallData{Name: data_name}}),
    do: member_name_variants(name, data_name)

  defp event_member_names(%Event{name: "@call:" <> name}), do: [name]
  defp event_member_names(%Event{data: %{name: name}}), do: [name]
  defp event_member_names(%Event{name: name}), do: member_name_variants(name, name)

  defp call_event_names(%Event{name: name, data: %HSM.CallData{Name: data_name}}) do
    [name, data_name]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp call_event_names(%Event{name: name}), do: [name]

  defp member_name_variants(name, data_name) do
    [name, data_name, basename(name), basename(data_name)]
    |> Enum.filter(&is_binary/1)
    |> Enum.uniq()
  end

  defp basename(nil), do: nil
  defp basename(name), do: name |> String.split("/", trim: true) |> List.last()

  defp truthy_result!(value) do
    reject_async_result!(value)
    truthy?(value)
  end

  defp reject_async_result!(%Task{}) do
    raise ValidationError, message: "sequential behavior must not return Task"
  end

  defp reject_async_result!(_value), do: :ok

  defp truthy?(value), do: value not in [false, nil]

  defp qualify_attributes(instance) do
    Map.new(instance.attributes, fn {key, value} -> {instance.model.path <> "/" <> key, value} end)
  end

  defp event_detail(event),
    do: %{
      Event: event.name,
      Target: event.target,
      Guard: false,
      Schema: event.schema
    }

  defp transition_snapshots(instance) do
    instance.model
    |> active_path(instance.state)
    |> Enum.flat_map(fn path ->
      instance.model.transition_candidates
      |> Map.get(path, %{list: []})
      |> Map.fetch!(:list)
    end)
    |> Enum.uniq_by(&{&1.source, &1.id})
    |> Enum.map(&transition_snapshot(instance, &1))
  end

  defp transition_snapshot(instance, transition) do
    %TransitionSnapshot{
      Name: transition_snapshot_name(transition),
      Kind: transition_snapshot_kind(transition),
      Source: transition.source,
      Target: transition.target,
      Events: transition_snapshot_events(instance, transition),
      Guard: transition_snapshot_guard?(transition)
    }
  end

  defp transition_snapshot_name(%Transition{} = transition),
    do: transition_observation_source(transition)

  defp transition_observation_source(%Transition{id: "/" <> _ = id}), do: id

  defp transition_observation_source(%Transition{source: source, id: id})
       when is_binary(source) and is_binary(id),
       do: source <> "/" <> basename(id)

  defp transition_observation_source(%Transition{id: id}) when is_binary(id), do: id

  defp transition_observation_source(%Transition{source: source}) when is_binary(source),
    do: source

  defp transition_snapshot_kind(%Transition{trigger: trigger})
       when trigger in [{:on, "FinalEvent"}, {:on, "hsm/final"}, {:on, :completion}],
       do: :local

  defp transition_snapshot_kind(%Transition{kind: kind})
       when kind in [:external, :internal, :local, :self],
       do: kind

  defp transition_snapshot_events(_instance, %Transition{trigger: {:on, "FinalEvent"}}),
    do: ["hsm/final"]

  defp transition_snapshot_events(_instance, %Transition{trigger: {:on, "hsm/final"}}),
    do: ["hsm/final"]

  defp transition_snapshot_events(_instance, %Transition{trigger: {:on, events}})
       when is_list(events),
       do: events

  defp transition_snapshot_events(_instance, %Transition{trigger: {:on, event}}), do: [event]

  defp transition_snapshot_events(instance, %Transition{trigger: {:on_set, attribute}}),
    do: [instance.model.path <> "/" <> attribute]

  defp transition_snapshot_events(
         instance,
         %Transition{trigger: {:on_call, operation}} = transition
       ) do
    {key, _callback} =
      operation_callback(instance, operation, %{path: transition_operation_scope(transition)})

    [qualified_member_name(instance, key)]
  end

  defp transition_snapshot_events(_instance, %Transition{
         trigger: {:at, _},
         source: source,
         id: id
       }),
       do: [source <> "/" <> id <> "/timepoint"]

  defp transition_snapshot_events(_instance, %Transition{
         trigger: {kind, _},
         source: source,
         id: id
       })
       when kind in [:after, :every],
       do: [source <> "/" <> id <> "/duration"]

  defp transition_snapshot_events(_instance, %Transition{}), do: []

  defp transition_snapshot_guard?(%Transition{trigger: {kind, _}})
       when kind in [:after, :every, :at],
       do: true

  defp transition_snapshot_guard?(%Transition{
         guard: {:exit_point, _name, guarded?, _user_guard, _guard}
       }),
       do: guarded?

  defp transition_snapshot_guard?(%Transition{guard: guard}), do: guard != nil

  defp unique_id, do: "hsm-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp clone(nil), do: nil

  defp clone(value)
       when is_boolean(value) or is_number(value) or is_atom(value) or is_binary(value),
       do: value

  defp clone(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))

  defp value_matches_type?(_value, :any), do: true
  defp value_matches_type?(value, :integer), do: is_integer(value)
  defp value_matches_type?(value, :float), do: is_float(value)
  defp value_matches_type?(value, :number), do: is_number(value)
  defp value_matches_type?(value, :boolean), do: is_boolean(value)
  defp value_matches_type?(value, :binary), do: is_binary(value)
  defp value_matches_type?(value, :string), do: is_binary(value)
  defp value_matches_type?(value, :atom), do: is_atom(value)
  defp value_matches_type?(value, :list), do: is_list(value)
  defp value_matches_type?(value, :map), do: is_map(value)
  defp value_matches_type?(value, type) when is_atom(type), do: is_struct(value, type)
  defp value_matches_type?(value, type) when is_function(type, 1), do: truthy?(type.(value))
  defp value_matches_type?(_value, _type), do: true

  defp enqueue_event(instance, event) do
    {queue, error} = Queue.push(instance.queue, event, instance)
    {%{instance | queue: queue}, error}
  end

  defp pop_event(instance) do
    {queue, event_or_error} = Queue.pop(instance.queue, instance)
    instance = %{instance | queue: queue}

    case event_or_error do
      %Event{} = event ->
        case pop_cancelled_event(instance, event) do
          {instance, true} ->
            pop_event(instance)

          {instance, false} ->
            if pop_process_cancelled_event(instance, event),
              do: pop_event(instance),
              else: {unmark_deferred_queued(instance, event), event}
        end

      _ ->
        {instance, event_or_error}
    end
  end

  defp queue_empty(instance) do
    case queue_len_result(instance) do
      {count, nil} -> {count == 0, nil}
      {_count, error} -> {false, error}
    end
  end

  defp snapshot_queue_len(instance) do
    case queue_len_result(instance) do
      {count, nil} -> count
      {_count, _error} -> 0
    end
  end

  defp queue_len_result(instance) do
    case Queue.len(instance.queue, instance) do
      count when is_integer(count) and count >= 0 -> {count, nil}
      error -> {0, error}
    end
  end

  defp clear_queue_len_error(%__MODULE__{id: id}) do
    errors = Process.get(:hsm_runtime_queue_len_errors, %{})
    put_process_map(:hsm_runtime_queue_len_errors, Map.delete(errors, id))
  end

  defp reset_queue(%Queue{hooks: hooks}), do: Queue.new(if(hooks, do: hooks, else: nil))
  defp default_queue_empty?(%Queue{regular: {[], []}, completion: [], hooks: nil}), do: true
  defp default_queue_empty?(%Queue{regular: [], completion: [], hooks: nil}), do: true
  defp default_queue_empty?(_queue), do: false

  defp drain_queue(instance) do
    case process_event(instance) do
      {%__MODULE__{} = instance, :ignored} -> instance
      {%__MODULE__{} = instance, _status} -> drain_queue(instance)
    end
  end

  defp deferred_entry(event, path, defer) do
    case deferred_scope(defer) do
      nil -> {event, path}
      scope -> {event, scope}
    end
  end

  defp deferred_scope({_event_name, scope}), do: scope
  defp deferred_scope(_event_name), do: nil

  defp deferred_trigger(defers, event_name),
    do: Enum.find(defers, &(DSL.defer_name(&1) == event_name))

  defp carry_deferred_across_child_exit(%__MODULE__{deferred: []} = instance, _transition),
    do: instance

  defp carry_deferred_across_child_exit(instance, %Transition{} = transition) do
    deferred =
      Enum.map(instance.deferred, fn
        {event, scope} when is_binary(scope) ->
          if child_exit_replays_deferred?(instance.model, scope, transition),
            do: {event, nil},
            else: {event, scope}

        event ->
          event
      end)

    %{instance | deferred: deferred}
  end

  defp child_exit_replays_deferred?(model, scope, %Transition{target: target} = transition)
       when is_binary(target) do
    !path_in_scope?(target, scope) and
      !exits_enclosing_submachine?(model, scope, target) and
      (path_in_scope?(transition.source, scope) or completion_trigger?(transition.trigger))
  end

  defp child_exit_replays_deferred?(_model, _scope, _transition), do: false

  defp exits_enclosing_submachine?(model, scope, target) do
    case enclosing_submachine(model, scope) do
      nil -> false
      boundary when boundary == scope -> false
      boundary -> !path_in_scope?(target, boundary)
    end
  end

  defp enclosing_submachine(model, path) do
    path
    |> path_and_ancestors()
    |> Enum.find(fn candidate ->
      match?(%Node{kind: :submachine}, model.states[candidate])
    end)
  end

  defp path_and_ancestors(path) do
    Stream.iterate(path, &DSL.parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", "."]))
  end

  defp path_in_scope?(path, scope), do: path == scope or path_below_scope?(path, scope)

  defp path_below_scope?(path, scope) when is_binary(path),
    do: String.starts_with?(path, scope <> "/")

  defp path_below_scope?(_path, _scope), do: false

  defp deferred_event({event, _scope}), do: Event.coerce(event)
  defp deferred_event(event), do: Event.coerce(event)

  defp deferred_event_value({event, _scope}), do: event
  defp deferred_event_value(event), do: event

  defp deferred_scope_active?(_instance, {_event, nil}), do: true

  defp deferred_scope_active?(instance, {_event, scope}) do
    instance.state == scope or String.starts_with?(instance.state, scope <> "/")
  end

  defp deferred_scope_active?(_instance, _event), do: true

  defp pop_queued_deferred(instance, event) do
    {queued?, events} = remove_deferred_occurrence(instance.events, event)
    {%{instance | events: events}, queued?}
  end

  defp put_popped_queued_deferred(instance, event),
    do: update_generated_value(:hsm_runtime_popped_queued_deferred, instance, &[event | &1], [])

  defp take_popped_queued_deferred(instance, event) do
    events = generated_value(:hsm_runtime_popped_queued_deferred, instance, [])
    {popped?, remaining} = remove_deferred_occurrence(events, event)
    put_or_delete_generated_value(:hsm_runtime_popped_queued_deferred, instance, remaining)
    popped?
  end

  defp deferred_entry?(events, event) do
    Enum.any?(events, &same_deferred_entry?(&1, event))
  end

  defp unmark_deferred_queued(instance, event) do
    {removed?, events} = remove_deferred_occurrence(instance.events, event)
    if removed?, do: put_popped_queued_deferred(instance, event)
    %{instance | events: events}
  end

  defp remove_deferred_occurrence(events, event) do
    Enum.reduce(events, {false, []}, fn queued, {removed?, acc} ->
      cond do
        removed? ->
          {removed?, [queued | acc]}

        match?({:cancelled, _event}, queued) ->
          {removed?, [queued | acc]}

        same_deferred_event?(queued, event) ->
          {true, acc}

        true ->
          {false, [queued | acc]}
      end
    end)
    |> then(fn {removed?, rest} -> {removed?, Enum.reverse(rest)} end)
  end

  defp pop_cancelled_event(instance, event) do
    {cancelled?, events} = remove_cancelled_event(instance.events, event)
    {%{instance | events: events}, cancelled?}
  end

  defp pop_process_cancelled_event(instance, event) do
    events = Process.get(:hsm_runtime_cancelled_hook_events, [])
    {cancelled?, remaining} = remove_cancelled_hook_event(events, instance, event)
    put_or_delete(:hsm_runtime_cancelled_hook_events, remaining)
    cancelled?
  end

  defp remove_cancelled_event(events, event) do
    Enum.reduce(events, {false, []}, fn queued, {removed?, acc} ->
      cond do
        removed? ->
          {removed?, [queued | acc]}

        same_cancelled_event?(queued, event) ->
          {true, acc}

        true ->
          {false, [queued | acc]}
      end
    end)
    |> then(fn {removed?, rest} -> {removed?, Enum.reverse(rest)} end)
  end

  defp remove_cancelled_hook_event(events, instance, event) do
    Enum.reduce(events, {false, []}, fn queued, {removed?, acc} ->
      cond do
        removed? ->
          {removed?, [queued | acc]}

        same_cancelled_hook_event?(queued, instance, event) ->
          {true, acc}

        true ->
          {false, [queued | acc]}
      end
    end)
    |> then(fn {removed?, rest} -> {removed?, Enum.reverse(rest)} end)
  end

  defp same_cancelled_event?({:cancelled, cancelled}, event),
    do: same_deferred_event?(cancelled, event)

  defp same_cancelled_event?(_queued, _event), do: false

  defp same_cancelled_hook_event?({id, cancelled}, instance, event),
    do: id == instance.id and same_deferred_event?(cancelled, event)

  defp same_cancelled_hook_event?(_queued, _instance, _event), do: false

  defp remove_deferred_entry(events, event) do
    Enum.reduce(events, {false, []}, fn queued, {removed?, acc} ->
      cond do
        removed? ->
          {removed?, [queued | acc]}

        match?({:cancelled, _event}, queued) ->
          {removed?, [queued | acc]}

        same_deferred_entry?(queued, event) ->
          {true, acc}

        true ->
          {false, [queued | acc]}
      end
    end)
    |> then(fn {_removed?, rest} -> Enum.reverse(rest) end)
  end

  defp same_deferred_entry?({event, scope}, {other, other_scope}),
    do: scope == other_scope and same_deferred_event?(event, other)

  defp same_deferred_entry?(event, other), do: same_deferred_event?(event, other)

  defp same_deferred_event?(event, other), do: deferred_event(event) == deferred_event(other)

  defp requeue_popped_deferred(instance) do
    active_defer = active_deferred_events(instance)

    events =
      take_popped_deferred(instance)
      |> Enum.filter(
        &(deferred_event(&1).name in active_defer and deferred_scope_active?(instance, &1))
      )

    Enum.reduce_while(events, {instance, :deferred}, fn event, {acc, _status} ->
      event = deferred_event_value(event)

      case enqueue_event(acc, event) do
        {queued, nil} -> {:cont, {%{queued | events: queued.events ++ [event]}, :deferred}}
        {queued, error} -> {:halt, handle_runtime_error(queued, error)}
      end
    end)
  end

  defp put_popped_deferred(instance, event),
    do: update_generated_value(:hsm_runtime_popped_deferred, instance, &[event | &1], [])

  defp take_popped_deferred(instance),
    do: take_generated_value(:hsm_runtime_popped_deferred, instance, []) |> Enum.reverse()

  defp drop_popped_deferred(instance, events) do
    remaining =
      Enum.reduce(
        events,
        generated_value(:hsm_runtime_popped_deferred, instance, []),
        fn event, acc -> remove_deferred_entry(acc, event) end
      )

    put_or_delete_generated_value(:hsm_runtime_popped_deferred, instance, remaining)
  end

  defp processing?(%__MODULE__{id: id}),
    do: MapSet.member?(Process.get(:hsm_runtime_processing_instances, MapSet.new()), id)

  defp call_depth(%__MODULE__{id: id}) do
    if Process.get(:hsm_runtime_call_instance) == id,
      do: Process.get(:hsm_runtime_call_depth, 0),
      else: 0
  end

  defp hooked_queue?(%Queue{hooks: nil}), do: false
  defp hooked_queue?(%Queue{}), do: true

  defp put_generated_event(instance, event),
    do: update_generated_value(:hsm_runtime_generated_events, instance, &[event | &1], [])

  defp generated_queue(instance), do: generated_value(:hsm_runtime_generated_queue, instance)

  defp put_generated_queue(instance, queue),
    do: put_generated_value(:hsm_runtime_generated_queue, instance, queue)

  defp put_generated_hook_event(instance, event) do
    update_generated_value(:hsm_runtime_generated_hook_events, instance, &[event | &1], [])
  end

  defp cancel_generated_hook_events(instance) do
    events =
      take_generated_value(:hsm_runtime_generated_hook_events, instance, [])
      |> Enum.reverse()

    cancelled = Enum.map(events, &{:cancelled, &1})

    %{instance | events: instance.events ++ cancelled}
  end

  defp flush_generated_events(instance) do
    instance = flush_generated_attributes(instance)
    instance = take_generated_queue(instance)
    delete_generated_value(:hsm_runtime_generated_hook_events, instance)

    events =
      take_generated_value(:hsm_runtime_generated_events, instance, [])
      |> Enum.reverse()

    Enum.reduce(events, instance, fn event, acc ->
      case enqueue_event(acc, event) do
        {queued, nil} -> queued
        {queued, error} -> enqueue_event(queued, error_event(error)) |> elem(0)
      end
    end)
  end

  defp take_generated_queue(instance) do
    case take_generated_value(:hsm_runtime_generated_queue, instance) do
      nil -> instance
      queue -> %{instance | queue: queue}
    end
  end

  defp hook_regular_event?(%Event{kind: kind}),
    do: kind not in [:completion_event, :initial_event, :error_event]

  defp put_generated_attribute(instance, name, value),
    do:
      update_generated_value(
        :hsm_runtime_generated_attributes,
        instance,
        &[{name, value} | &1],
        []
      )

  defp flush_generated_attributes(instance) do
    attributes =
      take_generated_value(:hsm_runtime_generated_attributes, instance, [])
      |> Enum.reverse()

    Enum.reduce(attributes, instance, fn {name, value}, acc ->
      %{acc | attributes: Map.put(acc.attributes, name, value)}
    end)
  end

  defp snapshot_state(instance), do: exit_point_snapshot_state(instance) || instance.state

  defp with_exit_point_snapshot_state(instance, state, fun) do
    previous = generated_value(:hsm_runtime_exit_point_snapshot_state, instance, @missing)
    put_generated_value(:hsm_runtime_exit_point_snapshot_state, instance, state)

    try do
      fun.()
    after
      if previous == @missing,
        do: delete_generated_value(:hsm_runtime_exit_point_snapshot_state, instance),
        else: put_generated_value(:hsm_runtime_exit_point_snapshot_state, instance, previous)
    end
  end

  defp exit_point_snapshot_state(instance),
    do: generated_value(:hsm_runtime_exit_point_snapshot_state, instance)

  defp generated_value(key, %__MODULE__{id: id}, default \\ nil),
    do: Process.get(key, %{}) |> Map.get(id, default)

  defp put_generated_value(key, %__MODULE__{id: id}, value) do
    values = Process.get(key, %{})
    put_process_map(key, Map.put(values, id, value))
  end

  defp update_generated_value(key, instance, fun, default) do
    put_generated_value(key, instance, fun.(generated_value(key, instance, default)))
  end

  defp take_generated_value(key, %__MODULE__{id: id}, default \\ nil) do
    values = Process.get(key, %{})
    value = Map.get(values, id, default)
    put_process_map(key, Map.delete(values, id))
    value
  end

  defp delete_generated_value(key, %__MODULE__{id: id}) do
    values = Process.get(key, %{})
    put_process_map(key, Map.delete(values, id))
  end

  defp put_or_delete_generated_value(key, instance, []), do: delete_generated_value(key, instance)

  defp put_or_delete_generated_value(key, instance, value),
    do: put_generated_value(key, instance, value)

  defp put_process_map(key, values) when map_size(values) == 0, do: Process.delete(key)
  defp put_process_map(key, values), do: Process.put(key, values)

  defp with_processing(instance, fun) do
    nested? = processing?(instance)
    previous = Process.get(:hsm_runtime_processing, @missing)
    previous_instance = Process.get(:hsm_runtime_processing_instance, @missing)
    previous_instances = Process.get(:hsm_runtime_processing_instances, @missing)

    active_instances =
      if previous_instances == @missing, do: MapSet.new(), else: previous_instances

    Process.put(:hsm_runtime_processing, true)
    Process.put(:hsm_runtime_processing_instance, instance.id)
    Process.put(:hsm_runtime_processing_instances, MapSet.put(active_instances, instance.id))

    try do
      with_generated_cleanup(instance, nested?, fun)
    after
      restore_process_key(:hsm_runtime_processing, previous)
      restore_process_key(:hsm_runtime_processing_instance, previous_instance)
      restore_process_key(:hsm_runtime_processing_instances, previous_instances)
    end
  end

  defp with_transition_processing(instance, fun) do
    if processing?(instance), do: fun.(), else: with_processing(instance, fun)
  end

  defp with_generated_cleanup(instance, nested?, fun) do
    try do
      fun.()
    rescue
      error ->
        unless nested?, do: clear_generated_runtime(instance)
        reraise error, __STACKTRACE__
    catch
      kind, reason ->
        unless nested?, do: clear_generated_runtime(instance)
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp clear_generated_runtime(instance) do
    cancel_generated_runtime_hook_events(instance)
    delete_generated_value(:hsm_runtime_generated_attributes, instance)
    delete_generated_value(:hsm_runtime_generated_events, instance)
    delete_generated_value(:hsm_runtime_generated_queue, instance)
    delete_generated_value(:hsm_runtime_exit_point_snapshot_state, instance)
    delete_generated_value(:hsm_runtime_popped_deferred, instance)
    delete_generated_value(:hsm_runtime_popped_queued_deferred, instance)
    Process.delete(:hsm_runtime_preserve_timer_error)
    Process.delete(:hsm_runtime_timer_error)
  end

  defp cancel_generated_runtime_hook_events(instance) do
    events = take_generated_value(:hsm_runtime_generated_hook_events, instance, [])

    if events != [] do
      cancelled = Process.get(:hsm_runtime_cancelled_hook_events, [])
      events = events |> Enum.reverse() |> Enum.map(&{instance.id, &1})
      Process.put(:hsm_runtime_cancelled_hook_events, events ++ cancelled)
    end
  end

  defp with_call_body(instance, fun) do
    previous = Process.get(:hsm_runtime_call_depth, @missing)
    previous_instance = Process.get(:hsm_runtime_call_instance, @missing)
    depth = if previous_instance == instance.id and previous != @missing, do: previous, else: 0
    Process.put(:hsm_runtime_call_depth, depth + 1)
    Process.put(:hsm_runtime_call_instance, instance.id)

    try do
      fun.()
    after
      restore_process_key(:hsm_runtime_call_depth, previous)
      restore_process_key(:hsm_runtime_call_instance, previous_instance)
    end
  end

  defp restore_process_key(key, @missing), do: Process.delete(key)
  defp restore_process_key(key, value), do: Process.put(key, value)

  defp put_or_delete(key, []), do: Process.delete(key)
  defp put_or_delete(key, value), do: Process.put(key, value)

  defp handle_runtime_error(instance, %ValidationError{} = error),
    do: handle_runtime_error(instance, error.message)

  defp handle_runtime_error(instance, error) do
    instance
    |> enqueue_event(error_event(error))
    |> elem(0)
    |> process_event()
  end

  defp error_event(error), do: %Event{name: "hsm/error", kind: :error_event, data: error}
end
