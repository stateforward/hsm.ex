defmodule TrafficLightBench do
  @warmup_ms max(1, String.to_integer(System.get_env("HSM_BENCH_WARMUP_MS", "250")))
  @duration_ms max(1, String.to_integer(System.get_env("HSM_BENCH_DURATION_MS", "2000")))
  @validate System.get_env("HSM_BENCH_VALIDATE", "0") not in ["", "0", "false", "False"]
  @target_batch_ms 10.0

  @car_arrival HSM.event("CarArrival")
  @timer_event HSM.event("TimerEvent")

  def model do
    HSM.define("TrafficLight", [
      HSM.attribute("maintenance_mode", :boolean, false),
      HSM.attribute("cars_waiting", :integer, 0),
      HSM.attribute("timer", :integer, 0),
      HSM.initial([HSM.target("operational")]),
      HSM.state("operational", [
        HSM.transition([
          HSM.on("MaintenanceSwitch"),
          HSM.guard(&is_maintenance/3),
          HSM.target("../maintenance")
        ]),
        HSM.initial([HSM.target("red")]),
        HSM.state("red", [
          HSM.transition([
            HSM.on(@timer_event),
            HSM.guard(&check_cars_for_choice/3),
            HSM.effect(&set_timer_extended/3),
            HSM.target("../green")
          ]),
          HSM.transition([
            HSM.on(@timer_event),
            HSM.effect(&set_timer_standard/3),
            HSM.target("../green")
          ]),
          HSM.transition([
            HSM.on(@car_arrival),
            HSM.effect(&add_car/3)
          ])
        ]),
        HSM.state("green", [
          HSM.transition([
            HSM.on(@timer_event),
            HSM.target("../yellow")
          ]),
          HSM.transition([
            HSM.on("PedestrianButton"),
            HSM.guard(&no_cars_waiting/3),
            HSM.target("../yellow")
          ])
        ]),
        HSM.state("yellow", [
          HSM.defer("CarArrival"),
          HSM.transition([
            HSM.on(@timer_event),
            HSM.target("../red")
          ])
        ])
      ]),
      HSM.state("maintenance", [
        HSM.entry(&reset_cars/3),
        HSM.transition([
          HSM.on("Tick"),
          HSM.effect(&maintenance_tick/3)
        ]),
        HSM.transition([
          HSM.on("MaintenanceSwitch"),
          HSM.guard(&is_not_maintenance/3),
          HSM.target("../operational")
        ])
      ])
    ])
  end

  def reset_cars(_ctx, instance, _event), do: put_attr(instance, "cars_waiting", 0)
  def add_car(_ctx, instance, _event), do: update_attr(instance, "cars_waiting", &(&1 + 1))
  def no_cars_waiting(_ctx, instance, _event), do: attr(instance, "cars_waiting") == 0
  def is_maintenance(_ctx, instance, _event), do: attr(instance, "maintenance_mode") == true
  def is_not_maintenance(_ctx, instance, _event), do: attr(instance, "maintenance_mode") == false
  def check_cars_for_choice(_ctx, instance, _event), do: attr(instance, "cars_waiting") > 10
  def set_timer_extended(_ctx, instance, _event), do: put_attr(instance, "timer", 60)
  def set_timer_standard(_ctx, instance, _event), do: put_attr(instance, "timer", 40)
  def maintenance_tick(_ctx, instance, _event), do: update_attr(instance, "timer", &(&1 + 1))

  def run do
    model = model()

    if @validate do
      validate_traffic_light(model)
    end

    warmup_light = HSM.new(model) |> HSM.start()
    batch_cycles = calibrate_batch(warmup_light)
    run_for(warmup_light, @warmup_ms, batch_cycles)

    :erlang.garbage_collect()

    light = HSM.new(model) |> HSM.start()
    {completed_cycles, duration_ms} = run_for(light, @duration_ms, batch_cycles)

    total_dispatches = completed_cycles * 4
    duration_s = duration_ms / 1000
    ops_per_sec = if duration_s > 0, do: trunc(total_dispatches / duration_s), else: 0
    memory_mb = :erlang.memory(:total) / (1024 * 1024)

    IO.puts(
      JSON.encode!(%{
        language: "Elixir",
        iterations: total_dispatches,
        duration_ms: round(duration_ms),
        memory_mb: Float.round(memory_mb, 2),
        throughput_ops_per_sec: ops_per_sec
      })
    )
  end

  defp attr(instance, name), do: Map.fetch!(instance.attributes, name)

  defp put_attr(instance, name, value) do
    %{instance | attributes: Map.put(instance.attributes, name, value)}
  end

  defp update_attr(instance, name, fun) do
    put_attr(instance, name, fun.(attr(instance, name)))
  end

  defp assert_traffic_light(light, state, cars_waiting, timer, step) do
    unless HSM.state(light) == state do
      raise "#{step}: state #{inspect(HSM.state(light))}, expected #{inspect(state)}"
    end

    unless attr(light, "cars_waiting") == cars_waiting do
      raise "#{step}: cars_waiting #{attr(light, "cars_waiting")}, expected #{cars_waiting}"
    end

    unless attr(light, "timer") == timer do
      raise "#{step}: timer #{attr(light, "timer")}, expected #{timer}"
    end
  end

  defp validate_traffic_light(model) do
    light = HSM.new(model) |> HSM.start()
    assert_traffic_light(light, "/TrafficLight/operational/red", 0, 0, "initial")

    {light, status} = HSM.dispatch(light, @car_arrival)
    unless status == :processed, do: raise("dispatch did not return :processed")
    assert_traffic_light(light, "/TrafficLight/operational/red", 1, 0, "after CarArrival")

    {light, :processed} = HSM.dispatch(light, @timer_event)

    assert_traffic_light(
      light,
      "/TrafficLight/operational/green",
      1,
      40,
      "after first TimerEvent"
    )

    {light, :processed} = HSM.dispatch(light, @timer_event)

    assert_traffic_light(
      light,
      "/TrafficLight/operational/yellow",
      1,
      40,
      "after second TimerEvent"
    )

    {light, :processed} = HSM.dispatch(light, @timer_event)
    assert_traffic_light(light, "/TrafficLight/operational/red", 1, 40, "after third TimerEvent")
  end

  defp dispatch_batch(light, cycles) do
    Enum.reduce(1..cycles, light, fn _, current ->
      {current, _} = HSM.dispatch(current, @car_arrival)
      {current, _} = HSM.dispatch(current, @timer_event)
      {current, _} = HSM.dispatch(current, @timer_event)
      {current, _} = HSM.dispatch(current, @timer_event)
      current
    end)
  end

  defp calibrate_batch(light, cycles \\ 1) do
    start = System.monotonic_time(:microsecond)
    dispatch_batch(light, cycles)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000

    if elapsed_ms >= @target_batch_ms or cycles >= Bitwise.bsl(1, 20) do
      cycles
    else
      calibrate_batch(light, cycles * 2)
    end
  end

  defp run_for(light, duration_ms, batch_cycles) do
    start = System.monotonic_time(:microsecond)
    deadline = start + duration_ms * 1000
    {cycles, _light} = run_until(light, deadline, batch_cycles, 0)
    elapsed_ms = (System.monotonic_time(:microsecond) - start) / 1000
    {cycles, elapsed_ms}
  end

  defp run_until(light, deadline, batch_cycles, cycles) do
    if System.monotonic_time(:microsecond) < deadline do
      run_until(
        dispatch_batch(light, batch_cycles),
        deadline,
        batch_cycles,
        cycles + batch_cycles
      )
    else
      {cycles, light}
    end
  end
end

TrafficLightBench.run()
