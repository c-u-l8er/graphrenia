defmodule GraphTrxServerTest do
  use ExUnit.Case
  require Logger

  setup do
    {:ok, server} = GraphTrxServer.start_link()
    %{server: server}
  end

  describe "schema management" do
    test "can define vertex type", %{server: server} do
      schema = [
        name: [type: :string, required: true],
        age: [type: :integer]
      ]

      {result, _} = GraphTrxServer.define_vertex_type(server, :person, schema)
      assert match?(%GraphTrx.State{}, result)
      assert result.schema[:person]
    end
  end

  describe "transaction management" do
    test "can begin transaction", %{server: server} do
      {tx_id, _} = GraphTrxServer.begin_transaction(server)
      assert is_integer(tx_id)
    end

    test "can commit transaction", %{server: server} do
      # Setup schema
      GraphTrxServer.define_vertex_type(server, :person, name: [type: :string, required: true])

      # Begin transaction and add vertex
      {tx_id, _} = GraphTrxServer.begin_transaction(server)

      {:ok, _} = GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})

      # Commit transaction
      {result, _} = GraphTrxServer.commit_transaction(server, tx_id)
      assert is_list(result)
    end

    test "can rollback transaction", %{server: server} do
      {tx_id, _} = GraphTrxServer.begin_transaction(server)
      reason = "Test rollback"
      {^reason, state} = GraphTrxServer.rollback_transaction(server, tx_id, reason)

      tx = Map.get(state.transactions, tx_id)
      assert match?(%{variant: :rolled_back, reason: ^reason}, tx)
    end
  end

  describe "graph operations" do
    setup %{server: server} do
      # Setup schema
      GraphTrxServer.define_vertex_type(server, :person,
        name: [type: :string, required: true],
        age: [type: :integer]
      )

      {tx_id, _} = GraphTrxServer.begin_transaction(server)
      %{tx_id: tx_id}
    end

    test "can add vertex", %{server: server, tx_id: tx_id} do
      {result, _} =
        GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{
          name: "Alice",
          age: 30
        })

      assert match?({true, %GraphTrx.State{}}, result)
    end

    test "validates required properties", %{server: server, tx_id: tx_id} do
      {result, _} =
        GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{
          # missing required name
          age: 30
        })

      assert match?({:error, _reason}, result)
    end

    test "can add edge", %{server: server, tx_id: tx_id} do
      # Add vertices first
      GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})
      GraphTrxServer.add_vertex(server, tx_id, :person, "2", %{name: "Bob"})

      # Add edge
      {result, _} = GraphTrxServer.add_edge(server, tx_id, "1", "2", :knows)
      assert match?({true, %GraphTrx.State{}}, result)
    end
  end

  describe "query operations" do
    setup %{server: server} do
      # Setup schema
      GraphTrxServer.define_vertex_type(server, :person, name: [type: :string, required: true])

      # Create transaction and add data
      {tx_id, _} = GraphTrxServer.begin_transaction(server)

      GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})
      GraphTrxServer.add_vertex(server, tx_id, :person, "2", %{name: "Bob"})
      GraphTrxServer.add_edge(server, tx_id, "1", "2", :knows)

      GraphTrxServer.commit_transaction(server, tx_id)

      :ok
    end

    test "can query graph", %{server: server} do
      {results, _state} = GraphTrxServer.query(server, [:person, :knows, :person])
      assert is_list(results)
    end
  end

  describe "graph metrics" do
    test "tracks vertex count", %{server: server} do
      # Setup schema and transaction
      GraphTrxServer.define_vertex_type(server, :person, name: [type: :string, required: true])
      {tx_id, _} = GraphTrxServer.begin_transaction(server)

      # Add vertices
      GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})
      GraphTrxServer.add_vertex(server, tx_id, :person, "2", %{name: "Bob"})
      GraphTrxServer.commit_transaction(server, tx_id)

      {count, _} = GraphTrxServer.get_vertex_count(server)
      assert count == 2
    end

    test "tracks edge count", %{server: server} do
      # Setup schema and transaction
      GraphTrxServer.define_vertex_type(server, :person, name: [type: :string, required: true])
      {tx_id, _} = GraphTrxServer.begin_transaction(server)

      # Add vertices and edge
      GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})
      GraphTrxServer.add_vertex(server, tx_id, :person, "2", %{name: "Bob"})
      GraphTrxServer.add_edge(server, tx_id, "1", "2", :knows)
      GraphTrxServer.commit_transaction(server, tx_id)

      {count, _} = GraphTrxServer.get_edge_count(server)
      assert count == 1
    end
  end

  describe "error handling" do
    test "handles invalid transaction id", %{server: server} do
      assert_raise GraphTrx.Error, fn ->
        GraphTrxServer.commit_transaction(server, 999)
      end
    end

    test "handles invalid vertex type", %{server: server} do
      {tx_id, _} = GraphTrxServer.begin_transaction(server)
      {result, _} = GraphTrxServer.add_vertex(server, tx_id, :invalid_type, "1", %{})
      assert match?({:error, _}, result)
    end

    test "prevents duplicate vertex ids in same transaction", %{server: server} do
      GraphTrxServer.define_vertex_type(server, :person, name: [type: :string, required: true])

      {tx_id, _} = GraphTrxServer.begin_transaction(server)
      GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Alice"})

      {result, _} = GraphTrxServer.add_vertex(server, tx_id, :person, "1", %{name: "Bob"})
      assert match?({:error, _}, result)
    end
  end
end
