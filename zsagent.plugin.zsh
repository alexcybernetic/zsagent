# zsagent (Z Shell Agent): connects a language model to the user's interactive zsh, unrestricted; curl + jq against an LLM API.

# Aliases are expanded when a function is defined, so the user's aliases (mv -i, global aliases) would end up in
# the functions below: alias expansion is off while this file is read (quoted words are never expanded).
'builtin' 'typeset' '-g' '_zsagent_aliases=0'
[[ -o aliases ]] && _zsagent_aliases=1
'builtin' 'setopt' 'no_aliases'

ZSAGENT_VERSION=0.1.5
ZSAGENT_HOME=${ZSAGENT_HOME:-~/.zsagent}  # directory of config.zsh and sessions/; set it before the plugin loads
_zsagent_system="You are a language model connected to the user's interactive zsh by zsagent (Z Shell Agent). \
The user writes to you from the shell prompt. With the shell tool you run commands directly in that shell, \
without confirmation; cd, exports and variables persist. Keep answers short.

Sessions: every conversation is stored in $ZSAGENT_HOME/sessions/<id>.<profile>.json (JSON array of API items). \
\`zsagent --sessions\` lists them; \`zsagent --resume <id>\` switches the user's shell to a session from the next message on. \
\`zsagent --profile [name]\` lists the LLM profiles or switches to one (with a new session). \
\`zsagent --new\` starts a new session; \`zsagent --clear\` deletes the history of the current session. \
To look into an old session without switching, read its file with jq."
zmodload zsh/datetime  # $EPOCHREALTIME, $EPOCHSECONDS and strftime
zmodload -F zsh/stat b:zstat  # zstat for file times (without replacing the stat command)
zmodload -F zsh/system b:zsystem  # zsystem flock for the session locks

# Set the defaults, then the user's settings from config.zsh over them. Runs when the plugin loads, on
# `zsagent --reload`, and before each zsagent command when config.zsh changed since it was read.
# config.zsh runs inside this function: plain assignments are global, `typeset` without -g would be local.
_zsagent_load_config() {
  local conf=$ZSAGENT_HOME/config.zsh
  ZSAGENT_PROFILES=  # JSON object of named profiles (provider, url, key, model, options); see config.zsh.example
  ZSAGENT_PROFILE=   # the profile to use; empty: the first profile
  ZSAGENT_SYSTEM=    # replaces the complete built-in system prompt (including the system information)
  ZSAGENT_MESSAGE_PS1='👾 %# '  # message mode: replaces PS1, so the mode is visible
  ZSAGENT_DIM=$'\e[2m'  # style of reasoning, commands and the footer: faint, i.e. the text color dimmed
  # Limits (whole numbers).
  ZSAGENT_OUTPUT_LIMIT=30000   # characters of a command's output the model gets; longer output loses its middle; 0: no limit
  ZSAGENT_MAX_ROUNDS=100       # requests per turn (1-500); then the turn stops, and a new message continues it
  ZSAGENT_CONNECT_TIMEOUT=30   # seconds to connect to the API
  ZSAGENT_STALL_TIMEOUT=600    # seconds a response may send nothing before it is aborted; 0: no limit
  _zsagent_config_stamp=
  if [[ -f $conf ]]; then
    source "$conf"
    _zsagent_stamp "$conf" warn
    _zsagent_config_stamp=$REPLY
  fi
  _zsagent_use_config_profile
  return 0
}

# The functions that run code of the user or the model keep the user's options and aliases: _zsagent_load_config
# (config.zsh), zsagent, _zsagent_rounds and _zsagent_calls (the model's commands), _zsagent_run and
# _zsagent_accept_line. They quote their expansions and contain no $(...), which is parsed when it runs, with the
# user's aliases. All other functions start with `emulate -L zsh -o noaliases` and do that work for them.

# Time and size of file $1 in REPLY (empty if there is none), to see whether it changed. With $2, warn when other
# users can read the file: config.zsh holds the API keys.
_zsagent_stamp() {
  emulate -L zsh -o noaliases
  local -A st
  REPLY=
  zstat -H st $1 2>/dev/null || return 0
  REPLY=$st[mtime]/$st[size]
  [[ -z $2 ]] || (( ! (st[mode] & 8#077) )) ||
    print -r -- "zsagent: other users can read $1, which holds API keys; chmod 600 it" >&2
  return 0
}

# Whenever config.zsh is read, the profile of this shell (_zsagent_profile) is the one it names: ZSAGENT_PROFILE,
# else the first profile. `zsagent --profile` and `--resume` set another one until config.zsh is read again.
_zsagent_use_config_profile() {
  emulate -L zsh -o noaliases
  _zsagent_profile=$ZSAGENT_PROFILE
  [[ -n $_zsagent_profile ]] ||
    _zsagent_profile=$(jq -r 'keys_unsorted[0] // empty' <<< $ZSAGENT_PROFILES 2>/dev/null)
}

# Read config.zsh again if it changed (time or size) since it was read.
_zsagent_reload_if_changed() {
  _zsagent_stamp "$ZSAGENT_HOME/config.zsh"
  [[ $REPLY == "$_zsagent_config_stamp" ]] && return 0
  local was="$_zsagent_profile"
  _zsagent_load_config
  [[ $was == "$_zsagent_profile" ]] ||
    print -r -- "zsagent: config.zsh changed: profile $_zsagent_profile (was $was)" >&2
}
_zsagent_load_config
# A new session id: a UUID from uuidgen (macOS) or the kernel (Linux).
_zsagent_new_id() {
  emulate -L zsh -o noaliases
  REPLY=${(L)$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
}
# One session id per shell; it survives sourcing the plugin again.
[[ -n ${ZSAGENT_SESSION-} ]] || { _zsagent_new_id; ZSAGENT_SESSION=$REPLY }

ZSAGENT_TOOLS='[{"type": "function", "name": "shell",
  "description": "Run a command in the interactive zsh of the user. Same session: cd, exports and variable assignments persist. The command runs inside a function: declare variables that must persist with typeset -g. Returns exit code and combined output.",
  "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}]'

# Fill _zs_cfg (an associative array of the caller) with this shell's profile from ZSAGENT_PROFILES:
# provider, url, key, model, options. Only the API URL of openai is fixed here; everything else
# comes from the profile. Status 1 with a message if the profile cannot be used.
_zsagent_config() {
  emulate -L zsh -o noaliases
  local -a f
  [[ -n $ZSAGENT_PROFILES ]] ||
    { _zsagent_fail "no profile configured in $ZSAGENT_HOME/config.zsh; see config.zsh.example"; return 1 }
  jq -e 'type == "object" and length > 0' <<< $ZSAGENT_PROFILES > /dev/null 2>&1 ||
    { _zsagent_fail "ZSAGENT_PROFILES is not a JSON object of profiles"; return 1 }
  # One field per line, in a fixed order; a missing profile gives no lines.
  f=("${(@f)$(jq -r --arg p "$_zsagent_profile" '.[$p] | select(type == "object")
    | .provider // "", .url // "", .key // "", .model // "", (.options // {} | tojson)' <<< $ZSAGENT_PROFILES)}")
  (( $#f == 5 )) || { _zsagent_fail "profile '$_zsagent_profile' is not in $ZSAGENT_HOME/config.zsh \
(zsagent --profile lists the profiles)"; return 1 }
  _zs_cfg=(provider "$f[1]" url "$f[2]" key "$f[3]" model "$f[4]" options "$f[5]")  # quoted: fields may be empty
  # The keys of all profiles (8 characters or more), removed from tool output before it is saved or sent.
  _zs_cfg[secrets]=$(jq -c '[.[] | objects | .key | strings | select(length >= 8)] | unique' <<< $ZSAGENT_PROFILES)
  case $_zs_cfg[provider] in
    openai) _zs_cfg[url]=https://api.openai.com/v1/responses ;;
    custom) ;;
    *) _zsagent_fail "profile $_zsagent_profile: provider must be openai or custom"; return 1 ;;
  esac
  [[ -n $_zs_cfg[model] ]] || { _zsagent_fail "profile $_zsagent_profile needs a model"; return 1 }
  [[ -n $_zs_cfg[url] ]] || { _zsagent_fail "profile $_zsagent_profile needs a url"; return 1 }
  local v
  for v in ZSAGENT_OUTPUT_LIMIT ZSAGENT_MAX_ROUNDS ZSAGENT_CONNECT_TIMEOUT ZSAGENT_STALL_TIMEOUT; do
    [[ ${(P)v} == <-> ]] || { _zsagent_fail "$v must be a whole number"; return 1 }
  done
  (( ZSAGENT_MAX_ROUNDS >= 1 && ZSAGENT_MAX_ROUNDS <= 500 )) ||
    { _zsagent_fail "ZSAGENT_MAX_ROUNDS must be 1 to 500 (each round is a nested function call)"; return 1 }
}

# jq function output: a command's output as the model gets it. The API keys of the profiles ($secrets) are
# replaced; of output longer than ZSAGENT_OUTPUT_LIMIT characters ($limit) the start and the end are kept,
# with a note on what was left out.
_zsagent_jq_output='def output: reduce $secrets[] as $s (.; split($s) | join("[API key removed by zsagent]"))
  | if $limit > 0 and length > $limit
    then (($limit / 2) | floor) as $h
      | .[:$h] + "\n[… \(length - $limit) of \(length) characters left out by zsagent …]\n" + .[length - ($limit - $h):]
    else . end;'

# Session file of this shell in REPLY: <id>.<profile>.json.
_zsagent_session_file() {
  emulate -L zsh -o noaliases
  REPLY=$ZSAGENT_HOME/sessions/$ZSAGENT_SESSION.$_zsagent_profile.json
}

# Id and profile of session file $1 in reply=(id profile); the id has no dots, the profile name may.
_zsagent_session_name() {
  emulate -L zsh -o noaliases
  local name=${1:t:r}
  reply=(${name%%.*} ${name#*.})
}

# System facts for the system prompt: kernel and architecture, OS release (macOS or Linux), zsh version.
_zsagent_sysinfo() {
  emulate -L zsh -o noaliases
  uname -srm
  if (( $+commands[sw_vers] )); then
    print -r -- "$(sw_vers -productName) $(sw_vers -productVersion)"
  elif [[ -r /etc/os-release ]]; then
    (. /etc/os-release; print -r -- $PRETTY_NAME)
  fi
  print -r -- "zsh $ZSH_VERSION"
}

# Append JSON values (from stdin) to the array in session file $1. The temp file is private (mode 600) and has a
# unique name; the session file is replaced atomically, and a failed write leaves it untouched (status 1).
# No value on stdin is a failure too: the caller's item was not produced, so the history would miss it.
_zsagent_add() {
  emulate -L zsh -o noaliases
  (umask 077; jq -s 'if length > 1 then .[0] + .[1:] else error("zsagent: no item to add") end' $1 - > $1.tmp.$$) &&
    mv $1.tmp.$$ $1 || { rm -f $1.tmp.$$; return 1 }
}

# Give tool calls of session file $1 without output the output $2, so the history stays valid for the API:
# with $3 only the call with that id, else all of them. A call that has an output keeps it; a call without a
# string id cannot be answered and is left alone.
_zsagent_close_calls() {
  emulate -L zsh -o noaliases
  (umask 077; jq --arg text $2 --arg id "$3" '[.[] | select(.type == "function_call_output") | .call_id] as $done
      | . + [.[] | select(.type == "function_call" and (.call_id | type) == "string" and (.call_id | IN($done[]) | not)
                      and ($id == "" or .call_id == $id))
             | {type: "function_call_output", call_id, output: $text}]' $1 > $1.tmp.$$) &&
    mv $1.tmp.$$ $1 || { rm -f $1.tmp.$$; return 1 }
}

# Outputs of tool calls that a turn did not answer. They tell the model whether a command may have run, so it
# checks its effects instead of repeating a command that already changed something.
_zsagent_msg_aborted="interrupted: the turn was aborted while this command ran (Ctrl+C or a shell error); \
it may have taken effect partly or fully. Check its effects before running it again. Output until then:"
_zsagent_msg_not_run="not run: the turn was aborted (Ctrl+C or an error) before this call."
_zsagent_msg_unknown="no result recorded: the turn ended before this call was answered (Ctrl+C, a closed terminal \
or an error). The command may have run, partly or fully; check its effects before running it again."
# Output of a command that ran, when zsagent cannot read what it printed.
_zsagent_msg_unreadable="zsagent: the output of this command could not be read (its temp file is gone, or \
ZSAGENT_OUTPUT_LIMIT is not a whole number any more)."

# Make the sessions directory (700) and an existing session file (600) private; status 1 if that is not possible.
_zsagent_private() {
  emulate -L zsh -o noaliases
  mkdir -p ${1:h} && chmod 700 ${1:h} || return 1
  [[ ! -e $1 ]] || chmod 600 $1
}

# Take the lock of session file $1 for a whole turn: an fcntl lock (zsystem flock) on <id>.<profile>.lock.
# The kernel releases it when the shell ends, so a lock is never stale. A process may lock a file twice, so
# _zsagent_locks (lock file -> descriptor) refuses a second turn of this shell, e.g. zsagent run by a tool call.
# Status 1 if another shell or a running turn of this shell holds the lock. The lock file is never deleted:
# deleting it would let a shell that opened the old file lock it together with one that created a new file.
typeset -gA _zsagent_locks
_zsagent_lock() {
  emulate -L zsh -o noaliases
  local lock=${1%.json}.lock fd
  (( ! $+_zsagent_locks[$lock] )) || return 1
  [[ -e $lock ]] || (umask 077; : >> $lock) || return 1
  zsystem flock -t 0 -f fd $lock 2>/dev/null || return 1
  _zsagent_locks[$lock]=$fd
}

# Release the lock of session file $1, if this shell holds it.
_zsagent_unlock() {
  emulate -L zsh -o noaliases
  local lock=${1%.json}.lock
  (( $+_zsagent_locks[$lock] )) || return 0
  zsystem flock -u $_zsagent_locks[$lock]
  unset "_zsagent_locks[$lock]"
}

# Shadow exit and logout while a tool command runs (they would close the user's terminal).
# Inside a subshell of the command, e.g. `(cd x || exit 1)`, exit works as usual.
# Definitions the user already has are saved in _zsagent_saved and restored by _zsagent_unshadow.
# A command can start a turn of another session, whose commands shadow again: _zsagent_shadows counts the
# commands that run, the first one installs the shadows and the last one removes them.
typeset -gA _zsagent_saved
typeset -gi _zsagent_shadows
_zsagent_shadow() {
  emulate -L zsh -o noaliases
  local name
  _zsagent_level=$ZSH_SUBSHELL  # deeper levels are subshells started by the command
  (( _zsagent_shadows++ )) && return 0
  for name in exit logout; do
    (( $+functions[$name] )) && _zsagent_saved[$name]=$functions[$name]
  done
  exit() {
    (( ZSH_SUBSHELL > _zsagent_level )) && builtin exit "$@"
    print -r -- "zsagent: exit is blocked"
    return 1
  }
  logout() { exit "$@" }
}

# Undo one _zsagent_shadow; after the last one, remove the shadows and restore the earlier definitions.
# The saved text of a function is parsed again here; with aliases off, it is not alias-expanded a second time.
_zsagent_unshadow() {
  emulate -L zsh -o noaliases
  (( _zsagent_shadows > 0 )) || return 0
  (( --_zsagent_shadows )) && return 0
  local name
  for name in exit logout; do
    if (( $+_zsagent_saved[$name] )); then
      functions[$name]=$_zsagent_saved[$name]
    else
      unfunction $name 2>/dev/null
    fi
  done
  _zsagent_saved=()
}

# Show the growth of file $1 live, as a disowned background process without job messages; its id is left in REPLY.
_zsagent_tail() {
  emulate -L zsh -o noaliases -o nomonitor
  tail -n +1 -f $1 &!
  REPLY=$!
}

# Print an error for a failed turn.
_zsagent_fail() {
  emulate -L zsh -o noaliases
  print -r -- "zsagent: $1" >&2
}

# POST the session history (with tools and the provider's options) to a Responses API; print the event stream.
# The key header is read from a process substitution, so it never appears in curl's arguments (ps).
_zsagent_request() {
  emulate -L zsh -o noaliases
  local -a stall  # abort a response that sends less than 1 byte per second for ZSAGENT_STALL_TIMEOUT seconds
  (( ZSAGENT_STALL_TIMEOUT )) && stall=(--speed-limit 1 --speed-time $ZSAGENT_STALL_TIMEOUT)
  jq -n --arg model $_zs_cfg[model] --slurpfile input $1 --argjson tools $ZSAGENT_TOOLS --argjson options $_zs_cfg[options] \
    '{model: $model, input: $input[0], tools: $tools, stream: true} + $options' |
    curl -sSN $_zs_cfg[url] --connect-timeout $ZSAGENT_CONNECT_TIMEOUT $stall \
      -H @<(print -r -- "Authorization: Bearer $_zs_cfg[key]") \
      -H "Content-Type: application/json" \
      -d @-
}

# zsagent [--profile [name] | --sessions | --resume <id> | --new | --clear | --reload | --version | --help | [--] <text>]
# Options are long (--name) only: any other argument is message text, so no -h or -? (a message may start with -).
# Without option: send the arguments as the next user message; loop until the model answers without tool calls.
# Locals carry the _zs_ prefix: the model's commands are eval'd below and see this function's variables.
zsagent() {
  _zsagent_reload_if_changed
  case ${1-} in
    --reload) _zsagent_load_config; print -r -- "read $ZSAGENT_HOME/config.zsh, profile $_zsagent_profile"; return ;;
    --profile) shift; _zsagent_cmd_profile "$@"; return ;;
    --sessions) _zsagent_cmd_sessions; return ;;
    --resume) shift; _zsagent_cmd_resume "$@"; return ;;
    --new) _zsagent_cmd_new; return ;;
    --clear) _zsagent_cmd_clear; return ;;
    --version) print -r -- "zsagent $ZSAGENT_VERSION"; return ;;
    --help)  # usage summary
      print -r -- "usage: zsagent [--profile [name] | --sessions | --resume <id> | --new | --clear | --reload | --version | --help | [--] <text>]
  <text>            send <text> as the next message
  --profile [name]  list the LLM profiles, or switch to one (new session)
  --sessions        list the sessions
  --resume <id>     switch to a session from the next message on (<id>.<profile> if profiles share the id)
  --new             start a new session
  --clear           delete the history of the current session
  --reload          read config.zsh again (zsagent also does it by itself when the file changed)
  --version         print the version
  --help            print this summary"
      return ;;
    --) shift ;;  # the rest is message text, even if it starts with --
    --*) _zsagent_fail "unknown option '$1'"; return 1 ;;
  esac
  # No text (or only blanks): nothing to send, so no request is made.
  [[ $* == *[^[:space:]]* ]] || { _zsagent_fail "no message text (zsagent --help lists the options)"; return 1 }
  local _zs_session _zs_out _zs_raw _zs_tail
  local _zs_response _zs_calls _zs_call _zs_id _zs_cmd _zs_code _zs_running _zs_item
  local -F _zs_start=$EPOCHREALTIME
  local -i _zs_in=0 _zs_outtok=0 _zs_rounds=0 _zs_shadow=0 _zs_monitor=0
  local -A _zs_cfg
  _zsagent_config || return 1
  _zsagent_session_file
  _zs_session=$REPLY

  # Private session storage and the session lock come first; without them the turn does not start.
  if ! _zsagent_private "$_zs_session"; then
    _zsagent_fail "cannot make ${_zs_session:h} private (mode 700)"
    return 1
  fi
  if ! _zsagent_lock "$_zs_session"; then
    _zsagent_fail "session ${ZSAGENT_SESSION[1,8]} is in use by another shell or a running turn"
    return 1
  fi

  {
    _zsagent_turn_start "$*" && _zsagent_rounds
  } always {
    _zsagent_turn_end  # also after errors and Ctrl+C
    (( _zs_monitor )) && setopt monitor  # job control, if the turn ended while a command ran
    # Ctrl+C: say so on a line of its own (TRY_BLOCK_INTERRUPT is set when the block above was interrupted).
    (( TRY_BLOCK_INTERRUPT > 0 )) && print -r -- $'\n'"${ZSAGENT_DIM}interrupted"$'\e[0m'
  }
}

# The functions from here to _zsagent_call_end are the parts of a turn that run no code of the model. They run
# inside zsagent and use its _zs_ variables.

# A new, empty temp file of the turn in REPLY: <id>.<profile>.$1 beside the session file, mode 600; $1 is raw (the
# response streams) or out (the output of one command). The turn holds the session lock, so the name is its own;
# a file left by a turn that was killed is replaced. Status 1 if the file cannot be created.
_zsagent_temp() {
  emulate -L zsh -o noaliases
  REPLY=${_zs_session%.json}.$1
  rm -f $REPLY && (umask 077; : >| $REPLY) 2>/dev/null
}

# Start of a turn, with the session lock held: the temp file for the response streams, the session file of a
# new session, an output for each call that an earlier turn left open, and the user's message $1. Status 1 with
# a message if one of them fails; nothing is sent then.
_zsagent_turn_start() {
  emulate -L zsh -o noaliases
  local now item
  _zsagent_temp raw || { _zsagent_fail "cannot create $REPLY; nothing was sent"; return 1 }
  _zs_raw=$REPLY
  rm -f "${_zs_session%.json}.out"  # left by a turn that was killed
  # New session: start the history with the system prompt: ZSAGENT_SYSTEM as it is, or else the built-in
  # prompt plus system information.
  if [[ ! -f $_zs_session ]]; then
    (umask 077; jq -n --arg s "${ZSAGENT_SYSTEM:-$_zsagent_system

System information (captured at session start):
$(_zsagent_sysinfo)}" '[{role: "system", content: $s}]' >| "$_zs_session") ||
      { _zsagent_fail "cannot create $_zs_session"; return 1 }
  fi
  # Every write to the history is checked: nothing is sent or run on top of a history that was not saved.
  _zsagent_close_calls "$_zs_session" "$_zsagent_msg_unknown" || { _zsagent_fail "cannot write $_zs_session"; return 1 }
  # Prefix time and working directory; both can change during a session.
  strftime -s now '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS
  # An item is made first and saved then, here and below: `jq | _zsagent_add` would hide a failure of jq.
  item=$(jq -n --arg q "[$now · $PWD] $1" '{role: "user", content: $q}') &&
    _zsagent_add "$_zs_session" <<< "$item" ||
    { _zsagent_fail "cannot save the message in $_zs_session; nothing was sent"; return 1 }
}

# End of a turn, also after errors and Ctrl+C: stop the live display, restore exit/logout if a command of this
# turn was running, answer the calls of the last response that have no output yet, remove the temp files,
# release the lock.
_zsagent_turn_end() {
  emulate -L zsh -o noaliases
  [[ -n $_zs_tail ]] && kill $_zs_tail 2>/dev/null
  (( _zs_shadow )) && _zsagent_unshadow
  if [[ -n $_zs_running ]]; then  # aborted while a command ran: save what it printed until then
    _zsagent_close_calls "$_zs_session" "$_zsagent_msg_aborted"$'\n'"$(jq -Rrs --argjson limit \
      "$ZSAGENT_OUTPUT_LIMIT" --argjson secrets "${_zs_cfg[secrets]}" "$_zsagent_jq_output output" "$_zs_out" \
      2>/dev/null)" "$_zs_running"
  fi
  [[ -n $_zs_calls ]] && _zsagent_close_calls "$_zs_session" "$_zsagent_msg_not_run"
  [[ -z $_zs_out ]] || rm -f "$_zs_out"
  [[ -z $_zs_raw ]] || rm -f "$_zs_raw"
  _zsagent_unlock "$_zs_session"
}

# Print the error of a request without a completed response; $1: the raw response, $2: curl's exit status.
# The message comes from a JSON error body, a stream event or curl; else the start of the body is shown.
_zsagent_api_error() {
  emulate -L zsh -o noaliases
  local msg
  msg=$(jq -r '(.error | if type == "string" then . else .message? end) // empty' $1 2>/dev/null)
  [[ -n $msg ]] || msg=$(jq -nRr 'first(inputs | select(startswith("data: ")) | .[6:] | fromjson? // empty | objects
    | (.response.error?.message? // .error.message? // .message
       // (.response.incomplete_details?.reason? | strings | "incomplete: " + .) // empty) | strings)' $1 2>/dev/null)
  if [[ -z $msg && $2 == 28 ]]; then
    msg="request timed out (no connection within ZSAGENT_CONNECT_TIMEOUT, or nothing received for ZSAGENT_STALL_TIMEOUT seconds)"
  elif [[ -z $msg && $2 != 0 ]]; then
    msg="request failed (curl exit status $2)"
  elif [[ -z $msg && -s $1 ]]; then
    msg="no completed response from the API: $(head -c 300 $1 | tr -s '\n\t ' ' ')"
  fi
  _zsagent_fail "${msg:-no response from the API}"
}

# The rounds of a turn: send the history, show and save the response, run its tool calls, repeat until a response
# has no tool call. Recursion instead of loops, here and in _zsagent_calls: a `break` or `continue` in a model
# command finds no loop of zsagent to leave. Runs inside zsagent and uses its _zs_ variables.
_zsagent_rounds() {
  if (( ++_zs_rounds > ZSAGENT_MAX_ROUNDS )); then
    _zsagent_fail "stopped after $ZSAGENT_MAX_ROUNDS requests in this turn (ZSAGENT_MAX_ROUNDS); a new message continues"
    return 1
  fi
  _zsagent_exchange || return 1
  [[ -n $_zs_calls ]] || return 0  # no tool calls: the model is done
  _zsagent_calls "${(@f)_zs_calls}" || return 1
  _zsagent_rounds
}

# One request: send the history, show the response as it arrives, check it, count its tokens, save its output
# items and leave its tool calls in _zs_calls (one JSON object per line); without tool calls, print the footer.
# Status 1 with a message if there is no usable response; nothing of it is saved or run then.
_zsagent_exchange() {
  emulate -L zsh -o noaliases
  local rc usage items
  # Stream: show reasoning (ZSAGENT_DIM; OpenAI sends a summary, local servers the reasoning text) and the answer
  # as they arrive; keep the raw stream in $_zs_raw. The filter keeps two facts between events: whether the
  # current message has shown text yet (leading whitespace is dropped) and whether the output ends a line.
  # Only a string type and a string delta of an event are used, so events of any other shape cannot stop it.
  _zsagent_request "$_zs_session" | tee "$_zs_raw" | jq --unbuffered -nRj --arg dim "$ZSAGENT_DIM" '
    foreach (inputs | select(startswith("data: ")) | .[6:] | fromjson? // empty | objects
             | {type: (.type | strings // ""), delta: (.delta | strings // "")}) as $e ({text: false, eol: true, out: ""};
      if $e.type == "response.output_item.added" then .text = false | .out = ""
      elif $e.type == "response.reasoning_summary_text.delta" or $e.type == "response.reasoning_text.delta" then
        .out = $dim + $e.delta + "\u001b[0m" | .eol = ($e.delta | endswith("\n"))
      elif $e.type == "response.output_text.delta" then
        (if .text then $e.delta else ($e.delta | sub("^\\s+"; "")) end) as $d
        | .out = $d | .text = (.text or $d != "") | .eol = (if $d == "" then .eol else ($d | endswith("\n")) end)
      elif ($e.type | test("^response\\.(reasoning_summary_part|reasoning_text|output_text)\\.done$")) then
        .out = (if .eol then "" else "\n" end) | .eol = true
      else .out = "" end;
      .out | select(. != ""))'
  rc=$pipestatus[1]  # curl's exit status

  # The complete response is in the (last) response.completed event; lines that are not JSON are skipped.
  _zs_response=$(jq -nRc 'last(inputs | select(startswith("data: ")) | .[6:] | fromjson? // empty | objects
                         | select(.type == "response.completed") | .response | objects) // empty' "$_zs_raw")
  if [[ -z $_zs_response ]]; then
    _zsagent_api_error "$_zs_raw" "$rc"
    return 1
  fi
  # Nothing of a response without an output array of objects is saved or run.
  if ! jq -e '.output | type == "array" and all(.[]; type == "object")' <<< "$_zs_response" > /dev/null; then
    _zsagent_fail "malformed response from the API (no output array of items); nothing was saved or run"
    return 1
  fi
  # A tool call without an id cannot be answered, and a history with such a call is rejected by the API from
  # then on: nothing of that response is saved or run.
  if ! jq -e 'all(.output[] | select(.type == "function_call"); (.call_id | type) == "string" and .call_id != "")' \
    <<< "$_zs_response" > /dev/null; then
    _zsagent_fail "the API sent a tool call without call_id; nothing was saved or run"
    return 1
  fi
  usage=$(jq -r '[(.usage.input_tokens? | numbers) // 0, (.usage.output_tokens? | numbers) // 0] | join(" ")' \
    <<< "$_zs_response")
  (( _zs_in += ${usage%% *}, _zs_outtok += ${usage##* } ))

  # Store the output items without null fields. If that fails, no tool call of this response is run.
  # A response with an empty output array has nothing to store.
  items=$(jq -c '.output[] | del(.. | nulls)' <<< "$_zs_response") &&
    { [[ -z $items ]] || _zsagent_add "$_zs_session" <<< "$items" } ||
    { _zsagent_fail "cannot save the response in $_zs_session; no command was run"; return 1 }

  # No tool calls: the model is done; print the footer.
  _zs_calls=$(jq -c '.output[] | select(.type == "function_call")' <<< "$_zs_response")
  [[ -n $_zs_calls ]] ||
    printf '%s%.1fs · %d in · %d out\e[0m\n' "$ZSAGENT_DIM" $(( EPOCHREALTIME - _zs_start )) "$_zs_in" "$_zs_outtok"
  return 0
}

# The command of tool call $1 (JSON) in REPLY with status 0; for a call that cannot be run, the reason in REPLY
# with status 1: another tool than shell, arguments that are not a JSON object, or no command string.
_zsagent_call_command() {
  emulate -L zsh -o noaliases
  local out
  out=$(jq -r '(.arguments | try fromjson catch null) as $a
    | if .name != "shell" then "1", "unknown tool \(.name | tojson); the only tool is shell"
      elif ($a | type) != "object" then "1", "the arguments are not a JSON object"
      elif ($a.command | type) != "string" then "1", "the arguments need a string field \"command\""
      elif ($a.command | test("^\\s*$")) then "1", "the command is empty"
      else "0", $a.command end' <<< $1 2>/dev/null) || { REPLY="the tool call is not valid JSON"; return 1 }
  REPLY=${out#*$'\n'}
  return ${out%%$'\n'*}
}

# Run the tool calls $@ (one JSON object each) in this shell, one after another, and save each result.
# Output goes to the file $_zs_out (for the model) and is shown live by a tail process; no pipe is involved,
# so a background process started by the command cannot block the turn. Every command gets a new file: what a
# background process prints later goes to the removed file of its command, not into a later result.
_zsagent_calls() {
  (( $# )) || return 0
  _zs_call=$1
  _zsagent_call_start || return 1
  if [[ -n $_zs_running ]]; then
    # Job control is off while the command runs: its processes stay in the process group of the shell, so Ctrl+C
    # reaches the shell too and ends the turn, also when a program handles it and exits normally (e.g. ping).
    [[ -o monitor ]] && _zs_monitor=1
    setopt nomonitor
    # The anonymous function keeps a `return` in the command from leaving zsagent.
    () { eval "$_zs_cmd" } >| "$_zs_out" 2>&1
    _zs_code=$?
    (( _zs_monitor )) && setopt monitor
  fi
  _zsagent_call_end || return 1
  shift
  _zsagent_calls "$@"
}

# Before tool call $_zs_call (its id: _zs_id). A call that can be run: show the command (_zs_cmd), create the file
# for its output (_zs_out), start the live display and shadow exit/logout; _zs_running holds the id until the
# result is saved, so _zsagent_turn_end saves it if the turn is aborted. A call that cannot be run: the reason is
# its result (_zs_item), so the model can correct it. Status 1 with a message if the turn has to stop.
_zsagent_call_start() {
  emulate -L zsh -o noaliases
  _zs_cmd= _zs_code= _zs_item=
  _zs_id=$(jq -r '.call_id' <<< "$_zs_call")  # a string: _zsagent_exchange checked it
  if ! _zsagent_call_command "$_zs_call"; then
    print -r -- "${ZSAGENT_DIM}▸ not run: $REPLY"$'\e[0m'
    _zs_item=$(jq -n --arg id "$_zs_id" --arg text "error: $REPLY; nothing was run"$'\n' \
      '{type: "function_call_output", call_id: $id, output: $text}')
    return 0
  fi
  _zs_cmd=$REPLY
  _zsagent_temp out || { _zsagent_fail "cannot create $REPLY for the command's output; stopping"; return 1 }
  _zs_out=$REPLY
  print -r -- "${ZSAGENT_DIM}▸ $_zs_cmd"$'\e[0m'
  _zs_running=$_zs_id
  _zsagent_tail "$_zs_out"
  _zs_tail=$REPLY
  _zsagent_shadow
  _zs_shadow=1  # the shadow of this turn's command; a turn started by the command has its own
}

# After the tool call: for a command that ran, restore exit/logout, stop the live display and make the result
# from its exit code ($_zs_code) and output; if the output cannot be read (the command removed the file or
# changed ZSAGENT_OUTPUT_LIMIT), the result says so. Then save the result and remove the file. Status 1 with a
# message if the result cannot be saved: a further request would make the model repeat the command.
_zsagent_call_end() {
  emulate -L zsh -o noaliases
  if [[ -n $_zs_running ]]; then
    _zsagent_unshadow
    _zs_shadow=0
    sleep 0.1  # let tail show the last output
    kill $_zs_tail 2>/dev/null
    _zs_tail=
    _zs_item=$(jq -n --arg id "$_zs_id" --arg code "$_zs_code" --rawfile output "$_zs_out" \
      --argjson limit "$ZSAGENT_OUTPUT_LIMIT" --argjson secrets "${_zs_cfg[secrets]}" \
      "$_zsagent_jq_output"'{type: "function_call_output", call_id: $id,
        output: ("exit code " + $code + "\n" + ($output | output))}' 2>/dev/null) ||
      _zs_item=$(jq -n --arg id "$_zs_id" --arg code "$_zs_code" --arg text "$_zsagent_msg_unreadable" \
        '{type: "function_call_output", call_id: $id, output: ("exit code " + $code + "\n" + $text)}')
  fi
  [[ -n $_zs_item ]] && _zsagent_add "$_zs_session" <<< "$_zs_item" ||
    { _zsagent_fail "cannot save the command result in $_zs_session; stopping"; return 1 }
  _zs_running=
  [[ -z $_zs_out ]] || rm -f "$_zs_out"
  _zs_out=
}

# List sessions, newest first: marker for the current one, short id, profile, last change, user messages,
# first question.
_zsagent_cmd_sessions() {
  emulate -L zsh -o noaliases
  local f mark
  for f in $ZSAGENT_HOME/sessions/*.*.json(Nom); do
    _zsagent_session_name $f
    [[ $reply[1] == $ZSAGENT_SESSION && $reply[2] == $_zsagent_profile ]] && mark='*' || mark=' '
    jq -r --arg head "$mark ${reply[1][1,8]}  ${(r:10:)reply[2]}  $(zstat -F '%Y-%m-%d %H:%M' +mtime $f)" \
      '[.[] | select(.role == "user" and (.content | type) == "string") | .content | sub("^\\[[^]]*\\] "; "")]
       | "\($head)  \(length) msgs  \(.[0] // "" | .[0:60])"' $f
  done
}

# Switch this shell to an existing session and its profile; a unique id prefix is enough. One id can have a
# session per profile: <id>.<profile> names one of them.
_zsagent_cmd_resume() {
  emulate -L zsh -o noaliases
  local -a matches
  if [[ $1 == *.* ]]; then
    matches=($ZSAGENT_HOME/sessions/${1%%.*}*.${1#*.}.json(N))
  else
    matches=($ZSAGENT_HOME/sessions/$1*.*.json(N))
  fi
  if (( $#matches != 1 )); then
    _zsagent_fail "--resume: $#matches sessions match '$1'${matches:+ (name one as <id>.<profile>)}"
    return 1
  fi
  _zsagent_session_name $matches[1]
  ZSAGENT_SESSION=$reply[1] _zsagent_profile=$reply[2]
  print -r -- "resumed ${ZSAGENT_SESSION[1,8]} ($_zsagent_profile)"
}

# Switch this shell to a new session id; the profile stays, the previous session file is kept.
_zsagent_cmd_new() {
  emulate -L zsh -o noaliases
  _zsagent_new_id
  ZSAGENT_SESSION=$REPLY
  print -r -- "new session ${ZSAGENT_SESSION[1,8]} ($_zsagent_profile)"
}

# Delete the session file of this shell; id and profile stay, the next message starts the history anew.
# The session lock is taken first, so a turn running in another shell is not cut off.
_zsagent_cmd_clear() {
  emulate -L zsh -o noaliases
  local -A _zs_cfg
  _zsagent_config || return 1
  _zsagent_session_file
  if ! _zsagent_lock $REPLY; then
    _zsagent_fail "--clear: session ${ZSAGENT_SESSION[1,8]} is in use"
    return 1
  fi
  rm -f $REPLY ${REPLY%.json}.raw ${REPLY%.json}.out  # the last two only exist after a turn that was killed
  _zsagent_unlock $REPLY
  print -r -- "cleared session ${ZSAGENT_SESSION[1,8]} ($_zsagent_profile)"
}

# Without argument: list the profiles with provider, model and URL, the current one marked with *.
# With a profile name: switch this shell to it and start a new session, because a session's history
# belongs to the API it was made with.
_zsagent_cmd_profile() {
  emulate -L zsh -o noaliases
  local current=$_zsagent_profile mark name provider model url
  if [[ -z $1 ]]; then
    jq -r --arg c "$current" 'to_entries[] | [(if .key == $c then "*" else " " end), .key, (.value.provider // "?"),
      (.value.model // "(no model)"), (.value.url // "-")] | @tsv' <<< $ZSAGENT_PROFILES 2>/dev/null |
      while IFS=$'\t' read -r mark name provider model url; do
        print -r -- "$mark ${(r:12:)name}  ${(r:10:)provider}  ${(r:18:)model}  ${url:#-}"
      done
    return
  fi
  if ! jq -e --arg p $1 'has($p)' <<< $ZSAGENT_PROFILES > /dev/null 2>&1; then
    _zsagent_fail "--profile: unknown profile '$1'"
    return 1
  fi
  _zsagent_profile=$1
  _zsagent_new_id
  ZSAGENT_SESSION=$REPLY
  print -r -- "profile $1, new session ${ZSAGENT_SESSION[1,8]}"
}

# PS1 in REPLY without the zero-width OSC 133 marks that terminal integrations (Ghostty, iTerm2, kitty) wrap
# around it, so zsagent can recognize its own message prompt and save the user's prompt without them.
_zsagent_unmarked() {
  emulate -L zsh -o noaliases -o extendedglob
  REPLY=${1//\%\{$'\e']133\;[^%]#\%\}/}
}

# Sourced again in message mode: restore the user's prompt first.
if [[ ${_zsagent_mode-} == message ]]; then
  _zsagent_unmarked "$PS1"
  [[ $REPLY == "${_zsagent_shown-}" ]] && PS1=${_zsagent_ps1-}
fi
_zsagent_mode=command     # command: Enter runs the line in zsh; message: Enter sends it to the model
_zsagent_pending=         # the line that Enter took in message mode, until _zsagent_run sends it

# Message mode: remember the user's prompt and show the message-mode one. Runs on the switch and as the last
# precmd hook, because many themes rebuild PS1 before every prompt.
_zsagent_prompt() {
  emulate -L zsh -o noaliases
  [[ $_zsagent_mode == message && -n $ZSAGENT_MESSAGE_PS1 ]] || return 0
  _zsagent_unmarked $PS1
  [[ $REPLY == $_zsagent_shown ]] || _zsagent_ps1=$REPLY  # not the message prompt: it is the user's prompt
  PS1=$ZSAGENT_MESSAGE_PS1
  _zsagent_shown=$PS1
}

# Shift+Tab: switch between command and message mode; swap the prompt string and redraw the line.
_zsagent_toggle() {
  emulate -L zsh -o noaliases
  if [[ $_zsagent_mode == message ]]; then
    _zsagent_mode=command
    _zsagent_unmarked $PS1
    [[ $REPLY == $_zsagent_shown ]] && PS1=$_zsagent_ps1
  else
    _zsagent_mode=message
    _zsagent_prompt
  fi
  zle reset-prompt
}

# Message mode with text in the line: save the line for _zsagent_run and in the history and empty it (an empty
# submitted line creates no history entry); status 0. Else status 1.
_zsagent_take_line() {
  emulate -L zsh -o noaliases
  [[ $_zsagent_mode == message && -n $BUFFER ]] || return 1
  _zsagent_pending=$BUFFER
  # HIST_IGNORE_SPACE: a message typed with a leading space stays out of the history, like a command would.
  [[ -o histignorespace && $BUFFER == ' '* ]] || print -rs -- $BUFFER
  BUFFER=
}

# Enter: a message is taken (see above) and an empty line submitted; any other line goes on as before zsagent
# was loaded: to the accept-line widget of another plugin, if there was one, else to zsh. That widget runs with
# the user's options, so this function has no `emulate`.
_zsagent_accept_line() {
  if _zsagent_take_line; then
    zle .accept-line
  elif (( ${+widgets[_zsagent_orig_accept_line]} )); then
    zle _zsagent_orig_accept_line "$@"
  else
    zle .accept-line
  fi
}

# First precmd hook: run zsagent on a line saved by Enter in message mode, in the shell (not in zle).
# The empty submitted line is redrawn as typed first (cursor up, clear line, last prompt line + text);
# (%%) expands the prompt like zsh does, including $(...) with PROMPT_SUBST.
# zsagent runs with the user's options, so this function has no `emulate`: its expansions are quoted.
_zsagent_run() {
  [[ -n ${_zsagent_pending-} ]] || return 0
  local line="$_zsagent_pending"
  _zsagent_pending=
  print -rn -- $'\e[1A\e[2K'"${${(%%)PS1}##*$'\n'}"
  print -r -- "$line"
  zsagent -- "$line"  # -- : the line is message text, even if it starts with --
}

# Install the widgets, the Shift+Tab key and the precmd hooks; safe to run again.
_zsagent_bind() {
  emulate -L zsh -o noaliases
  # An accept-line widget of another plugin stays in use under another name; ours calls it. Sourced again, the
  # widget found is ours and the name kept before stays.
  if [[ ${widgets[accept-line]-} == user:* && $widgets[accept-line] != user:_zsagent_accept_line ]]; then
    zle -A accept-line _zsagent_orig_accept_line
  fi
  zle -N accept-line _zsagent_accept_line
  zle -N _zsagent_toggle
  bindkey '^[[Z' _zsagent_toggle  # Shift+Tab
  # ${array:#name} drops an existing entry, so sourcing again does not register hooks twice.
  typeset -ga precmd_functions
  precmd_functions=(_zsagent_run ${precmd_functions:#(_zsagent_run|_zsagent_prompt)} _zsagent_prompt)  # run first, prompt last
}
[[ -o interactive ]] && _zsagent_bind

# Alias expansion as the user had it (see the top of this file).
(( _zsagent_aliases )) && 'builtin' 'setopt' 'aliases'
'builtin' 'unset' '_zsagent_aliases'
