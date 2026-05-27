defmodule HSM.Context do
  @moduledoc false
  defstruct machines: %{}

  def register(%__MODULE__{} = ctx, instance),
    do: %{ctx | machines: Map.put(ctx.machines, instance.id, instance)}

  def dispatch_all(%__MODULE__{} = ctx, event) do
    machines =
      Map.new(ctx.machines, fn {id, machine} ->
        {updated, _result} = HSM.Instance.dispatch(machine, event)
        {id, updated}
      end)

    %{ctx | machines: machines}
  end

  def dispatch_to(%__MODULE__{} = ctx, event, ids) do
    ids = MapSet.new(ids)

    machines =
      Map.new(ctx.machines, fn {id, machine} ->
        if MapSet.member?(ids, id) do
          {updated, _result} = HSM.Instance.dispatch(machine, event)
          {id, updated}
        else
          {id, machine}
        end
      end)

    %{ctx | machines: machines}
  end
end

defmodule HSM.Group do
  @moduledoc false
  defstruct id: "", machines: []

  def new(id, machines), do: %__MODULE__{id: id, machines: machines}

  def dispatch(%__MODULE__{} = group, event) do
    %{
      group
      | machines:
          Enum.map(group.machines, fn machine ->
            elem(HSM.Instance.dispatch(machine, event), 0)
          end)
    }
  end

  def snapshot(%__MODULE__{} = group) do
    %{members: Map.new(group.machines, &{&1.id, &1.state})}
  end
end
