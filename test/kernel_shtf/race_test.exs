defmodule KernelShtf.RaceTest do
  use ExUnit.Case, async: true
  use KernelShtf.Race

  defmodule TestMessage do
    defstruct [:data]
  end

  defmodule DummyJumper do
    use GenStage

    def start_link(opts \\ []) do
      GenStage.start_link(__MODULE__, opts)
    end

    def init(opts) do
      broadway_opts = opts[:broadway] || %{}
      counter = broadway_opts[:counter] || 0

      {:producer, %{counter: counter}}
    end

    def handle_demand(demand, state) when demand > 0 do
      counter = state.counter
      events = Enum.map(counter..(counter + demand - 1), &%TestMessage{data: &1})
      {:noreply, events, %{state | counter: counter + demand}}
    end
  end

  track TestTrack do
    checkpoints(
      module: {DummyJumper, [counter: 0]},
      checker_concurrency: 2,
      batch_size: 50
    )

    def handle_message(_, message, _) do
      message
    end

    # Modified handle_batch to properly handle message acknowledgment
    def handle_batch(_batcher, messages, _batch_info, _context) do
      messages
      |> Enum.map(fn message ->
        %{message | data: message.data.data}
      end)
    end
  end

  jump TestJump do
    def handle_demand(demand, state) do
      events = Enum.to_list(1..demand)
      {:noreply, events, state}
    end
  end

  land TestLand, [TestJump] do
    def handle_events(events, _from, state) do
      send(state.test_pid, {:events_received, events})
      {:noreply, [], state}
    end
  end

  describe "track" do
    test "starts broadway pipeline" do
      opts = [
        name: :test_pipeline
      ]

      {:ok, pid} = TestTrack.start_link(opts)
      assert Process.alive?(pid)

      # Give pipeline time to initialize
      Process.sleep(100)

      # Clean shutdown
      :ok = Broadway.stop(pid, 30_000)
    end
  end

  describe "jump and land" do
    test "producer-consumer communication" do
      {:ok, _jumper} = TestJump.start_link([])
      {:ok, _lander} = TestLand.start_link(%{test_pid: self()})

      # Wait for events
      assert_receive {:events_received, events}, 1000
      assert length(events) > 0
      assert Enum.all?(events, &is_integer/1)
    end
  end

  describe "flow" do
    test "processes enumerable data" do
      result =
        1..10
        |> flow(stages: 2)
        |> Flow.map(&(&1 * 2))
        |> Enum.sort()

      assert result == Enum.map(1..10, &(&1 * 2)) |> Enum.sort()
    end

    test "basic partition operations" do
      result =
        1..100
        |> flow()
        # Partition into even/odd
        |> partition(key: &rem(&1, 2))
        |> Flow.reduce(fn -> [] end, fn num, acc ->
          [num | acc]
        end)
        |> Flow.on_trigger(fn acc ->
          # Only emit non-empty lists
          case Enum.reverse(acc) do
            [] -> {[], acc}
            list -> {[list], acc}
          end
        end)
        |> Enum.to_list()
        # Remove empty lists
        |> Enum.reject(&Enum.empty?/1)

      # Should have 2 partitions (even/odd)
      assert length(result) == 2

      # Verify contents
      [odds, evens] = Enum.sort_by(result, &hd/1)
      assert Enum.all?(odds, &(rem(&1, 2) == 1))
      assert Enum.all?(evens, &(rem(&1, 2) == 0))
      assert length(odds) + length(evens) == 100
    end
  end

  describe "complex pipeline" do
    defmodule ComplexPipeline do
      use KernelShtf.Race

      jump NumberJumper do
        def init(opts) do
          # Explicitly convert any input to a map with appropriate defaults
          state =
            case opts do
              opts when is_list(opts) ->
                # Convert keyword list to map with default
                Enum.into(opts, %{counter: 1})

              %{} = map ->
                # Ensure counter exists in map
                Map.put_new(map, :counter, 1)

              _ ->
                # Default state if neither list nor map
                %{counter: 1}
            end

          # Set counter from start_from if specified
          counter = if state[:start_from], do: state.start_from, else: state.counter

          {:producer, %{counter: counter}}
        end

        def handle_demand(demand, %{counter: counter} = state)
            when is_integer(demand) and is_integer(counter) do
          events = Enum.to_list(counter..(counter + demand - 1))
          {:noreply, events, %{state | counter: counter + demand}}
        end
      end

      land NumberChecker, [NumberJumper] do
        def init(opts) do
          {:consumer, opts}
        end

        def handle_events(events, _from, state) do
          checked = Enum.map(events, &(&1 * 2))
          send(state.test_pid, {:checked, checked})
          {:noreply, [], state}
        end
      end

      track MetricsPipeline do
        checkpoints(
          module: {DummyJumper, [counter: 0]},
          checker_concurrency: 2,
          batch_size: 10
        )

        def handle_message(_, message, _) do
          message
        end

        # Modified handle_batch to properly handle message acknowledgment
        def handle_batch(_batcher, messages, _batch_info, _context) do
          messages
          |> Enum.map(fn message ->
            %{message | data: message.data.data}
          end)
        end
      end
    end

    test "runs integrated pipeline" do
      {:ok, jumper} = ComplexPipeline.NumberJumper.start_link(start_from: 1)
      {:ok, checker} = ComplexPipeline.NumberChecker.start_link(%{test_pid: self()})

      opts = [
        name: :metrics_pipeline
      ]

      {:ok, metrics} = ComplexPipeline.MetricsPipeline.start_link(opts)

      # Give pipeline time to start
      Process.sleep(200)

      assert_receive {:checked, events}, 1000
      assert length(events) > 0
      # All numbers should be even
      assert Enum.all?(events, &(rem(&1, 2) == 0))

      assert Process.alive?(jumper)
      assert Process.alive?(checker)
      assert Process.alive?(metrics)

      # Clean shutdown
      :ok = Broadway.stop(metrics)
    end
  end
end
