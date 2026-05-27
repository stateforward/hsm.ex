defmodule HSM do
  import Kernel, except: [exit: 1]

  @moduledoc """
  Native Elixir implementation of the HSM DSL/runtime.

  The public API provides idiomatic snake_case functions and exported canonical
  PascalCase atom functions for cross-language parity. Because Elixir syntax
  reserves uppercase identifiers for aliases, PascalCase exports are intended
  for `apply/3`, for example `apply(HSM, :Define, ["Door", parts])`.
  """

  alias HSM.{Clock, Config, Context, Event, Group, Instance, Kind, Queue}
  alias HSM.DSL

  def define(name, partials \\ []), do: DSL.define(name, List.wrap(partials))
  def state(%Instance{} = instance), do: Instance.state(instance)
  def state(name) when is_binary(name), do: DSL.partial(:state, name, [])

  def state(name, partials) when is_binary(name),
    do: DSL.partial(:state, name, List.wrap(partials))

  def final(name), do: DSL.partial(:final, name, [])
  def choice(name, transitions), do: DSL.partial(:choice, name, List.wrap(transitions))

  def shallow_history(name, partials),
    do: DSL.partial(:shallow_history, name, List.wrap(partials))

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
  def external, do: {:kind, :external}
  def internal, do: {:kind, :internal}
  def local, do: {:kind, :local}
  def self_transition, do: {:kind, :self}
  def entry(actions), do: {:entry, List.wrap(actions)}
  def exit(actions), do: {:exit, List.wrap(actions)}
  def activity(actions), do: {:activity, List.wrap(actions)}
  def defer(events), do: {:defer, List.wrap(events)}
  def attribute(name, default \\ nil)

  def attribute(name, value) do
    if known_type?(value),
      do: {:attribute, name, value, nil},
      else: {:attribute, name, inferred_type(value), value}
  end

  def attribute(name, type, default), do: {:attribute, name, type, default}
  def operation(name, fun), do: {:operation, name, fun}
  def event(name, opts \\ []), do: Event.new(name, opts)
  def completion_event(name \\ "FinalEvent", data \\ nil), do: Event.completion(name, data)
  def event_kind, do: :event
  def time_event_kind, do: :timer_event
  def completion_event_kind, do: :completion_event
  def change_event_kind, do: :set_event
  def call_event_kind, do: :call_event
  def error_event_kind, do: :error_event
  def state_kind, do: :state
  def initial_kind, do: :initial
  def choice_kind, do: :choice
  def shallow_history_kind, do: :shallow_history
  def deep_history_kind, do: :deep_history
  def pseudostate_kind, do: :pseudostate
  def final_state_kind, do: :final
  def transition_kind, do: :transition
  def external_kind, do: :external
  def internal_kind, do: :internal
  def local_kind, do: :local
  def self_kind, do: :self
  def attribute_kind, do: :attribute
  def operation_kind, do: :operation
  def behavior_kind, do: :behavior
  def state_machine_kind, do: :state_machine
  def queue(hooks \\ nil), do: Queue.new(hooks)
  def clock(opts \\ []), do: Clock.new(opts)
  def default_clock, do: Clock.default()

  def new(model, config \\ nil), do: Instance.new(model, config || Config.new())
  def start(instance, data \\ nil), do: Instance.start(instance, data)
  def stop(instance), do: Instance.stop(instance)
  def restart(instance, data \\ nil), do: Instance.restart(instance, data)
  def dispatch(instance, event), do: Instance.dispatch(instance, Event.coerce(event))
  def tick(instance, millis), do: Instance.tick(instance, millis)
  def handle_timer(instance, timer_ref), do: Instance.handle_timer(instance, timer_ref)
  def call(instance, operation, args \\ []), do: Instance.call(instance, operation, args)
  def get(instance, name), do: Instance.get(instance, name)
  def set(instance, name, value), do: Instance.set(instance, name, value)
  def current_state(instance), do: Instance.state(instance)
  def id(%Instance{} = instance), do: instance.id
  def name(%Instance{} = instance), do: instance.name
  def qualified_name(%Instance{} = instance), do: instance.name
  def take_snapshot(instance), do: Instance.snapshot(instance)
  def take_snapshot(_ctx, instance), do: Instance.snapshot(instance)

  def make_group(id_or_first, machines \\ [])
  def make_group(id, machines) when is_binary(id), do: Group.new(id, List.wrap(machines))
  def make_group(first, rest), do: Group.new("", [first | List.wrap(rest)])
  def dispatch_all(%Context{} = ctx, event), do: Context.dispatch_all(ctx, Event.coerce(event))

  def dispatch_to(%Context{} = ctx, event, ids),
    do: Context.dispatch_to(ctx, Event.coerce(event), List.wrap(ids))

  def make_kind(base_kinds \\ []), do: Kind.make(List.wrap(base_kinds))
  def is_kind(kind, base_kinds), do: Kind.is_kind(kind, List.wrap(base_kinds))

  defp inferred_type(value) when is_integer(value), do: :integer
  defp inferred_type(value) when is_float(value), do: :float
  defp inferred_type(value) when is_boolean(value), do: :boolean
  defp inferred_type(value) when is_binary(value), do: :binary
  defp inferred_type(value) when is_atom(value), do: :atom
  defp inferred_type(value) when is_list(value), do: :list
  defp inferred_type(value) when is_map(value), do: :map
  defp inferred_type(_value), do: :any

  defp known_type?(type)
       when type in [
              :any,
              :integer,
              :float,
              :number,
              :boolean,
              :binary,
              :string,
              :atom,
              :list,
              :map
            ],
       do: true

  defp known_type?(_type), do: false

  for name <- [:Define],
      do: def(unquote(name)(model_name, partials \\ []), do: define(model_name, partials))

  for name <- [:State],
      do: def(unquote(name)(state_name, partials \\ []), do: state(state_name, partials))

  for name <- [:Final], do: def(unquote(name)(state_name), do: final(state_name))

  for name <- [:Choice],
      do: def(unquote(name)(state_name, transitions), do: choice(state_name, transitions))

  for name <- [:ShallowHistory],
      do: def(unquote(name)(state_name, partials), do: shallow_history(state_name, partials))

  for name <- [:DeepHistory],
      do: def(unquote(name)(state_name, partials), do: deep_history(state_name, partials))

  for name <- [:Initial], do: def(unquote(name)(partials), do: initial(partials))
  for name <- [:Transition], do: def(unquote(name)(partials), do: transition(partials))

  for name <- [:Transition],
      do: def(unquote(name)(transition_name, partials), do: transition(transition_name, partials))

  for name <- [:Source], do: def(unquote(name)(path), do: source(path))
  for name <- [:Target], do: def(unquote(name)(path), do: target(path))
  for name <- [:On], do: def(unquote(name)(event), do: on(event))
  for name <- [:OnSet], do: def(unquote(name)(attr_name), do: on_set(attr_name))

  for name <- [:When],
      do: def(unquote(name)(attr_name) when is_binary(attr_name), do: when_attr(attr_name))

  for name <- [:When], do: def(unquote(name)(fun) when is_function(fun), do: when_expr(fun))
  for name <- [:OnCall], do: def(unquote(name)(op_name), do: on_call(op_name))
  for name <- [:After], do: def(unquote(name)(ms), do: after_ms(ms))
  for name <- [:Every], do: def(unquote(name)(ms), do: every_ms(ms))
  for name <- [:At], do: def(unquote(name)(ms), do: at_ms(ms))
  for name <- [:Guard], do: def(unquote(name)(fun_or_name), do: guard(fun_or_name))
  for name <- [:Effect], do: def(unquote(name)(actions), do: effect(actions))
  for name <- [:External], do: def(unquote(name)(), do: external())
  for name <- [:Internal], do: def(unquote(name)(), do: internal())
  for name <- [:Local], do: def(unquote(name)(), do: local())
  for name <- [:Self], do: def(unquote(name)(), do: self_transition())
  for name <- [:Entry], do: def(unquote(name)(actions), do: entry(actions))
  for name <- [:Exit], do: def(unquote(name)(actions), do: exit(actions))
  for name <- [:Activity], do: def(unquote(name)(actions), do: activity(actions))
  for name <- [:Defer], do: def(unquote(name)(events), do: defer(events))

  for name <- [:Attribute],
      do: def(unquote(name)(attr_name, default \\ nil), do: attribute(attr_name, default))

  for name <- [:Attribute],
      do:
        def(unquote(name)(attr_name, attr_type, default),
          do: attribute(attr_name, attr_type, default)
        )

  for name <- [:Operation], do: def(unquote(name)(op_name, fun), do: operation(op_name, fun))

  for name <- [:Event],
      do: def(unquote(name)(event_name, opts \\ []), do: event(event_name, opts))

  for name <- [:CompletionEvent],
      do:
        def(unquote(name)(event_name \\ "FinalEvent", data \\ nil),
          do: completion_event(event_name, data)
        )

  for name <- [:EventKind], do: def(unquote(name)(), do: event_kind())
  for name <- [:TimeEventKind], do: def(unquote(name)(), do: time_event_kind())
  for name <- [:CompletionEventKind], do: def(unquote(name)(), do: completion_event_kind())
  for name <- [:ChangeEventKind], do: def(unquote(name)(), do: change_event_kind())
  for name <- [:CallEventKind], do: def(unquote(name)(), do: call_event_kind())
  for name <- [:ErrorEventKind], do: def(unquote(name)(), do: error_event_kind())
  for name <- [:StateKind], do: def(unquote(name)(), do: state_kind())
  for name <- [:InitialKind], do: def(unquote(name)(), do: initial_kind())
  for name <- [:ChoiceKind], do: def(unquote(name)(), do: choice_kind())
  for name <- [:ShallowHistoryKind], do: def(unquote(name)(), do: shallow_history_kind())
  for name <- [:DeepHistoryKind], do: def(unquote(name)(), do: deep_history_kind())
  for name <- [:PseudostateKind], do: def(unquote(name)(), do: pseudostate_kind())
  for name <- [:FinalStateKind], do: def(unquote(name)(), do: final_state_kind())
  for name <- [:TransitionKind], do: def(unquote(name)(), do: transition_kind())
  for name <- [:ExternalKind], do: def(unquote(name)(), do: external_kind())
  for name <- [:InternalKind], do: def(unquote(name)(), do: internal_kind())
  for name <- [:LocalKind], do: def(unquote(name)(), do: local_kind())
  for name <- [:SelfKind], do: def(unquote(name)(), do: self_kind())
  for name <- [:AttributeKind], do: def(unquote(name)(), do: attribute_kind())
  for name <- [:OperationKind], do: def(unquote(name)(), do: operation_kind())
  for name <- [:BehaviorKind], do: def(unquote(name)(), do: behavior_kind())
  for name <- [:StateMachineKind], do: def(unquote(name)(), do: state_machine_kind())
  for name <- [:Queue], do: def(unquote(name)(hooks \\ nil), do: queue(hooks))
  for name <- [:Clock], do: def(unquote(name)(opts \\ []), do: clock(opts))
  for name <- [:DefaultClock], do: def(unquote(name)(), do: default_clock())
  for name <- [:Config], do: def(unquote(name)(opts \\ []), do: Config.new(opts))
  for name <- [:New], do: def(unquote(name)(model, config \\ nil), do: new(model, config))
  for name <- [:Start], do: def(unquote(name)(instance, data \\ nil), do: start(instance, data))
  for name <- [:Stop], do: def(unquote(name)(instance), do: stop(instance))

  for name <- [:Restart],
      do: def(unquote(name)(instance, data \\ nil), do: restart(instance, data))

  for name <- [:Dispatch],
      do: def(unquote(name)(instance, event), do: dispatch(instance, event) |> elem(0))

  for name <- [:Tick], do: def(unquote(name)(instance, millis), do: tick(instance, millis))

  for name <- [:HandleTimer],
      do: def(unquote(name)(instance, timer_ref), do: handle_timer(instance, timer_ref))

  for name <- [:Call],
      do: def(unquote(name)(instance, operation, args \\ []), do: call(instance, operation, args))

  for name <- [:Get], do: def(unquote(name)(instance, attr_name), do: get(instance, attr_name))

  for name <- [:Set],
      do: def(unquote(name)(instance, attr_name, value), do: set(instance, attr_name, value))

  for name <- [:ID], do: def(unquote(name)(instance), do: id(instance))
  for name <- [:Name], do: def(unquote(name)(instance), do: name(instance))

  for name <- [:QualifiedName],
      do: def(unquote(name)(instance), do: qualified_name(instance))

  for name <- [:MakeGroup],
      do: def(unquote(name)(id_or_first, machines \\ []), do: make_group(id_or_first, machines))

  for name <- [:DispatchAll], do: def(unquote(name)(ctx, event), do: dispatch_all(ctx, event))

  for name <- [:DispatchTo],
      do: def(unquote(name)(ctx, event, ids), do: dispatch_to(ctx, event, ids))

  for name <- [:TakeSnapshot],
      do: def(unquote(name)(ctx, instance), do: take_snapshot(ctx, instance))

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
      {"ID", value} -> {:id, value}
      {"Name", value} -> {:name, value}
      {"Data", value} -> {:data, value}
      {"Clock", value} -> {:clock, value}
      {"Queue", value} -> {:queue, value}
      {"id", value} -> {:id, value}
      {"name", value} -> {:name, value}
      {"data", value} -> {:data, value}
      {"clock", value} -> {:clock, value}
      {"queue", value} -> {:queue, value}
      pair -> pair
    end)
  end
