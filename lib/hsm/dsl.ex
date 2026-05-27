defmodule HSM.DSL do
  @moduledoc false

  alias HSM.{Model, Node, Transition, ValidationError}

  def partial(kind, name, parts),
    do: %{__hsm_partial__: true, kind: kind, name: name, parts: parts}

  def define(name, partials) when is_binary(name) do
    validate_name!("model", name)
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

    validate_model!(model)
  end

  defp apply_root_partial(model, %{kind: :initial, parts: parts}) do
    {transition, _} = build_transition(model, model.root, parts, nil, true)
    %{model | initial: %{transition | source: model.root}}
  end

  defp apply_root_partial(model, %{kind: kind} = partial)
       when kind in [:state, :final, :choice] do
    add_node(model, model.root, partial)
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
       when is_binary(name) and is_function(fun) do
    validate_name!("operation", name)
    %{model | operations: Map.put(model.operations, name, fun)}
  end

  defp apply_root_partial(model, %{kind: :transition, parts: parts, name: id}) do
    {transition, model} = build_transition(model, model.root, parts, id)
    %{model | transitions: model.transitions ++ [transition]}
  end

  defp apply_root_partial(_model, other),
    do: raise(ValidationError, message: "unsupported model partial #{inspect(other)}")

  defp add_node(model, parent_path, %{kind: kind, name: name, parts: parts}) do
    validate_name!(Atom.to_string(kind), name)
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

  defp apply_node_partial(model, path, %{kind: kind} = partial)
       when kind in [:state, :final, :choice, :shallow_history, :deep_history] do
    add_node(model, path, partial)
  end

  defp apply_node_partial(model, path, %{kind: :initial, parts: parts}) do
    {transition, model} = build_transition(model, path, parts, nil, true)
    put_in(model.states[path].initial, %{transition | source: path})
  end

  defp apply_node_partial(model, path, %{kind: :transition, parts: parts, name: id}) do
    bare_relative_to_owner = model.states[path].kind in [:choice, :shallow_history, :deep_history]
    {transition, model} = build_transition(model, path, parts, id, bare_relative_to_owner)
    update_in(model.states[path].transitions, &((&1 || []) ++ [%{transition | owner: path}]))
  end

  defp apply_node_partial(model, path, {:entry, actions}),
    do: update_in(model.states[path].entry, &((&1 || []) ++ actions))

  defp apply_node_partial(model, path, {:exit, actions}),
    do: update_in(model.states[path].exit, &((&1 || []) ++ actions))

  defp apply_node_partial(model, path, {:activity, actions}),
    do: update_in(model.states[path].activity, &((&1 || []) ++ actions))

  defp apply_node_partial(model, path, {:defer, events}) do
    event_names = Enum.map(events, fn event -> event_name(event) end)
    update_in(model.states[path].defer, &((&1 || []) ++ event_names))
  end

  defp apply_node_partial(model, path, part) do
    cond do
      model.states[path].kind in [:choice, :shallow_history, :deep_history] and
          transition_part?(part) ->
        apply_node_partial(model, path, %{kind: :transition, name: nil, parts: [part]})

      true ->
        raise ValidationError, message: "unsupported state partial #{inspect(part)}"
    end
  end

  defp transition_part?({key, _}) when key in [:target, :source, :trigger, :guard], do: true
  defp transition_part?({:effect, _}), do: true
  defp transition_part?(_), do: false

  defp build_transition(model, owner, parts, id),
    do: build_transition(model, owner, parts, id, false)

  defp build_transition(model, owner, parts, id, bare_relative_to_owner) do
    path_owner =
      case model.states[owner] do
        %HSM.Node{kind: kind, parent: parent}
        when kind in [:choice, :shallow_history, :deep_history] ->
          parent

        _ ->
          owner
      end

    transition =
      Enum.reduce(parts, %Transition{id: id, owner: owner}, fn
        {:source, source}, tr ->
          %{tr | source: resolve_path(model, path_owner, source)}

        {:target, target}, tr ->
          %{tr | target: resolve_path(model, path_owner, target, bare_relative_to_owner)}

        {:trigger, trigger}, tr ->
          %{tr | trigger: normalize_trigger(trigger)}

        {:guard, guard}, tr ->
          %{tr | guard: guard}

        {:effect, effects}, tr ->
          %{tr | effects: tr.effects ++ List.wrap(effects)}

        {:kind, kind}, tr when kind in [:external, :internal, :local, :self] ->
          %{tr | kind: kind}

        other, _tr ->
          raise ValidationError, message: "unsupported transition partial #{inspect(other)}"
      end)

    {%{transition | source: transition.source || owner}, model}
  end

  defp normalize_trigger({:on, event}), do: {:on, event_name(event)}

  defp normalize_trigger({kind, value})
       when kind in [:on_set, :on_call, :when, :after, :every, :at], do: {kind, value}

  defp normalize_trigger(other), do: other

  defp validate_model!(model) do
    Enum.each(model.states, fn {_path, node} ->
      if node.kind == :final and node.transitions != [] do
        raise ValidationError,
          message: "final state #{node.path} cannot have outgoing transitions"
      end

      if node.kind == :choice do
        last = List.last(node.transitions)

        if last == nil or last.guard != nil do
          raise ValidationError,
            message: "choice #{node.path} last transition must be guardless fallback"
        end
      end

      if node.kind in [:shallow_history, :deep_history] and node.transitions == [] do
        raise ValidationError, message: "history #{node.path} requires a default transition"
      end
    end)

    all_transitions =
      [model.initial | model.transitions] ++
        Enum.flat_map(model.states, fn {_path, node} -> [node.initial | node.transitions] end)

    Enum.each(Enum.reject(all_transitions, &is_nil/1), fn transition ->
      if transition.target && !Map.has_key?(model.states, transition.target) do
        raise ValidationError, message: "Vertex #{inspect(transition.target)} not found"
      end

      if transition.source && !Map.has_key?(model.states, transition.source) do
        raise ValidationError, message: "Source #{inspect(transition.source)} not found"
      end
    end)

    index_model(model)
  end

  defp index_model(model) do
    model = %{model | active_paths: active_paths(model)}

    %{
      model
      | active_defers: active_defers(model),
        transition_candidates: transition_candidates(model),
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

      {path, defers}
    end)
  end

  defp transition_candidates(model) do
    Map.new(model.states, fn {path, node} ->
      owned =
        if path == model.root,
          do: node.transitions ++ model.transitions,
          else: node.transitions

      parent_owned =
        model.active_paths
        |> Map.fetch!(path)
        |> Enum.drop(1)
        |> Enum.flat_map(fn parent ->
          model.states[parent].transitions
          |> Enum.filter(&(&1.source == path))
        end)

      {path, owned ++ parent_owned}
    end)
  end

  defp timer_transitions(model) do
    Map.new(model.states, fn {path, node} ->
      {path, Enum.filter(node.transitions, &timer_trigger?(&1.trigger))}
    end)
  end

  defp timer_trigger?({kind, _}) when kind in [:after, :every, :at], do: true
  defp timer_trigger?(_trigger), do: false

  defp path_ancestors(path),
    do:
      Stream.iterate(parent(path), &parent/1)
      |> Enum.take_while(&(&1 not in [nil, "", "."]))

  def resolve_path(model, owner, path) when is_binary(path) do
    resolve_path(model, owner, path, false)
  end

  def resolve_path(model, owner, path, bare_relative_to_owner) when is_binary(path) do
    cond do
      String.starts_with?(path, "/") ->
        normalize(path)

      bare_relative_to_owner or path == "." or String.starts_with?(path, "./") or
          String.starts_with?(path, "../") ->
        normalize(join(owner, path))

      true ->
        normalize(join(model.root, path))
    end
  end

  def ancestors(model, path) do
    Stream.iterate(path, &parent/1)
    |> Enum.take_while(&(&1 not in [nil, "", "."]))
    |> Enum.filter(&Map.has_key?(model.states, &1))
  end

  def parent(path) do
    case path |> String.split("/", trim: true) |> Enum.drop(-1) do
      [] -> nil
      parts -> "/" <> Enum.join(parts, "/")
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

  def event_name(%HSM.Event{name: name}), do: name
  def event_name(name) when is_binary(name), do: name

  defp validate_name!(kind, name) when is_binary(name) do
    if name == "" or String.contains?(name, "/") do
      raise ValidationError, message: "#{kind} name cannot contain /"
    end
  end
end
