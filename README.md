# zsagent: Z Shell Agent

## What it is and what it is not

zsagent is a zsh plugin, the file `zsagent.plugin.zsh`. It POSTs the session history with `curl` as `input` to an OpenAI Responses API endpoint and runs the `shell` tool calls of the response with `eval` in the interactive zsh that loaded the plugin.

It is:

- **a prototype** for experiments and for studying unrestricted model behavior.
- **minimal:** one zsh file of about 20 KB.
- **agentic:** zsagent runs each `shell` tool call of the model in that shell and sends the output back, until a response contains no tool call.
- **portable:** runtime dependencies are zsh, `curl`, `jq`, and `uuidgen` or `/proc`.
- **transparent:** the session file is the complete history as a JSON array: the `system` item, the `user` items, the API output items (`reasoning`, `message`, `function_call`) and the `function_call_output` items. It is exactly the `input` of the next request.
- **using what the environment provides:** each request defines one function tool, `shell`; its calls run with `eval` in that shell.

It is not:

- **It is not** a coding agent.
- **It is not** restricted: the unrestricted implementation is intentional.
- **It is not** for production environments, or for machines and accounts with sensitive data.

## Warning

> [!WARNING]
> - The model's commands run in the zsh process, with the user's permissions, without confirmation.
> - They can read all shell variables, including the API keys in `ZSAGENT_PROFILES`.
> - A model command runs in the zsh process, so `exit` or `logout` in it would end that process. While a model command runs, zsagent therefore replaces both with functions.
> - These functions print `zsagent: exit is blocked` and return status 1. Inside a subshell of the command, e.g. `(cd x || exit 1)`, they run the real `exit`, which ends only that subshell.
> - Other commands, e.g. `kill $$` or `exec`, can still end the zsh process.

## Installation

### Requirements

- zsh, `curl`, `jq`, `tar`
- `uuidgen` (macOS) or `/proc/sys/kernel/random/uuid` (Linux)
- an OpenAI API key, or a server with an OpenAI-compatible Responses API (`/v1/responses`) with streaming and function tools, e.g. LM Studio

Tested on macOS 27 with zsh 5.9 and jq 1.7.1.

### Install

1. Create the directory:
   ```zsh
   mkdir -p ~/.zsagent
   ```
2. Download and extract the release into it:
   ```zsh
   curl -fsSL https://github.com/alexcybernetic/zsagent/archive/refs/tags/v0.1.1.tar.gz | tar -xz -C ~/.zsagent --strip-components 1
   ```
3. Create the config with mode 600:
   ```zsh
   (umask 077; cp ~/.zsagent/config.zsh.example ~/.zsagent/config.zsh)
   ```
4. Fill in the profiles in `~/.zsagent/config.zsh`.
5. Load the plugin in every new shell:
   ```zsh
   echo 'source ~/.zsagent/zsagent.plugin.zsh' >> ~/.zshrc
   ```
6. Open a new shell.

### Configuration

The plugin sources `$ZSAGENT_HOME/config.zsh` when it is loaded. [`config.zsh.example`](config.zsh.example) lists every setting.

| Variable | Meaning |
|---|---|
| `ZSAGENT_PROFILES` | The profiles, as one JSON object |
| `ZSAGENT_PROFILE` | The profile of a new shell; empty: the first key of `ZSAGENT_PROFILES` |
| `ZSAGENT_SYSTEM` | Replaces the built-in system prompt and the appended system information; written as first item of new sessions |
| `ZSAGENT_MESSAGE_PS1` | Replaces `PS1` in message mode; default `👾 %# ` |
| `ZSAGENT_HOME` | Directory of `config.zsh` and `sessions/`; default `~/.zsagent`; set before `source` |

To apply a change of `config.zsh` in a running shell:

1. Load the plugin again:
   ```zsh
   source ~/.zsagent/zsagent.plugin.zsh
   ```

### Profiles

```zsh
ZSAGENT_PROFILES='{
  "openai":   {"provider": "openai", "key": "sk-proj-...", "model": "gpt-6-sol"},
  "lmstudio": {"provider": "custom", "url": "http://localhost:1234/v1/responses", "key": "sk-lm-...", "model": "qwen/qwen3.8-27b"}
}'
ZSAGENT_PROFILE=openai
```

