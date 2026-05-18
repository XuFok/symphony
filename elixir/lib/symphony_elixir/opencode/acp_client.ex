defmodule SymphonyElixir.OpenCode.ACPClient do
  @moduledoc """
  Minimal client for the OpenCode ACP (Agent Client Protocol) JSON-RPC 2.0 stream over stdio.

  ## Protocol Overview

  ACP is a JSON-RPC 2.0 protocol (NDJSON) used to communicate with OpenCode agents:

    1. `initialize`       — negotiate capabilities
    2. `session/new`      — create a new session with a working directory
    3. `session/prompt`   — send a prompt and receive streaming updates
    4. `session/cancel`   — interrupt an active prompt (not used during normal flow)

  Sessions are tied to a stdio subprocess started with the configured `opencode` command.
  """

  require Logger
  alias SymphonyElixir.{Config, PathSafety}

  @initialize_id 1
  @session_new_id 2
  @session_prompt_id 3
  @port_line_bytes 1_048_576
  @max_stream_log_bytes 1_000

  @type session :: %{
          port: port(),
          metadata: map(),
          session_id: String.t(),
          workspace: Path.t(),
          worker_host: nil
        }

  @doc """
  Runs a complete ACP lifecycle: starts a session, sends a prompt, and stops the session.

  Returns `{:ok, result_map}` on success or `{:error, reason}` on failure.
  """
  @spec run(Path.t(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run(workspace, prompt, issue, opts \\ []) do
    with {:ok, session} <- start_session(workspace, opts) do
      try do
        run_turn(session, prompt, issue, opts)
      after
        stop_session(session)
      end
    end
  end

  @doc """
  Starts a new ACP session by launching the OpenCode subprocess, sending `initialize`,
  and creating a new session via `session/new`.

  Returns `{:ok, session}` or `{:error, reason}`.
  """
  @spec start_session(Path.t(), keyword()) :: {:ok, session()} | {:error, term()}
  def start_session(workspace, _opts \\ []) do
    with {:ok, expanded_workspace} <- validate_workspace_cwd(workspace),
         {:ok, port} <- start_port(expanded_workspace) do
      with {:ok, session_id} <- initialize_and_create_session(port, expanded_workspace) do
        # Try to get PID after handshake (process is now running)
        metadata = port_metadata(port)

        {:ok,
         %{
           port: port,
           metadata: metadata,
           session_id: session_id,
           workspace: expanded_workspace,
           worker_host: nil
         }}
      else
        {:error, reason} ->
          stop_port(port)
          {:error, reason}
      end
    end
  end

  @doc """
  Sends a prompt to an existing ACP session and streams `session/update` notifications
  until the prompt completes.

  ## Options

    * `:on_message` — a function that receives event maps (same pattern as `Codex.AppServer`)

  Returns `{:ok, result_map}` or `{:error, reason}`.
  """
  @spec run_turn(session(), String.t(), map(), keyword()) :: {:ok, map()} | {:error, term()}
  def run_turn(
        %{port: port, metadata: metadata, session_id: session_id, workspace: _workspace},
        prompt,
        issue,
        opts \\ []
      ) do
    on_message = Keyword.get(opts, :on_message, &default_on_message/1)
    opencode_settings = Config.settings!().opencode

    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @session_prompt_id,
      "method" => "session/prompt",
      "params" => %{
        "sessionId" => session_id,
        "prompt" => [%{"type" => "text", "text" => prompt}]
      }
    })

    Logger.info("OpenCode prompt sent for #{issue_context(issue)} session_id=#{session_id}")

    emit_message(
      on_message,
      :session_started,
      %{session_id: session_id},
      metadata
    )

    case await_prompt_completion(port, on_message, opencode_settings) do
      {:ok, result} ->
        Logger.info("OpenCode session completed for #{issue_context(issue)} session_id=#{session_id}")

        emit_message(
          on_message,
          :session_completed,
          %{session_id: session_id, result: result, usage: Map.get(result, "usage")},
          metadata
        )

        {:ok, %{result: result, session_id: session_id}}

      {:error, reason} ->
        Logger.warning("OpenCode session ended with error for #{issue_context(issue)} session_id=#{session_id}: #{inspect(reason)}")

        emit_message(
          on_message,
          :session_ended_with_error,
          %{session_id: session_id, reason: reason},
          metadata
        )

        {:error, reason}
    end
  end

  @doc """
  Stops an ACP session by closing the underlying subprocess port.

  Always returns `:ok`.
  """
  @spec stop_session(session()) :: :ok
  def stop_session(%{port: port}) when is_port(port) do
    stop_port(port)
  end

  # ── Port lifecycle ────────────────────────────────────────────────────────

  defp start_port(workspace) do
    executable = System.find_executable("bash")

    if is_nil(executable) do
      {:error, :bash_not_found}
    else
      command = Config.settings!().opencode.command

      port =
        Port.open(
          {:spawn_executable, String.to_charlist(executable)},
          [
            :binary,
            :exit_status,
            :stderr_to_stdout,
            args: [~c"-lc", String.to_charlist(command)],
            cd: String.to_charlist(workspace),
            line: @port_line_bytes
          ]
        )

      {:ok, port}
    end
  end

  defp stop_port(port) when is_port(port) do
    case :erlang.port_info(port) do
      :undefined ->
        :ok

      _ ->
        try do
          Port.close(port)
          :ok
        rescue
          ArgumentError ->
            :ok
        end
    end
  end

  defp port_metadata(port) when is_port(port) do
    case :erlang.port_info(port, :os_pid) do
      {:os_pid, os_pid} ->
        %{codex_app_server_pid: to_string(os_pid)}

      _ ->
        %{}
    end
  end

  # ── Workspace validation ──────────────────────────────────────────────────

  defp validate_workspace_cwd(workspace) when is_binary(workspace) do
    expanded_workspace = Path.expand(workspace)
    expanded_root = Path.expand(Config.settings!().workspace.root)
    expanded_root_prefix = expanded_root <> "/"

    with {:ok, canonical_workspace} <- PathSafety.canonicalize(expanded_workspace),
         {:ok, canonical_root} <- PathSafety.canonicalize(expanded_root) do
      canonical_root_prefix = canonical_root <> "/"

      cond do
        canonical_workspace == canonical_root ->
          {:error, {:invalid_workspace_cwd, :workspace_root, canonical_workspace}}

        String.starts_with?(canonical_workspace <> "/", canonical_root_prefix) ->
          {:ok, canonical_workspace}

        String.starts_with?(expanded_workspace <> "/", expanded_root_prefix) ->
          {:error, {:invalid_workspace_cwd, :symlink_escape, expanded_workspace, canonical_root}}

        true ->
          {:error, {:invalid_workspace_cwd, :outside_workspace_root, canonical_workspace, canonical_root}}
      end
    else
      {:error, {:path_canonicalize_failed, path, reason}} ->
        {:error, {:invalid_workspace_cwd, :path_unreadable, path, reason}}
    end
  end

  # ── ACP Handshake: initialize → session/new ───────────────────────────────

  defp initialize_and_create_session(port, workspace) do
    with :ok <- send_initialize(port) do
      create_session(port, workspace)
    end
  end

  defp send_initialize(port) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @initialize_id,
      "method" => "initialize",
      "params" => %{
        "protocolVersion" => 1,
        "clientInfo" => %{
          "name" => "symphony-orchestrator",
          "version" => "0.1.0"
        }
      }
    })

    case await_response(port, @initialize_id) do
      {:ok, _result} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp create_session(port, workspace) do
    send_message(port, %{
      "jsonrpc" => "2.0",
      "id" => @session_new_id,
      "method" => "session/new",
      "params" => %{
        "cwd" => workspace,
        "mcpServers" => []
      }
    })

    case await_response(port, @session_new_id) do
      {:ok, %{"sessionId" => session_id}} ->
        {:ok, session_id}

      {:ok, result} ->
        {:error, {:invalid_session_payload, result}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # ── Prompt with streaming notifications ───────────────────────────────────

  defp await_prompt_completion(port, on_message, opencode_settings) do
    timeout_ms = opencode_settings.turn_timeout_ms
    receive_loop(port, timeout_ms, "", on_message)
  end

  defp receive_loop(port, timeout_ms, pending_line, on_message) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_incoming(port, complete_line, timeout_ms, on_message)

      {^port, {:data, {:noeol, chunk}}} ->
        receive_loop(port, timeout_ms, pending_line <> to_string(chunk), on_message)

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :turn_timeout}
    end
  end

  defp handle_incoming(port, data, timeout_ms, on_message) do
    payload_string = to_string(data)

    case Jason.decode(payload_string) do
      # Response matching the prompt request — session completed
      {:ok, %{"id" => @session_prompt_id, "result" => result}} ->
        # Extract ACP usage format and convert to Codex-compatible format
        usage = extract_acp_usage(result)
        {:ok, Map.merge(result, usage)}

      # Error response for the prompt request
      {:ok, %{"id" => @session_prompt_id, "error" => error}} ->
        {:error, {:response_error, error}}

      # Response with our id but unexpected shape
      {:ok, %{"id" => @session_prompt_id} = payload} ->
        {:error, {:response_error, payload}}

      # JSON-RPC notification (no "id" field) — e.g. session/update
      {:ok, %{"method" => method} = payload} when is_binary(method) ->
        handle_notification(on_message, payload, payload_string)
        receive_loop(port, timeout_ms, "", on_message)

      # Any other structured message — ignore and continue
      {:ok, _payload} ->
        receive_loop(port, timeout_ms, "", on_message)

      # Non-JSON output from the subprocess
      {:error, _reason} ->
        log_non_json_stream_line(payload_string, "prompt stream")
        receive_loop(port, timeout_ms, "", on_message)
    end
  end

  defp handle_notification(on_message, %{"method" => "session/update", "params" => params}, payload_string) do
    update = Map.get(params, "update", %{})
    update_type = Map.get(update, "type")

    # Try to extract token usage from ACP update
    acp_usage = extract_acp_usage_from_update(update)

    # Construct payload with method field for status dashboard to recognize
    # Format matches Codex: %{"method" => "...", "params" => ...}
    payload = %{
      "method" => "session/update",
      "params" => params
    }

    details = %{
      payload: payload,
      raw: payload_string,
      update: update
    }

    details = if acp_usage, do: Map.put(details, :usage, acp_usage), else: details

    # Convert ACP update type to specific event for status dashboard
    event =
      case update_type do
        "agentMessage/delta" -> :agent_message_delta
        "toolCall/started" -> :tool_call_started
        "toolCall/completed" -> :tool_call_completed
        "fileOperation/started" -> :file_operation_started
        "fileOperation/completed" -> :file_operation_completed
        _ -> :notification
      end

    emit_message(
      on_message,
      event,
      details,
      %{}
    )

    case update do
      %{"type" => "agentMessage/delta", "content" => content} when is_binary(content) ->
        Logger.debug("OpenCode agent message delta: #{String.slice(content, 0, @max_stream_log_bytes)}")

      _ ->
        :ok
    end
  end

  defp handle_notification(on_message, payload, payload_string) do
    emit_message(
      on_message,
      :notification,
      %{payload: payload, raw: payload_string},
      %{}
    )
  end

  # ── Response helpers (used during handshake) ──────────────────────────────

  defp await_response(port, request_id) do
    with_timeout_response(port, request_id, Config.settings!().opencode.read_timeout_ms, "")
  end

  defp with_timeout_response(port, request_id, timeout_ms, pending_line) do
    receive do
      {^port, {:data, {:eol, chunk}}} ->
        complete_line = pending_line <> to_string(chunk)
        handle_response(port, request_id, complete_line, timeout_ms)

      {^port, {:data, {:noeol, chunk}}} ->
        with_timeout_response(port, request_id, timeout_ms, pending_line <> to_string(chunk))

      {^port, {:exit_status, status}} ->
        {:error, {:port_exit, status}}
    after
      timeout_ms ->
        {:error, :response_timeout}
    end
  end

  defp handle_response(port, request_id, data, timeout_ms) do
    payload = to_string(data)

    case Jason.decode(payload) do
      {:ok, %{"id" => ^request_id, "error" => error}} ->
        {:error, {:response_error, error}}

      {:ok, %{"id" => ^request_id, "result" => result}} ->
        {:ok, result}

      {:ok, %{"id" => ^request_id} = response_payload} ->
        {:error, {:response_error, response_payload}}

      # Notifications or other messages while waiting — skip and retry
      {:ok, %{} = other} ->
        Logger.debug("Ignoring message while waiting for response: #{inspect(other)}")
        with_timeout_response(port, request_id, timeout_ms, "")

      {:error, _} ->
        log_non_json_stream_line(payload, "response stream")
        with_timeout_response(port, request_id, timeout_ms, "")
    end
  end

  # ── Logging ───────────────────────────────────────────────────────────────

  defp log_non_json_stream_line(data, stream_label) do
    text =
      data
      |> to_string()
      |> String.trim()
      |> String.slice(0, @max_stream_log_bytes)

    if text != "" do
      if String.match?(text, ~r/\b(error|warn|warning|failed|fatal|panic|exception)\b/i) do
        Logger.warning("OpenCode #{stream_label} output: #{text}")
      else
        Logger.debug("OpenCode #{stream_label} output: #{text}")
      end
    end
  end

  defp issue_context(%{id: issue_id, identifier: identifier}) do
    "issue_id=#{issue_id} issue_identifier=#{identifier}"
  end

  # ── Token usage extraction ─────────────────────────────────────────────────

  defp extract_acp_usage(result) when is_map(result) do
    case Map.get(result, "usage") do
      %{"inputTokens" => input, "outputTokens" => output} ->
        %{
          "usage" => %{
            "input_tokens" => input,
            "output_tokens" => output,
            "total_tokens" => input + output
          }
        }

      _ ->
        %{}
    end
  end

  defp extract_acp_usage(_), do: %{}

  defp extract_acp_usage_from_update(%{"cost" => _cost, "used" => used}) when is_map(used) do
    input = Map.get(used, "inputTokens", 0)
    output = Map.get(used, "outputTokens", 0)

    %{
      "input_tokens" => input,
      "output_tokens" => output,
      "total_tokens" => input + output
    }
  end

  defp extract_acp_usage_from_update(_), do: nil

  # ── Message helpers ───────────────────────────────────────────────────────

  defp send_message(port, message) do
    line = Jason.encode!(message) <> "\n"
    Port.command(port, line)
  end

  defp emit_message(on_message, event, details, metadata) when is_function(on_message, 1) do
    message =
      metadata
      |> Map.merge(details)
      |> Map.put(:event, event)
      |> Map.put(:timestamp, DateTime.utc_now())

    on_message.(message)
  end

  defp default_on_message(_message), do: :ok
end