end

defmodule HSM.Event do
  @moduledoc false
  defstruct name: "",
            data: nil,
            kind: :event,
            id: "",
            source: "",
            target: "",
            qualified_name: "",
            schema: nil

  def new(name, opts \\ []) when is_binary(name) do
    opts = if is_map(opts), do: Map.to_list(opts), else: opts
    struct(__MODULE__, Keyword.merge([name: name], normalize_keys(opts)))
  end

  def coerce(%__MODULE__{} = event), do: %{event | schema: clone(event.schema)}
  def coerce(name) when is_binary(name), do: %__MODULE__{name: name}
  def coerce(%{name: name} = map), do: struct(__MODULE__, Map.put(map, :name, name))

  def completion(name \\ "FinalEvent", data \\ nil),
    do: %__MODULE__{name: name, data: data, kind: :completion_event}

  def call(name, args), do: %__MODULE__{name: "@call:" <> name, data: args, kind: :call_event}

  def set(name, value),
    do: %__MODULE__{name: "@set:" <> name, data: %{name: name, value: value}, kind: :set_event}

  defp normalize_keys(opts) do
    Enum.map(opts, fn
      {:Name, value} -> {:name, value}
      {:Data, value} -> {:data, value}
      {:Kind, value} -> {:kind, value}
      {:ID, value} -> {:id, value}
      {:Source, value} -> {:source, value}
      {:Target, value} -> {:target, value}
      {:QualifiedName, value} -> {:qualified_name, value}
      {:Schema, value} -> {:schema, value}
      {"Name", value} -> {:name, value}
      {"Data", value} -> {:data, value}
      {"Kind", value} -> {:kind, value}
      {"ID", value} -> {:id, value}
      {"Source", value} -> {:source, value}
      {"Target", value} -> {:target, value}
      {"QualifiedName", value} -> {:qualified_name, value}
      {"Schema", value} -> {:schema, value}
      {"name", value} -> {:name, value}
      {"data", value} -> {:data, value}
      {"kind", value} -> {:kind, value}
      {"id", value} -> {:id, value}
      {"source", value} -> {:source, value}
      {"target", value} -> {:target, value}
      {"qualified_name", value} -> {:qualified_name, value}
      {"schema", value} -> {:schema, value}
      {key, value} when is_atom(key) -> {key, value}
      {_key, _value} -> nil
    end)
    |> Enum.reject(&is_nil/1)
  end

  defp clone(value), do: :erlang.binary_to_term(:erlang.term_to_binary(value))
