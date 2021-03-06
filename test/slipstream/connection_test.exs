defmodule Slipstream.ConnectionTest do
  use ExUnit.Case, async: false

  # this file is not directly related to any features
  # tests might end up in this file if any of these conditions are met:
  #
  # 1. the test would be difficult to do as an integration test because of
  #    timing (e.g. heartbeat sending)
  # 2. the test involves the remote websocket server sending events to the
  #    connection process

  # N.B. V2 encoded messages are in the form of
  # [join_ref, ref, topic, event, payload | _]

  import Slipstream
  import Slipstream.Socket, except: [send: 2]
  import Slipstream.Signatures
  alias Slipstream.{Commands, Events}

  import Mox
  setup :verify_on_exit!
  # I prefer testing with local mode (which allows us to use async: true), but
  # the connections that are spawned with Slipstream.connect/2 invoke the
  # `:gun.open/3` function immediately after start-up, leading to a race in
  # trying to `Mox.allow/3` the pid to use mocks.
  setup :set_mox_global
  @gun GunMock

  @moduletag :capture_log

  setup do
    original_value = Application.fetch_env!(:slipstream, :gun_client)
    Application.put_env(:slipstream, :gun_client, @gun)

    on_exit(fn ->
      Application.put_env(:slipstream, :gun_client, original_value)
    end)

    stub(@gun, :close, fn _conn -> :ok end)

    [config: Application.fetch_env!(:slipstream, Slipstream.GoodExample)]
  end

  describe "given an open connection socket" do
    setup c do
      conn = self()
      stream_ref = make_ref()

      @gun
      |> stub(:open, fn _host, _port, _opts ->
        # N.B.: we're providing the test process as the conn so it makes life
        # easier later when we expect messages and want to send them to the
        # test process for an assert_receive/2
        {:ok, conn}
      end)
      |> stub(:ws_upgrade, fn _conn, _path, _headers, _opts ->
        send(
          self(),
          {:gun_upgrade, conn, stream_ref, ["websocket"], _headers = []}
        )

        stream_ref
      end)

      socket =
        c.config
        |> connect!()
        |> await_connect!()

      assert connected?(socket)

      [socket: socket, conn: conn, stream_ref: stream_ref]
    end

    test """
         when the connection receives the heartbeat command,
         then it pushes a heartbeat message and can handle the reply
         """,
         c do
      @gun
      |> expect(:ws_send, 1, fn conn, {:text, encoded_message} ->
        send(conn, {:ws_send, encoded_message})

        :ok
      end)

      # the heartbeat is typically sent from the connection process to itself
      # in an interval by `:timer.send_interval/2`
      # but that interval is too long to be tested reasonably
      send(c.socket.channel_pid, command(%Commands.SendHeartbeat{}))

      assert_receive {:ws_send, encoded_message}

      message = encoded_message |> Jason.decode!(keys: :atoms)

      assert match?(
               [nil, ref, "phoenix", "heartbeat", %{} = payload]
               when is_binary(ref) and map_size(payload) == 0,
               message
             )

      reply =
        [
          nil,
          "2",
          "phoenix",
          "phx_reply",
          %{"response" => %{}, "status" => "ok"}
        ]
        |> Jason.encode!()

      # N.B. this doesn't have an effect measurable in this test, but it does
      # nab the lines of coverage we want from Events.map/2 and the connection
      # impl module
      send(
        c.socket.channel_pid,
        {:gun_ws, c.conn, c.stream_ref, {:text, reply}}
      )
    end

    test """
         when the remote websocket server disconnects,
         then the socket is notified that the connection has been terminated
         and the connection is closed
         """,
         c do
      conn = c.conn

      @gun |> expect(:close, 1, fn ^conn -> :ok end)

      send(
        c.socket.channel_pid,
        {:gun_down, c.conn, :ws, :closed, [c.stream_ref], []}
      )

      refute c.socket |> await_disconnect!() |> connected?
    end

    # e.g. your networking interface shuts down
    test """
         when the remote websocket connection is lost,
         then the socket is notified that the connection has been terminated
         and the connection is closed
         """,
         c do
      conn = c.conn

      @gun |> expect(:close, 1, fn ^conn -> :ok end)

      send(
        c.socket.channel_pid,
        {:gun_error, c.conn,
         {:websocket, c.stream_ref, "VFeeglQh/qqSFe9rqSM5FQ==", [], %{}},
         {:closed, 'The connection was lost.'}}
      )

      refute c.socket |> await_disconnect!() |> connected?
    end

    test "when the connection receives a ping, then it responds with pong", c do
      conn = c.conn

      @gun
      |> expect(:ws_send, 1, fn ^conn, :pong ->
        send(conn, :pong_sent)

        :ok
      end)

      send(c.socket.channel_pid, {:gun_ws, conn, c.stream_ref, :ping})

      assert_receive :pong_sent

      # when we send a pong, it just no-ops
      # no real test here, just getting coverage
      send(c.socket.channel_pid, {:gun_ws, conn, c.stream_ref, :pong})
    end

    test "when the connection receives a close, the client is disconnected",
         c do
      conn = c.conn

      @gun |> expect(:close, 1, fn ^conn -> :ok end)

      send(
        c.socket.channel_pid,
        {:gun_ws, c.conn, c.stream_ref, {:close, 1_000, ""}}
      )

      refute c.socket |> await_disconnect!() |> connected?
    end
  end

  describe "given an open connection socket with heartbeat interval set very low" do
    setup c do
      conn = self()
      stream_ref = make_ref()

      @gun
      |> stub(:open, fn _host, _port, _opts ->
        # N.B.: we're providing the test process as the conn so it makes life
        # easier later when we expect messages and want to send them to the
        # test process for an assert_receive/2
        {:ok, conn}
      end)
      |> stub(:ws_upgrade, fn _conn, _path, _headers, _opts ->
        send(
          self(),
          {:gun_upgrade, conn, stream_ref, ["websocket"], _headers = []}
        )

        stream_ref
      end)

      config =
        c.config
        # 20ms between heartbeat requests
        |> Keyword.put(:heartbeat_interval_msec, 20)

      [config: config, conn: conn, stream_ref: stream_ref]
    end

    test """
         when we snub heartbeat responses to the connection process,
         then the client will disconnect
         """,
         c do
      conn = c.conn

      @gun
      |> expect(:ws_send, 1, fn ^conn, {:text, heartbeat_request} ->
        request =
          heartbeat_request
          |> IO.iodata_to_binary()
          |> Jason.decode!()

        send(conn, {:request, request})

        :ok
      end)
      |> expect(:close, 1, fn ^conn -> :ok end)

      socket = c.config |> connect!() |> await_connect!()

      assert connected?(socket)

      assert_receive {:request,
                      [_join_ref, _ref, "phoenix", "heartbeat", _payload]}

      # we don't send the connection process a reply to that heartbeat, so we
      # expect it to disconnect the client

      # also, normally we would test the disconnect with this code:
      #     assert {:ok, socket} = await_disconnect(socket)
      #     assert connected?(socket) == false
      # which passes the test, but I want to get that disconnect reason
      # and assert that it is :heartbeat_timeout

      assert_receive event(%Events.ChannelClosed{reason: :heartbeat_timeout})
    end
  end

  test """
       when gun refuses to open/3 a connection
       the client gets a ChannelConnectFailed event
       """,
       c do
    reason = :some_reason

    @gun |> expect(:open, 1, fn _host, _port, _opts -> {:error, reason} end)

    assert {:error, ^reason} =
             c.config
             |> connect!
             |> await_connect
  end
end
