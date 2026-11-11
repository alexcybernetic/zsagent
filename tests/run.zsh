#!/bin/zsh -f
# Regression tests for zsagent.plugin.zsh: zsh -f tests/run.zsh [test_name ...]
# Each test runs in a fresh `zsh -f` with its own ZSAGENT_HOME; `curl` is replaced by a function that records the
# request and replays a prepared event stream, so no network and no API key are needed.

ROOT=${0:A:h:h}

# ---- mock API -------------------------------------------------------------------------------------------------

# curl: request N (counted by files, because curl runs in a pipeline subshell) saves its body to $MOCK/req.N,
# its arguments to $MOCK/args.N and prints $MOCK/resp.N; if $MOCK/fail.N exists, it fails like curl with status 7.
curl() {
  local -a reqs=($MOCK/req.*(N))
  local n=$(( $#reqs + 1 ))
  print -rl -- "$@" > $MOCK/args.$n
  cat > $MOCK/req.$n
  [[ -f $MOCK/resp.$n ]] && cat $MOCK/resp.$n
  [[ -f $MOCK/fail.$n ]] || return 0
  print -ru2 -- "curl: (7) Failed to connect"
  return 7
}

# Events (JSON, one per line on stdin) as an event stream into response N.
_sse() { sed 's/^/data: /' > $MOCK/resp.$1 }

# Response N: a text answer.
mock_text() {
  jq -nc --arg t $2 '{type: "response.output_text.delta", delta: $t},
    {type: "response.completed", response: {output: [{type: "message", role: "assistant",
      content: [{type: "output_text", text: $t}]}], usage: {input_tokens: 10, output_tokens: 2}}}' | _sse $1
}

# Response N: one shell call per remaining argument (command text); call ids are cN.1, cN.2, ...
mock_calls() {
  local n=$1; shift
  jq -nc --arg n $n '[$ARGS.positional | to_entries[] | {type: "function_call", call_id: "c\($n).\(.key + 1)",
      name: "shell", arguments: ({command: .value} | tojson)}]
    | {type: "response.completed", response: {output: ., usage: {input_tokens: 10, output_tokens: 2}}}' \
    --args "$@" | _sse $n
}

# Response N: the output items given as a JSON array.
mock_output() {
  jq -nc --argjson o $2 '{type: "response.completed", response: {output: $o, usage: {input_tokens: 10, output_tokens: 2}}}' | _sse $1
}

# Response N: raw text as it is.
mock_raw() { print -r -- $2 > $MOCK/resp.$1 }

# ---- assertions -----------------------------------------------------------------------------------------------

_failed=0
fail() { print -r -- "    $*"; _failed=1 }
assert_eq() { [[ $1 == $2 ]] || fail "${3:-value}: expected [${(V)2}], got [${(V)1}]" }
assert_match() { [[ $1 == $~2 ]] || fail "${3:-value}: [${(V)1}] does not match [$2]" }
assert_no_match() { [[ $1 != $~2 ]] || fail "${3:-value}: [${(V)1}] matches [$2]" }

