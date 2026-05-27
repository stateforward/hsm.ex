defmodule HSM do
  @moduledoc """
  Native Elixir implementation of the HSM DSL/runtime.

  The public API provides idiomatic snake_case functions and exported canonical
  PascalCase atom functions for cross-language parity. Because Elixir syntax
  reserves uppercase identifiers for aliases, PascalCase exports are intended
  for `apply/3`, for example `apply(HSM, :Define, ["Door", parts])`.
  """

  alias HSM.{Config, Context, Event, Group, Instance, Kind, Model, Snapshot}
  alias HSM.DSL

  def define(name, partials \\ []), do: DSL.define(name, List.wrap(partials))
  def state(%Instance{} = instance), do: Instance.state(instance)
  def state(name) when is_binary(name), do: DSL.partial(:state, name, [])
  def state(name, partials) when is_binary(name), do: DSL.partial(:state, name, List.wrap(partials))
  def final(name), do: DSL.partial(:final, name, [])
  def choice(name, transitions), do: DSL.partial(:choice, name, List.wrap(transitions))
  def shallow_history(name, partials), do: DSL.partial(:shallow_history, name, List.wrap(partials))
  def deep_history(name, partials), do: DSL.partial(:deep_history, name, List.wrap(partials))
  def initial(partials), do: DSL.partial(:initial, nil, List.wrap(partials))
  def transition(partials), do: DSL.partial(:transition, nil, List.wrap(partials))
  def transition(name, partials), do: DSL.partial(:transition, name, List.wrap(partials))
  def source(path), do: {:source, path}
  def target(path), do: {:target, path}
  def on(event), do: {:trigger, {:on, event}}
  def on_set(name), do: {:trigger, {:on_set, name}}
  def when_attr(name) when is_binary(name), do: on_set(name)
  def when_expr(fun) when is_function(fun), do: {:trigger, {:when, fun}}
  def on_call(name), do: {:trigger, {:on_call, name}}
  def after_ms(ms), do: {:trigger, {:after, ms}}
  def every_ms(ms), do: {:trigger, {:every, ms}}
  def at_ms(ms), do: {:trigger, {:at, ms}}
  def guard(fun_or_name), do: {:guard, fun_or_name}
  def effect(actions), do: {:effect, List.wrap(actions)}
  def entry(actions), do: {:entry, List.wrap(actions)}
  def exit(actions), do: {:exit, List.wrap(actions)}
  def activity(actions), do: {:activity, List.wrap(actions)}
  def defer(events), do: {:defer, List.wrap(events)}
  def attribute(name, default \\ nil), do: {:attribute, name, default}
  def operation(name, fun), do: {:operation, name, fun}

  def new(model, config \\ nil), do: Instance.new(model, config || Config.new())
  def start(instance, data \\ nil), do: Instance.start(instance, data)
  def stop(instance), do: Instance.stop(instance)
  def restart(instance, data \\ nil), do: Instance.restart(instance, data)
  def dispatch(instance, event), do: Instance.dispatch(instance, Event.coerce(event))
  def call(instance, operation, args \\ []), do: Instance.call(instance, operation, args)
  def get(instance, name), do: Instance.get(instance, name)
  def set(instance, name, value), do: Instance.set(instance, name, value)
  def current_state(instance), do: Instance.state(instance)
  def take_snapshot(instance), do: Instance.snapshot(instance)
  def take_snapshot(_ctx, instance), do: Instance.snapshot(instance)

  def make_group(id_or_first, machines \\ [])
  def make_group(id, machines) when is_binary(id), do: Group.new(id, List.wrap(machines))
  def make_group(first, rest), do: Group.new("", [first | List.wrap(rest)])
  def dispatch_all(%Context{} = ctx, event), do: Context.dispatch_all(ctx, Event.coerce(event))
  def dispatch_to(%Context{} = ctx, event, ids), do: Context.dispatch_to(ctx, Event.coerce(event), List.wrap(ids))

  def make_kind(base_kinds \\ []), do: Kind.make(List.wrap(base_kinds))
  def is_kind(kind, base_kinds), do: Kind.is_kind(kind, List.wrap(base_kinds))

  for name <- [:Define], do: def(unquote(name)(model_name, partials \\ []), do: define(model_name, partials))
  for name <- [:State], do: def(unquote(name)(state_name, partials \\ []), do: state(state_name, partials))
  for name <- [:Final], do: def(unquote(name)(state_name), do: final(state_name))
  for name <- [:Choice], do: def(unquote(name)(state_name, transitions), do: choice(state_name, transitions))
  for name <- [:ShallowHistory], do: def(unquote(name)(state_name, partials), do: shallow_history(state_name, partials))
  for name <- [:DeepHistory], do: def(unquote(name)(state_name, partials), do: deep_history(state_name, partials))
  for name <- [:Initial], do: def(unquote(name)(partials), do: initial(partials))
  for name <- [:Transition], do: def(unquote(name)(partials), do: transition(partials))
  for name <- [:Transition], do: def(unquote(name)(transition_name, partials), do: transition(transition_name, partials))
  for name <- [:Source], do: def(unquote(name)(path), do: source(path))
  for name <- [:Target], do: def(unquote(name)(path), do: target(path))
  for name <- [:On], do: def(unquote(name)(event), do: on(event))
  for name <- [:OnSet], do: def(unquote(name)(attr_name), do: on_set(attr_name))
  for name <- [:When], do: def(unquote(name)(attr_name) when is_binary(attr_name), do: when_attr(attr_name))
  for name <- [:When], do: def(unquote(name)(fun) when is_function(fun), do: when_expr(fun))
  for name <- [:OnCall], do: def(unquote(name)(op_name), do: on_call(op_name))
  for name <- [:After], do: def(unquote(name)(ms), do: after_ms(ms))
  for name <- [:Every], do: def(unquote(name)(ms), do: every_ms(ms))
  for name <- [:At], do: def(unquote(name)(ms), do: at_ms(ms))
  for name <- [:Guard], do: def(unquote(name)(fun_or_name), do: guard(fun_or_name))
  for name <- [:Effect], do: def(unquote(name)(actions), do: effect(actions))
  for name <- [:Entry], do: def(unquote(name)(actions), do: entry(actions))
  for name <- [:Exit], do: def(unquote(name)(actions), do: exit(actions))
  for name <- [:Activity], do: def(unquote(name)(actions), do: activity(actions))
  for name <- [:Defer], do: def(unquote(name)(events), do: defer(events))
  for name <- [:Attribute], do: def(unquote(name)(attr_name, default \\ nil), do: attribute(attr_name, default))
  for name <- [:Operation], do: def(unquote(name)(op_name, fun), do: operation(op_name, fun))
  for name <- [:Config], do: def(unquote(name)(opts \\ []), do: Config.new(opts))
  for name <- [:New], do: def(unquote(name)(model, config \\ nil), do: new(model, config))
  for name <- [:Start], do: def(unquote(name)(instance, data \\ nil), do: start(instance, data))
  for name <- [:Stop], do: def(unquote(name)(instance), do: stop(instance))
  for name <- [:Restart], do: def(unquote(name)(instance, data \\ nil), do: restart(instance, data))
  for name <- [:Dispatch], do: def(unquote(name)(instance, event), do: dispatch(instance, event))
  for name <- [:Call], do: def(unquote(name)(instance, operation, args \\ []), do: call(instance, operation, args))
  for name <- [:Get], do: def(unquote(name)(instance, attr_name), do: get(instance, attr_name))
  for name <- [:Set], do: def(unquote(name)(instance, attr_name, value), do: set(instance, attr_name, value))
  for name <- [:MakeGroup], do: def(unquote(name)(id_or_first, machines \\ []), do: make_group(id_or_first, machines))
  for name <- [:DispatchAll], do: def(unquote(name)(ctx, event), do: dispatch_all(ctx, event))
  for name <- [:DispatchTo], do: def(unquote(name)(ctx, event, ids), do: dispatch_to(ctx, event, ids))
  for name <- [:TakeSnapshot], do: def(unquote(name)(ctx, instance), do: take_snapshot(ctx, instance))
  for name <- [:MakeKind], do: def(unquote(name)(bases \\ []), do: make_kind(bases))
  for name <- [:IsKind], do: def(unquote(name)(kind, bases), do: is_kind(kind, bases))

  defmodule ValidationError do
    defexception [:message]
  end
