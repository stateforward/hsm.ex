defmodule HSM.Context do
  @moduledoc false
  defstruct machines: %{}

  def register(%__MODULE__{} = ctx, instance),
    do: %{ctx | machines: Map.put(ctx.machines, instance.id, instance)}

  def dispatch_all(%__MODULE__{} = ctx, event) do
    Enum.reduce(ctx.machines, ctx, fn {_id, machine}, acc ->
      {_machine, _result} = HSM.Instance.dispatch(machine, event)
      acc
    end)
  end

  def dispatch_to(%__MODULE__{} = ctx, event, ids) do
    ids = MapSet.new(ids)

    Enum.reduce(ctx.machines, ctx, fn {id, machine}, acc ->
      if MapSet.member?(ids, id) do
        {_machine, _result} = HSM.Instance.dispatch(machine, event)
        acc
      else
        acc
      end
    end)
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
