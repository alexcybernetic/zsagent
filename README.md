# zsagent: Z Shell Agent

## What it is and what it is not

zsagent is a zsh plugin, the file `zsagent.plugin.zsh`. It POSTs the session history with `curl` as `input` to an OpenAI Responses API endpoint and runs the `shell` tool calls of the response with `eval` in the interactive zsh that loaded the plugin.

It is:

- **a prototype** for experiments and for studying unrestricted model behavior.
- **minimal:** one zsh file of about 30 KB.
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
2. Download zsagent and extract it into the directory:
   ```zsh
   curl -fsSL https://github.com/alexcybernetic/zsagent/archive/refs/heads/main.tar.gz | tar -xz -C ~/.zsagent --strip-components 1
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
| `ZSAGENT_DIM` | Escape sequence for reasoning, `▸` command lines and the footer; default `$'\e[2m'` (faint: the text color, dimmed), e.g. `$'\e[38;5;245m'` for grey |
| `ZSAGENT_HOME` | Directory of `config.zsh` and `sessions/`; default `~/.zsagent`; set before `source` |
| `ZSAGENT_OUTPUT_LIMIT` | Characters of a command's output that the model gets; of longer output it gets the start and the end and a note on what was left out; the terminal shows all of it; default `30000`, `0`: no limit |
| `ZSAGENT_MAX_ROUNDS` | Requests per turn, `1` to `500`; then the turn stops with an error, and the next message continues; default `100` |
| `ZSAGENT_CONNECT_TIMEOUT` | Seconds to connect to the API; default `30` |
| `ZSAGENT_STALL_TIMEOUT` | Seconds a response may send nothing before it is aborted; default `600`, `0`: no limit |

zsagent reads `config.zsh` again by itself before each `zsagent` command (and each message) when the file changed since it was read. `zsagent --reload` reads it at once.

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

1. Download zsagent and extract it over `~/.zsagent`:
   ```zsh
   curl -fsSL https://github.com/alexcybernetic/zsagent/archive/refs/heads/main.tar.gz | tar -xz -C ~/.zsagent --strip-components 1
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
| `zsagent <text>` | Sends the arguments, joined with spaces, as a user message; without text (or only blanks) it fails and sends nothing |
| `zsagent -- <text>` | The same, for text that starts with `--` |
| `zsagent --profile` | Lists the profiles: name, provider, model, url |
| `zsagent --profile <name>` | Sets the shell's profile and a new session id |
| `zsagent --sessions` | Lists the session files: id prefix, profile, modification time, number of user messages, first user message |
| `zsagent --resume <id>` | Sets the shell's session id and profile from the one session file whose id starts with `<id>`; fails if none or several match |
| `zsagent --new` | Sets a new session id; the profile stays, the previous session file is kept |
| `zsagent --clear` | Deletes the session file of the current session id and profile; fails while a turn holds the lock |
| `zsagent --reload` | Reads `config.zsh` again; zsagent also does this by itself when the file changed |
| `zsagent --version` | Prints `ZSAGENT_VERSION` |
| `zsagent --help` | Prints a usage summary of the options |
| Ctrl+C | Ends the running request or command and prints `interrupted`. The interrupted command gets an output that says it may have taken effect, with what it printed until then; the calls of the response not yet run get `not run: …`. If a turn ends without that (e.g. a closed terminal), the next turn gives each call without output `no result recorded: …` |

### Sessions

- The session id (UUID), is created when the plugin is loaded in a shell; it is kept when the plugin is sourced again.
- A session is the file `~/.zsagent/sessions/<id>.<profile>.json`, a JSON array.
- It holds the system prompt, each user message, each API output item without null fields, and each tool output as `exit code <N>` plus the command's output. A tool call that cannot be run (another tool than `shell`, arguments that are not a JSON object with a non-empty string `command`) is not run; its output is `error: <reason>; nothing was run`.
- zsagent sets the sessions directory to mode 700 and the file to mode 600 at every turn. Other user accounts can't read it; processes of the same user account, including the model's commands, and root can.
- Several shells can use the same session, but only one turn at a time: a turn takes a lock on `<id>.<profile>.lock` (an fcntl lock, `zsystem flock`), and a turn started meanwhile, from another shell or by a tool call in the same shell, fails with an error. The system releases the lock when the shell ends, so a lock is never left behind.

### Data and secrets

What zsagent stores and sends, and where secrets can end up:

| Data | Where it goes | How long |
|---|---|---|
| Messages, commands, command output, model output | The session file, and the API provider with every request of the session | Until you delete the session (`zsagent --clear` or `rm`) |
| Message-mode lines | The zsh history (`$HISTFILE`), except lines with a leading space when `HIST_IGNORE_SPACE` is set | As your history keeps them |
| The raw response stream and the output of the running command | Temp files from `mktemp` (mode 600) | Deleted at the end of the turn |
| API keys | `config.zsh` and the shell variable `ZSAGENT_PROFILES`; the model's commands can read both | As long as they are there |

- Before a command's output is saved or sent, zsagent replaces each profile key (8 or more characters) in it with `[API key removed by zsagent]`. Other secrets in the output, e.g. tokens, passwords, or the contents of `.env` files, are saved and sent as they are.
- When the plugin loads, it warns if other users can read `config.zsh`. Create it with mode 600 (see Install), or run `chmod 600 ~/.zsagent/config.zsh`.
- The terminal shows each command before it runs; zsagent does not hide commands, even ones with secrets in them.

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

## Tests

```zsh
zsh -f tests/run.zsh            # all tests
zsh -f tests/run.zsh test_name  # selected tests
```

Each test runs in a new `zsh -f` with its own `ZSAGENT_HOME`. A `curl` function replaces the API: it records each request and replays a prepared event stream, so the tests need no network and no key.

## License

[MIT](LICENSE)
