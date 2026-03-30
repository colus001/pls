# pls

AI-powered CLI assistant. Type what you want in natural language, and `pls` figures out the shell commands.

```
$ pls 'stop all processes using port 1380'
```

```
$ pls '1380 포트 서비스를 다 멈춰줘'
```

Both work. `pls` understands any language.

## How it works

1. You describe a task in plain text
2. An LLM interprets it and generates shell commands
3. Commands run in a loop: execute, observe output, decide next step
4. Destructive commands (kill, rm, etc.) require your confirmation

**No API key required.** `pls` works out of the box using a free hosted proxy powered by Gemini. No setup, no config — just install and go. Power users can bring their own API key for unlimited usage.

## Install

### Quick install (macOS / Linux)

```bash
curl -sSfL https://raw.githubusercontent.com/colus001/pls/main/install.sh | sh
```

### Homebrew

```bash
brew tap colus001/tap
brew install pls
```

### Build from source

Requires [Zig 0.15+](https://ziglang.org/download/).

```bash
git clone https://github.com/colus001/pls.git && cd pls
zig build -Doptimize=ReleaseFast
cp zig-out/bin/pls ~/.local/bin/
```

Pre-built binaries and `.deb` packages are also available on the [releases page](https://github.com/colus001/pls/releases/latest).

### Update

```bash
brew upgrade pls
```

## Setup

`pls` works immediately after install — no setup needed. The default free tier requires no API key.

To configure a different provider or bring your own API key, run:

```
$ pls init

  Welcome to pls! Let's get you set up.

  Select your LLM provider:
    1) Free tier - no API key needed (default)
    2) Anthropic (Claude)
    3) OpenAI (GPT)
    4) Google Gemini
    5) Ollama (local)

  Choice [1]: _
```

Config is saved to `~/.config/pls/config.toml`.

### Supported providers

| Provider | Auth | Use case |
|----------|------|----------|
| **Free tier (proxy)** | None | Works out of the box, no API key needed |
| **Anthropic** | API key | Best tool-use, recommended for power users |
| **OpenAI** | API key | GPT-4o, widely available |
| **Gemini** | API key | Google's Gemini models |
| **Ollama** | None (local) | Offline, private, free |

### Environment variables

These override the config file:

```bash
export PLS_PROVIDER=gemini        # proxy | anthropic | openai | gemini | ollama
export DO_PROVIDER=gemini         # same as PLS_PROVIDER (legacy alias)
export PLS_CONFIRM=destructive    # all | destructive | none
export PLS_PROXY_URL=https://my-proxy.example.com
export PLS_PROXY_MODEL=gemini-3-flash-preview
export ANTHROPIC_API_KEY=sk-ant-...
export OPENAI_API_KEY=sk-...
export GEMINI_API_KEY=AIza...
export OLLAMA_HOST=http://localhost:11434
export OLLAMA_MODEL=llama3.2
```

## Usage

### Quoting your task

Quotes are **optional** for plain natural language. `pls` collects all non-flag arguments and joins them with spaces, so these two are identical:

```bash
pls 'show disk usage by directory'
pls show disk usage by directory
```

You only need quotes when your task contains **shell special characters** that the shell would interpret before `pls` sees them:

| Character | Example | Why quotes are needed |
|-----------|---------|----------------------|
| `!` | `pls 'fix this bug!'` | History expansion in bash |
| `$` | `pls 'what is $HOME'` | Variable substitution |
| `>` `<` `\|` | `pls 'write output > file'` | Redirection / pipes |
| `(` `)` | `pls 'calculate (a+b)'` | Subshell execution |
| `;` `&&` | `pls 'do this; then that'` | Command separators |

When in doubt, wrapping in single quotes (`'...'`) is always safe.

```bash
# Basic usage
pls 'stop all processes using port 1380'
pls 'find all files larger than 1GB in home directory'
pls 'create a git branch called feature/auth'
pls 'compress all jpg files in this folder'
pls 'show disk usage by directory'

# Skip confirmation prompts
pls -y 'kill process on port 3000'

# Dry run (show commands without executing)
pls --dry-run 'clean up docker containers'

# Override provider or model for one invocation
pls --provider openai --model gpt-4o 'explain this error'

# Pipe a task from stdin
echo 'find large files over 1GB' | pls
```

## CLI reference

```
pls <task>                   Run a natural language task
pls init                     Interactive setup wizard
pls config                   Interactive config editor
pls config show              Show active configuration

--confirm <mode>             Confirmation mode: all | destructive | none
--yes, -y                    Shorthand for --confirm=none
--provider <name>            Override LLM provider (proxy, anthropic, openai, gemini, ollama)
--model <name>               Override model name for this invocation
--max-turns <n>              Maximum agent turns (default: 20)
--dry-run                    Show commands without executing them
--version, -v                Show version
--help, -h                   Show this help

Piping:
  echo 'your task' | pls
```

## Config file

`~/.config/pls/config.toml`:

```toml
provider = "proxy"
confirm_mode = "all"          # all | destructive | none

# Proxy settings (optional, defaults shown)
# proxy_url = "https://pls-proxy.seokjun.kim"
# proxy_model = "gemini-3-flash-preview"

anthropic_api_key = "sk-ant-..."
anthropic_model = "claude-sonnet-4-5-20250514"

openai_api_key = "sk-..."
openai_model = "gpt-4o"

gemini_api_key = "AIza..."
gemini_model = "gemini-2.5-flash"

ollama_host = "http://localhost:11434"
ollama_model = "llama3.1"
```

## Safety

- Destructive commands (`kill`, `rm`, `rmdir`, `dd`, `shutdown`, etc.) trigger a confirmation prompt
- Use `--dry-run` to preview what commands would run
- Use `-y` to skip confirmations (power users only)
- The agent loop is capped at 20 turns to prevent runaway execution

## Self-hosting the proxy

You can self-host your own proxy to remove rate limits or use a different model.

### Proxy protocol

The proxy is a simple passthrough that forwards requests to the Google Gemini API. It speaks the [Gemini REST API](https://ai.google.dev/api/generate-content) format natively:

**Endpoint:**

```
POST /v1beta/models/{model}:generateContent
Content-Type: application/json
```

**Request body:** Standard Gemini `generateContent` request (with `system_instruction`, `contents`, and `tools` fields).

**Response:** Standard Gemini `generateContent` response, passed through unmodified.

The proxy's only responsibilities:
1. Inject the Gemini API key (so clients don't need one)
2. Rate limiting / abuse prevention

### Deploy your own

A reference implementation using Cloudflare Workers is available. Once deployed, configure `pls` to use your proxy:

```bash
export PLS_PROXY_URL=https://your-proxy.example.com
```

Or in `~/.config/pls/config.toml`:

```toml
proxy_url = "https://your-proxy.example.com"
```

## Architecture

Written in Zig 0.15. Single binary, no runtime dependencies.

```
src/
  main.zig              Entry point, arg parsing, subcommand routing
  agent.zig             Tool-calling loop (LLM -> tool -> observe -> repeat)
  config.zig            Config file parsing (~/.config/pls/config.toml)
  config_editor.zig     Interactive config editor (terminal UI)
  init.zig              Interactive setup wizard
  tty.zig               TTY helpers (readLine, readLineMasked with echo off)
  llm/
    provider.zig        Shared types (Message, Tool, ToolCall, etc.)
    anthropic.zig       Anthropic Claude API
    openai.zig          OpenAI GPT API
    gemini.zig          Google Gemini API (also used by proxy provider)
    ollama.zig          Ollama local API (delegates to openai.zig format)
    http_client.zig     HTTP POST helper using std.http.Client
    json_helpers.zig    JSON serialization for API request bodies
  tools/
    shell.zig           Shell command execution via /bin/sh
    confirm.zig         ask() y/N prompt and askUser() numbered options
```

## License

MIT
