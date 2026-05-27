defmodule HSM.Instance do
  @moduledoc false

  alias HSM.{Config, DSL, Event, Model, Node, Snapshot, Transition, ValidationError}

  defstruct id: "",
            name: "",
            model: nil,
            state: "",
            attributes: %{},
            queue: [],
            deferred: [],
            history_shallow: %{},
            history_deep: %{},
            started?: false,
            done?: false,
            events: []

  def new(%Model{} = model, %Config{} = config \\ %Config{}) do
    id = config.id || ""

    %__MODULE__{
      id: if(id == "", do: unique_id(), else: id),
      name: if(config.name in [nil, ""], do: model.path, else: config.name),
      model: model,
      attributes: model.attributes
    }
  end

  def start(%__MODULE__{} = instance, data \\ nil) do
    instance
    |> reset_runtime(data)
    |> enter_initial(%Event{name: "InitialEvent", kind: :initial_event, data: data})
    |> elem(0)
  end

  def stop(%__MODULE__{} = instance), do: %{instance | started?: false, state: ""}
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

    result =
      if is_function(callback) do
        invoke(callback, instance, event)
      else
        nil
      end

    {instance, _} = dispatch(instance, event)
    {instance, result}
  end

  def dispatch(%__MODULE__{started?: false} = instance, _event), do: {instance, :not_started}

  def dispatch(%__MODULE__{} = instance, %Event{} = event) do
    event = %{event | schema: clone(event.schema)}

    if deferred?(instance, event) do
      {%{instance | deferred: instance.deferred ++ [event]}, :deferred}
    else
      process_event(%{instance | queue: instance.queue ++ [event]})
    end
  end

  def snapshot(%__MODULE__{} = instance) do
    %Snapshot{
      ID: unique_id(),
      QualifiedName: instance.name,
      State: instance.state,
      Attributes: qualify_attributes(instance),
      QueueLen: length(instance.queue),
      Events: Enum.map(instance.events, &event_detail/1)
    }
  end

  defp reset_runtime(instance, _data) do
    %{
      instance
      | state: instance.model.root,
        attributes: instance.model.attributes,
        queue: [],
        deferred: [],
        history_shallow: %{},
        history_deep: %{},
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

  defp process_event(%__MODULE__{queue: []} = instance), do: {instance, :ignored}

  defp process_event(%__MODULE__{queue: [event | rest]} = instance) do
    instance = %{instance | queue: rest, events: instance.events ++ [event]}

    instance =
      case select_transition(instance, event) do
        nil -> instance
        transition -> elem(take_transition(instance, transition, event), 0)
      end

    instance = replay_deferred(instance)

    if instance.queue == [] do
      {instance, :processed}
    else
      process_event(instance)
    end
  end

  defp replay_deferred(%__MODULE__{deferred: []} = instance), do: instance

  defp replay_deferred(instance) do
    active_defer = active_deferred_events(instance)
    {still_deferred, ready} = Enum.split_with(instance.deferred, &(Event.coerce(&1).name in active_defer))
    %{instance | deferred: still_deferred, queue: ready ++ instance.queue}
  end

  defp select_transition(instance, event) do
    instance.model
    |> active_path(instance.state)
    |> Enum.find_value(fn path ->
      node = instance.model.states[path]

      Enum.find(node.transitions ++ parent_owned_transitions(instance, path), fn transition ->
        source_matches?(instance, transition) and trigger_matches?(instance, transition, event) and guard_passes?(instance, transition, event)
      end)
    end)
  end

  defp parent_owned_transitions(instance, path) do
    parent_paths =
      instance.model
      |> active_path(path)
      |> Enum.drop(1)

    Enum.flat_map(parent_paths, fn parent ->
      instance.model.states[parent].transitions
      |> Enum.filter(&(&1.source == path))
    end)
  end

  defp source_matches?(instance, %Transition{source: source}) do
    source in active_path(instance.model, instance.state)
  end

  defp trigger_matches?(_instance, %Transition{trigger: nil}, _event), do: false
  defp trigger_matches?(_instance, %Transition{trigger: {:on, expected}}, %Event{name: actual}), do: expected == actual

  defp trigger_matches?(_instance, %Transition{trigger: {:on_set, expected}}, %Event{kind: :set_event, data: %{name: actual}}),
    do: expected == actual

  defp trigger_matches?(_instance, %Transition{trigger: {:on_call, expected}}, %Event{name: actual}), do: actual == "@call:" <> expected
  defp trigger_matches?(instance, %Transition{trigger: {:when, fun}}, event), do: truthy?(invoke(fun, instance, event))
  defp trigger_matches?(_instance, %Transition{trigger: {:after, _}}, %Event{name: "__timer_after__"}), do: true
  defp trigger_matches?(_instance, %Transition{trigger: {:every, _}}, %Event{name: "__timer_every__"}), do: true
  defp trigger_matches?(_instance, %Transition{trigger: {:at, _}}, %Event{name: "__timer_at__"}), do: true
  defp trigger_matches?(_instance, _transition, _event), do: false

  defp guard_passes?(_instance, %Transition{guard: nil}, _event), do: true
  defp guard_passes?(instance, %Transition{guard: guard}, event) when is_binary(guard), do: truthy?(invoke(Map.fetch!(instance.model.operations, guard), instance, event))
  defp guard_passes?(instance, %Transition{guard: guard}, event), do: truthy?(invoke(guard, instance, event))

  defp take_transition(instance, %Transition{target: nil} = transition, event) do
    instance = run_actions(instance, transition.effects, event)
    {instance, :internal}
  end

  defp take_transition(instance, %Transition{} = transition, event) do
    target = resolve_dynamic_target(instance, transition.target, event)
    source = transition.source || instance.state
    {exit_paths, enter_paths} = transition_paths(instance.model, source, target, transition.kind, instance.state)

    instance =
      instance
      |> remember_history(exit_paths)
      |> exit_states(exit_paths, event)
      |> run_actions(transition.effects, event)
      |> enter_states(enter_paths, event)
      |> maybe_enter_default(target, event)
      |> maybe_completion()

    {instance, :transitioned}
  end

  defp resolve_dynamic_target(instance, target, event) do
    case instance.model.states[target] do
      %Node{kind: :choice} = node -> select_choice_target(instance, node, event)
      %Node{kind: :shallow_history} = node -> Map.get(instance.history_shallow, node.parent) || default_history_target(instance, node, event)
      %Node{kind: :deep_history} = node -> Map.get(instance.history_deep, node.parent) || default_history_target(instance, node, event)
      _ -> target
    end
  end

  defp select_choice_target(instance, node, event) do
    transition =
      Enum.find(node.transitions, fn transition ->
        guard_passes?(instance, transition, event)
      end)

    transition && transition.target
  end

  defp default_history_target(instance, node, event) do
    transition = List.first(node.transitions)
    transition && resolve_dynamic_target(instance, transition.target, event)
  end

  defp transition_paths(model, source, target, kind, active_leaf) do
    cond do
      kind == :internal ->
        {[], []}

      kind == :self ->
        {[active_leaf], [target]}

      true ->
        lca = DSL.lca(source, target)

        exit_paths =
          active_path(model, active_leaf)
          |> Enum.take_while(&(&1 != lca))

        enter_paths =
          path_from_lca(target, lca)

        {exit_paths, enter_paths}
    end
  end

  defp path_from_lca(target, lca) do
    Stream.iterate(target, &DSL.parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", ".", lca]))
    |> Enum.reverse()
  end

  defp enter_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]
      acc = %{acc | state: path}
      run_actions(acc, node.entry, event)
    end)
  end

  defp exit_states(instance, paths, event) do
    Enum.reduce(paths, instance, fn path, acc ->
      node = acc.model.states[path]
      run_actions(acc, node.exit, event)
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
    instance.model.states[parent].transitions
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

  defp active_path(model, leaf), do: Enum.filter([leaf | ancestors(leaf)], &Map.has_key?(model.states, &1))
  defp ancestors(path), do: Stream.iterate(DSL.parent(path), &DSL.parent/1) |> Enum.take_while(&(&1 not in [nil, "", "."]))

  defp active_deferred_events(instance) do
    instance.model
    |> active_path(instance.state)
    |> Enum.flat_map(&instance.model.states[&1].defer)
  end

  defp deferred?(instance, event), do: event.name in active_deferred_events(instance)

  defp run_actions(instance, actions, event) do
    Enum.reduce(actions, instance, fn action, acc ->
      case action do
        name when is_binary(name) -> invoke(Map.fetch!(acc.model.operations, name), acc, event)
        fun when is_function(fun) -> invoke(fun, acc, event)
        _ -> acc
      end

      acc
    end)
  end

  defp invoke(fun, instance, event) when is_function(fun, 3), do: fun.(nil, instance, event)
  defp invoke(fun, instance, event) when is_function(fun, 2), do: fun.(instance, event)
  defp invoke(fun, _instance, event) when is_function(fun, 1), do: fun.(event)
  defp invoke(fun, _instance, _event) when is_function(fun, 0), do: fun.()

  defp truthy?(value), do: value not in [false, nil]

  defp qualify_attributes(instance) do
    Map.new(instance.attributes, fn {key, value} -> {instance.model.path <> "/" <> key, value} end)
  end

  defp event_detail(event), do: %{Name: event.name, Kind: event.kind, Target: event.target, Schema: event.schema}
  defp unique_id, do: "hsm-" <> Base.encode16(:crypto.strong_rand_bytes(8), case: :lower)
  defp clone(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))
end