end

defmodule HSM.Model do
  @moduledoc false
  defstruct name: "",
            path: "",
            states: %{},
            root: nil,
            attributes: %{},
            attribute_types: %{},
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

defmodule HSM.ActivityHandle do
  @moduledoc false
  defstruct path: nil, cancel: nil, metadata: nil
end

defmodule HSM.Snapshot do
  @moduledoc false
  defstruct ID: "", QualifiedName: "", State: "", Attributes: %{}, QueueLen: 0, Events: []
end

defmodule HSM.Queue do
  @moduledoc false
  alias HSM.{Event, ValidationError}

  defstruct regular: [], completion: [], hooks: nil

  def new(nil), do: %__MODULE__{}
  def new(%__MODULE__{} = queue), do: queue

  def new(hooks) when is_map(hooks) or is_list(hooks) do
    hooks = normalize_hooks(hooks)

    unless hooks.push && hooks.pop && hooks.len do
      raise ValidationError,
        message: "Queue requires complete Push/Pop/Len or push/pop/len hooks"
    end

    %__MODULE__{hooks: hooks}
  end

  def push(queue, event, context \\ nil)

  def push(%__MODULE__{} = queue, event, context) do
    event = Event.coerce(event)

    cond do
      priority_event?(event) ->
        {%{queue | completion: [event | queue.completion]}, nil}

      queue.hooks ->
        case invoke_push_hook(queue.hooks.push, context, event) do
          nil -> {queue, nil}
          :ok -> {queue, nil}
          {:ok, _} -> {queue, nil}
          error -> {queue, error}
        end

      true ->
        {%{queue | regular: queue.regular ++ [event]}, nil}
    end
  end

  def pop(queue, context \\ nil)

  def pop(%__MODULE__{completion: [event | rest]} = queue, _context),
    do: {%{queue | completion: rest}, event}

  def pop(%__MODULE__{hooks: hooks} = queue, context) when not is_nil(hooks) do
    case invoke_hook(hooks.pop, [context], "Pop/pop") do
      nil -> {queue, nil}
      %ValidationError{} = error -> {queue, error}
      %_{} = event -> {queue, Event.coerce(event)}
      event when is_binary(event) or is_map(event) -> {queue, Event.coerce(event)}
      error -> {queue, error}
    end
  end

  def pop(%__MODULE__{regular: [event | rest]} = queue, _context),
    do: {%{queue | regular: rest}, event}

  def pop(%__MODULE__{} = queue, _context), do: {queue, nil}

  def len(queue, context \\ nil)

  def len(%__MODULE__{hooks: hooks, completion: completion}, context) when not is_nil(hooks) do
    case invoke_hook(hooks.len, [context], "Len/len") do
      count when is_integer(count) and count >= 0 -> length(completion) + count
      error -> error
    end
  end

  def len(%__MODULE__{regular: regular, completion: completion}, _context),
    do: length(regular) + length(completion)

  def empty?(%__MODULE__{} = queue, context \\ nil), do: len(queue, context) == 0

  def events(%__MODULE__{regular: regular, completion: completion}),
    do: Enum.reverse(completion) ++ regular

  defp normalize_hooks(hooks) do
    source = if is_list(hooks), do: Map.new(hooks), else: hooks

    %{
      push:
        Map.get(source, :Push) || Map.get(source, "Push") || Map.get(source, :push) ||
          Map.get(source, "push"),
      pop:
        Map.get(source, :Pop) || Map.get(source, "Pop") || Map.get(source, :pop) ||
          Map.get(source, "pop"),
      len:
        Map.get(source, :Len) || Map.get(source, "Len") || Map.get(source, :len) ||
          Map.get(source, "len")
    }
  end

  defp invoke_push_hook(fun, context, event) when is_function(fun) do
    args =
      case :erlang.fun_info(fun, :arity) do
        {:arity, 2} -> [context, event]
        {:arity, 1} -> [event]
        {:arity, 0} -> []
      end

    invoke_hook_args(fun, args, "Push/push")
  end

  defp invoke_hook(fun, args, label) when is_function(fun) do
    args =
      case :erlang.fun_info(fun, :arity) do
        {:arity, 2} -> args
        {:arity, 1} -> Enum.take(args, 1)
        {:arity, 0} -> []
      end

    invoke_hook_args(fun, args, label)
  end

  defp invoke_hook_args(fun, args, label) do
    result = apply(fun, args)

    if awaitable?(result) do
      %ValidationError{message: "Queue #{label} must be synchronous"}
    else
      result
    end
  end

  defp priority_event?(%Event{kind: kind})
       when kind in [:completion_event, :initial_event, :timer_event, :error_event],
       do: true

  defp priority_event?(_event), do: false
  defp awaitable?(%Task{}), do: true
  defp awaitable?(_), do: false
