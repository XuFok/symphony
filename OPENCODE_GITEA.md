# Symphony: OpenCode + Gitea 集成指南

本文档介绍如何配置 Symphony 使用 OpenCode 作为 agent backend，Gitea 作为 issue tracker。

## 前置要求

### 1. 安装依赖

```bash
cd /home/xufo1412/github/symphony/elixir

# 安装 mise (版本管理器)
curl https://mise.jdx.dev/install.sh | sh

# 安装 Elixir/Erlang
mise trust
mise install
mise exec -- elixir --version

# 安装项目依赖
mise exec -- mix setup
mise exec -- mix build
```

### 2. 配置 Gitea

确保你已经有一个 Gitea 实例（例如：`http://192.168.5.50:4000`），并且：

1. 创建一个仓库（例如：`AI-APP/TestSymphony`）
2. 生成 API Token（Settings → Applications → Generate Token）
3. 配置 Git 凭据（用于工作区 clone）

```bash
git config --global user.name "Your Name"
git config --global user.email "your@email.com"
git config --global credential.helper store
```

### 3. 安装 OpenCode

确保 OpenCode CLI 已安装并配置 API Key：

```bash
opencode --version
export OPENCODE_API_KEY=your-opencode-api-key
```

## WORKFLOW.md 配置

以下是一个完整的 `WORKFLOW.md` 配置示例：

```yaml
---
tracker:
  kind: gitea
  api_key: $GITEA_API_KEY
  endpoint: http://192.168.5.50:4000
  owner: AI-APP
  repo: TestSymphony
  active_states:
    - open
  terminal_states:
    - closed

polling:
  interval_ms: 30000

workspace:
  root: ~/code/symphony-workspaces

hooks:
  after_create: |
    git clone --depth 1 http://user:password@192.168.5.50:4000/AI-APP/TestSymphony.git .
  before_run: |
    mise trust
    mise exec -- mix deps.get

agent:
  backend: opencode
  max_turns: 20
  max_concurrent_agents: 10

opencode:
  command: opencode acp
  agent: build
  turn_timeout_ms: 3600000
  read_timeout_ms: 5000
  stall_timeout_ms: 300000
---

You are working on issue {{ issue.identifier }}.

Title: {{ issue.title }}
Body: {{ issue.description }}

# Context

- This is a self-contained workspace with its own Git repository
- You have full access to the workspace files
- Changes should be committed and pushed back to the repository

# Instructions

1. Analyze the issue requirements
2. Implement the necessary changes
3. Test your changes
4. Commit with a descriptive message
5. Push to the repository
6. Update the issue status to "closed" when done

# Available Tools

- Git commands (commit, push, etc.)
- File operations (read, write, edit)
- Build and test commands

# Notes

- Use `mise exec --` for any build/test commands
- Ensure all tests pass before marking the issue as complete
```

## 配置说明

### Tracker (Gitea)

| 字段 | 说明 | 示例 |
|------|------|------|
| `kind` | Tracker 类型 | `gitea` |
| `api_key` | Gitea API Token | `$GITEA_API_KEY` |
| `endpoint` | Gitea 实例 URL | `http://192.168.5.50:4000` |
| `owner` | 仓库所有者 | `AI-APP` |
| `repo` | 仓库名称 | `TestSymphony` |
| `active_states` | 活跃状态 | `["open"]` |
| `terminal_states` | 终止状态 | `["closed"]` |

### Agent (OpenCode)

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `backend` | Agent 后端 | `codex` (可选: `opencode`) |
| `max_turns` | 最大对话轮次 | `20` |
| `max_concurrent_agents` | 最大并发数 | `10` |

### OpenCode 配置

| 字段 | 说明 | 默认值 |
|------|------|--------|
| `command` | OpenCode 启动命令 | `opencode acp` |
| `agent` | 使用的 agent | `build` |
| `turn_timeout_ms` | 单轮超时 | `3600000` (1小时) |
| `read_timeout_ms` | 读取超时 | `5000` (5秒) |
| `stall_timeout_ms` | 停滞超时 | `300000` (5分钟) |

## 启动 Symphony

### 基本启动

```bash
export GITEA_API_KEY=d132c6eacd09d2b0012844b592a5da839b3dc16a
export OPENCODE_API_KEY=your-opencode-api-key

./bin/symphony ./WORKFLOW.md --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

### 带 Web 仪表板启动

```bash
./bin/symphony ./WORKFLOW.md \
  --port 4000 \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