# No temp file of a turn (<id>.<profile>.raw or .out beside the session file) is left ($1: when).
assert_no_temp() {
  local -a left=($ZSAGENT_HOME/sessions/*.(raw|out)(ND:e))
  assert_eq "$left" "" "temp files left $1"
}

# The session file of this shell, and a jq query on it.
session() { print -r -- $ZSAGENT_HOME/sessions/$ZSAGENT_SESSION.mock.json }
sq() { jq -r "$1" "$(session)" }

# Run a turn; output (stdout and stderr) in $OUT, status in $STATUS. Not in a subshell: tool commands change it.
turn() {
  zsagent "$@" > $T/out 2>&1
  STATUS=$?
  OUT=$(<$T/out)
}

# ---- setup ----------------------------------------------------------------------------------------------------

setup() {
  T=$(mktemp -d)
  MOCK=$T/mock ZSAGENT_HOME=$T/home
  mkdir -p $MOCK $ZSAGENT_HOME
  (umask 077; print -r -- "ZSAGENT_PROFILES='{\"mock\": {\"provider\": \"custom\", \"url\": \"http://mock.invalid/v1/responses\", \
\"key\": \"secret-key\", \"model\": \"m\"}, \"other\": {\"provider\": \"openai\", \"key\": \"sk-other-key\", \"model\": \"m\"}}'" \
    > $ZSAGENT_HOME/config.zsh)
  source $ROOT/zsagent.plugin.zsh
}

# ---- tests ----------------------------------------------------------------------------------------------------

test_text_turn() {
  mock_text 1 "hello there"
  turn hi you
  assert_eq $STATUS 0 status
  assert_match $OUT '*hello there*' output
  assert_eq "$(sq 'map(.role // .type) | join(",")')" "system,user,assistant" items
  assert_match "$(sq '.[1].content')" '\[*\] hi you' "user message"
  assert_match $OUT '*· 10 in · 2 out*' footer
}

test_request_body_and_key() {
  mock_text 1 ok
  turn hi
  assert_eq "$(jq -r '[.model, .stream, (.tools[0].name), (.input | length)] | join(" ")' $MOCK/req.1)" "m true shell 2" request
  assert_no_match "$(<$MOCK/args.1)" '*secret-key*' "curl arguments"
}

test_tool_runs_in_this_shell() {
  mock_calls 1 'typeset -g ZT_VAR=42; cd /; echo out'
  mock_text 2 done
  local here=$PWD
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$ZT_VAR" 42 "variable set by the tool"
  assert_eq $PWD / "cwd after cd"
  assert_eq "$(sq '.[] | select(.type == "function_call_output") | .output')" $'exit code 0\nout' "tool output"
  assert_eq "$(jq -r '.input[-1].output' $MOCK/req.2)" $'exit code 0\nout' "output sent back"
  cd $here
}

test_several_calls_in_one_response() {
  mock_calls 1 'echo one' 'echo two'
  mock_text 2 done
  turn go
  assert_eq "$(sq '[.[] | select(.type == "function_call_output") | .call_id] | join(",")')" "c1.1,c1.2" "call ids"
}

test_exit_is_blocked_and_restored() {
  mock_calls 1 'exit 3'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_match "$(sq '.[] | select(.type == "function_call_output") | .output')" $'exit code 1\nzsagent: exit is blocked' "tool output"
  assert_eq $+functions[exit] 0 "exit function removed"
  assert_eq $+functions[logout] 0 "logout function removed"
}

test_exit_in_subshell_works() {
  mock_calls 1 '(exit 3)'
  mock_text 2 done
  turn go
  assert_eq "$(sq '.[] | select(.type == "function_call_output") | .output')" "exit code 3" "tool output"
}

test_user_exit_function_restored() {
  exit() { print -r -- mine }
  local before=$functions[exit]
  mock_calls 1 'true'
  mock_text 2 done
  turn go
  assert_eq "$functions[exit]" "$before" "user's exit"
}

# The lock file of the session, and whether another process can take its lock now.
lockfile() { print -r -- ${$(session)%.json}.lock }
can_lock() { zsh -fc 'zmodload zsh/system; zsystem flock -t 0 -f fd $1' x $(lockfile) 2>/dev/null }

# Hold the session lock from another process until it is killed; its process id in REPLY.
hold_lock() {
  mkdir -p ${$(session):h}; : >> $(lockfile)
  zsh -fc 'zmodload zsh/system; zsystem flock -f fd $1 && touch $1.held && sleep 30' x $(lockfile) &!
  REPLY=$!
  while [[ ! -e $(lockfile).held ]]; do sleep 0.05; done
}

test_lock_busy() {
  mock_text 1 ok
  hold_lock
  turn hi
  kill $REPLY
  assert_eq $STATUS 1 status
  assert_match $OUT '*in use by another shell*' error
  assert_eq "$(print $MOCK/req.*(N))" "" "no request"
}

test_lock_freed_when_holder_dies() {
  mock_text 1 ok
  hold_lock
  kill $REPLY
  sleep 0.2
  turn hi
  assert_eq $STATUS 0 status
  can_lock || fail "lock still held after the turn"
}

test_lock_released_after_error() {
  turn hi   # no response prepared
  assert_eq $STATUS 1 status
  can_lock || fail "lock still held after a failed turn"
}

test_lock_held_during_turn_nested_refused() {
  mock_calls 1 "zsh -fc 'zmodload zsh/system; zsystem flock -t 0 -f fd \$1' x $(lockfile) && print free || print held" \
    'zsagent nested' 'zsagent --clear'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  local -a outs=("${(@f)$(sq '.[] | select(.type == "function_call_output") | .output | @json')}")
  assert_match $outs[1] '*held*' "lock held by the turn"
  assert_match $outs[2] '*in use*' "nested turn"
  assert_match $outs[3] '*in use*' "--clear during the turn"
  [[ -f $(session) ]] || fail "session file removed"
  mock_text 3 again
  turn again
  assert_eq $STATUS 0 status "next turn"
}

test_concurrent_turn_from_another_shell() {
  export ZSAGENT_HOME ZSAGENT_SESSION
  mock_calls 1 "zsh -fc 'source $ROOT/zsagent.plugin.zsh; zsagent second' 2>&1"
  mock_text 2 done
  turn first
  assert_match "$(sq '.[] | select(.type == "function_call_output") | .output')" '*in use by another shell*' "second shell"
  assert_eq "$(sq '[.[] | select(.role == "user")] | length')" 1 "user messages"
}

test_clear() {
  mock_text 1 ok
  turn hi
  zsagent --clear > /dev/null
  [[ ! -e $(session) ]] || fail "session file still there"
  can_lock || fail "lock still held"
}

test_no_completed_response_runs_nothing() {
  mock_raw 1 $'data: {"type":"response.output_text.delta","delta":"x"}\ndata: {"type":"error","message":"overloaded"}'
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*zsagent: overloaded*' error
}

test_http_error_body() {
  mock_raw 1 '{"error": {"message": "invalid api key"}}'
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*zsagent: invalid api key*' error
}

test_unanswered_call_closed_next_turn() {
  mock_text 1 ok
  mkdir -p ${$(session):h}
  jq -n '[{role: "system", content: "s"}, {role: "user", content: "u"},
    {type: "function_call", call_id: "old", name: "shell", arguments: "{\"command\":\"true\"}"}]' > $(session)
  turn hi
  assert_eq "$(jq -r '.input[] | select(.call_id == "old" and .type == "function_call_output") | .output' $MOCK/req.1)" \
    "$_zsagent_msg_unknown" "closing output"
}

test_failed_save_runs_no_command() {
  functions[_zt_add]=$functions[_zsagent_add]
  integer adds=0
  _zsagent_add() { (( ++adds == 2 )) && return 1; _zt_add "$@" }   # 1: user message, 2: response
  mock_calls 1 "touch $T/ran"
  turn go
  assert_eq $STATUS 1 status
  [[ ! -e $T/ran ]] || fail "command ran although the response was not saved"
}

test_user_options_noclobber() {
  setopt noclobber
  mock_calls 1 'echo first' 'echo second'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '[.[] | select(.type == "function_call_output") | .output] | join("|")')" \
    $'exit code 0\nfirst\n|exit code 0\nsecond' "tool outputs"
}

test_user_options_ksharrays_shwordsplit() {
  setopt ksharrays shwordsplit
  mock_calls 1 'echo "a  b"'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '.[] | select(.type == "function_call_output") | .output')" $'exit code 0\na  b' "tool output"
}

test_break_continue_stay_in_the_command() {
  mock_calls 1 'break' 'continue 2' 'echo after'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '[.[] | select(.type == "function_call_output") | .call_id] | join(",")')" "c1.1,c1.2,c1.3" "all calls answered"
  assert_match "$(sq '.[] | select(.call_id == "c1.3" and .type == "function_call_output") | .output')" '*after*' "later call ran"
  assert_eq $+functions[exit] 0 "exit function removed"
}

test_many_rounds() {
  integer i
  for i in {1..30}; do mock_calls $i "echo $i"; done
  mock_text 31 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '[.[] | select(.type == "function_call_output")] | length')" 30 "outputs"
}

test_invalid_calls_not_run() {
  mock_output 1 '[
    {"type": "function_call", "call_id": "a", "name": "shell", "arguments": "{bad json"},
    {"type": "function_call", "call_id": "b", "name": "shell", "arguments": "{\"cmd\": \"touch ran\"}"},
    {"type": "function_call", "call_id": "c", "name": "python", "arguments": "{\"command\": \"touch ran\"}"},
    {"type": "function_call", "call_id": "d", "name": "shell", "arguments": "{\"command\": \"  \"}"},
    {"type": "function_call", "call_id": "e", "name": "shell", "arguments": "{\"command\": 5}"},
    {"type": "function_call", "call_id": "f", "name": "shell", "arguments": "{\"command\": \"echo fine\"}"}]'
  mock_text 2 done
  cd $T
  turn go
  assert_eq $STATUS 0 status
  [[ ! -e $T/ran ]] || fail "an invalid call ran"
  local -A out=("${(@f)$(sq '.[] | select(.type == "function_call_output") | .call_id, (.output | @json)')}")
  assert_eq $out[a] '"error: the arguments are not a JSON object; nothing was run\n"' a
  assert_eq $out[b] '"error: the arguments need a string field \"command\"; nothing was run\n"' b
  assert_eq $out[c] '"error: unknown tool \"python\"; the only tool is shell; nothing was run\n"' c
  assert_eq $out[d] '"error: the command is empty; nothing was run\n"' d
  assert_eq $out[e] '"error: the arguments need a string field \"command\"; nothing was run\n"' e
  assert_eq $out[f] '"exit code 0\nfine\n"' f
}

test_call_without_id_stops() {
  mock_output 1 '[{"type": "function_call", "name": "shell", "arguments": "{\"command\": \"touch ran\"}"}]'
  cd $T
  turn go
  assert_eq $STATUS 1 status
  assert_match $OUT '*without call_id*' error
  [[ ! -e $T/ran ]] || fail "the call ran"
  # Nothing of that response is in the session, so the next request has a valid history.
  assert_eq "$(sq 'map(.role // .type) | join(",")')" "system,user" "items after the response without id"
  mock_text 2 ok
  turn again
  assert_eq $STATUS 0 "status of the next turn"
  assert_eq "$(jq -r '.input | map(.role // .type) | join(",")' $MOCK/req.2)" "system,user,user" "next request"
}

test_call_without_id_runs_no_other_call() {
  mock_output 1 '[{"type": "function_call", "call_id": "a", "name": "shell", "arguments": "{\"command\": \"touch ran\"}"},
    {"type": "function_call", "call_id": null, "name": "shell", "arguments": "{\"command\": \"touch ran2\"}"}]'
  cd $T
  turn go
  assert_eq $STATUS 1 status
  [[ ! -e $T/ran && ! -e $T/ran2 ]] || fail "a call of the response ran"
  assert_eq "$(sq 'length')" 2 "items (system, user)"
}

test_open_call_without_id_gets_no_output() {
  mock_text 1 ok
  mkdir -p ${$(session):h}
  jq -n '[{role: "system", content: "s"}, {type: "function_call", name: "shell", arguments: "{}"},
    {type: "function_call", call_id: "old", name: "shell", arguments: "{}"}]' > $(session)
  turn hi
  assert_eq "$(sq '[.[] | select(.type == "function_call_output") | .call_id | tojson] | join(",")')" '"old"' "outputs"
}

test_stream_with_junk_and_done_lines() {
  { print -r -- 'data: {"type":"response.output_text.delta","delta":"hel"}'
    print -r -- 'data: not json'
    print -rl -- 'data: {}' 'data: {"type": 1}' 'data: 1' 'data: "x"' 'data: [1]' 'data: null' \
      'data: {"type":"response.output_text.delta"}' 'data: {"type":"response.output_text.delta","delta":5}' \
      'data: {"type":"response.completed","response":"junk"}' 'data: {"response":{"error":"x"}}'
    print -r -- 'data: {"type":"response.output_text.delta","delta":"lo"}'
    jq -nc '{type: "response.completed", response: {output: [{type: "message", role: "assistant",
      content: [{type: "output_text", text: "hello"}]}], usage: {input_tokens: 1, output_tokens: 1}}}' | sed 's/^/data: /'
    print -r -- 'data: [DONE]' } > $MOCK/resp.1
  turn hi
  assert_eq $STATUS 0 status
  assert_match $OUT 'hello*' output
  assert_no_match $OUT '*jq: error*' "jq errors"
}

test_non_json_error_body() {
  mock_raw 1 '<html><body>502 Bad Gateway</body></html>'
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*zsagent: no completed response from the API: <html><body>502 Bad Gateway*' error
}

test_string_error_body() {
  mock_raw 1 '{"error": "model not found"}'
  turn hi
  assert_match $OUT '*zsagent: model not found*' error
}

test_curl_failure() {
  touch $MOCK/fail.1
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*zsagent: request failed \(curl exit status 7\)*' error
}

test_output_not_array_saves_nothing() {
  jq -nc '{type: "response.completed", response: {output: {type: "function_call", call_id: "x", name: "shell",
    arguments: "{\"command\": \"touch ran\"}"}}}' | _sse 1
  cd $T
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*malformed response*' error
  assert_eq "$(sq 'length')" 2 "items (system, user)"
  [[ ! -e $T/ran ]] || fail "command ran"
}

test_missing_usage_counts_zero() {
  null=5
  jq -nc '{type: "response.completed", response: {output: [{type: "message", role: "assistant",
    content: [{type: "output_text", text: "x"}]}]}}' | _sse 1
  turn hi
  assert_eq $STATUS 0 status
  assert_match $OUT '*· 0 in · 0 out*' footer
}

# Run a turn in an interactive zsh (-i), where Ctrl+C (SIGINT) and shell errors abort it as at the prompt.
turn_interactive() {
  export T MOCK ZSAGENT_HOME ZSAGENT_SESSION
  zsh -fi $ROOT/tests/run.zsh --turn "$@" > $T/out 2>&1
  OUT=$(<$T/out)
}

test_ctrl_c_during_command() {
  mock_calls 1 'print partial; kill -INT $$; sleep 1; print never' "touch $T/second"
  turn_interactive go
  local -A out=("${(@f)$(sq '.[] | select(.type == "function_call_output") | .call_id, (.output | @json)')}")
  assert_eq $out[c1.1] "$(jq -n --arg t "$_zsagent_msg_aborted"$'\npartial' '$t')" "running call"
  assert_eq $out[c1.2] "$(jq -n --arg t "$_zsagent_msg_not_run" '$t')" "call not started"
  [[ ! -e $T/second ]] || fail "second call ran"
  assert_eq "$(print $MOCK/req.*(N:t))" "req.1" "requests"
  assert_match $OUT '*interrupted*' "interrupted message"
  can_lock || fail "lock still held"
  assert_no_temp "after Ctrl+C"
}

test_shell_error_during_command() {
  mock_calls 1 'print partial; : ${undefined_v?boom}; print never' "touch $T/second"
  turn_interactive go
  assert_match "$(sq '.[] | select(.call_id == "c1.1" and .type == "function_call_output") | .output')" \
    "${(b)_zsagent_msg_aborted}"$'\npartial\n*undefined_v: boom' "running call"
  assert_match "$(sq '.[] | select(.call_id == "c1.2" and .type == "function_call_output") | .output')" 'not run:*' \
    "call not started"
  [[ ! -e $T/second ]] || fail "second call ran"
  assert_no_temp "after a shell error"
}

# Read the output of the pseudo terminal zt until it matches pattern $1, at most $2 seconds (default 10).
# The shell on it only runs while its output is read, so this is also the way to let it work.
pty_wait() {
  local chunk got=
  integer tries=0 max=$(( ${2:-10} * 10 ))
  while [[ $got != $~1 ]] && (( tries++ < max )); do
    zpty -r -t zt chunk && got+=$chunk || sleep 0.1
  done
  [[ $got == $~1 ]]
}

# Ctrl+C on a real terminal goes to the program in the foreground. One that handles it and exits normally (here a
# script with a trap; ping does the same) must not let the turn go on with the next call and request.
test_ctrl_c_ends_turn_when_the_program_handles_it() {
  zmodload zsh/zpty
  export T MOCK ZSAGENT_HOME ZSAGENT_SESSION
  mock_calls 1 "sh -c 'trap \"exit 0\" INT; sleep 20'" "touch $T/second"
  mock_calls 2 "touch $T/next-round"
  zpty -b zt zsh -fi
  zpty -w zt "source $ROOT/tests/run.zsh --pty; PS1='READY> '"
  pty_wait '*READY> *' || fail "no prompt on the pseudo terminal"
  zpty -w zt 'zsagent go'
  pty_wait '*▸ sh -c*' 5 || fail "the command did not start"
  pty_wait NEVER 1
  zpty -w -n zt $'\x03'  # one Ctrl+C
  pty_wait '*interrupted*READY> *' 8 || fail "the turn did not end after one Ctrl+C"
  zpty -w zt 'print -r -- "monitor=$options[monitor]"'
  pty_wait '*monitor=on*' 5 || fail "job control is not on again after the turn"
  zpty -d zt
  assert_eq "$(print $MOCK/req.*(N:t))" "req.1" "requests"
  [[ ! -e $T/second && ! -e $T/next-round ]] || fail "a later call ran"
  assert_match "$(sq '.[] | select(.call_id == "c1.1" and .type == "function_call_output") | .output')" \
    'interrupted:*' "running call"
  assert_match "$(sq '.[] | select(.call_id == "c1.2" and .type == "function_call_output") | .output')" \
    'not run:*' "call not started"
  assert_no_temp "after Ctrl+C"
}

test_curl_timeouts() {
  mock_text 1 ok; mock_text 2 ok
  turn hi
  assert_eq "${(j: :)${(f)$(<$MOCK/args.1)}[3,8]}" "--connect-timeout 30 --speed-limit 1 --speed-time 600" "curl options"
  ZSAGENT_STALL_TIMEOUT=0
  turn again
  assert_no_match "$(<$MOCK/args.2)" '*speed*' "no stall limit"
}

test_curl_timeout_message() {
  touch $MOCK/fail.1
  curl() { cat > /dev/null; return 28 }
  turn hi
  assert_match $OUT '*zsagent: request timed out*' error
}

test_output_limit() {
  ZSAGENT_OUTPUT_LIMIT=20
  mock_calls 1 'print -r -- {a..z}' 'print -r -- short'
  mock_text 2 done
  turn go
  local -a outs=("${(@f)$(sq '.[] | select(.type == "function_call_output") | .output | @json')}")
  assert_eq $outs[1] '"exit code 0\na b c d e \n[… 32 of 52 characters left out by zsagent …]\nv w x y z\n"' "long output"
  assert_eq $outs[2] '"exit code 0\nshort\n"' "short output"
}

test_max_rounds() {
  ZSAGENT_MAX_ROUNDS=3
  integer i
  for i in {1..5}; do mock_calls $i "echo $i"; done
  turn go
  assert_eq $STATUS 1 status
  assert_match $OUT '*stopped after 3 requests*' error
  assert_eq "$(print $MOCK/req.*(N:t))" "req.1 req.2 req.3" requests
  assert_eq "$(sq '[.[] | select(.type == "function_call_output")] | length')" 3 "answered calls"
}

test_invalid_limit() {
  ZSAGENT_OUTPUT_LIMIT=lots
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT '*ZSAGENT_OUTPUT_LIMIT must be a whole number*' error
}

test_api_keys_removed_from_output() {
  mock_calls 1 'print -r -- $ZSAGENT_PROFILES' "jq -r '.[].key' <<< \$ZSAGENT_PROFILES | sed 's/^/x-/; s/\$/-y/'"
  mock_text 2 done
  turn go
  local all=$(<$(session))$(<$MOCK/req.2)
  assert_no_match $all '*secret-key*' "first key"
  assert_no_match $all '*sk-other-key*' "other profile's key"
  assert_eq "$(sq '.[] | select(.call_id == "c1.2" and .type == "function_call_output") | .output')" \
    $'exit code 0\nx-[API key removed by zsagent]-y\nx-[API key removed by zsagent]-y' "replaced keys"
}

test_config_readable_by_others_warns() {
  chmod 644 $ZSAGENT_HOME/config.zsh
  local warn=$(source $ROOT/zsagent.plugin.zsh 2>&1)
  assert_match $warn '*other users can read*config.zsh*chmod 600*' warning
  chmod 600 $ZSAGENT_HOME/config.zsh
  warn=$(source $ROOT/zsagent.plugin.zsh 2>&1)
  assert_eq "$warn" "" "no warning for mode 600"
}

test_no_text_sends_nothing() {
  local args
  for args in "" "--" "-- " "' '"; do
    eval "turn $args"
    assert_eq $STATUS 1 "status for [$args]"
    assert_match $OUT '*no message text*' "error for [$args]"
  done
  assert_eq "$(print $MOCK/req.*(N))" "" "no request"
  [[ ! -e $(session) ]] || fail "session file created"
}

test_changed_config_read_before_turn() {
  mock_text 1 ok
  (umask 077; print -r -- "ZSAGENT_PROFILES='{\"mock\": {\"provider\": \"custom\", \"url\": \"http://new.invalid\", \
\"key\": \"new-secret-key\", \"model\": \"m2\"}}'" > $ZSAGENT_HOME/config.zsh)
  turn hi
  assert_eq $STATUS 0 status
  assert_eq "$(jq -r .model $MOCK/req.1)" m2 "model from the changed config"
  assert_match "$(<$MOCK/args.1)" '*http://new.invalid*' "url from the changed config"
}

test_unchanged_config_not_read_again() {
  ZSAGENT_OUTPUT_LIMIT=7
  mock_text 1 ok
  turn hi
  assert_eq $ZSAGENT_OUTPUT_LIMIT 7 "setting made in the shell"
}

test_reload_option() {
  ZSAGENT_OUTPUT_LIMIT=7
  zsagent --reload > $T/out
  assert_eq $ZSAGENT_OUTPUT_LIMIT 30000 "default after --reload"
  assert_match "$(<$T/out)" '*read*config.zsh*' message
}

test_reload_names_the_profile() {
  assert_match "$(zsagent --reload)" 'read *config.zsh, profile mock' "first profile"
  print -r -- 'ZSAGENT_PROFILE=other' >> $ZSAGENT_HOME/config.zsh
  assert_match "$(zsagent --reload)" 'read *config.zsh, profile other' "ZSAGENT_PROFILE"
}

test_dim_style() {
  { print -r -- 'data: {"type":"response.reasoning_summary_text.delta","delta":"thinking"}'
    jq -nc '{type: "response.completed", response: {output: [{type: "message", role: "assistant",
      content: [{type: "output_text", text: "x"}]}], usage: {input_tokens: 1, output_tokens: 1}}}' | sed 's/^/data: /'
  } > $MOCK/resp.2
  mock_calls 1 'true'
  turn go
  local e=$'\e'  # escape sequences in patterns: ESC, then \[ for a literal [
  assert_match $OUT "*$e\\[2m▸ true*$e\\[2mthinking$e\\[0m*$e\\[2m*· 11 in · 3 out$e\\[0m*" "faint by default"
  assert_no_match $OUT "*$e\\[90m*" "no color 90"
  ZSAGENT_DIM=$'\e[38;5;245m'
  mock_text 3 y
  turn again
  assert_match $OUT "*$e\\[38;5;245m*· 10 in · 2 out*" "own style"
}

test_prompt_roundtrip() {
  zle() { : }
  PS1='user %# '
  _zsagent_toggle
  assert_eq $PS1 $ZSAGENT_MESSAGE_PS1 "message prompt"
  _zsagent_toggle
  assert_eq $PS1 'user %# ' "user prompt restored"
}

test_temp_files_removed() {
  # While a command runs, the turn has two temp files beside the session file, readable by the user only:
  # the response stream and the command's output.
  mock_calls 1 'echo one' 'for f in $ZSAGENT_HOME/sessions/*.(raw|out); do print $f:e $(zstat -o +mode $f); done'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '.[] | select(.call_id == "c1.2" and .type == "function_call_output") | .output')" \
    $'exit code 0\nout 0100600\nraw 0100600' "temp files during a command"
  assert_no_temp "after a turn with commands"
  turn again  # no response prepared: the request fails
  assert_eq $STATUS 1 "status of the failed turn"
  assert_no_temp "after a failed turn"
}

test_temp_files_of_a_killed_turn_are_replaced() {
  # A turn that was killed left its temp files behind, readable by others.
  local base=${$(session)%.json}
  mkdir -p $base:h
  print -r -- stale > $base.raw; print -r -- stale > $base.out
  chmod 644 $base.raw $base.out
  mock_calls 1 "print -r -- \"[\$(<$base.out)]\" \$(zstat -o +mode $base.out)"
  mock_text 2 done
  turn go
  assert_eq "$(sq '.[] | select(.type == "function_call_output") | .output')" $'exit code 0\n[] 0100600' "new output file"
  assert_no_temp "after the next turn"
  print -r -- stale > $base.raw; print -r -- stale > $base.out
  zsagent --clear > /dev/null
  assert_no_temp "after --clear"
}

test_user_aliases_stay_out_of_zsagent() {
  mock_calls 1 'zt_hello' 'echo second'
  mock_text 2 done
  # As in ~/.zshrc: the aliases first, then the plugin. mv -i and rm -i would ask before they overwrite or remove,
  # jq -C would put colours into the session file, and chmod would fail.
  alias mv='mv -i' rm='rm -i' jq='jq -C' chmod='false' zt_hello='print aliased'
  alias -g -- -r='-R'
  source $ROOT/zsagent.plugin.zsh
  [[ -o aliases ]] || fail "sourcing left alias expansion off"
  turn go
  unalias -m '*'  # the assertions below use jq as well
  assert_eq $STATUS 0 status
  assert_no_match "$functions[_zsagent_add]" '*mv -i*' "alias in a function"
  assert_eq "$(sq '[.[] | select(.type == "function_call_output") | .output] | join("|")')" \
    $'exit code 0\naliased\n|exit code 0\nsecond' "tool outputs (the model's command uses the alias)"
}

test_nested_turn_keeps_exit_blocked_and_restores_it() {
  local outer=$(session)
  # The command starts a turn of another session (requests 2 and 3) and tries to exit after it.
  mock_calls 1 'zsagent --new > /dev/null; zsagent sub; exit 5'
  mock_calls 2 'true'
  mock_text 3 "nested done"
  mock_text 4 done
  turn go
  assert_eq $STATUS 0 status
  assert_match "$(jq -r '.[] | select(.type == "function_call_output") | .output' $outer)" \
    'exit code 1*nested done*zsagent: exit is blocked' "output of the outer command"
  assert_eq $+functions[exit] 0 "exit function removed"
  assert_eq $+functions[logout] 0 "logout function removed"
}

test_nested_turn_without_command_keeps_exit_blocked() {
  mock_calls 1 'zsagent --new > /dev/null; zsagent sub; exit 5'
  mock_text 2 "nested done"
  mock_text 3 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq $+functions[exit] 0 "exit function removed"
}

test_nested_turn_restores_user_exit_function() {
  exit() { print -r -- mine }
  local before=$functions[exit]
  mock_calls 1 'zsagent --new > /dev/null; zsagent sub'
  mock_calls 2 'true'
  mock_text 3 "nested done"
  mock_text 4 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$functions[exit]" "$before" "user's exit"
}

test_background_output_stays_out_of_later_results() {
  # The background process of the first command prints while the second command runs.
  mock_calls 1 'print -r -- ${(l:5000::x:):-}; (sleep 0.3; print late) &' 'sleep 0.8; print ok'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  assert_eq "$(sq '.[] | select(.call_id == "c1.2" and .type == "function_call_output") | .output | @json')" \
    '"exit code 0\nok\n"' "result of the second command"
  assert_no_temp "after the turn"
}

test_unreadable_output_still_answers_the_call() {
  mock_calls 1 'print gone; rm -f $ZSAGENT_HOME/sessions/*.out' 'ZSAGENT_OUTPUT_LIMIT=lots; print limit'
  mock_text 2 done
  turn go
  assert_eq $STATUS 0 status
  local -A out=("${(@f)$(sq '.[] | select(.type == "function_call_output") | .call_id, (.output | @json)')}")
  local expected=$(jq -n --arg t "exit code 0"$'\n'"$_zsagent_msg_unreadable" '$t')
  assert_eq "$out[c1.1]" "$expected" "temp file removed by the command"
  assert_eq "$out[c1.2]" "$expected" "limit changed by the command"
  assert_eq "$(jq -r '[.input[] | select(.type == "function_call_output")] | length' $MOCK/req.2)" 2 \
    "results in the next request"
}

test_add_without_item_fails() {
  mock_text 1 ok
  turn hi
  local before=$(<$(session))
  _zsagent_add $(session) < /dev/null 2> /dev/null && fail "adding nothing succeeded"
  assert_eq "$(<$(session))" "$before" "session file"
}

test_load_and_idle_with_user_options() {
  # A new shell with these options loads the plugin, shows a prompt without a message and runs zsagent without text.
  export ZSAGENT_HOME
  local out=$(zsh -f -o nounset -o shwordsplit -o globsubst -o ksharrays -c \
    'source "$1"; _zsagent_run; zsagent; print -r -- "status $?"' x $ROOT/zsagent.plugin.zsh 2>&1)
  assert_eq "$out" $'zsagent: no message text (zsagent --help lists the options)\nstatus 1' "non-interactive shell"
  # Interactive: the hooks go around the ones that are there.
  out=$(zsh -fi -o nounset -o ksharrays -c \
    'precmd_functions=(mine); source "$1"; source "$1"; print -r -- "${precmd_functions[@]}"' x $ROOT/zsagent.plugin.zsh 2>&1)
  assert_eq "$out" "_zsagent_run mine _zsagent_prompt" "interactive shell"
}

test_message_mode_with_user_options() {
  mock_text 1 ok
  cd $T
  : > a.md
  PS1='%# '
  setopt shwordsplit globsubst nounset
  _zsagent_pending=$'a   b\tc *.md'
  _zsagent_run > $T/out 2>&1
  unsetopt shwordsplit globsubst nounset
  assert_eq "$(jq -r '.input[-1].content | sub("^\\[[^]]*\\] "; "")' $MOCK/req.1)" $'a   b\tc *.md' "message as typed"
  assert_eq "$_zsagent_pending" "" "pending line"
}

test_accept_line_of_another_plugin_is_kept() {
  local -a calls
  zt_widget() { : }
  zle -N accept-line zt_widget
  _zsagent_bind
  _zsagent_bind  # as when the plugin is sourced again
  assert_eq "$widgets[accept-line]" user:_zsagent_accept_line "accept-line widget"
  assert_eq "$widgets[_zsagent_orig_accept_line]" user:zt_widget "widget kept"
  assert_eq "$precmd_functions" "_zsagent_run _zsagent_prompt" "hooks registered once"
  zle() { calls+=("$*") }
  _zsagent_mode=command BUFFER='ls'
  _zsagent_accept_line
  assert_eq "$calls" "_zsagent_orig_accept_line" "command mode"
  assert_eq "$BUFFER" ls "line in command mode"
  calls=() _zsagent_mode=message BUFFER='hello model'
  _zsagent_accept_line
  assert_eq "$calls" ".accept-line" "message mode"
  assert_eq "$_zsagent_pending" "hello model" "message taken"
  assert_eq "$BUFFER" "" "line emptied"
  calls=()
  _zsagent_accept_line
  assert_eq "$calls" "_zsagent_orig_accept_line" "empty line in message mode"
}

test_accept_line_without_another_plugin() {
  local -a calls
  _zsagent_bind
  assert_eq $+widgets[_zsagent_orig_accept_line] 0 "no widget kept"
  zle() { calls+=("$*") }
  _zsagent_mode=command BUFFER='ls'
  _zsagent_accept_line
  assert_eq "$calls" ".accept-line" "command mode"
}

# config.zsh with the profiles first (model m1) and second (model m2), then the lines $@.
two_profiles() {
  (umask 077; print -rl -- "ZSAGENT_PROFILES='{\"first\": {\"provider\": \"custom\", \"url\": \"http://one.invalid\", \
\"key\": \"key-of-first\", \"model\": \"m1\"}, \"second\": {\"provider\": \"custom\", \"url\": \"http://two.invalid\", \
\"key\": \"key-of-second\", \"model\": \"m2\"}}'" "$@" > $ZSAGENT_HOME/config.zsh)
}

test_profile_is_the_one_config_names() {
  # Whenever config.zsh is read, the shell uses the profile it names, also after messages and after --profile.
  mock_text 1 ok; mock_text 2 ok; mock_text 3 ok; mock_text 4 ok
  turn hi
  assert_eq "$(jq -r .model $MOCK/req.1)" m "first profile of the config"
  two_profiles 'ZSAGENT_PROFILE=second'
  assert_match "$(zsagent --profile 2>&1)" $'zsagent: config.zsh changed: profile second \\(was mock\\)\n*\n\\* second *' \
    "notice of the changed profile, and the current profile in the list"
  assert_match "$(zsagent --new)" 'new session * \(second\)' "profile named by --new"
  turn again
  assert_eq "$(jq -r .model $MOCK/req.2)" m2 "ZSAGENT_PROFILE of the changed config"
  zsagent --profile first > /dev/null
  turn more
  assert_eq "$(jq -r .model $MOCK/req.3)" m1 "profile set with --profile"
  two_profiles 'ZSAGENT_PROFILE=second' '# changed'
  turn last
  assert_eq "$(jq -r .model $MOCK/req.4)" m2 "the config's profile again after config.zsh changed"
}

test_resumed_profile_not_in_config() {
  mkdir -p $ZSAGENT_HOME/sessions
  print -r -- '[]' > $ZSAGENT_HOME/sessions/abcd.gone.json
  zsagent --resume abcd > /dev/null
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT "*profile 'gone' is not in *config.zsh*" error
  assert_eq "$(print $MOCK/req.*(N))" "" "no request"
}

test_profile_typo_is_not_kept() {
  mock_text 1 ok
  two_profiles 'ZSAGENT_PROFILE=secnd'
  turn hi
  assert_eq $STATUS 1 status
  assert_match $OUT "*profile 'secnd' is not in *" error
  two_profiles 'ZSAGENT_PROFILE=second'
  turn hi
  assert_eq $STATUS 0 "status after the correction"
  assert_eq "$(jq -r .model $MOCK/req.1)" m2 "model after the correction"
}

test_other_home_takes_its_own_default_profile() {
  # A shell that sent a message with the profile its config names loads another copy with its own config
  # (README: Point to different versions).
  print -r -- 'ZSAGENT_PROFILE=mock' >> $ZSAGENT_HOME/config.zsh
  mock_text 1 ok; mock_text 2 ok
  turn hi
  ZSAGENT_HOME=$T/home2
  mkdir -p $ZSAGENT_HOME
  two_profiles
  source $ROOT/zsagent.plugin.zsh
  turn hi
  assert_eq $STATUS 0 status
  assert_eq "$(jq -r .model $MOCK/req.2)" m1 "first profile of the other config"
}

# ---- runner ---------------------------------------------------------------------------------------------------

if [[ $1 == --pty ]]; then  # internal: sourced by an interactive shell on a pseudo terminal; mock API and plugin
  source $ROOT/zsagent.plugin.zsh
  return 0
fi

if [[ $1 == --turn ]]; then  # internal: one turn of zsagent in this shell, with the environment of the calling test
  source $ROOT/zsagent.plugin.zsh
  zsagent "${@[2,-1]}"
  builtin exit $?
fi

if [[ $1 == --one ]]; then  # internal: run one test in this (fresh) shell
  (( $+functions[$2] )) || { print -r -- "    no test $2"; builtin exit 1 }
  setup
  trap 'rm -rf $T' EXIT
  $2
  builtin exit $_failed  # builtin: a test may define an exit function
fi

local -a tests=(${@:-${(okM)functions:#test_*}})
integer failed=0
for t in $tests; do
  if out=$(zsh -f $0 --one $t 2>&1 < /dev/null); then  # no terminal input: a command that asks gets no answer
    print -r -- "ok   $t"
  else
    print -r -- "FAIL $t"; print -r -- $out
    (( failed++ ))
  fi
done
print -r -- "$(( $#tests - failed ))/$#tests passed"
(( failed == 0 ))
