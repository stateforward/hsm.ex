defmodule HSM.Kind do
  @moduledoc false
  use Agent
  import Bitwise

  @id_length 16
  @id_mask (1 <<< @id_length) - 1
  @counter_start 100

  def make(base_kinds \\ []) do
    ensure_started()
    id = Agent.get_and_update(__MODULE__, &{&1, &1 + 1})
    if id > @id_mask, do: raise(ArgumentError, message: "kind id space exhausted")
    pack_bases(id, List.wrap(base_kinds))
  end

  def is_kind(kind, bases) do
    Enum.any?(List.wrap(bases), fn base ->
      kind == base or inherited?(kind, base)
    end)
  end

  defp inherited?(kind, base) when is_atom(kind) and is_atom(base) do
    kind
    |> atom_bases()
    |> Enum.any?(&(&1 == base or inherited?(&1, base)))
  end

  defp inherited?(kind, base) when is_integer(kind) do
    case kind_id(base) do
      nil -> false
      base_id -> base_id in kind_ids(kind)
    end
  end

  defp inherited?(kind, base) when is_atom(kind) and is_integer(base),
    do: atom_id(kind) == (base &&& @id_mask)

  defp inherited?(_, _), do: false

  defp pack_bases(id, bases) do
    bases
    |> Enum.flat_map(&kind_ids/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.with_index(1)
    |> Enum.reduce(id, fn {base_id, depth}, acc -> acc ||| base_id <<< (@id_length * depth) end)
  end

  defp kind_ids(kind) when is_integer(kind) do
    Stream.iterate(kind, &(&1 >>> @id_length))
    |> Enum.take_while(&(&1 != 0))
    |> Enum.map(&(&1 &&& @id_mask))
    |> Enum.reject(&(&1 == 0))
  end

  defp kind_ids(kind) when is_atom(kind) do
    case atom_id(kind) do
      nil -> []
      id -> [id | Enum.flat_map(atom_bases(kind), &kind_ids/1)]
    end
  end

  defp kind_ids(_kind), do: []

  defp kind_id(kind) when is_integer(kind), do: kind &&& @id_mask
  defp kind_id(kind) when is_atom(kind), do: atom_id(kind)
  defp kind_id(_kind), do: nil

  defp atom_id(:element), do: 1
  defp atom_id(:vertex), do: 2
  defp atom_id(:pseudostate), do: 3
  defp atom_id(:state), do: 4
  defp atom_id(:final), do: 5
  defp atom_id(:submachine), do: 6
  defp atom_id(:choice), do: 7
  defp atom_id(:initial), do: 8
  defp atom_id(:shallow_history), do: 9
  defp atom_id(:deep_history), do: 10
  defp atom_id(:entry_point), do: 11
  defp atom_id(:exit_point), do: 12
  defp atom_id(:transition), do: 13
  defp atom_id(:external), do: 14
  defp atom_id(:internal), do: 15
  defp atom_id(:local), do: 16
  defp atom_id(:self), do: 17
  defp atom_id(:event), do: 18
  defp atom_id(:completion_event), do: 19
  defp atom_id(:timer_event), do: 20
  defp atom_id(:set_event), do: 21
  defp atom_id(:call_event), do: 22
  defp atom_id(:error_event), do: 23
  defp atom_id(:behavior), do: 24
  defp atom_id(:state_machine), do: 25
  defp atom_id(:attribute), do: 26
  defp atom_id(:operation), do: 27
  defp atom_id(_kind), do: nil

  defp atom_bases(:final), do: [:state]
  defp atom_bases(:submachine), do: [:state]
  defp atom_bases(:state), do: [:vertex]
  defp atom_bases(:choice), do: [:pseudostate, :vertex]
  defp atom_bases(:initial), do: [:pseudostate, :vertex]
  defp atom_bases(:shallow_history), do: [:pseudostate, :vertex]
  defp atom_bases(:deep_history), do: [:pseudostate, :vertex]
  defp atom_bases(:entry_point), do: [:pseudostate, :vertex]
  defp atom_bases(:exit_point), do: [:pseudostate, :vertex]
  defp atom_bases(:external), do: [:transition]
  defp atom_bases(:internal), do: [:transition]
  defp atom_bases(:local), do: [:transition]
  defp atom_bases(:self), do: [:transition]
  defp atom_bases(:completion_event), do: [:event]
  defp atom_bases(:timer_event), do: [:event]
  defp atom_bases(:set_event), do: [:event]
  defp atom_bases(:call_event), do: [:event]
  defp atom_bases(:error_event), do: [:completion_event, :event]
  defp atom_bases(:state_machine), do: [:behavior]
  defp atom_bases(_kind), do: []

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start_link(fn -> @counter_start end, name: __MODULE__)
      _pid -> :ok
    end
  end
end
