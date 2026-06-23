defmodule HSM.DSL do
  @moduledoc false

  alias HSM.{Model, Node, Transition, ValidationError}

  @hooks_table :hsm_dsl_model_hooks
  @hooks_key {__MODULE__, :hooks_key}
  @transition_paths_key {__MODULE__, :transition_paths}
  @exit_point_final_marker "//__hsm_exit__/"
  @operation_contract {__MODULE__, :operation_contract}

  def partial(kind, name, parts),
    do: %{__hsm_partial__: true, kind: kind, name: name, parts: parts}

  def define(name, partials) when is_binary(name) do
    validate_name!("model", name)
    {partials, validator, finalizer} = split_model_hooks(partials)
    root = "/" <> name

    model = %Model{
      name: name,
      path: root,
      root: root,
      states: %{root => %Node{name: name, path: root, kind: :state}}
    }

    model =
      Enum.reduce(partials, model, fn partial, acc ->
        apply_root_partial(acc, partial)
      end)

    model
    |> finish_model(validator, finalizer)
    |> remember_model(validator, finalizer, model)
  end

  def redefine(%Model{} = model, partials) do
    {hooks, replay_base} = model_metadata(model)
    redefine_with_hooks(replay_base, partials, hooks)
  end

  def redefine(%Model{} = model, name, partials) when is_binary(name) do
    validate_name!("model", name)
    {hooks, replay_base} = model_metadata(model)

    replay_base
    |> rebase_model_root("/" <> name)
    |> redefine_with_hooks(partials, hooks)
  end

  defp redefine_with_hooks(%Model{} = model, partials, {source_validator, source_finalizer}) do
    {partials, validator, finalizer} = split_model_hooks(partials)
    validator = validator || source_validator
    finalizer = finalizer || source_finalizer

    model =
      Enum.reduce(partials, model, fn partial, acc ->
        apply_root_partial(acc, partial)
      end)

    model
    |> finish_model(validator, finalizer)
    |> remember_model(validator, finalizer, model)
  end

  defp apply_root_partial(model, %{kind: :initial, parts: parts}) do
    validate_initial_parts!(parts)
    {transition, _} = build_transition(model, model.root, parts, nil, true)
    %{model | initial: %{transition | source: model.root}}
  end

  defp apply_root_partial(model, %{kind: kind} = partial)
       when kind in [:state, :final, :choice, :entry_point, :exit_point] do
    add_node(model, model.root, partial)
  end

  defp apply_root_partial(model, %{kind: :submachine} = partial) do
    add_submachine(model, model.root, partial)
  end

  defp apply_root_partial(model, {:attribute, name, type, default}) do
    validate_name!("attribute", name)

    %{
      model
      | attributes: Map.put(model.attributes, name, default),
        attribute_types: Map.put(model.attribute_types, name, type)
    }
  end

  defp apply_root_partial(model, {:operation, name, fun})
       when is_binary(name) and (is_function(fun) or is_nil(fun)) do
    validate_name!("operation", name)
    %{model | operations: Map.put(model.operations, name, operation_callback_contract(fun))}
  end

  defp apply_root_partial(model, {:operation_contract, name}) when is_binary(name) do
    validate_name!("operation", name)
    %{model | operations: Map.put_new(model.operations, name, nil)}
  end

  defp apply_root_partial(model, {:observer, observer, targets}) do
    %{model | observers: model.observers ++ [{observer, List.wrap(targets)}]}
  end

  defp apply_root_partial(model, %{kind: :transition, parts: parts, name: id}) do
    {transition, model} = build_transition(model, model.root, parts, id)
    %{model | transitions: model.transitions ++ [transition]}
  end

  defp apply_root_partial(_model, other),
    do: raise(ValidationError, message: "unsupported model partial #{inspect(other)}")

  defp add_node(model, parent_path, %{kind: :entry_point, name: name, parts: parts}) do
    validate_name!("entry_point", name)
    validate_entry_point_parts!(parts)
    path = join(parent_path, name)

    if Map.has_key?(model.states, path) do
      raise ValidationError, message: "state #{path} already exists"
    end

    node = %Node{name: name, path: path, parent: parent_path, kind: :entry_point}
    model = put_in(model.states[path], node)
    model = update_in(model.states[parent_path].children, &((&1 || []) ++ [path]))
    {transition, model} = build_transition(model, path, parts, nil, true)
    put_in(model.states[path].transitions, [%{transition | owner: path, source: path}])
  end

  defp add_node(model, parent_path, %{kind: :exit_point, name: name, parts: parts}) do
    validate_name!("exit_point", name)
    validate_exit_point_parts!(parts)
    path = join(parent_path, name)
    final_name = exit_point_final_name(name)
    final_path = exit_point_final_path(parent_path, name)

    cond do
      Map.has_key?(model.states, path) ->
        raise ValidationError, message: "state #{path} already exists"

      Map.has_key?(model.states, final_path) ->
        raise ValidationError, message: "state #{final_path} already exists"

      true ->
        :ok
    end

    node = %Node{name: name, path: path, parent: parent_path, kind: :exit_point}
    final = %Node{name: final_name, path: final_path, parent: parent_path, kind: :final}
    model = put_in(model.states[path], node)
    model = put_in(model.states[final_path], final)
    model = update_in(model.states[parent_path].children, &((&1 || []) ++ [path]))
    parts = [{:target, final_path} | parts]
    {transition, model} = build_transition(model, path, parts, nil, true)
    put_in(model.states[path].transitions, [%{transition | owner: path, source: path}])
  end

  defp add_node(model, parent_path, %{kind: kind, name: name, parts: parts}) do
    validate_name!(Atom.to_string(kind), name)
    parts = normalize_pseudostate_parts(kind, parts)
    path = join(parent_path, name)

    if Map.has_key?(model.states, path) do
      raise ValidationError, message: "state #{path} already exists"
    end

    node = %Node{name: name, path: path, parent: parent_path, kind: kind}
    model = put_in(model.states[path], node)
    model = update_in(model.states[parent_path].children, &((&1 || []) ++ [path]))

    Enum.reduce(parts, model, fn part, acc ->
      apply_node_partial(acc, path, part)
    end)
  end

  defp add_submachine(model, parent_path, %{name: name, parts: [%Model{} = child | parts]}) do
    validate_name!("submachine", name)
    validate_submachine_boundary_parts!(parts)
    path = join(parent_path, name)

    if Map.has_key?(model.states, path) do
      raise ValidationError, message: "state #{path} already exists"
    end

    child_root = child.root
    child_root_node = Map.fetch!(child.states, child_root)
    boundary = %Node{name: name, path: path, parent: parent_path, kind: :submachine}

    model =
      model
      |> put_in([Access.key(:states), path], boundary)
      |> update_in(
        [Access.key(:states), parent_path, Access.key(:children)],
        &((&1 || []) ++ [path])
      )
      |> merge_submachine_metadata(child, path)
      |> rebase_submachine_nodes(child, path)

    boundary =
      model.states[path]
      |> Map.put(:initial, rebase_transition(child.initial, child_root, path))
      |> Map.put(:transitions, rebase_transitions(child.transitions, child_root, path))
      |> Map.put(:entry, model.states[path].entry)
      |> Map.put(:exit, model.states[path].exit)
      |> Map.put(:activity, model.states[path].activity)
      |> Map.put(:defer, model.states[path].defer)
      |> Map.put(:children, direct_rebased_children(child_root_node.children, child_root, path))

    model = put_in(model.states[path], boundary)

    Enum.reduce(parts, model, fn part, acc ->
      apply_node_partial(acc, path, part)
    end)
  end

  defp add_submachine(_model, _parent_path, %{name: name}) do
    raise ValidationError, message: "submachine #{inspect(name)} requires a model"
  end

  defp validate_submachine_boundary_parts!(parts) do
    Enum.each(parts, fn
      %{kind: kind}
      when kind in [
             :initial,
             :state,
             :final,
             :choice,
             :shallow_history,
             :deep_history,
             :submachine,
             :entry_point,
             :exit_point
           ] ->
        raise ValidationError, message: "submachine state cannot contain #{kind}"

      _part ->
        :ok
    end)
  end

  defp validate_entry_point_parts!(parts) do
    Enum.each(parts, fn
      {:target, _target} ->
        :ok

      {:effect, _effects} ->
        :ok

      other ->
        raise ValidationError, message: "unsupported entry point partial #{inspect(other)}"
    end)
  end

  defp validate_exit_point_parts!(parts) do
    Enum.each(parts, fn
      {:effect, _effects} ->
        :ok

      other ->
        raise ValidationError, message: "unsupported exit point partial #{inspect(other)}"
    end)
  end

  defp validate_initial_parts!(parts) do
    Enum.each(parts, fn
      {:target, _target} ->
        :ok

      {:effect, _effects} ->
        :ok

      other ->
        raise ValidationError, message: "unsupported initial partial #{inspect(other)}"
    end)
  end

  defp apply_node_partial(model, path, part) do
    if model.states[path].kind in [:choice, :shallow_history, :deep_history],
      do: apply_pseudostate_partial(model, path, part),
      else: apply_state_partial(model, path, part)
  end

  defp apply_pseudostate_partial(model, path, %{kind: :transition, parts: parts, name: id}) do
    {transition, model} = build_transition(model, path, parts, id, true)
    update_in(model.states[path].transitions, &((&1 || []) ++ [%{transition | owner: path}]))
  end

  defp apply_pseudostate_partial(model, path, part) do
    raise ValidationError,
      message: "unsupported #{model.states[path].kind} partial #{inspect(part)}"
  end

  defp normalize_pseudostate_parts(kind, parts)
       when kind in [:shallow_history, :deep_history] do
    if parts != [] and Enum.all?(parts, &transition_part?/1),
      do: [%{kind: :transition, name: nil, parts: parts}],
      else: parts
  end

  defp normalize_pseudostate_parts(_kind, parts), do: parts

  defp apply_state_partial(model, path, %{kind: kind} = partial)
       when kind in [
              :state,
              :final,
              :choice,
              :shallow_history,
              :deep_history,
              :entry_point,
              :exit_point
            ] do
    add_node(model, path, partial)
  end

  defp apply_state_partial(model, path, %{kind: :submachine} = partial) do
    add_submachine(model, path, partial)
  end

  defp apply_state_partial(model, path, %{kind: :initial, parts: parts}) do
    validate_initial_parts!(parts)
    {transition, model} = build_transition(model, path, parts, nil, true)
    put_in(model.states[path].initial, %{transition | source: path})
  end

  defp apply_state_partial(model, path, %{kind: :transition, parts: parts, name: id}) do
    bare_relative_to_owner = model.states[path].kind in [:choice, :shallow_history, :deep_history]
    {transition, model} = build_transition(model, path, parts, id, bare_relative_to_owner)
    update_in(model.states[path].transitions, &((&1 || []) ++ [%{transition | owner: path}]))
  end

  defp apply_state_partial(model, path, {:entry, actions}),
    do: update_in(model.states[path].entry, &((&1 || []) ++ actions))

  defp apply_state_partial(model, path, {:exit, actions}),
    do: update_in(model.states[path].exit, &((&1 || []) ++ actions))

  defp apply_state_partial(model, path, {:activity, actions}),
    do: update_in(model.states[path].activity, &((&1 || []) ++ actions))

  defp apply_state_partial(model, path, {:defer, events}) do
    if events == [], do: raise(ValidationError, message: "defer requires at least one event")
    defer_entries = Enum.map(events, &defer_entry/1)
    update_in(model.states[path].defer, &((&1 || []) ++ defer_entries))
  end

  defp apply_state_partial(_model, _path, part),
    do: raise(ValidationError, message: "unsupported state partial #{inspect(part)}")

  defp transition_part?({key, _}) when key in [:target, :source, :trigger, :guard], do: true
  defp transition_part?({:effect, _}), do: true
  defp transition_part?(_), do: false

  defp build_transition(model, owner, parts, id),
    do: build_transition(model, owner, parts, id, false)

  defp build_transition(model, owner, parts, id, bare_relative_to_owner) do
    path_owner =
      case model.states[owner] do
        %HSM.Node{kind: kind, parent: parent}
        when kind in [:choice, :shallow_history, :deep_history, :entry_point, :exit_point] ->
          parent

        _ ->
          owner
      end

    {model, transition, entry_point, exit_point} =
      Enum.reduce(parts, {model, %Transition{id: id, owner: owner}, nil, nil}, fn
        {:source, source}, {acc_model, tr, entry_point, exit_point} ->
          source = resolve_path(acc_model, path_owner, source)
          {acc_model, %{tr | source: source}, entry_point, exit_point}

        {:target, target}, {acc_model, tr, entry_point, exit_point} ->
          target = resolve_path(acc_model, path_owner, target, bare_relative_to_owner)
          {acc_model, %{tr | target: target}, entry_point, exit_point}

        {:trigger, trigger}, {acc_model, tr, entry_point, exit_point} ->
          {trigger, acc_model} = normalize_trigger(acc_model, trigger)
          {acc_model, %{tr | trigger: trigger}, entry_point, exit_point}

        {:guard, guard}, {acc_model, tr, entry_point, exit_point} ->
          {acc_model, %{tr | guard: guard}, entry_point, exit_point}

        {:effect, effects}, {acc_model, tr, entry_point, exit_point} ->
          {acc_model, %{tr | effects: tr.effects ++ List.wrap(effects)}, entry_point, exit_point}

        {:kind, kind}, {acc_model, tr, entry_point, exit_point}
        when kind in [:external, :internal, :local, :self] ->
          {acc_model, %{tr | kind: kind}, entry_point, exit_point}

        %{kind: :entry_point, name: name, parts: []}, {acc_model, tr, _entry_point, exit_point} ->
          {acc_model, tr, name, exit_point}

        %{kind: :exit_point, name: name, parts: []}, {acc_model, tr, entry_point, _exit_point} ->
          {acc_model, tr, entry_point, name}

        other, _tr ->
          raise ValidationError, message: "unsupported transition partial #{inspect(other)}"
      end)

    transition =
      transition
      |> Map.put(:source, transition.source || owner)
      |> apply_entry_point(model, entry_point)
      |> apply_exit_point(owner, exit_point)

    {transition, model}
  end

  defp normalize_trigger(model, {:on, events}) when is_list(events),
    do: {{:on, Enum.map(events, &event_name/1)}, model}

  defp normalize_trigger(model, {:on, event}), do: {{:on, event_name(event)}, model}

  defp normalize_trigger(model, {:on_set, name}) do
    validate_name!(trigger_name_kind(:on_set), name)
    {{:on_set, name}, ensure_attribute_contract(model, name)}
  end

  defp normalize_trigger(model, {:on_call, name}) do
    validate_name!(trigger_name_kind(:on_call), name)
    {{:on_call, name}, model}
  end

  defp normalize_trigger(model, {kind, name}) when kind in [:on_set, :on_call] do
    validate_name!(trigger_name_kind(kind), name)
    {{kind, name}, model}
  end

  defp normalize_trigger(model, {:when, fun}) when is_function(fun),
    do: {{:when, fun, Map.keys(model.attributes)}, model}

  defp normalize_trigger(model, {:when, name}) do
    validate_name!(trigger_name_kind(:when), name)
    {{:on_set, name}, ensure_attribute_contract(model, name)}
  end

  defp normalize_trigger(model, {kind, value})
       when kind in [:after, :every, :at], do: {{kind, value}, model}

  defp normalize_trigger(model, other), do: {other, model}

  defp trigger_name_kind(:on_set), do: "attribute"
  defp trigger_name_kind(:when), do: "attribute"
  defp trigger_name_kind(:on_call), do: "operation"

  defp apply_entry_point(transition, _model, nil), do: transition

  defp apply_entry_point(%Transition{target: nil}, _model, name) do
    raise ValidationError,
      message: "entry point #{inspect(name)} requires a submachine transition target"
  end

  defp apply_entry_point(%Transition{target: target} = transition, model, name) do
    entry_path = join(target, name)

    case {model.states[target], model.states[entry_path]} do
      {%HSM.Node{kind: :submachine}, %HSM.Node{kind: :entry_point}} ->
        %{transition | target: entry_path}

      {%HSM.Node{kind: :submachine}, _entry} ->
        raise ValidationError, message: "missing entry point #{inspect(name)}"

      {nil, _entry} ->
        %{transition | target: entry_path}

      {_target, _entry} ->
        raise ValidationError,
          message: "entry point #{inspect(name)} requires a submachine transition target"
    end
  end

  defp apply_exit_point(transition, _owner, nil), do: transition

  defp apply_exit_point(%Transition{} = transition, _owner, name) do
    final_name = exit_point_final_name(name)
    guard = transition.guard
    guarded? = guard != nil

    %{
      transition
      | trigger: {:on, "hsm/final"},
        guard: {:exit_point, name, guarded?, guard, final_name}
    }
  end

  defp split_model_hooks(partials) do
    Enum.reduce(partials, {[], nil, nil}, fn
      {:validator, fun}, {partials, _validator, finalizer} ->
        {partials, fun, finalizer}

      {:finalizer, fun}, {partials, validator, _finalizer} ->
        {partials, validator, fun}

      partial, {partials, validator, finalizer} ->
        {partials ++ [partial], validator, finalizer}
    end)
  end

  defp finish_model(model, validator, finalizer) do
    model
    |> validate_model!()
    |> run_model_hook(validator)
    |> validate_model!()
    |> run_model_hook(finalizer)
    |> validate_model!()
  end

  defp run_model_hook(model, nil), do: model

  defp run_model_hook(model, fun) when is_function(fun, 1) do
    case fun.(model) do
      %Model{} = updated -> updated
      :ok -> model
      nil -> model
      true -> model
      false -> raise ValidationError, message: "model hook rejected model"
      other -> raise ValidationError, message: "model hook returned #{inspect(other)}"
    end
  end

  defp run_model_hook(_model, hook),
    do:
      raise(ValidationError,
        message: "model hook must be a one-argument function, got #{inspect(hook)}"
      )

  defp remember_model(model, validator, finalizer, replay_base) do
    {model, key} = ensure_model_hooks_key(model)
    :ets.insert(hooks_table(), {key, {{validator, finalizer}, replay_base}})
    model
  end

  defp model_metadata(model) do
    case :ets.lookup(hooks_table(), model_hooks_key(model)) do
      [{_key, {hooks, replay_base}}] -> {hooks, replay_base}
      [{_key, hooks}] -> {hooks, model}
      [] -> {{nil, nil}, model}
    end
  end

  defp ensure_model_hooks_key(model) do
    case model_hooks_key(model) do
      nil ->
        key = make_ref()
        model = put_in(model.transition_candidates[@hooks_key], key)
        {model, key}

      key ->
        {model, key}
    end
  end

  defp model_hooks_key(%Model{transition_candidates: transition_candidates}),
    do: Map.get(transition_candidates, @hooks_key)

  defp hooks_table do
    case :ets.whereis(@hooks_table) do
      :undefined ->
        try do
          :ets.new(@hooks_table, [:named_table, :public, :set, read_concurrency: true])
        rescue
          ArgumentError -> @hooks_table
        end

      table ->
        table
    end
  end

  defp rebase_model_root(model, new_root) do
    old_root = model.root

    states =
      Map.new(model.states, fn {path, node} ->
        path = rebase_path(path, old_root, new_root)
        node = rebase_node(node, old_root, new_root)
        node = if node.path == new_root, do: %{node | name: path_name(new_root)}, else: node
        {path, node}
      end)

    %{
      model
      | name: path_name(new_root),
        path: new_root,
        root: new_root,
        states: states,
        initial: rebase_transition(model.initial, old_root, new_root),
        transitions: rebase_transitions(model.transitions, old_root, new_root),
        active_paths: %{},
        active_defers: %{},
        transition_candidates: %{},
        timer_transitions: %{}
    }
  end

  defp merge_submachine_metadata(model, child, _path) do
    %{
      model
      | attributes: Map.merge(model.attributes, child.attributes),
        attribute_types: Map.merge(model.attribute_types, child.attribute_types),
        operations:
          Map.merge(model.operations, child.operations, fn _name, parent, child ->
            if explicit_operation_contract?(child), do: child, else: child || parent
          end),
        observers: model.observers ++ child.observers
    }
  end

  defp scoped_operation_key(model, path, name),
    do: [relative_scope(model, path), name] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join("/")

  defp operation_callback_contract(nil), do: @operation_contract
  defp operation_callback_contract(fun), do: fun

  defp explicit_operation_contract?(@operation_contract), do: true
  defp explicit_operation_contract?(_callback), do: false

  defp rebase_submachine_nodes(model, child, flat_root) do
    rebased =
      child.states
      |> Enum.reject(fn {path, _node} -> path == child.root end)
      |> Map.new(fn {path, node} ->
        path = rebase_path(path, child.root, flat_root)
        {path, rebase_node(node, child.root, flat_root)}
      end)

    states =
      Map.merge(model.states, rebased, fn path, _existing, _new ->
        raise ValidationError, message: "state #{path} already exists"
      end)

    %{model | states: states}
  end

  defp rebase_node(node, old_root, new_root) do
    %{
      node
      | path: rebase_path(node.path, old_root, new_root),
        parent: rebase_path_or_nil(node.parent, old_root, new_root),
        children: direct_rebased_children(node.children, old_root, new_root),
        initial: rebase_transition(node.initial, old_root, new_root),
        transitions: rebase_transitions(node.transitions, old_root, new_root),
        defer: rebase_defers(node.defer, old_root, new_root)
    }
  end

  defp direct_rebased_children(children, old_root, new_root),
    do: Enum.map(children, &rebase_path(&1, old_root, new_root))

  defp rebase_transitions(transitions, old_root, new_root),
    do: Enum.map(transitions, &rebase_transition(&1, old_root, new_root))

  defp rebase_transition(nil, _old_root, _new_root), do: nil

  defp rebase_transition(%Transition{} = transition, old_root, new_root) do
    %{
      transition
      | owner: rebase_path_or_nil(transition.owner, old_root, new_root),
        source: rebase_path_or_nil(transition.source, old_root, new_root),
        target: rebase_path_or_nil(transition.target, old_root, new_root),
        id: rebase_transition_id(transition.id, old_root, new_root)
    }
  end

  defp rebase_transition_id(nil, _old_root, _new_root), do: nil

  defp rebase_transition_id(id, old_root, new_root) when is_binary(id) do
    cond do
      id == old_root ->
        new_root

      String.starts_with?(id, old_root <> "/") or String.starts_with?(id, old_root <> "#") ->
        String.replace_prefix(id, old_root, new_root)

      true ->
        id
    end
  end

  defp rebase_transition_id(id, _old_root, _new_root), do: id

  defp rebase_defers(defers, old_root, new_root) do
    Enum.map(defers, fn
      {event, scope} -> {event, rebase_path_or_nil(scope, old_root, new_root)}
      event -> event
    end)
  end

  defp rebase_path_or_nil(nil, _old_root, _new_root), do: nil
  defp rebase_path_or_nil(path, old_root, new_root), do: rebase_path(path, old_root, new_root)

  defp rebase_path(path, old_root, new_root) do
    cond do
      path == old_root ->
        new_root

      String.starts_with?(path, old_root <> @exit_point_final_marker) ->
        String.replace_prefix(path, old_root, new_root)

      String.starts_with?(path, old_root <> "/") ->
        String.replace_prefix(path, old_root, new_root)

      true ->
        path
    end
  end

  defp path_name(path), do: path |> String.split("/", trim: true) |> List.last()

  defp exit_point_final_name(name), do: "__hsm_exit_" <> name

  defp exit_point_final_path(parent_path, name),
    do: parent_path <> @exit_point_final_marker <> name

  defp validate_model!(model) do
    model = assign_transition_ids(model)

    Enum.each(model.states, fn {_path, node} ->
      if node.kind == :final and node.transitions != [] do
        raise ValidationError,
          message: "final state #{node.path} cannot have outgoing transitions"
      end

      if node.kind == :choice do
        last = List.last(node.transitions)

        earlier_guardless? =
          node.transitions
          |> Enum.drop(-1)
          |> Enum.any?(&(is_nil(&1.guard) and is_nil(&1.trigger)))

        if last == nil or last.guard != nil do
          raise ValidationError,
            message: "choice #{node.path} last transition must be guardless fallback"
        end

        if earlier_guardless? do
          raise ValidationError,
            message: "choice #{node.path} guardless fallback must be last"
        end
      end

      if node.kind in [:shallow_history, :deep_history] and node.transitions == [] do
        raise ValidationError, message: "history #{node.path} requires a default transition"
      end

      if node.kind in [:shallow_history, :deep_history] and
           Enum.count(node.transitions, &is_nil(&1.guard)) > 1 do
        raise ValidationError, message: "history #{node.path} has multiple fallback transitions"
      end

      if node.kind in [:entry_point, :exit_point] and node.transitions == [] do
        raise ValidationError, message: "#{node.kind} #{node.path} requires a target"
      end

      validate_entry_point_declaration!(model, node)
    end)

    validate_required_initials!(model)
    validate_initial_transition!(model.initial)

    Enum.each(model.states, fn {_path, node} ->
      validate_initial_transition!(node.initial)
    end)

    all_transitions =
      ([model.initial | model.transitions] ++
         Enum.flat_map(model.states, fn {_path, node} -> [node.initial | node.transitions] end))
      |> Enum.reject(&is_nil/1)

    validate_timer_transition_ids!(all_transitions)

    Enum.each(all_transitions, fn transition ->
      validate_transition!(model, transition)

      if transition.target && !Map.has_key?(model.states, transition.target) do
        raise ValidationError, message: "Vertex #{inspect(transition.target)} not found"
      end

      if transition.source && !Map.has_key?(model.states, transition.source) do
        raise ValidationError, message: "Source #{inspect(transition.source)} not found"
      end

      validate_final_source!(model, transition)
      validate_composite_target!(model, transition)
      validate_entry_point_target!(model, transition)
      validate_exit_point_handler!(model, transition)
      validate_submachine_target!(model, transition)
    end)

    model = validate_operation_references!(model, all_transitions)
    validate_timer_sources!(model, all_transitions)
    validate_member_namespace!(model)

    index_model(model)
  end

  defp validate_required_initials!(%Model{initial: nil}) do
    raise ValidationError, message: "model requires initial transition"
  end

  defp validate_required_initials!(_model), do: :ok

  defp validate_initial_transition!(nil), do: :ok

  defp validate_initial_transition!(%Transition{target: nil}) do
    raise ValidationError, message: "initial transition requires target"
  end

  defp validate_initial_transition!(%Transition{}), do: :ok

  defp assign_transition_ids(model) do
    states =
      Map.new(model.states, fn {path, node} ->
        node =
          %{node | transitions: assign_transition_ids(path, node.transitions)}
          |> put_initial_id(path)

        {path, node}
      end)

    %{model | states: states, transitions: assign_transition_ids(model.root, model.transitions)}
    |> put_initial_id(model.root)
  end

  defp assign_transition_ids(owner, transitions) do
    transitions
    |> Enum.with_index()
    |> Enum.map(fn {transition, index} ->
      put_transition_id(transition, "#{owner}#transition:#{index}")
    end)
  end

  defp put_initial_id(%Model{initial: nil} = model, _owner), do: model

  defp put_initial_id(%Model{initial: transition} = model, owner),
    do: %{model | initial: put_transition_id(transition, "#{owner}#initial")}

  defp put_initial_id(%Node{initial: nil} = node, _owner), do: node

  defp put_initial_id(%Node{initial: transition} = node, owner),
    do: %{node | initial: put_transition_id(transition, "#{owner}#initial")}

  defp put_transition_id(%Transition{id: id} = transition, fallback) when id in [nil, ""],
    do: %{transition | id: fallback}

  defp put_transition_id(%Transition{} = transition, _fallback), do: transition

  defp validate_transition!(%Transition{trigger: {:every, interval}})
       when is_integer(interval) and interval <= 0,
       do: raise(ValidationError, message: "every interval must be positive")

  defp validate_transition!(%Transition{target: nil, effects: []}) do
    raise ValidationError, message: "transition requires target or effects"
  end

  defp validate_transition!(_transition), do: :ok

  defp validate_transition!(model, %Transition{target: nil, source: source} = transition) do
    case model.states[source] do
      %Node{kind: kind} when kind in [:choice, :shallow_history, :deep_history] ->
        raise ValidationError, message: "pseudostate transition requires target"

      _node ->
        validate_transition!(transition)
    end
  end

  defp validate_transition!(model, %Transition{trigger: trigger, source: source})
       when trigger != nil do
    case model.states[source] do
      %Node{kind: kind} when kind in [:choice, :shallow_history, :deep_history] ->
        raise ValidationError, message: "pseudostate transition cannot have trigger"

      _node ->
        :ok
    end
  end

  defp validate_transition!(_model, transition), do: validate_transition!(transition)

  defp validate_final_source!(model, %Transition{source: source}) do
    case model.states[source] do
      %Node{kind: :final, path: path} ->
        raise ValidationError, message: "final state #{path} cannot have outgoing transitions"

      _node ->
        :ok
    end
  end

  defp validate_operation_references!(model, transitions) do
    Enum.each(model.states, fn {_path, node} ->
      validate_actions!(model, node.path, "entry", node.entry)
      validate_actions!(model, node.path, "exit", node.exit)
      validate_actions!(model, node.path, "activity", node.activity)
    end)

    model =
      Enum.reduce(transitions, model, fn transition, acc ->
        acc
        |> validate_trigger_operation!(transition)
        |> validate_trigger_attribute!(transition)
      end)

    Enum.each(transitions, fn transition ->
      validate_guard_operation!(model, transition)
      validate_actions!(model, operation_scope(transition), "effect", transition.effects)
    end)

    model
  end

  defp validate_trigger_operation!(model, %Transition{trigger: {:on_call, name}} = transition),
    do: ensure_operation_contract(model, operation_scope(transition), name)

  defp validate_trigger_operation!(model, _transition), do: model

  defp validate_trigger_attribute!(model, %Transition{trigger: {:on_set, name}}),
    do: ensure_attribute_contract(model, name)

  defp validate_trigger_attribute!(model, _transition), do: model

  defp validate_timer_sources!(model, transitions) do
    Enum.each(transitions, fn
      %Transition{trigger: {kind, name}} when kind in [:after, :every, :at] and is_binary(name) ->
        unless Map.has_key?(model.attributes, name) do
          raise ValidationError, message: "timer source attribute #{inspect(name)} not found"
        end

      _transition ->
        :ok
    end)
  end

  defp validate_guard_operation!(model, %Transition{guard: name} = transition)
       when is_binary(name),
       do: validate_operation_reference!(model, operation_scope(transition), "guard", name)

  defp validate_guard_operation!(
         model,
         %Transition{
           guard: {:exit_point, _name, _guarded?, name, _guard}
         } = transition
       )
       when is_binary(name),
       do: validate_operation_reference!(model, operation_scope(transition), "guard", name)

  defp validate_guard_operation!(_model, _transition), do: :ok

  defp validate_actions!(model, scope, kind, actions) do
    Enum.each(actions, fn
      name when is_binary(name) -> validate_operation_reference!(model, scope, kind, name)
      _action -> :ok
    end)
  end

  defp validate_operation_reference!(model, scope, kind, name) do
    unless Enum.any?(
             operation_reference_keys(model, scope, name),
             &Map.has_key?(model.operations, &1)
           ) do
      raise ValidationError, message: "#{kind} references unknown operation #{inspect(name)}"
    end
  end

  defp validate_member_namespace!(model) do
    model
    |> member_namespace_entries()
    |> Enum.reduce(%{}, fn {name, kind}, seen ->
      case Map.fetch(seen, name) do
        {:ok, existing} when existing != kind ->
          raise ValidationError,
            message: "#{kind} #{inspect(name)} conflicts with #{existing} #{inspect(name)}"

        _missing ->
          Map.put_new(seen, name, kind)
      end
    end)

    :ok
  end

  defp member_namespace_entries(model) do
    state_entries =
      model.states
      |> Map.keys()
      |> Enum.map(&relative_scope(model, &1))
      |> Enum.reject(&(&1 == ""))
      |> Enum.map(&{&1, "state"})

    attribute_entries = Enum.map(Map.keys(model.attributes), &{&1, "attribute"})
    operation_entries = Enum.map(Map.keys(model.operations), &{&1, "operation"})

    state_entries ++ attribute_entries ++ operation_entries
  end

  defp ensure_operation_contract(model, scope, name) do
    keys = operation_reference_keys(model, scope, name)

    if Enum.any?(keys, &Map.has_key?(model.operations, &1)) do
      model
    else
      put_in(model.operations[List.last(keys)], nil)
    end
  end

  defp ensure_attribute_contract(model, name) do
    if Map.has_key?(model.attributes, name) do
      model
    else
      %{
        model
        | attributes: Map.put(model.attributes, name, nil),
          attribute_types: Map.put(model.attribute_types, name, :any)
      }
    end
  end

  defp operation_scope(%Transition{
         guard: {:exit_point, _name, _guarded?, _user_guard, _guard},
         owner: owner,
         source: source
       })
       when owner == source,
       do: parent(owner) || owner

  defp operation_scope(%Transition{owner: owner, source: source}), do: owner || source

  defp operation_key(%Model{path: path}, "/" <> _ = name) do
    if String.starts_with?(name, path <> "/"),
      do: String.replace_prefix(name, path <> "/", ""),
      else: name
  end

  defp operation_key(_model, name), do: name

  defp operation_reference_keys(model, _scope, "/" <> _ = name), do: [operation_key(model, name)]

  defp operation_reference_keys(model, nil, name), do: [operation_key(model, name)]

  defp operation_reference_keys(model, scope, name) do
    key = operation_key(model, name)

    scope
    |> ancestors_from_path_inclusive()
    |> Enum.map(&scoped_operation_key(model, &1, key))
    |> Kernel.++([key])
    |> Enum.uniq()
  end

  defp relative_scope(%Model{path: root}, path) when is_binary(path) do
    cond do
      path == root -> ""
      String.starts_with?(path, root <> "/") -> String.replace_prefix(path, root <> "/", "")
      true -> path
    end
  end

  defp relative_scope(_model, _path), do: ""

  defp validate_entry_point_declaration!(model, %Node{
         kind: :entry_point,
         path: path,
         transitions: [%Transition{target: target} | _]
       }) do
    cond do
      target == nil ->
        raise ValidationError, message: "entry point #{path} requires target"

      match?(%Node{kind: :exit_point}, model.states[target]) ->
        raise ValidationError, message: "entry point #{path} cannot target exit point"

      true ->
        :ok
    end
  end

  defp validate_entry_point_declaration!(_model, _node), do: :ok

  defp validate_composite_target!(_model, %Transition{target: nil}), do: :ok

  defp validate_composite_target!(model, %Transition{target: target}) do
    node = Map.fetch!(model.states, target)
    initial = if target == model.root, do: model.initial, else: node.initial

    if node.kind in [:state, :submachine] and node.children != [] and initial == nil do
      raise ValidationError, message: "composite state #{node.path} requires initial transition"
    end
  end

  defp validate_entry_point_target!(_model, %Transition{target: nil}), do: :ok

  defp validate_entry_point_target!(model, %Transition{target: target}) do
    case model.states[target] do
      %Node{kind: :entry_point, parent: parent} ->
        unless match?(%Node{kind: :submachine}, model.states[parent]) do
          raise ValidationError,
            message: "entry point target requires a submachine transition target"
        end

      _node ->
        :ok
    end
  end

  defp validate_exit_point_handler!(model, %Transition{
         guard: {:exit_point, name, _guarded?, _user_guard, _guard},
         owner: owner,
         source: source
       }) do
    boundary =
      cond do
        submachine_node?(model, source) -> source
        submachine_node?(model, owner) -> owner
        true -> nil
      end

    if boundary == nil do
      raise ValidationError, message: "exit point handler requires a submachine owner"
    end

    unless exit_point_in_boundary?(model, boundary, name) do
      raise ValidationError, message: "missing exit point #{inspect(name)}"
    end
  end

  defp validate_exit_point_handler!(_model, _transition), do: :ok

  defp submachine_node?(model, path), do: match?(%Node{kind: :submachine}, model.states[path])

  defp exit_point_in_boundary?(model, boundary, name) do
    Enum.any?(model.states, fn {path, node} ->
      path_inside?(path, boundary) and match?(%Node{kind: :exit_point, name: ^name}, node)
    end)
  end

  defp validate_submachine_target!(model, %Transition{} = transition) do
    source_boundary = containing_submachine(model, transition.source)
    owner_boundary = enclosing_submachine(model, transition.owner)
    source_node = model.states[transition.source]

    cond do
      source_boundary != nil and not boundary_matches?(owner_boundary, source_boundary) and
          not match?(%Node{kind: :exit_point}, source_node) ->
        raise ValidationError, message: "submachine internal source #{transition.source}"

      transition.target == nil ->
        model

      true ->
        validate_submachine_target_boundary!(model, transition)
    end
  end

  defp validate_submachine_target_boundary!(model, %Transition{target: target} = transition) do
    source_boundary = containing_submachine(model, transition.source)
    target_boundary = enclosing_submachine(model, target)
    target_node = Map.fetch!(model.states, target)
    source_node = model.states[transition.source]

    cond do
      source_boundary != nil and not path_inside?(target, source_boundary) and
        target_node.kind != :entry_point and
          not match?(%Node{kind: :exit_point}, source_node) ->
        raise ValidationError,
          message: "submachine boundary target #{target} leaves #{source_boundary}"

      target_boundary == nil ->
        model

      target_boundary == target ->
        model

      true ->
        boundary = target_boundary

        cond do
          target_node.kind == :entry_point and transition.source != boundary and
            path_inside?(transition.source, boundary) and
              not match?(%Node{kind: :exit_point}, source_node) ->
            raise ValidationError, message: "entry point target cannot be internal"

          transition.owner == boundary and transition.source == boundary ->
            model

          transition.source != boundary and path_inside?(transition.source, boundary) ->
            model

          target_node.kind == :entry_point ->
            model

          true ->
            raise ValidationError,
              message: "parent transition cannot target submachine internal state"
        end
    end
  end

  defp containing_submachine(_model, nil), do: nil

  defp containing_submachine(model, path) do
    path
    |> ancestors_from_path()
    |> Enum.find(fn candidate -> match?(%Node{kind: :submachine}, model.states[candidate]) end)
  end

  defp enclosing_submachine(model, path) do
    path
    |> ancestors_from_path_inclusive()
    |> Enum.find(fn candidate -> match?(%Node{kind: :submachine}, model.states[candidate]) end)
  end

  defp boundary_matches?(nil, _boundary), do: false

  defp boundary_matches?(owner_boundary, boundary),
    do: path_inside?(owner_boundary, boundary) or path_inside?(boundary, owner_boundary)

  defp ancestors_from_path_inclusive(path), do: [path | ancestors_from_path(path)]

  defp path_inside?(nil, _boundary), do: false

  defp path_inside?(path, boundary),
    do:
      path == boundary or String.starts_with?(path, boundary <> "/") or
        String.starts_with?(path, boundary <> @exit_point_final_marker)

  defp validate_timer_transition_ids!(transitions) do
    transitions
    |> Enum.filter(&timer_trigger?(&1.trigger))
    |> Enum.map(& &1.id)
    |> Enum.reduce(%{}, fn id, counts -> Map.update(counts, id, 1, &(&1 + 1)) end)
    |> Enum.find(fn {_id, count} -> count > 1 end)
    |> case do
      nil ->
        :ok

      {id, _count} ->
        raise ValidationError, message: "duplicate timer transition id #{inspect(id)}"
    end
  end

  defp index_model(model) do
    model = %{model | active_paths: active_paths(model)}
    transition_candidates = transition_candidates(model)
    transition_paths = transition_paths(%{model | transition_candidates: transition_candidates})

    %{
      model
      | active_defers: active_defers(model),
        transition_candidates:
          Map.put(transition_candidates, @transition_paths_key, transition_paths),
        timer_transitions: timer_transitions(model)
    }
  end

  defp active_paths(model) do
    Map.new(model.states, fn {path, _node} ->
      {path, Enum.filter([path | path_ancestors(path)], &Map.has_key?(model.states, &1))}
    end)
  end

  defp active_defers(model) do
    Map.new(model.states, fn {path, _node} ->
      defers =
        model.active_paths
        |> Map.fetch!(path)
        |> Enum.flat_map(&model.states[&1].defer)
        |> Enum.map(&defer_name/1)

      {path, defers}
    end)
  end

  defp transition_candidates(model) do
    Map.new(model.states, fn {path, _node} ->
      {local, parent} = transition_candidate_groups(model, path)

      {path,
       %{
         list: local ++ parent,
         local: index_transition_candidates(model, local),
         parent: index_transition_candidates(model, parent),
         all: index_transition_candidates(model, local ++ parent)
       }}
    end)
  end

  defp timer_transitions(model) do
    Map.new(model.states, fn {path, _node} ->
      timers =
        model
        |> transition_candidate_list(path)
        |> Enum.filter(&timer_trigger?(&1.trigger))

      {path, timers}
    end)
  end

  defp transition_candidate_list(model, path) do
    {local, parent} = transition_candidate_groups(model, path)
    local ++ parent
  end

  defp transition_candidate_groups(model, path) do
    owned = Enum.filter(owned_transitions(model, path), &(&1.source == path))

    parent_owned =
      model.active_paths
      |> Map.fetch!(path)
      |> Enum.drop(1)
      |> Enum.flat_map(fn parent ->
        model
        |> owned_transitions(parent)
        |> Enum.filter(&(&1.source == path))
      end)

    {owned, parent_owned}
  end

  defp index_transition_candidates(model, transitions) do
    entries = Enum.map(transitions, &{transition_keys(&1, model) |> Enum.uniq(), &1})

    by_key =
      Enum.reduce(entries, %{}, fn {keys, transition}, acc ->
        Enum.reduce(keys, acc, fn key, keyed ->
          Map.update(keyed, key, [transition], &(&1 ++ [transition]))
        end)
      end)

    %{by_key: by_key, ordered: entries}
  end

  defp transition_keys(%Transition{trigger: {:on, events}}, _model) when is_list(events),
    do: Enum.map(events, &{:on, &1})

  defp transition_keys(%Transition{trigger: {:on, event}}, _model), do: [{:on, event}]
  defp transition_keys(%Transition{trigger: {:on_set, name}}, _model), do: [{:on_set, name}]
  defp transition_keys(%Transition{trigger: {:on_call, name}}, _model), do: [{:on_call, name}]

  defp transition_keys(%Transition{trigger: {:when, _fun, attributes}}, _model) do
    case attributes do
      [] -> [{:on, "*"}]
      attributes -> Enum.map(attributes, &{:on_set, &1})
    end
  end

  defp transition_keys(%Transition{trigger: {:when, _fun}}, model) do
    case Map.keys(model.attributes) do
      [] -> [{:on, "*"}]
      attributes -> Enum.map(attributes, &{:on_set, &1})
    end
  end

  defp transition_keys(%Transition{id: id, trigger: {kind, _value}}, _model)
       when kind in [:after, :every, :at],
       do: [{:timer, id}]

  defp transition_keys(_transition, _model), do: []

  defp owned_transitions(model, path) do
    node = model.states[path]

    if path == model.root,
      do: node.transitions ++ model.transitions,
      else: node.transitions
  end

  defp timer_trigger?({kind, _}) when kind in [:after, :every, :at], do: true
  defp timer_trigger?(_trigger), do: false

  defp transition_paths(model) do
    Enum.reduce(Map.keys(model.states), %{}, fn active_leaf, plans ->
      (initial_transitions(model, active_leaf) ++
         (model.active_paths
          |> Map.fetch!(active_leaf)
          |> Enum.flat_map(&transition_candidate_list(model, &1))))
      |> Enum.reject(&is_nil(&1.target))
      |> Enum.reduce(plans, fn transition, acc ->
        Map.put_new(
          acc,
          {active_leaf, transition},
          transition_path_plan(model, active_leaf, transition)
        )
      end)
    end)
  end

  defp initial_transitions(model, active_leaf) do
    initial =
      if active_leaf == model.root,
        do: model.initial,
        else: model.states[active_leaf].initial

    List.wrap(initial)
  end

  defp transition_path_plan(model, active_leaf, %Transition{} = transition) do
    {exit_paths, lca} =
      transition_exit_paths(
        model,
        transition.source,
        transition.target,
        transition.kind,
        transition.trigger,
        active_leaf
      )

    enter_paths =
      if dynamic_target?(model, transition.target),
        do: nil,
        else: path_from_lca(model, transition.target, lca)

    %{exit: exit_paths, lca: lca, enter: enter_paths, history: history_entries(exit_paths)}
  end

  defp transition_exit_paths(_model, source, _target, :internal, _trigger, _active_leaf),
    do: {[], source}

  defp transition_exit_paths(model, source, _target, :self, _trigger, active_leaf) do
    lca = parent(source)
    {paths_to_lca(model, active_leaf, lca), lca}
  end

  defp transition_exit_paths(model, source, target, kind, trigger, active_leaf) do
    lca = external_lca(model, source, target, kind, trigger)
    {paths_to_lca(model, active_leaf, lca), lca}
  end

  defp external_lca(model, source, target, :external, trigger) do
    if trigger != nil and source != model.root and path_below_scope?(target, source),
      do: parent(source),
      else: lca(source, target)
  end

  defp external_lca(_model, source, target, _kind, _trigger), do: lca(source, target)

  defp paths_to_lca(model, active_leaf, lca) do
    model.active_paths
    |> Map.fetch!(active_leaf)
    |> Enum.take_while(&(&1 != lca))
  end

  defp path_from_lca(model, target, lca) do
    model.active_paths
    |> Map.fetch!(target)
    |> Enum.take_while(&(&1 != lca))
    |> Enum.reverse()
  end

  defp dynamic_target?(model, target) do
    case model.states[target] do
      %Node{kind: kind}
      when kind in [:choice, :shallow_history, :deep_history, :entry_point, :exit_point] ->
        true

      _node ->
        false
    end
  end

  defp path_below_scope?(path, scope) when is_binary(path),
    do: String.starts_with?(path, scope <> "/")

  defp path_below_scope?(_path, _scope), do: false

  defp history_entries([]), do: []

  defp history_entries(exit_paths) do
    leaf = List.first(exit_paths)

    Enum.flat_map(exit_paths, fn path ->
      case parent(path) do
        nil -> []
        parent -> [{parent, path, leaf}]
      end
    end)
  end

  defp path_ancestors(path),
    do:
      Stream.iterate(parent(path), &parent/1)
      |> Enum.take_while(&(&1 not in [nil, "", "."]))

  def resolve_path(model, owner, path) when is_binary(path) do
    resolve_path(model, owner, path, false)
  end

  def resolve_path(model, owner, path, bare_relative_to_owner) when is_binary(path) do
    cond do
      String.contains?(path, @exit_point_final_marker) ->
        path

      String.starts_with?(path, "/") ->
        normalize(path)

      bare_relative_to_owner or path == "." or String.starts_with?(path, "./") or
          String.starts_with?(path, "../") ->
        normalize(join(owner, path))

      true ->
        owner_path = normalize(join(owner, path))
        root_path = normalize(join(model.root, path))

        if Map.has_key?(model.states, owner_path), do: owner_path, else: root_path
    end
  end

  def ancestors(model, path) do
    Stream.iterate(path, &parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", "."]))
    |> Enum.filter(&Map.has_key?(model.states, &1))
  end

  def parent(path) do
    case :binary.match(path, @exit_point_final_marker) do
      {index, _length} ->
        binary_part(path, 0, index)

      :nomatch ->
        case path |> String.split("/", trim: true) |> Enum.drop(-1) do
          [] -> nil
          parts -> "/" <> Enum.join(parts, "/")
        end
    end
  end

  def lca(a, b) do
    if a == b do
      parent(a)
    else
      a_ancestors = [a | ancestors_from_path(a)]
      Enum.find([b | ancestors_from_path(b)], &(&1 in a_ancestors))
    end
  end

  defp ancestors_from_path(path) do
    Stream.iterate(parent(path), &parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", "."]))
  end

  def join(base, rel) do
    parts =
      (String.split(base, "/", trim: true) ++ String.split(rel, "/", trim: true))
      |> Enum.reduce([], fn
        ".", acc -> acc
        "..", [_ | rest] -> rest
        part, acc -> [part | acc]
      end)
      |> Enum.reverse()

    "/" <> Enum.join(parts, "/")
  end

  def normalize(path), do: join("/", path)

  def defer_entry(%{"event" => event, "scope" => scope}), do: {event_name(event), scope}
  def defer_entry(%{event: event, scope: scope}), do: {event_name(event), scope}
  def defer_entry(event), do: event_name(event)

  def defer_name({name, _scope}), do: name
  def defer_name(name), do: name

  def event_name(%HSM.Event{name: name}), do: name
  def event_name(%{"name" => name}) when is_binary(name), do: name
  def event_name(%{name: name}) when is_binary(name), do: name
  def event_name(name) when is_binary(name), do: name

  defp validate_name!(kind, name) when is_binary(name) do
    if name == "" or String.contains?(name, "/") do
      raise ValidationError, message: "#{kind} name cannot contain /"
    end
  end

  defp validate_name!(kind, _name) do
    raise ValidationError, message: "#{kind} name must be a string"
  end
end
