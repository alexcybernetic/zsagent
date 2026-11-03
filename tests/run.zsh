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
  print -r -- "ZSAGENT_PROFILES='{\"mock\": {\"provider\": \"custom\", \"url\": \"http://mock.invalid/v1/responses\", \
\"key\": \"secret-key\", \"model\": \"m\"}}'" > $ZSAGENT_HOME/config.zsh
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

test_lock_busy() {
  mock_text 1 ok
  sleep 30 &!
  local pid=$!
  mkdir -p $(session).lock && print -r -- $pid > $(session).lock/pid
  turn hi
  kill $pid
  assert_eq $STATUS 1 status
  assert_match $OUT '*in use by another shell*' error
  assert_eq "$(print $MOCK/req.*(N))" "" "no request"
}

test_lock_stale_taken_over_and_released() {
  mock_text 1 ok
  zsh -fc 'print $$' > $T/deadpid
  mkdir -p $(session).lock && cp $T/deadpid $(session).lock/pid
  turn hi
  assert_eq $STATUS 0 status
  [[ ! -e $(session).lock ]] || fail "lock not released"
}

test_lock_released_after_error() {
  turn hi   # no response prepared
  assert_eq $STATUS 1 status
  [[ ! -e $(session).lock ]] || fail "lock not released"
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
    "Interrupted by the user." "closing output"
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
}

test_stream_with_junk_and_done_lines() {
  { print -r -- 'data: {"type":"response.output_text.delta","delta":"hel"}'
    print -r -- 'data: not json'
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

test_prompt_roundtrip() {
  zle() { : }
  PS1='user %# '
  _zsagent_toggle
  assert_eq $PS1 $ZSAGENT_MESSAGE_PS1 "message prompt"
  _zsagent_toggle
  assert_eq $PS1 'user %# ' "user prompt restored"
}

# ---- runner ---------------------------------------------------------------------------------------------------

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
  if out=$(zsh -f $0 --one $t 2>&1); then
    print -r -- "ok   $t"
  else
    print -r -- "FAIL $t"; print -r -- $out
    (( failed++ ))
  fi
done
print -r -- "$(( $#tests - failed ))/$#tests passed"
(( failed == 0 ))