end

defmodule HSM.Clock do
  @moduledoc false
  defstruct sleep: nil, after: nil, new_timer: nil, now: nil

  def default, do: %__MODULE__{new_timer: &default_new_timer/2, now: &System.monotonic_time/1}
  def new(nil), do: default()
  def new(%__MODULE__{} = clock), do: inherit_default(clock)

  def new(opts) when is_list(opts) or is_map(opts) do
    source = if is_list(opts), do: Map.new(opts), else: opts

    %__MODULE__{
      sleep:
        Map.get(source, :Sleep) || Map.get(source, "Sleep") || Map.get(source, :sleep) ||
          Map.get(source, "sleep"),
      after:
        Map.get(source, :After) || Map.get(source, "After") || Map.get(source, :after) ||
          Map.get(source, "after"),
      new_timer:
        Map.get(source, :NewTimer) || Map.get(source, "NewTimer") ||
          Map.get(source, :new_timer) || Map.get(source, "new_timer"),
      now:
        Map.get(source, :Now) || Map.get(source, "Now") || Map.get(source, :now) ||
          Map.get(source, "now")
    }
    |> inherit_default()
  end

  def wait(%__MODULE__{} = clock, duration, context \\ nil) do
    fun = clock.after || clock.sleep

    if is_function(fun) do
      invoke(fun, [context, duration])
    else
      {:ok, duration}
    end
  end

  def new_timer(%__MODULE__{} = clock, duration, message) do
    cond do
      is_function(clock.new_timer, 3) ->
        clock.new_timer.(duration, message, self())

      is_function(clock.new_timer, 2) ->
        clock.new_timer.(duration, message)

      is_function(clock.new_timer, 1) ->
        clock.new_timer.(duration)

      true ->
        default_new_timer(duration, message)
    end
  end

  def cancel_timer({:hsm_timer, ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  def cancel_timer(%{cancel: cancel}) when is_function(cancel, 0), do: cancel.()
  def cancel_timer(%{ref: ref}) when is_reference(ref), do: Process.cancel_timer(ref)
  def cancel_timer(ref) when is_reference(ref), do: Process.cancel_timer(ref)
  def cancel_timer(_handle), do: false

  def now(clock, unit \\ :millisecond)

  def now(%__MODULE__{now: fun}, unit) when is_function(fun, 1), do: fun.(unit)
  def now(%__MODULE__{now: fun}, _unit) when is_function(fun, 0), do: fun.()
  def now(_clock, unit), do: System.monotonic_time(unit)

  defp inherit_default(clock) do
    default = default()

    %{
      clock
      | now: clock.now || default.now
    }
  end

  defp invoke(fun, args) do
    case :erlang.fun_info(fun, :arity) do
      {:arity, 2} -> fun.(Enum.at(args, 0), Enum.at(args, 1))
      {:arity, 1} -> fun.(Enum.at(args, 1))
      {:arity, 0} -> fun.()
    end
  end

  defp default_new_timer(duration, message) when is_integer(duration) and duration >= 0 do
    {:hsm_timer, Process.send_after(self(), message, duration)}
  end

  defp default_new_timer(_duration, _message), do: nil
end