end

defmodule HSM.Config do
  @moduledoc false
  defstruct id: "", name: "", data: nil, clock: nil, queue: nil
  def new(opts \\ []), do: struct(__MODULE__, normalize_keys(opts))

  defp normalize_keys(opts) do
    Enum.map(opts, fn
      {:ID, value} -> {:id, value}
      {:Name, value} -> {:name, value}
      {:Data, value} -> {:data, value}
      {:Clock, value} -> {:clock, value}
      {:Queue, value} -> {:queue, value}
      pair -> pair
    end)
  end
end

defmodule HSM.Event do
  @moduledoc false
  defstruct name: "", data: nil, kind: :event, id: "", source: "", target: "", qualified_name: "", schema: nil

  def coerce(%__MODULE__{} = event), do: %{event | schema: clone(event.schema)}
  def coerce(name) when is_binary(name), do: %__MODULE__{name: name}
  def coerce(%{name: name} = map), do: struct(__MODULE__, Map.put(map, :name, name))
  def completion, do: %__MODULE__{name: "FinalEvent", kind: :completion_event}
  def call(name, args), do: %__MODULE__{name: "@call:" <> name, data: args, kind: :call_event}
  def set(name, value), do: %__MODULE__{name: "@set:" <> name, data: %{name: name, value: value}, kind: :set_event}

  defp clone(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))
end

defmodule HSM.Model do
  @moduledoc false
  defstruct name: "",
            path: "",
            states: %{},
            root: nil,
            attributes: %{},
            operations: %{},
            transitions: [],
            initial: nil
end

defmodule HSM.Node do
  @moduledoc false
  defstruct name: "",
            path: "",
            kind: :state,
            parent: nil,
            children: [],
            initial: nil,
            transitions: [],
            entry: [],
            exit: [],
            activity: [],
            defer: []
end

defmodule HSM.Transition do
  @moduledoc false
  defstruct id: nil,
            owner: nil,
            source: nil,
            target: nil,
            trigger: nil,
            guard: nil,
            effects: [],
            kind: :external
end

defmodule HSM.Snapshot do
  @moduledoc false
  defstruct ID: "", QualifiedName: "", State: "", Attributes: %{}, QueueLen: 0, Events: []
end