| Field | Meaning |
|---|---|
| `provider` | `openai`: requests go to `https://api.openai.com/v1/responses`. `custom`: requests go to `url` |
| `url` | Endpoint of a `custom` profile; required there |
| `key` | Sent as header `Authorization: Bearer <key>`, read by `curl` from a process substitution, not from its arguments |
| `model` | Value of `model` in the request; required |
| `options` | JSON object merged into the request with jq `+`; its fields override `model`, `input`, `tools` and `stream` |

`ZSAGENT_PROFILES` is a zsh string in single quotes, so the JSON contains no single quote.

### Uninstall

1. Remove the line `source ~/.zsagent/zsagent.plugin.zsh` from `~/.zshrc`.
2. Delete `~/.zsagent`. It holds the extracted files, `config.zsh` and `sessions/`:
   ```zsh
   rm -rf ~/.zsagent
   ```
3. If `ZSAGENT_HOME` points to another directory, delete that directory.
4. End the shells that loaded the plugin.

Message-mode lines remain in the zsh history file `$HISTFILE`.

## Update

1. Download and extract the new version over `~/.zsagent`, with `<version>` e.g. `0.1.1`:
   ```zsh
   curl -fsSL https://github.com/alexcybernetic/zsagent/archive/refs/tags/v<version>.tar.gz | tar -xz -C ~/.zsagent --strip-components 1
   ```
2. Open a new shell.

`config.zsh` and `sessions/` are not part of the download and stay unchanged.

## Usage

```
% ls                                   ← command mode
Documents  Downloads  Music
👾 % what takes the most space here?   ← message mode
▸ du -sh * | sort -h | tail -3
4.2G  Music
11G   Downloads
Downloads, with 11 GB.
3.1s · 1840 in · 52 out
```

### Modes

- **Command mode:** Enter runs the line in zsh.
- **Message mode:** Enter sends the line as a user message, prefixed with `[<time> · <working directory>]`.
- **Shift+Tab** (`^[[Z`) switches between command and message mode and redraws the prompt.
- Loading the plugin sets command mode.

### Commands

| Command | What it does |
|---|---|
| `zsagent <text>` | Sends the arguments, joined with spaces, as a user message |
| `zsagent -- <text>` | The same, for text that starts with `--` |
| `zsagent --profile` | Lists the profiles: name, provider, model, url |
| `zsagent --profile <name>` | Sets the shell's profile and a new session id |
| `zsagent --sessions` | Lists the session files: id prefix, profile, modification time, number of user messages, first user message |
| `zsagent --resume <id>` | Sets the shell's session id and profile from the one session file whose id starts with `<id>`; fails if none or several match |
| `zsagent --version` | Prints `ZSAGENT_VERSION` |
| Ctrl+C | Ends the running request or command and prints `interrupted`; the next turn adds the output `Interrupted by the user.` to tool calls without output |

### Sessions

- The session id (UUID), is created when the plugin is loaded in a shell; it is kept when the plugin is sourced again.
- A session is the file `~/.zsagent/sessions/<id>.<profile>.json`, a JSON array.
- It holds the system prompt, each user message, each API output item without null fields, and each tool output as `exit code <N>` plus the command's output.
- zsagent sets the sessions directory to mode 700 and the file to mode 600 at every turn. Other user accounts can't read it; processes of the same user account, including the model's commands, and root can.
- Several shells can use the same session, but only one turn at a time: a turn takes a lock (`<file>.lock` with the shell's process ID), and a turn started meanwhile from another shell fails with an error.

## Point to different versions

Load another copy of zsagent into the current shell, e.g. a working copy, with its own config and sessions:

1. Change into the directory of that copy.
2. Create the directory for its config and sessions:
   ```zsh
   mkdir -p ~/.zsagent-dev
   ```
3. If `~/.zsagent-dev/config.zsh` does not exist, create it and fill in the profiles:
   ```zsh
   (umask 077; cp config.zsh.example ~/.zsagent-dev/config.zsh)
   ```
4. Set the directory and load the copy:
   ```zsh
   ZSAGENT_HOME=~/.zsagent-dev
   source ./zsagent.plugin.zsh
   ```

## License

[MIT](LICENSE)
