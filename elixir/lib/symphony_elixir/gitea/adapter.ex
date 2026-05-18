defmodule SymphonyElixir.Gitea.Adapter do
  @moduledoc """
  Gitea-backed tracker adapter implementing the `SymphonyElixir.Tracker` behaviour.
  """

  @behaviour SymphonyElixir.Tracker

  alias SymphonyElixir.{Config, Gitea.Client}
  alias SymphonyElixir.Linear.Issue

  @spec fetch_candidate_issues() :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_candidate_issues do
    case Client.list_issues(state: "open") do
      {:ok, issues} ->
        {:ok, Enum.map(issues, &Client.normalize_issue/1)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec fetch_issues_by_states([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issues_by_states(state_names) when is_list(state_names) do
    normalized_states = Enum.map(state_names, &to_string/1) |> Enum.uniq()

    if normalized_states == [] do
      {:ok, []}
    else
      tracker = Config.settings!().tracker
      active_set = MapSet.new(tracker.active_states)
      terminal_set = MapSet.new(tracker.terminal_states)
      requested_set = MapSet.new(normalized_states)

      gitea_states = resolve_gitea_states(requested_set, active_set, terminal_set)

      case fetch_issues_for_gitea_states(gitea_states) do
        {:ok, issues} ->
          filtered = Enum.filter(issues, fn %Issue{state: state} -> state in normalized_states end)
          {:ok, filtered}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @spec fetch_issue_states_by_ids([String.t()]) :: {:ok, [Issue.t()]} | {:error, term()}
  def fetch_issue_states_by_ids(issue_ids) when is_list(issue_ids) do
    ids = Enum.uniq(issue_ids)

    case ids do
      [] ->
        {:ok, []}

      ids ->
        issues =
          Enum.reduce_while(ids, {:ok, []}, fn id, {:ok, acc} ->
            number = parse_issue_number(id)

            case Client.get_issue(number) do
              {:ok, raw_issue} ->
                {:cont, {:ok, [Client.normalize_issue(raw_issue) | acc]}}

              {:error, reason} ->
                {:halt, {:error, reason}}
            end
          end)

        case issues do
          {:ok, result} -> {:ok, Enum.reverse(result)}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  @spec create_comment(String.t(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(issue_id) and is_binary(body) do
    Client.create_comment(issue_id, body)
  end

  @spec update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
  def update_issue_state(issue_id, state_name)
      when is_binary(issue_id) and is_binary(state_name) do
    case symphony_state_to_gitea_state(state_name) do
      nil ->
        {:error, {:unknown_symphony_state, state_name}}

      gitea_state ->
        Client.update_issue(issue_id, %{"state" => gitea_state})
    end
  end

  defp resolve_gitea_states(requested_set, active_set, terminal_set) do
    needs_open = not MapSet.disjoint?(requested_set, active_set)
    needs_closed = not MapSet.disjoint?(requested_set, terminal_set)

    (if needs_open, do: ["open"], else: []) ++
      (if needs_closed, do: ["closed"], else: [])
  end

  defp fetch_issues_for_gitea_states([]), do: {:ok, []}

  defp fetch_issues_for_gitea_states(gitea_states) do
    Enum.reduce_while(gitea_states, {:ok, []}, fn state, {:ok, acc} ->
      case Client.list_issues(state: state) do
        {:ok, issues} ->
          normalized = Enum.map(issues, &Client.normalize_issue/1)
          {:cont, {:ok, acc ++ normalized}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
  end

  defp symphony_state_to_gitea_state(state_name) do
    tracker = Config.settings!().tracker

    cond do
      state_name in tracker.active_states -> "open"
      state_name in tracker.terminal_states -> "closed"
      true -> nil
    end
  end

  defp parse_issue_number(issue_id) when is_binary(issue_id) do
    case Integer.parse(issue_id) do
      {number, _} -> number
      :error -> issue_id
    end
  end
end