访问 `http://localhost:4000` 查看 Web 仪表板。

### 自定义日志目录

```bash
./bin/symphony ./WORKFLOW.md \
  --logs-root ~/symphony-logs \
  --i-understand-that-this-will-be-running-without-the-usual-guardrails
```

## 工作流程

1. **Polling Gitea** - Symphony 每 30 秒轮询 Gitea 获取 `open` 状态的 issue
2. **创建工作区** - 为每个 issue 创建独立工作区
3. **Git Clone** - 通过 `after_create` hook 克隆仓库到工作区
4. **启动 OpenCode** - 在工作区启动 OpenCode ACP agent
5. **执行任务** - OpenCode 分析并执行任务
6. **提交代码** - OpenCode 提交更改到仓库
7. **关闭 Issue** - 更新 issue 状态为 `closed`
8. **清理工作区** - 删除工作区目录

## 状态仪表板

运行 Symphony 后，终端会显示实时状态仪表板：

```
Symphony v0.0.0 (db5cd76) | poll: 30s | workers: 1/10 | tokens: in 81 | out 74 | total 155

Running:
┌──────────────────────────────────────────────────────────────────────────────┐
│ ● GITEA-1 │ open │ 28220 │ 00:05:23 T1 │ in 81 | out 74 | total 155 │ ses_... │ :tool_call_completed │ tool: bash, cmd: git status  │
└──────────────────────────────────────────────────────────────────────────────┘

Gitea: http://192.168.5.50:4000/AI-APP/TestSymphony
Next poll in: 28s
```

### 字段说明

| 字段 | 说明 |
|------|------|
| `●` | 状态指示器（● 运行中，○ 空闲） |
| `GITEA-1` | Issue 标识符 |
| `open` | Issue 状态 |
| `28220` | OpenCode 进程 PID |
| `00:05:23 T1` | 运行时间和对话轮次 |
| `in/out/total` | Token 消耗（输入/输出/总计） |
| `ses_...` | Session ID（截断显示） |
| `:tool_call_completed` | 最后事件类型 |
| `tool: bash...` | 事件详情 |

### 事件类型

- `:agent_message_delta` - Agent 输出
- `:tool_call_started` - 工具调用开始
- `:tool_call_completed` - 工具调用完成
- `:file_operation_started` - 文件操作开始
- `:file_operation_completed` - 文件操作完成
- `:notification` - 其他通知

## 工作区管理

### 工作区位置

工作区默认位于 `~/code/symphony-workspaces/<issue-identifier>/`

```
~/code/symphony-workspaces/
├── GITEA-1/
│   ├── .git/
│   ├── README.md
│   └── ...
└── GITEA-2/
    ├── .git/
    └── ...
```

### 工作区生命周期

1. **创建** - Issue 被 dispatch 时创建
2. **执行** - OpenCode 在工作区中执行任务
3. **清理** - Issue 状态变为 `closed` 时自动删除

### 手动清理工作区

```bash
cd /home/xufo1412/github/symphony/elixir
mise exec -- mix workspace.before_remove /home/xufo1412/code/symphony-workspaces/GITEA-1
```

## 并发支持

Symphony 支持并发执行多个 issue：

```yaml
agent:
  max_concurrent_agents: 10
```

- 每个 issue 独立的工作区
- 每个 issue 独立的 OpenCode 进程
- 互不干扰，隔离执行

## 故障排查

### 1. Git Clone 失败

**错误**：`could not read Username for 'http://...'`

**解决方案**：在 WORKFLOW.md 的 `after_create` hook 中嵌入凭据：

```yaml
after_create: |
  git clone --depth 1 http://user:password@gitea.example.com/owner/repo.git .
```

或者配置 Git credential helper：

```bash
git config --global credential.helper store
git clone http://gitea.example.com/owner/repo.git
# 输入用户名和密码
```

### 2. OpenCode 连接失败

**错误**：`Agent run failed: :response_timeout`

**解决方案**：
- 检查 `OPENCODE_API_KEY` 是否设置
- 检查 OpenCode CLI 是否可用：`opencode --version`
- 增加 `turn_timeout_ms` 配置

### 3. PID 显示 `n/a`

**错误**：仪表盘显示 `n/a` 而不是 PID

