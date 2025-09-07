defmodule Collector.Workers.ConsoleConnection.ReplayManager do
  @moduledoc """
  Keeps **logical** state for a Wii connection.

  • authoritative cursor
  • payload_sizes (after 0x35 event)
  • current ReplaySession pid / monitor
  • parses handshake / replay messages and
    decides when to spawn, forward to, or
    finalize a ReplaySession.
  """

  use GenServer

  alias Collector.Utils.ConsoleLogger, as: ConnLogger
  alias Collector.Workers.ConsoleConnection.EventExtractor
  alias Collector.Workers.ReplaySession, as: ReplaySession
  alias Collector.Workers.ReplaySessionSupervisor, as: SessionSup
  alias Slippi.WiiConsole

  # -----------------------------------------------------------------------------
  # State
  # -----------------------------------------------------------------------------

  defmodule State do
    @enforce_keys [:wii]
    defstruct wii: nil,
              cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
              payload_sizes: nil,
              buffer: <<>>,
              token: nil,
              current_session: nil,
              current_session_ref: nil,
              status: :idle

    @type t :: %__MODULE__{
            wii: WiiConsole.t(),
            cursor: binary(),
            payload_sizes: %{byte() => non_neg_integer()} | nil,
            buffer: binary(),
            token: binary() | nil,
            current_session: pid() | nil,
            current_session_ref: reference() | nil,
            status: :idle | :active
          }
  end

  # -----------------------------------------------------------------------------
  # Public API
  # -----------------------------------------------------------------------------

  def start_link(wii) do
    GenServer.start_link(__MODULE__, wii, name: via_tuple(wii.mac))
  end

  def deliver_message(pid, message), do: GenServer.cast(pid, {:msg, message})

  @spec get_cursor(pid()) :: binary()
  def get_cursor(pid), do: GenServer.call(pid, :get_cursor)

  @spec get_handshake_info(pid()) :: binary()
  def get_handshake_info(pid), do: GenServer.call(pid, :get_handshake_info)

  @spec get_token(pid()) :: binary()
  def get_token(pid), do: GenServer.call(pid, :get_token)

  # -----------------------------------------------------------------------------
  # Server Callbacks
  # -----------------------------------------------------------------------------

  @impl true
  def init(%WiiConsole{} = wii) do
    {:ok, %State{wii: wii}}
  end

  # --------------------- synchronous callbacks ----------------------------------

  @impl true
  def handle_call(:get_cursor, _from, %State{} = state) do
    {:reply, state.cursor, state}
  end

  @impl true
  def handle_call(:handshake, _from, %State{wii: wii} = state) do
    # 1. check for running sessions
    # 2. If there are no running sessions, set cursor to 0
    # 3. If there is a running session, get the cursor, pid and ref from the session
    # 4. update state with the new cursor and session info
    # 5. return the cursor and token

    # filter for sessions that have the same mac as the wii
    spec = [
      {
        # MATCH_HEAD ---------------------------------------------------------------
        {{:session, :"$1"}, :"$2", %{mac: wii.mac, status: :started, token: :"$3"}},
        # GUARDS -------------------------------------------------------------------
        [],
        # RESULT: here we return the session_id ( $"$1"), its pid ($"$2") and token ($"$3")
        [{{:"$1", :"$2", :"$3"}}]
      }
    ]

    sessions = Registry.select(Collector.SessionRegistry, spec)

    case sessions do
      [] ->
        {:reply, {:ok, <<0, 0, 0, 0, 0, 0, 0, 0>>, <<0, 0, 0, 0>>}, reset_state(state)}

      [{session_id, pid, token}] ->
        case ReplaySession.get_cursor(pid) do
          {:ok, cursor} ->
            ref = Process.monitor(pid)

            {:reply, {:ok, cursor, token},
             %State{
               state
               | cursor: cursor,
                 current_session: pid,
                 current_session_ref: ref,
                 status: :active
             }}

          {:error, reason} ->
            {:reply, {:ok, <<0, 0, 0, 0, 0, 0, 0, 0>>, <<0, 0, 0, 0>>}, reset_state(state)}
        end
    end

    {:reply, state.cursor, state}
  end

  # --------------------- asynchronous callbacks ----------------------------------

  @impl true
  def handle_cast({:msg, message}, %State{cursor: expected_cursor, buffer: buffer} = state) do
    %{"data" => data, "pos" => current_pos, "nextPos" => next_pos, "forcePos" => force_pos} =
      message

    binary_data = :binary.list_to_bin(data)
    current_cursor = :binary.list_to_bin(current_pos)
    next_cursor = :binary.list_to_bin(next_pos)

    with {:ok, next_cursor} <-
           validate_cursor(current_cursor, next_cursor, force_pos, expected_cursor),
         {:ok, updated_state} <-
           process_replay_event_data(<<buffer::binary, binary_data::binary>>, %State{
             state
             | cursor: next_cursor
           }) do
      {:noreply, updated_state}
    else
      {:error, reason} ->
        {:stop, reason, state}
    end
  end

  # --------------------- termination callbacks ----------------------------------

  @impl true
  def terminate(reason, _state) do
    ConnLogger.debug("ReplayManager terminating: #{inspect(reason)}",
      pid: self()
    )

    :ok
  end

  # --------------------- DOWN from ReplaySession ----------------------------------

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, :normal},
        %State{current_session_ref: ref} = state
      ) do
    ConnLogger.debug("ReplaySession terminated normally", session_pid: state.current_session)

    {:noreply,
     %State{
       state
       | status: :idle,
         current_session: nil,
         current_session_ref: nil,
         cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
         payload_sizes: nil,
         buffer: <<>>
     }}
  end

  @impl true
  def handle_info(
        {:DOWN, ref, :process, _pid, reason},
        %State{current_session_ref: ref} = state
      ) do
    ConnLogger.error("ReplaySession terminated abnormally",
      session_pid: state.current_session,
      reason: reason
    )

    # TODO: Handle this better, this is just for now
    #       In the future the session will save it's state and recover gracefully

    {:noreply,
     %State{
       state
       | status: :idle,
         current_session: nil,
         current_session_ref: nil,
         cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
         payload_sizes: nil,
         buffer: <<>>
     }}
  end

  # -----------------------------------------------------------------------------
  # Helpers
  # -----------------------------------------------------------------------------

  defp process_replay_event_data(
         message_payload,
         %State{payload_sizes: payload_sizes} = state
       ) do
    case EventExtractor.process_replay_event_data(message_payload, payload_sizes) do
      {:payload_sizes, payload_sizes, event_data, rest} ->
        {:ok, create_new_session(payload_sizes, event_data, rest, state)}

      {:event, _cmd, event_data, rest} ->
        forward_to_session(state.current_session, event_data)
        {:ok, %State{state | buffer: rest}}

      {:continue, rest} ->
        {:ok, %State{state | buffer: rest}}

      {:error, reason} ->
        ConnLogger.error("Error processing replay message: #{inspect(reason)}")
        {:error, reason}
    end
  end

  defp create_new_session(payload_sizes, event_data, rest, %State{} = state) do
    {:ok, pid} = SessionSup.start_session()
    ref = Process.monitor(pid)

    ConnLogger.debug("Created new ReplaySession", session_pid: pid, pid: self())

    forward_to_session(pid, event_data)

    %State{
      state
      | payload_sizes: payload_sizes,
        buffer: rest,
        current_session: pid,
        current_session_ref: ref,
        status: :active,
        cursor: next_cursor
    }
  end

  defp forward_to_session(pid, event_data) do
    ReplaySession.process_event(pid, event_data, state.cursor, state.next_cursor)
  end

  defp validate_cursor(current_cursor, next_cursor, force_pos, expected_cursor) do
    cond do
      # Force position for overflow handling
      # this happens when we request a position that is too far back in the buffer
      force_pos ->
        ConnLogger.warning(
          "Forced position! Replay is likely corrupted.",
          current_cursor: current_cursor,
          next_cursor: next_cursor,
          expected_cursor: expected_cursor
        )

        {:ok, next_cursor}

      # Normal case - positions match
      current_cursor == expected_cursor ->
        {:ok, next_cursor}

      # Initial position
      current_cursor == <<0, 0, 0, 0, 0, 0, 0, 0>> ->
        {:ok, next_cursor}

      # Position mismatch error
      current_cursor != expected_cursor ->
        ConnLogger.error(
          "Position mismatch. Expected: #{inspect(expected_cursor)}, Got: #{inspect(current_cursor)}"
        )

        {:error, :position_mismatch}
    end
  end

  defp reset_state(%State{} = state) do
    %State{
      state
      | cursor: <<0, 0, 0, 0, 0, 0, 0, 0>>,
        status: :idle,
        current_session: nil,
        current_session_ref: nil,
        buffer: <<>>,
        payload_sizes: nil
    }
  end

  defp via_tuple(mac), do: {:via, Registry, {Collector.SessionRegistry, {:mgr, mac}}}
end
