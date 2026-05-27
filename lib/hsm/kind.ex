defmodule HSM.Kind do
  @moduledoc false
  use Agent

  def make(base_kinds \\ []) do
    ensure_started()
    id = Agent.get_and_update(__MODULE__, &{&1, &1 + 1})
    %{id: id, bases: List.wrap(base_kinds)}
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

  defp inherited?(%{bases: bases}, base),
    do: Enum.any?(bases, &(&1 == base or inherited?(&1, base)))

  defp inherited?(_, _), do: false

  defp atom_bases(:final), do: [:state]
  defp atom_bases(:state), do: [:vertex]
  defp atom_bases(:choice), do: [:pseudostate, :vertex]
  defp atom_bases(:initial), do: [:pseudostate, :vertex]
  defp atom_bases(:shallow_history), do: [:pseudostate, :vertex]
  defp atom_bases(:deep_history), do: [:pseudostate, :vertex]
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
      nil -> Agent.start_link(fn -> 1 end, name: __MODULE__)
      _pid -> :ok
    end
  end
end
