defmodule SymphonyElixir.Gitea.Client do
  @moduledoc """
  Thin Gitea REST API client for polling candidate issues.
  """

  require Logger
  alias SymphonyElixir.Config
  alias SymphonyElixir.Linear.Issue

  @page_size 50

  @spec list_issues(keyword()) :: {:ok, [map()]} | {:error, term()}
  def list_issues(opts \\ []) do
    with {:ok, config} <- gitea_config(),
         {:ok, headers} <- auth_headers() do
      do_list_issues(config, opts, headers, 1, [])
    end
  end

  @spec get_issue(integer() | String.t()) :: {:ok, map()} | {:error, term()}
  def get_issue(number)

  def get_issue(number) when is_integer(number) do
    with {:ok, config} <- gitea_config(),
         {:ok, headers} <- auth_headers() do
      do_get_issue(config, number, headers)
    end
  end

  def get_issue(number) when is_binary(number) do
    case Integer.parse(number) do
      {int, _} -> get_issue(int)
      :error -> {:error, {:invalid_issue_number, number}}
    end
  end

  @spec create_comment(String.t() | integer(), String.t()) :: :ok | {:error, term()}
  def create_comment(issue_id, body) when is_binary(body) do
    number = to_integer(issue_id)

    with {:ok, config} <- gitea_config(),
         {:ok, headers} <- auth_headers() do
      do_create_comment(config, number, body, headers)
    end
  end

  @spec update_issue(String.t() | integer(), map()) :: :ok | {:error, term()}
  def update_issue(issue_id, attrs) when is_map(attrs) do
    number = to_integer(issue_id)

    with {:ok, config} <- gitea_config(),
         {:ok, headers} <- auth_headers() do
      do_update_issue(config, number, attrs, headers)
    end
  end

  @doc false
  @spec normalize_issue(map()) :: Issue.t()
  def normalize_issue(issue) when is_map(issue) do
    %Issue{
      id: to_string(issue["number"]),
      identifier: "GITEA-#{issue["number"]}",
      title: issue["title"],
      description: issue["body"],
      priority: nil,
      state: map_gitea_state(issue["state"]),
      branch_name: nil,
      url: issue["html_url"],
      assignee_id: extract_assignee_id(issue),
      blocked_by: [],
      labels: extract_labels(issue),
      assigned_to_worker: true,
      created_at: parse_datetime(issue["created_at"]),
      updated_at: parse_datetime(issue["updated_at"])
    }
  end

  defp do_list_issues(config, opts, headers, page, acc) do
    url = build_list_url(config, opts, page)

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} when is_list(body) ->
        updated_acc = acc ++ body

        if length(body) >= @page_size do
          do_list_issues(config, opts, headers, page + 1, updated_acc)
        else
          {:ok, updated_acc}
        end

      {:ok, response} ->
        Logger.error("Gitea list_issues failed status=#{response.status}")
        {:error, {:gitea_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Gitea list_issues request failed: #{inspect(reason)}")
        {:error, {:gitea_api_request, reason}}
    end
  end

  defp do_get_issue(config, number, headers) do
    url = "#{config.endpoint}/api/v1/repos/#{config.owner}/#{config.repo}/issues/#{number}"

    case Req.get(url, headers: headers, connect_options: [timeout: 30_000]) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, body}

      {:ok, response} ->
        Logger.error("Gitea get_issue failed status=#{response.status}")
        {:error, {:gitea_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Gitea get_issue request failed: #{inspect(reason)}")
        {:error, {:gitea_api_request, reason}}
    end
  end

  defp do_create_comment(config, number, body, headers) do
    url =
      "#{config.endpoint}/api/v1/repos/#{config.owner}/#{config.repo}/issues/#{number}/comments"

    case Req.post(url,
           headers: headers,
           json: %{"body" => body},
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 201, body: _body}} ->
        :ok

      {:ok, response} ->
        Logger.error("Gitea create_comment failed status=#{response.status}")
        {:error, {:gitea_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Gitea create_comment request failed: #{inspect(reason)}")
        {:error, {:gitea_api_request, reason}}
    end
  end

  defp do_update_issue(config, number, attrs, headers) do
    url = "#{config.endpoint}/api/v1/repos/#{config.owner}/#{config.repo}/issues/#{number}"

    case Req.patch(url,
           headers: headers,
           json: attrs,
           connect_options: [timeout: 30_000]
         ) do
      {:ok, %{status: 200, body: _body}} ->
        :ok

      {:ok, response} ->
        Logger.error("Gitea update_issue failed status=#{response.status}")
        {:error, {:gitea_api_status, response.status}}

      {:error, reason} ->
        Logger.error("Gitea update_issue request failed: #{inspect(reason)}")
        {:error, {:gitea_api_request, reason}}
    end
  end

  defp build_list_url(config, opts, page) do
    base = "#{config.endpoint}/api/v1/repos/#{config.owner}/#{config.repo}/issues"

    query_params =
      [page: page, limit: @page_size] ++
        Enum.flat_map(Keyword.take(opts, [:state, :labels]), fn {key, value} ->
          [{key, value}]
        end)

    query =
      query_params
      |> Enum.map(fn {key, value} -> "#{key}=#{URI.encode(to_string(value))}" end)
      |> Enum.join("&")

    "#{base}?#{query}"
  end

  defp gitea_config do
    tracker = Config.settings!().tracker

    cond do
      is_nil(tracker.api_key) ->
        {:error, :missing_gitea_api_token}

      is_nil(tracker.owner) or is_nil(tracker.repo) ->
        {:error, :missing_gitea_repo_config}

      true ->
        {:ok,
         %{
           endpoint: String.trim_trailing(tracker.endpoint, "/"),
           owner: tracker.owner,
           repo: tracker.repo
         }}
    end
  end

  defp auth_headers do
    api_key = Config.settings!().tracker.api_key

    {:ok,
     [
       {"Authorization", "token #{api_key}"},
       {"Content-Type", "application/json"}
     ]}
  end

  defp to_integer(value) when is_integer(value), do: value

  defp to_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {int, _} -> int
      :error -> value
    end
  end

  defp map_gitea_state("open"), do: first_active_state()
  defp map_gitea_state("closed"), do: first_terminal_state()
  defp map_gitea_state(_other), do: nil

  defp first_active_state do
    Config.settings!().tracker.active_states |> List.first()
  end

  defp first_terminal_state do
    Config.settings!().tracker.terminal_states |> List.first()
  end

  defp extract_assignee_id(%{"assignee" => %{"id" => id}}) when not is_nil(id),
    do: to_string(id)

  defp extract_assignee_id(_issue), do: nil

  defp extract_labels(%{"labels" => labels}) when is_list(labels) do
    labels
    |> Enum.map(& &1["name"])
    |> Enum.reject(&is_nil/1)
    |> Enum.map(&String.downcase/1)
  end

  defp extract_labels(_issue), do: []

  defp parse_datetime(nil), do: nil

  defp parse_datetime(raw) do
    case DateTime.from_iso8601(raw) do
      {:ok, dt, _offset} -> dt
      _ -> nil
    end
  end
end
