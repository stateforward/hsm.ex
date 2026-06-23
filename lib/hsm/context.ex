defmodule HSM.Context do
  @moduledoc false
  defstruct hsm: nil, owner: nil, machines: %{}

  def new, do: %__MODULE__{}

  def register(%__MODULE__{} = ctx, instance),
    do: extend(%{ctx | machines: Map.put(ctx.machines, instance.id, instance)}, instance)

  def extend(%__MODULE__{} = ctx, hsm) do
    id = hsm_id(hsm)
    machines = if id, do: Map.put(ctx.machines, id, hsm), else: ctx.machines
    %{ctx | hsm: hsm, owner: ctx.hsm, machines: machines}
  end

  def extend_current(%__MODULE__{} = ctx, hsm) do
    if same_hsm?(ctx.hsm, hsm) do
      id = hsm_id(hsm)
      machines = if id, do: Map.put(ctx.machines, id, hsm), else: ctx.machines
      %{ctx | hsm: hsm, machines: machines}
    else
      extend(ctx, hsm)
    end
  end

  def from_context(%__MODULE__{hsm: nil}), do: {nil, false}
  def from_context(%__MODULE__{hsm: hsm}), do: {hsm, true}
  def instances_from_context(%__MODULE__{machines: machines}), do: {machines, true}

  def event_for(%__MODULE__{} = ctx, event, target) do
    event_for_target(ctx, event, hsm_id(target))
  end

  def dispatch_all(%__MODULE__{} = ctx, event) do
    machines =
      Map.new(ctx.machines, fn {id, machine} ->
        if active_hsm?(machine),
          do: {id, HSM.dispatch(ctx, machine, event)},
          else: {id, machine}
      end)

    refresh_current(ctx, machines)
  end

  def dispatch_to(%__MODULE__{} = ctx, event, ids) do
    ids = MapSet.new(ids)

    machines =
      Map.new(ctx.machines, fn {id, machine} ->
        if MapSet.member?(ids, id) and active_hsm?(machine) do
          {id, HSM.dispatch(ctx, machine, event)}
        else
          {id, machine}
        end
      end)

    refresh_current(ctx, machines)
  end

  defp event_for_target(%__MODULE__{} = ctx, %{__struct__: HSM.Event} = event, id) do
    event
    |> put_target(id)
    |> put_source(hsm_id(ctx.hsm))
  end

  defp put_target(%{target: target} = event, id) when target in ["", nil],
    do: %{event | target: id}

  defp put_target(event, _id), do: event
  defp put_source(event, nil), do: event

  defp put_source(%{source: source} = event, id) when source in ["", nil],
    do: %{event | source: id}

  defp put_source(event, _id), do: event

  defp hsm_id(nil), do: nil
  defp hsm_id(%{id: id}) when id not in [nil, ""], do: id
  defp hsm_id(%{name: name}) when name not in [nil, ""], do: name
  defp hsm_id(_hsm), do: nil

  defp refresh_current(%__MODULE__{} = ctx, machines) do
    %{
      ctx
      | hsm: refreshed_hsm(ctx.hsm, machines),
        owner: refreshed_hsm(ctx.owner, machines),
        machines: machines
    }
  end

  defp refreshed_hsm(nil, _machines), do: nil

  defp refreshed_hsm(hsm, machines) do
    id = hsm_id(hsm)

    if id && Map.has_key?(machines, id),
      do: Map.fetch!(machines, id),
      else: hsm
  end

  defp same_hsm?(%{id: left}, %{id: right}) when left != nil and left != "" and left == right,
    do: true

  defp same_hsm?(left, right), do: left == right

  defp active_hsm?(%{started?: true}), do: true
  defp active_hsm?(_hsm), do: false
end

defmodule HSM.Keys do
  @moduledoc false
  for name <- [:HSM], do: def(unquote(name)(), do: :hsm)
  for name <- [:Owner], do: def(unquote(name)(), do: :owner)
  for name <- [:Instances], do: def(unquote(name)(), do: :instances)
  def hsm, do: :hsm
  def owner, do: :owner
  def instances, do: :instances
end

defmodule HSM.Group do
  @moduledoc false
  defstruct id: "", machines: []

  def new(id, machines), do: %__MODULE__{id: id, machines: flatten(List.wrap(machines))}

  def state(%__MODULE__{} = group), do: Enum.map(group.machines, &HSM.Instance.state/1)

  def start(%__MODULE__{} = group) do
    %{group | machines: Enum.map(group.machines, &HSM.Instance.start/1)}
  end

  def start(%__MODULE__{} = group, data) do
    %{group | machines: Enum.map(group.machines, &HSM.Instance.start(&1, data))}
  end

  def stop(%__MODULE__{} = group) do
    %{group | machines: Enum.map(group.machines, &HSM.Instance.stop/1)}
  end

  def restart(%__MODULE__{} = group) do
    %{group | machines: Enum.map(group.machines, &HSM.Instance.restart/1)}
  end

  def restart(%__MODULE__{} = group, data) do
    %{group | machines: Enum.map(group.machines, &HSM.Instance.restart(&1, data))}
  end

  def dispatch(%__MODULE__{} = group, event) do
    %{
      group
      | machines:
          Enum.map(group.machines, fn machine ->
            if machine.started?,
              do: elem(HSM.Instance.dispatch(machine, event_for_target(event, machine.id)), 0),
              else: machine
          end)
    }
  end

  def snapshot(%__MODULE__{} = group) do
    Enum.map(group.machines, &HSM.Instance.snapshot/1)
  end

  defp flatten(members) do
    Enum.flat_map(members, fn
      %__MODULE__{} = group -> group.machines
      member when is_list(member) -> flatten(member)
      nil -> []
      member -> [member]
    end)
  end

  defp event_for_target(%{__struct__: HSM.Event, target: target} = event, id)
       when target in ["", nil],
       do: %{event | target: id}

  defp event_for_target(event, _id), do: event
end