**解决方案**：这是正常的，PID 会在 OpenCode 进程启动后显示。如果一直显示 `n/a`，检查日志是否有错误。

### 4. Token 计数不正确

**错误**：显示 `in 81 | out 74 | total 25590`（81 + 74 ≠ 25590）

**解决方案**：这个问题已修复。重新编译即可：

```bash
mise exec -- mix clean && mise exec -- mix compile && mise exec -- mix build
```

### 5. 事件一直显示 `:notification`

**错误**：所有事件都显示为通用的 `:notification` 而不是具体类型

**解决方案**：这个问题已修复。重新编译并重启 Symphony 即可。

## 代码示例

### 简单 WORKFLOW.md

```yaml
---
tracker:
  kind: gitea
  api_key: $GITEA_API_KEY
  endpoint: http://gitea.example.com
  owner: myorg
  repo: myrepo
  active_states: ["open"]
  terminal_states: ["closed"]

agent:
  backend: opencode
  max_turns: 10

workspace:
  root: ~/code/symphony-workspaces

hooks:
  after_create: |
    git clone --depth 1 http://user:pass@gitea.example.com/myorg/myrepo.git .
---

You are working on issue {{ issue.identifier }}.

{{ issue.title }}

{{ issue.description }}

Please implement this feature and push the changes.
```

### 高级 WORKFLOW.md（多项目）

使用 `symphony.yml` 进行全局配置，每个项目有自己的 `WORKFLOW.md`。

**symphony.yml**:

```yaml
tracker:
  kind: gitea
  api_key: $GITEA_API_KEY
  endpoint: http://gitea.example.com

workspace:
  root: ~/code/symphony-workspaces

agent:
  backend: opencode
  max_concurrent_agents: 10

projects:
  - gitea_project: "project-a"
    repo: http://gitea.example.com/org/project-a.git
    workflow: /path/to/project-a/WORKFLOW.md
  - gitea_project: "project-b"
    repo: http://gitea.example.com/org/project-b.git
    workflow: /path/to/project-b/WORKFLOW.md
```

## 与 Codex + Linear 的对比

| 特性 | Codex + Linear | OpenCode + Gitea |
|------|----------------|------------------|
| Agent Backend | Codex app-server | OpenCode ACP |
| Issue Tracker | Linear (SaaS) | Gitea (自托管) |
| 协议 | Codex JSON-RPC | ACP JSON-RPC 2.0 |
| Token 格式 | `%{input_tokens: N}` | `%{"inputTokens": N}` |
| 工作区清理 | 自动 | 自动 |
| Web 仪表板 | 支持 | 支持 |
| SSH Workers | 支持 | 不支持 |

## API 参考

### Tracker Behaviour

Gitea adapter 实现了 `SymphonyElixir.Tracker` behaviour：

```elixir
@callback fetch_candidate_issues() :: [Issue.t()]
@callback fetch_issues_by_states([String.t()]) :: [Issue.t()]
@callback fetch_issue_states_by_ids([String.t()]) :: [%{id: String.t(), state: String.t()}]
@callback create_comment(String.t(), String.t()) :: :ok | {:error, term()}
@callback update_issue_state(String.t(), String.t()) :: :ok | {:error, term()}
```

### OpenCode ACP Client

ACP client 提供与 Codex AppServer 相同的 API：

```elixir
@spec start_session(workspace :: String.t(), opts :: keyword()) ::
  {:ok, session} | {:error, term()}

@spec run_turn(session, String.t(), keyword()) ::
  {:ok, result} | {:error, term()}

@spec stop_session(session) :: :ok
```

## 后续优化方向

1. **MCP 服务器支持** - 为 OpenCode 添加 MCP 服务器集成
2. **Gitea Webhook** - 实时同步 issue 变更，减少轮询
3. **标签路由** - 通过 Gitea 标签选择 agent backend 或推理强度
4. **工作区保留** - 可选配置，失败时保留工作区便于调试

## 许可证

Apache License 2.0

## 贡献

欢迎提交 PR 和 Issue！

## 相关资源

- [Symphony SPEC.md](../SPEC.md) - 语言无关的规范
- [Symphony README.md](../README.md) - 项目总览
- [Agent Client Protocol](https://agentclientprotocol.com/) - ACP 规范
- [Gitea API 文档](https://docs.gitea.com/en/next/api) - Gitea REST API