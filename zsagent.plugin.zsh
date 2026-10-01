# zsagent (Z Shell Agent): connects a language model to the user's interactive zsh, unrestricted; curl + jq against an LLM API.

ZSAGENT_VERSION=0.1.0
ZSAGENT_HOME=${ZSAGENT_HOME:-~/.zsagent}  # directory of config.zsh and sessions/; set it before the plugin loads
ZSAGENT_PROFILES=  # JSON object of named profiles (provider, url, key, model, options), set in config.zsh; see config.zsh.example
ZSAGENT_PROFILE=   # profile a new shell starts with; empty: the first profile
ZSAGENT_SYSTEM=  # set in config.zsh: replaces the complete system prompt below (including the system information)
_zsagent_system="You are a language model connected to the user's interactive zsh by zsagent (Z Shell Agent). \
The user writes to you from the shell prompt. With the shell tool you run commands directly in that shell, \
without confirmation; cd, exports and variables persist. Keep answers short.

Sessions: every conversation is stored in $ZSAGENT_HOME/sessions/<id>.<profile>.json (JSON array of API items). \
\`zsagent --sessions\` lists them; \`zsagent --resume <id>\` switches the user's shell to a session from the next message on. \
\`zsagent --profile [name]\` lists the LLM profiles or switches to one (with a new session). \
To look into an old session without switching, read its file with jq."
ZSAGENT_MESSAGE_PS1='👾 %# '  # message mode: replaces PS1, so the mode is visible; config.zsh can override it
[[ -f $ZSAGENT_HOME/config.zsh ]] && source $ZSAGENT_HOME/config.zsh  # user settings override the defaults above
zmodload zsh/datetime  # $EPOCHREALTIME, $EPOCHSECONDS and strftime
# A new session id: a UUID from uuidgen (macOS) or the kernel (Linux).
_zsagent_new_id() {
  REPLY=${(L)$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)}
}
# One session and one profile per shell; both survive sourcing the plugin again.
[[ -n $ZSAGENT_SESSION ]] || { _zsagent_new_id; ZSAGENT_SESSION=$REPLY }
_zsagent_profile=${_zsagent_profile:-$ZSAGENT_PROFILE}
zmodload -F zsh/stat b:zstat  # zstat for file times (without replacing the stat command)

ZSAGENT_TOOLS='[{"type": "function", "name": "shell",
  "description": "Run a command in the interactive zsh of the user. Same session: cd, exports and variable assignments persist. The command runs inside a function: declare variables that must persist with typeset -g. Returns exit code and combined output.",
  "parameters": {"type": "object", "properties": {"command": {"type": "string"}}, "required": ["command"]}}]'

# Fill _zs_cfg (an associative array of the caller) with this shell's profile from ZSAGENT_PROFILES:
# provider, url, key, model, options. Only the API URL of openai is fixed here; everything else
# comes from the profile. Status 1 with a message if the profile cannot be used.
_zsagent_config() {
  local -a f
  [[ -n $ZSAGENT_PROFILES ]] || { _zsagent_fail "no profile configured; see config.zsh.example"; return 1 }
  jq -e 'type == "object" and length > 0' <<< $ZSAGENT_PROFILES > /dev/null 2>&1 ||
    { _zsagent_fail "ZSAGENT_PROFILES is not a JSON object of profiles"; return 1 }
  [[ -n $_zsagent_profile ]] || _zsagent_profile=$(jq -r 'keys_unsorted[0]' <<< $ZSAGENT_PROFILES)
  # One field per line, in a fixed order; a missing profile gives no lines.
  f=("${(@f)$(jq -r --arg p $_zsagent_profile '.[$p] | select(type == "object")
    | .provider // "", .url // "", .key // "", .model // "", (.options // {} | tojson)' <<< $ZSAGENT_PROFILES)}")
  (( $#f == 5 )) || { _zsagent_fail "unknown profile '$_zsagent_profile' (zsagent --profile lists them)"; return 1 }
  _zs_cfg=(provider "$f[1]" url "$f[2]" key "$f[3]" model "$f[4]" options "$f[5]")  # quoted: fields may be empty
  case $_zs_cfg[provider] in
    openai) _zs_cfg[url]=https://api.openai.com/v1/responses ;;
    custom) ;;
    *) _zsagent_fail "profile $_zsagent_profile: provider must be openai or custom"; return 1 ;;
  esac
  [[ -n $_zs_cfg[model] ]] || { _zsagent_fail "profile $_zsagent_profile needs a model"; return 1 }
  [[ -n $_zs_cfg[url] ]] || { _zsagent_fail "profile $_zsagent_profile needs a url"; return 1 }
}

# Session file of this shell in REPLY: <id>.<profile>.json.
_zsagent_session_file() {
  REPLY=$ZSAGENT_HOME/sessions/$ZSAGENT_SESSION.$_zsagent_profile.json
}

# Id and profile of session file $1 in reply=(id profile); the id has no dots, the profile name may.
_zsagent_session_name() {
  local name=${1:t:r}
  reply=(${name%%.*} ${name#*.})
}

# System facts for the system prompt: kernel and architecture, OS release (macOS or Linux), zsh version.
_zsagent_sysinfo() {
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
_zsagent_add() {
  (umask 077; jq -s '.[0] + .[1:]' $1 - > $1.tmp.$$) && mv $1.tmp.$$ $1 || { rm -f $1.tmp.$$; return 1 }
}

# Give tool calls without output (e.g. after Ctrl+C) an output, so the history stays valid for the API.
_zsagent_close_calls() {
  (umask 077; jq '[.[] | select(.type == "function_call_output") | .call_id] as $done
      | . + [.[] | select(.type == "function_call" and (.call_id | IN($done[]) | not))
             | {type: "function_call_output", call_id, output: "Interrupted by the user."}]' $1 > $1.tmp.$$) &&
    mv $1.tmp.$$ $1 || { rm -f $1.tmp.$$; return 1 }
}

# Make the sessions directory (700) and an existing session file (600) private; status 1 if that is not possible.
_zsagent_private() {
  mkdir -p ${1:h} && chmod 700 ${1:h} || return 1
  [[ ! -e $1 ]] || chmod 600 $1
}

# Take the lock of session file $1 for a whole turn: an atomic mkdir holding the owner's process id.
# A lock whose owner no longer runs is taken over; status 1 if another shell is using the session.
_zsagent_lock() {
  local lock=$1.lock owner
  if ! mkdir $lock 2>/dev/null; then
    owner=$(cat $lock/pid 2>/dev/null)
    [[ -n $owner ]] && kill -0 $owner 2>/dev/null && return 1
    rm -rf $lock && mkdir $lock 2>/dev/null || return 1
  fi
  print -r -- $$ > $lock/pid
}

# Shadow exit and logout while a tool command runs (they would close the user's terminal).
# Inside a subshell of the command, e.g. `(cd x || exit 1)`, exit works as usual.
# Definitions the user already has are saved in _zsagent_saved and restored by _zsagent_unshadow.
typeset -gA _zsagent_saved
_zsagent_shadow() {
  local name
  for name in exit logout; do
    (( $+functions[$name] )) && _zsagent_saved[$name]=$functions[$name]
  done
  _zsagent_level=$ZSH_SUBSHELL  # deeper levels are subshells started by the command
  exit() {
    (( ZSH_SUBSHELL > _zsagent_level )) && builtin exit "$@"
    print -r -- "zsagent: exit is blocked"
    return 1
  }
  logout() { exit "$@" }
  _zsagent_shadowed=1
}

# Remove the shadows and restore earlier definitions; does nothing if no shadows are installed.
_zsagent_unshadow() {
  (( _zsagent_shadowed )) || return 0
  local name
  for name in exit logout; do
    if (( $+_zsagent_saved[$name] )); then
      functions[$name]=$_zsagent_saved[$name]
    else
      unfunction $name 2>/dev/null
    fi
  done
  _zsagent_saved=()
  _zsagent_shadowed=0
}

# Show the growth of file $1 live, as a disowned background process without job messages; its id is left in REPLY.
_zsagent_tail() {
  setopt localoptions nomonitor
  tail -n +1 -f $1 &!
  REPLY=$!
}

# Print an error for a failed turn.
_zsagent_fail() {
  print -r -- "zsagent: $1" >&2
}

# POST the session history (with tools and the provider's options) to a Responses API; print the event stream.
# The key header is read from a process substitution, so it never appears in curl's arguments (ps).
_zsagent_request() {
  jq -n --arg model $_zs_cfg[model] --slurpfile input $1 --argjson tools $ZSAGENT_TOOLS --argjson options $_zs_cfg[options] \
    '{model: $model, input: $input[0], tools: $tools, stream: true} + $options' |
    curl -sSN $_zs_cfg[url] \
      -H @<(print -r -- "Authorization: Bearer $_zs_cfg[key]") \
      -H "Content-Type: application/json" \
      -d @-
}

# zsagent [--profile [name] | --sessions | --resume <id> | --version | [--] <text>]
# Without option: send the arguments as the next user message; loop until the model answers without tool calls.
# Locals carry the _zs_ prefix: the model's commands are eval'd below and see this function's variables.
zsagent() {
  case $1 in
    --profile) shift; _zsagent_cmd_profile "$@"; return ;;
    --sessions) _zsagent_cmd_sessions; return ;;
    --resume) shift; _zsagent_cmd_resume "$@"; return ;;
    --version) print -r -- "zsagent $ZSAGENT_VERSION"; return ;;
    --) shift ;;  # the rest is message text, even if it starts with --
    --*) _zsagent_fail "unknown option '$1'"; return 1 ;;
  esac
  local _zs_session _zs_out _zs_raw _zs_tail
  local _zs_now _zs_response _zs_error _zs_calls _zs_call _zs_cmd _zs_code
  local -F _zs_start=$EPOCHREALTIME
  local -i _zs_in=0 _zs_outtok=0
  local -A _zs_cfg
  _zsagent_config || return 1
  _zsagent_session_file
  _zs_session=$REPLY

  # Private session storage and the session lock come first; without them the turn does not start.
  if ! _zsagent_private $_zs_session; then
    _zsagent_fail "cannot make ${_zs_session:h} private (mode 700)"
    return 1
  fi
  if ! _zsagent_lock $_zs_session; then
    _zsagent_fail "session ${ZSAGENT_SESSION[1,8]} is in use by another shell"
    return 1
  fi

  {
    _zs_out=$(mktemp) _zs_raw=$(mktemp)

    # New session: start the history with the system prompt: ZSAGENT_SYSTEM as it is, or else the built-in
    # prompt plus system information.
    if [[ ! -f $_zs_session ]]; then
      (umask 077; jq -n --arg s "${ZSAGENT_SYSTEM:-$_zsagent_system

System information (captured at session start):
$(_zsagent_sysinfo)}" '[{role: "system", content: $s}]' > $_zs_session) ||
        { _zsagent_fail "cannot create $_zs_session"; return 1 }
    fi
    # Every write to the history is checked: nothing is sent or run on top of a history that was not saved.
    _zsagent_close_calls $_zs_session || { _zsagent_fail "cannot write $_zs_session"; return 1 }
    # Prefix time and working directory; both can change during a session.
    strftime -s _zs_now '%Y-%m-%dT%H:%M:%S%z' $EPOCHSECONDS
    jq -n --arg q "[$_zs_now · $PWD] $*" '{role: "user", content: $q}' | _zsagent_add $_zs_session ||
      { _zsagent_fail "cannot save the message in $_zs_session; nothing was sent"; return 1 }

    while true; do
      # Stream: show reasoning (grey; OpenAI sends a summary, local servers the reasoning text) and the answer
      # as they arrive; keep the raw stream in $_zs_raw. The filter keeps two facts between events: whether the
      # current message has shown text yet (leading whitespace is dropped) and whether the output ends a line.
      _zsagent_request $_zs_session | tee $_zs_raw | jq --unbuffered -nRj '
        foreach (inputs | select(startswith("data: ")) | .[6:] | fromjson) as $e ({text: false, eol: true, out: ""};
          if $e.type == "response.output_item.added" then .text = false | .out = ""
          elif $e.type == "response.reasoning_summary_text.delta" or $e.type == "response.reasoning_text.delta" then
            .out = "\u001b[90m" + $e.delta + "\u001b[0m" | .eol = ($e.delta | endswith("\n"))
          elif $e.type == "response.output_text.delta" then
            (if .text then $e.delta else ($e.delta | sub("^\\s+"; "")) end) as $d
            | .out = $d | .text = (.text or $d != "") | .eol = (if $d == "" then .eol else ($d | endswith("\n")) end)
          elif ($e.type | test("^response\\.(reasoning_summary_part|reasoning_text|output_text)\\.done$")) then
            .out = (if .eol then "" else "\n" end) | .eol = true
          else .out = "" end;
          .out | select(. != ""))'

      # The complete response is in the response.completed event.
      _zs_response=$(jq -Rc 'select(startswith("data: ")) | .[6:] | fromjson
                             | select(.type == "response.completed") | .response' $_zs_raw)
      if [[ -z $_zs_response ]]; then
        # No completed response: the API's message from a plain JSON error body or from a stream event, else a generic one.
        _zs_error=$(jq -r '.error.message // empty' $_zs_raw 2>/dev/null)
        [[ -z $_zs_error ]] && _zs_error=$(jq -Rr 'select(startswith("data: ")) | .[6:] | fromjson
          | .response.error.message // .error.message // .message
            // (.response.incomplete_details.reason | select(.) | "incomplete: " + .) // empty' $_zs_raw 2>/dev/null | head -1)
        _zsagent_fail "${_zs_error:-no response from the API}"
        return 1
      fi
      (( _zs_in += $(jq .usage.input_tokens <<< $_zs_response) ))
      (( _zs_outtok += $(jq .usage.output_tokens <<< $_zs_response) ))

      # Store the output items without null fields. If that fails, no tool call of this response is run.
      jq '.output[] | del(.. | nulls)' <<< $_zs_response | _zsagent_add $_zs_session ||
        { _zsagent_fail "cannot save the response in $_zs_session; no command was run"; return 1 }

      # No tool calls: the model is done; print the footer.
      _zs_calls=$(jq -c '.output[] | select(.type == "function_call")' <<< $_zs_response)
      if [[ -z $_zs_calls ]]; then
        printf '\e[90m%.1fs · %d in · %d out\e[0m\n' $(( EPOCHREALTIME - _zs_start )) $_zs_in $_zs_outtok
        return 0
      fi

      # Run each call in this shell. Output goes to the file $_zs_out (for the model) and is shown live by a tail
      # process; no pipe is involved, so a background process started by the command cannot block the turn.
      for _zs_call in ${(f)_zs_calls}; do
        _zs_cmd=$(jq -r '.arguments | fromjson | .command' <<< $_zs_call)
        print -r -- $'\e[90m'"▸ $_zs_cmd"$'\e[0m'
        : > $_zs_out
        _zsagent_tail $_zs_out
        _zs_tail=$REPLY
        _zsagent_shadow
        # The anonymous function keeps a `return` in the command from leaving zsagent.
        () { eval $_zs_cmd } > $_zs_out 2>&1
        _zs_code=$?
        _zsagent_unshadow
        sleep 0.1  # let tail show the last output
        kill $_zs_tail 2>/dev/null
        _zs_tail=
        # If the result cannot be saved, stop: a further request would make the model repeat the command.
        jq -n --arg id "$(jq -r .call_id <<< $_zs_call)" --arg code $_zs_code --rawfile output $_zs_out \
          '{type: "function_call_output", call_id: $id, output: ("exit code " + $code + "\n" + $output)}' |
          _zsagent_add $_zs_session ||
          { _zsagent_fail "cannot save the command result in $_zs_session; stopping"; return 1 }
      done
    done
  } always {
    # Also after errors and Ctrl+C: stop the live display, restore exit/logout, remove temp files, release the lock.
    [[ -n $_zs_tail ]] && kill $_zs_tail 2>/dev/null
    _zsagent_unshadow
    rm -f $_zs_out $_zs_raw
    rm -rf $_zs_session.lock 2>/dev/null
    # Ctrl+C: say so on a line of its own (TRY_BLOCK_INTERRUPT is set when the block above was interrupted).
    (( TRY_BLOCK_INTERRUPT > 0 )) && print -r -- $'\n\e[90minterrupted\e[0m'
  }
}

# List sessions, newest first: marker for the current one, short id, profile, last change, user messages,
# first question.
_zsagent_cmd_sessions() {
  local f mark
  for f in $ZSAGENT_HOME/sessions/*.*.json(Nom); do
    _zsagent_session_name $f
    [[ $reply[1] == $ZSAGENT_SESSION && $reply[2] == $_zsagent_profile ]] && mark='*' || mark=' '
    jq -r --arg head "$mark ${reply[1][1,8]}  ${(r:10:)reply[2]}  $(zstat -F '%Y-%m-%d %H:%M' +mtime $f)" \
      '[.[] | select(.role == "user" and (.content | type) == "string") | .content | sub("^\\[[^]]*\\] "; "")]
       | "\($head)  \(length) msgs  \(.[0] // "" | .[0:60])"' $f
  done
}

# Switch this shell to an existing session and its profile; a unique id prefix is enough.
_zsagent_cmd_resume() {
  local -a matches=($ZSAGENT_HOME/sessions/$1*.*.json(N))
  if (( $#matches != 1 )); then
    _zsagent_fail "--resume: $#matches sessions match '$1'"
    return 1
  fi
  _zsagent_session_name $matches[1]
  ZSAGENT_SESSION=$reply[1] _zsagent_profile=$reply[2]
  print -r -- "resumed ${ZSAGENT_SESSION[1,8]} ($_zsagent_profile)"
}

# Without argument: list the profiles with provider, model and URL, the current one marked with *.
# With a profile name: switch this shell to it and start a new session, because a session's history
# belongs to the API it was made with.
_zsagent_cmd_profile() {
  local current=${_zsagent_profile:-$(jq -r 'keys_unsorted[0] // empty' <<< $ZSAGENT_PROFILES 2>/dev/null)}
  local mark name provider model url
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
  setopt localoptions extendedglob
  REPLY=${1//\%\{$'\e']133\;[^%]#\%\}/}
}

# Sourced again in message mode: restore the user's prompt first.
if [[ $_zsagent_mode == message ]]; then
  _zsagent_unmarked $PS1
  [[ $REPLY == $_zsagent_shown ]] && PS1=$_zsagent_ps1
fi
_zsagent_mode=command     # command: Enter runs the line in zsh; message: Enter sends it to the model

# Message mode: remember the user's prompt and show the message-mode one. Runs on the switch and as the last
# precmd hook, because many themes rebuild PS1 before every prompt.
_zsagent_prompt() {
  [[ $_zsagent_mode == message && -n $ZSAGENT_MESSAGE_PS1 ]] || return 0
  _zsagent_unmarked $PS1
  [[ $REPLY == $_zsagent_shown ]] || _zsagent_ps1=$REPLY  # not the message prompt: it is the user's prompt
  PS1=$ZSAGENT_MESSAGE_PS1
  _zsagent_shown=$PS1
}

# Shift+Tab: switch between command and message mode; swap the prompt string and redraw the line.
_zsagent_toggle() {
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

# Enter: in message mode, save the line for _zsagent_run and in the history, then submit an empty line (which
# creates no history entry); in command mode zsh runs the line as usual.
_zsagent_accept_line() {
  if [[ $_zsagent_mode == message && -n $BUFFER ]]; then
    _zsagent_pending=$BUFFER
    # HIST_IGNORE_SPACE: a message typed with a leading space stays out of the history, like a command would.
    [[ -o histignorespace && $BUFFER == ' '* ]] || print -rs -- $BUFFER
    BUFFER=
  fi
  zle .accept-line
}

# First precmd hook: run zsagent on a line saved by Enter in message mode, in the shell (not in zle).
# The empty submitted line is redrawn as typed first (cursor up, clear line, last prompt line + text);
# (%%) expands the prompt like zsh does, including $(...) with PROMPT_SUBST.
_zsagent_run() {
  [[ -n $_zsagent_pending ]] || return 0
  local line=$_zsagent_pending
  _zsagent_pending=
  print -rn -- $'\e[1A\e[2K'"${${(%%)PS1}##*$'\n'}"
  print -r -- $line
  zsagent -- $line  # -- : the line is message text, even if it starts with --
}

if [[ -o interactive ]]; then
  zle -N accept-line _zsagent_accept_line
  zle -N _zsagent_toggle
  bindkey '^[[Z' _zsagent_toggle  # Shift+Tab
  # ${array:#name} drops an existing entry, so sourcing again does not register hooks twice.
  precmd_functions=(_zsagent_run ${precmd_functions:#(_zsagent_run|_zsagent_prompt)} _zsagent_prompt)  # run first, prompt last
fi
