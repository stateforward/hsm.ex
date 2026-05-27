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

  defp inherited?(%{bases: bases}, base),
    do: Enum.any?(bases, &(&1 == base or inherited?(&1, base)))

  defp inherited?(_, _), do: false

  defp ensure_started do
    case Process.whereis(__MODULE__) do
      nil -> Agent.start_link(fn -> 1 end, name: __MODULE__)
      _pid -> :ok
    end
  end
end
