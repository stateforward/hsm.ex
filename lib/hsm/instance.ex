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
    ValidationError
  }

  defstruct id: "",
            name: "",
            model: nil,
            state: "",
            attributes: %{},
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
      queue: Queue.new(config.queue),
      clock: Clock.new(config.clock)
    }
  end

  def start(%__MODULE__{} = instance, data \\ nil) do
    instance
    |> reset_runtime(data)
    |> enter_initial(%Event{name: "InitialEvent", kind: :initial_event, data: data})
    |> elem(0)
  end

  def stop(%__MODULE__{started?: false} = instance), do: instance

  def stop(%__MODULE__{} = instance) do
    exit_paths =
      instance.model
      |> active_path(instance.state)
      |> Enum.reject(&(&1 == instance.model.root))

    instance
    |> exit_states(exit_paths, %Event{name: "StopEvent", kind: :stop_event})
    |> Map.merge(%{
      started?: false,
      state: "",
      queue: reset_queue(instance.queue),
      deferred: [],
      active_activities: [],
      timers: []
    })
  end

  def restart(%__MODULE__{} = instance, data \\ nil), do: instance |> stop() |> start(data)
  def state(%__MODULE__{state: state}), do: state

  def get(%__MODULE__{} = instance, name) do
    case Map.fetch(instance.attributes, name) do
      {:ok, value} -> {value, true}
      :error -> {nil, false}
    end
  end

  def set(%__MODULE__{} = instance, name, value) when is_binary(name) do
    unless Map.has_key?(instance.model.attributes, name) do
      raise ValidationError, message: "unknown attribute #{inspect(name)}"
    end

    type = Map.get(instance.model.attribute_types, name, :any)

    unless value_matches_type?(value, type) do
      raise ValidationError,
        message: "attribute #{inspect(name)} expected #{inspect(type)}, got #{inspect(value)}"
    end

    old = Map.get(instance.attributes, name)
    instance = %{instance | attributes: Map.put(instance.attributes, name, value)}

    if old == value do
      instance
    else
      dispatch(instance, Event.set(name, value)) |> elem(0)
    end
  end

  def call(%__MODULE__{} = instance, name, args \\ []) do
    callback = Map.get(instance.model.operations, name)
    event = Event.call(name, args)
    {instance, _} = dispatch(instance, event)

    result =
      if is_function(callback) do
        invoke(callback, instance, event)
      else
        nil
      end

    {instance, result}
  end

  def dispatch(%__MODULE__{started?: false} = instance, _event), do: {instance, :not_started}

  def dispatch(%__MODULE__{} = instance, %Event{} = event) do
    event = %{event | schema: clone(event.schema)}

    cond do
      deferred?(instance, event) ->
        {%{instance | deferred: instance.deferred ++ [event]}, :deferred}

      default_queue_empty?(instance.queue) ->
        process_popped_event(instance, event)

      true ->
        case enqueue_event(instance, event) do
          {%__MODULE__{} = instance, nil} -> process_event(instance)
          {%__MODULE__{} = instance, error} -> handle_runtime_error(instance, error)
        end
    end
  end

  def tick(%__MODULE__{} = instance, millis) when is_integer(millis) and millis >= 0 do
    instance = %{instance | logical_time: instance.logical_time + millis}
    fire_due_timers(instance)
  end

  def handle_timer(%__MODULE__{} = instance, {:hsm_timer, timer_id}),
    do: handle_timer(instance, timer_id)

  def handle_timer(%__MODULE__{} = instance, timer_id) do
    case Enum.split_with(instance.timers, &(&1.id == timer_id)) do
      {[], _timers} ->
        instance

      {[timer | _], rest} ->
        instance = %{instance | timers: rest}

        instance =
          if timer.kind == :every do
            timer =
              timer
              |> Map.put(:due, instance.logical_time + timer.interval)
              |> Map.put(:duration, timer.interval)
              |> Map.put(:ref, nil)

            %{instance | timers: instance.timers ++ [arm_timer(timer, instance)]}
          else
            instance
          end

        instance
        |> enqueue_event(timer_event(timer))
        |> elem(0)
        |> process_event()
        |> elem(0)
    end
  end

  def snapshot(%__MODULE__{} = instance) do
    %Snapshot{
      ID: unique_id(),
      QualifiedName: instance.name,
      State: instance.state,
      Attributes: qualify_attributes(instance),
      QueueLen: queue_len(instance),
      Events: Enum.map(Queue.events(instance.queue), &event_detail/1)
    }
  end

  defp reset_runtime(instance, _data) do
    %{
      instance
      | state: instance.model.root,
        attributes: instance.model.attributes,
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
    instance =
      case select_transition(instance, event) do
        nil -> instance
        transition -> elem(take_transition(instance, transition, event), 0)
      end

    instance = replay_deferred(instance)

    if queue_empty?(instance) do
      {instance, :processed}
    else
      process_event(instance)
    end
  end

  defp replay_deferred(%__MODULE__{deferred: []} = instance), do: instance

  defp replay_deferred(instance) do
    active_defer = active_deferred_events(instance)

    {still_deferred, ready} =
      Enum.split_with(instance.deferred, &(Event.coerce(&1).name in active_defer))

    Enum.reduce(ready, %{instance | deferred: still_deferred}, fn event, acc ->
      elem(enqueue_event(acc, event), 0)
    end)
  end

  defp select_transition(instance, event) do
    active_paths = active_path(instance.model, instance.state)

    active_paths
    |> Enum.find_value(fn path ->
      instance.model.transition_candidates
      |> Map.get_lazy(path, fn -> transition_candidates(instance, path) end)
      |> Enum.find(fn transition ->
        trigger_matches?(instance, transition, event) and
          guard_passes?(instance, transition, event)
      end)
    end)
  end

  defp transition_candidates(instance, path) do
    node = instance.model.states[path]

    owned =
      if path == instance.model.root,
        do: node.transitions ++ instance.model.transitions,
        else: node.transitions

    parent_paths = active_path(instance.model, path) |> Enum.drop(1)

    parent_owned =
      Enum.flat_map(parent_paths, fn parent ->
        instance.model.states[parent].transitions
        |> Enum.filter(&(&1.source == path))
      end)

    owned ++ parent_owned
  end

  defp trigger_matches?(_instance, %Transition{trigger: nil}, _event), do: false

  defp trigger_matches?(_instance, %Transition{trigger: {:on, expected}}, %Event{name: actual}),
    do: expected == actual

  defp trigger_matches?(_instance, %Transition{trigger: {:on_set, expected}}, %Event{
         kind: :set_event,
         data: %{name: actual}
       }),
       do: expected == actual

  defp trigger_matches?(_instance, %Transition{trigger: {:on_call, expected}}, %Event{
         name: actual
       }),
       do: actual == "@call:" <> expected

  defp trigger_matches?(instance, %Transition{trigger: {:when, fun}}, event),
    do: truthy?(invoke(fun, instance, event))

  defp trigger_matches?(_instance, %Transition{trigger: {:after, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: transition}
       }),
       do: current == transition

  defp trigger_matches?(_instance, %Transition{trigger: {:every, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: transition}
       }),
       do: current == transition

  defp trigger_matches?(_instance, %Transition{trigger: {:at, _}} = current, %Event{
         kind: :timer_event,
         data: %{transition: transition}
       }),
       do: current == transition

  defp trigger_matches?(_instance, _transition, _event), do: false

  defp guard_passes?(_instance, %Transition{guard: nil}, _event), do: true

  defp guard_passes?(instance, %Transition{guard: guard}, event) when is_binary(guard),
    do: truthy?(invoke(Map.fetch!(instance.model.operations, guard), instance, event))

  defp guard_passes?(instance, %Transition{guard: guard}, event),
    do: truthy?(invoke(guard, instance, event))

  defp take_transition(instance, %Transition{target: nil} = transition, event) do
    instance = run_actions(instance, transition.effects, event)
    {instance, :internal}
  end

  defp take_transition(instance, %Transition{} = transition, event) do
    source = transition.source || instance.state
    dynamic? = dynamic_target?(instance, transition.target)

    path_target =
      if dynamic? do
        transition.target
      else
        elem(resolve_dynamic_target(instance, transition.target, event), 0)
      end

    {exit_paths, path_lca} =
      transition_paths(instance.model, source, path_target, transition.kind, instance.state)

    instance =
      instance
      |> remember_history(exit_paths)
      |> exit_states(exit_paths, event)
      |> run_actions(transition.effects, event)

    {target, chained_effects} = resolve_dynamic_target(instance, transition.target, event)

    enter_lca = if target == path_target, do: path_lca, else: DSL.lca(source, target)
    enter_paths = path_from_lca(instance.model, target, enter_lca)

    instance =
      instance
      |> run_actions(chained_effects, event)
      |> enter_states(enter_paths, event)
      |> maybe_enter_default(target, event)
      |> maybe_completion()

    {instance, :transitioned}
  end

  defp resolve_dynamic_target(instance, target, event) do
    case instance.model.states[target] do
      %Node{kind: :choice} = node -> choice_target(instance, node, event)
      %Node{kind: :shallow_history} = node -> history_target(instance, node, event, :shallow)
      %Node{kind: :deep_history} = node -> history_target(instance, node, event, :deep)
      _ -> {target, []}
    end
  end

  defp dynamic_target?(instance, target) do
    case instance.model.states[target] do
      %Node{kind: kind} when kind in [:choice, :shallow_history, :deep_history] -> true
      _ -> false
    end
  end

  defp choice_target(instance, node, event) do
    transition =
      Enum.find(node.transitions, fn transition ->
        guard_passes?(instance, transition, event)
      end)

    if transition, do: {transition.target, transition.effects}, else: {node.path, []}
  end

  defp history_target(instance, node, event, kind) do
    remembered =
      case kind do
        :shallow -> Map.get(instance.history_shallow, node.parent)
        :deep -> Map.get(instance.history_deep, node.parent)
      end

    if remembered do
      {remembered, []}
    else
      transition = List.first(node.transitions)

      if transition do
        {target, effects} = resolve_dynamic_target(instance, transition.target, event)
        {target, transition.effects ++ effects}
      else
        {node.parent, []}
      end
    end
  end

  defp transition_paths(model, source, target, kind, active_leaf) do
    cond do
      kind == :internal ->
        {[], source}

      kind == :self ->
        {[active_leaf], DSL.lca(source, target)}

      true ->
        lca = DSL.lca(source, target)

        exit_paths =
          active_path(model, active_leaf)
          |> Enum.take_while(&(&1 != lca))

        {exit_paths, lca}
    end
  end

  defp path_from_lca(model, target, lca) do
    model
    |> active_path(target)
    |> Enum.take_while(&(&1 != lca))
    |> Enum.reverse()
  end

  defp enter_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]
      acc = %{acc | state: path}

      acc
      |> run_actions(node.entry, event)
      |> run_activity_actions(path, node.activity, event)
      |> schedule_timers(path)
    end)
  end

  defp exit_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]

      acc
      |> cancel_activities(path, event)
      |> cancel_timers(path)
      |> run_actions(node.exit, event)
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

  defp maybe_completion(instance) do
    case instance.model.states[instance.state] do
      %Node{kind: :final, parent: parent} ->
        instance = %{instance | done?: parent == instance.model.root}
        parent_transition = completion_transition(instance, parent)

        if parent_transition do
          elem(take_transition(instance, parent_transition, Event.completion()), 0)
        else
          instance
        end

      _ ->
        instance
    end
  end

  defp completion_transition(instance, parent) do
    transitions =
      if parent == instance.model.root do
        instance.model.states[parent].transitions ++ instance.model.transitions
      else
        instance.model.states[parent].transitions
      end

    transitions
    |> Enum.find(&(&1.trigger == {:on, "FinalEvent"} or &1.trigger == {:on, :completion}))
  end

  defp remember_history(instance, []), do: instance

  defp remember_history(instance, exit_paths) do
    leaf = List.first(exit_paths)

    Enum.reduce(exit_paths, instance, fn path, acc ->
      case DSL.parent(path) do
        nil ->
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

  defp active_path(model, leaf),
    do:
      Map.get(model.active_paths, leaf) ||
        Enum.filter([leaf | ancestors(leaf)], &Map.has_key?(model.states, &1))

  defp ancestors(path),
    do:
      Stream.iterate(DSL.parent(path), &DSL.parent/1)
      |> Enum.take_while(&(&1 not in [nil, "", "."]))

  defp active_deferred_events(instance),
    do:
      Map.get_lazy(instance.model.active_defers, instance.state, fn ->
        active_deferred_events_fallback(instance)
      end)

  defp active_deferred_events_fallback(instance) do
    instance.model
    |> active_path(instance.state)
    |> Enum.flat_map(&instance.model.states[&1].defer)
  end

  defp deferred?(instance, event), do: event.name in active_deferred_events(instance)

  defp schedule_timers(instance, path) do
    node = instance.model.states[path]

    timers =
      node.transitions
      |> Enum.filter(fn transition -> timer_trigger?(transition.trigger) end)
      |> Enum.map(fn transition ->
        {kind, value} = transition.trigger
        interval = timer_value(instance, value)
        duration = timer_duration(instance.logical_time, kind, interval)
        timer_id = unique_id()

        timer =
          %{
            id: timer_id,
            ref: nil,
            source: path,
            transition: transition,
            kind: kind,
            interval: interval,
            duration: duration,
            clock_wait: Clock.wait(instance.clock, duration, %{instance: instance, path: path}),
            due: timer_due(instance.logical_time, kind, interval)
          }

        arm_timer(timer, instance)
      end)

    %{instance | timers: instance.timers ++ timers}
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
    Enum.each(cancelled, &Clock.cancel_timer(&1.ref))
    %{instance | timers: active}
  end

  defp fire_due_timers(instance) do
    {due, pending} = Enum.split_with(instance.timers, &(&1.due <= instance.logical_time))
    instance = %{instance | timers: pending}

    Enum.reduce(due, instance, fn timer, acc ->
      Clock.cancel_timer(timer.ref)

      acc =
        if timer.kind == :every do
          timer =
            timer
            |> Map.put(:due, acc.logical_time + timer.interval)
            |> Map.put(:duration, timer.interval)
            |> Map.put(:ref, nil)

          %{acc | timers: acc.timers ++ [arm_timer(timer, acc)]}
        else
          acc
        end

      acc
      |> enqueue_event(timer_event(timer))
      |> elem(0)
      |> process_event()
      |> elem(0)
    end)
  end

  defp timer_event(timer) do
    %Event{
      name: "__timer_#{timer.kind}__",
      kind: :timer_event,
      data: %{source: timer.source, transition: timer.transition, timer: timer.id}
    }
  end

  defp timer_trigger?({kind, _}) when kind in [:after, :every, :at], do: true
  defp timer_trigger?(_), do: false

  defp timer_value(_instance, value) when is_integer(value), do: value

  defp timer_value(instance, value) when is_binary(value),
    do: Map.fetch!(instance.attributes, value)

  defp timer_value(instance, fun) when is_function(fun),
    do: invoke(fun, instance, %Event{name: "TimerSchedule"})

  defp timer_due(_now, :at, value), do: value
  defp timer_due(now, _kind, value), do: now + value
  defp timer_duration(now, :at, value), do: max(value - now, 0)
  defp timer_duration(_now, _kind, value), do: value

  defp run_actions(instance, actions, event) do
    run_actions(instance, actions, event, %{action: :effect})
  end

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

  defp run_actions(instance, actions, event, context) do
    Enum.reduce(actions, instance, fn action, acc ->
      result =
        case action do
          name when is_binary(name) ->
            invoke_with_context(Map.fetch!(acc.model.operations, name), acc, event, context)

          fun when is_function(fun) ->
            invoke_with_context(fun, acc, event, context)

          _ ->
            acc
        end

      case result do
        %__MODULE__{} = updated ->
          updated

        {%__MODULE__{} = updated, _status} ->
          updated

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

  defp remember_activity(instance, handle, %{action: :activity, path: path}) do
    %{instance | active_activities: instance.active_activities ++ [%{handle | path: path}]}
  end

  defp remember_activity(instance, _handle, _context), do: instance

  defp invoke_with_context(fun, instance, event, context) when is_function(fun, 3),
    do: fun.(context, instance, event)

  defp invoke_with_context(fun, instance, event, _context), do: invoke(fun, instance, event)

  defp invoke(fun, instance, event) when is_function(fun, 3), do: fun.(nil, instance, event)
  defp invoke(fun, instance, event) when is_function(fun, 2), do: fun.(instance, event)
  defp invoke(fun, _instance, event) when is_function(fun, 1), do: fun.(event)
  defp invoke(fun, _instance, _event) when is_function(fun, 0), do: fun.()

  defp truthy?(value), do: value not in [false, nil]

  defp qualify_attributes(instance) do
    Map.new(instance.attributes, fn {key, value} -> {instance.model.path <> "/" <> key, value} end)
  end

  defp event_detail(event),
    do: %{
      Name: event.name,
      Kind: event.kind,
      Target: event.target,
      Guard: false,
      Schema: event.schema
    }

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
    {%{instance | queue: queue}, event_or_error}
  end

  defp queue_empty?(instance), do: Queue.empty?(instance.queue, instance)
  defp queue_len(instance), do: Queue.len(instance.queue, instance)
  defp reset_queue(%Queue{hooks: hooks}), do: Queue.new(if(hooks, do: hooks, else: nil))
  defp default_queue_empty?(%Queue{regular: [], completion: [], hooks: nil}), do: true
  defp default_queue_empty?(_queue), do: false

  defp handle_runtime_error(instance, %ValidationError{} = error),
    do: handle_runtime_error(instance, error.message)

  defp handle_runtime_error(instance, error) do
    error_event = %Event{name: "hsm_error", kind: :error_event, data: error}

    instance
    |> enqueue_event(error_event)
    |> elem(0)
    |> process_event()
  end
end
