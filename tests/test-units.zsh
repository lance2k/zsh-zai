#!/usr/bin/env zsh
# Unit tests for zai's pure functions, dispatcher, and `zai` command.
# No ZLE, no live backends — the CLIs are replaced by tests/fake-cli.
emulate zsh

source "${0:A:h}/../zai.plugin.zsh" || { print "FAIL: source"; exit 1 }

_zai_cache=$(mktemp -d)
bindir=$(mktemp -d)
trap 'rm -rf "$_zai_cache" "$bindir"' EXIT

fails=0

t() { # name want_rc input [want_out]
  local name=$1 want=$2 in=$3 wantout=${4-}
  local out rc
  out=$(_zai_validate_cmd "$in"); rc=$?
  if (( rc != want )) || { (( want == 0 )) && [[ $out != $wantout ]] }; then
    print -r -- "FAIL: $name (rc=$rc want=$want out=${(q)out})"; (( fails++ ))
  else
    print -r -- "ok: $name"
  fi
}

# --- validation ---
t plain          0 'ls -la' 'ls -la'
t trimmed        0 $'  ls -la  \n' 'ls -la'
t fenced         0 $'```zsh\nls -la\n```' 'ls -la'
t fenced-bare    0 $'```\nfind . -name "*.log"\n```' 'find . -name "*.log"'
t backtick-kept  0 'echo `date`' 'echo `date`'
t leading-dash   0 '--help me' '--help me'
t trailing-cr    0 $'ls -la\r' 'ls -la'
t multiline      1 $'ls\npwd'
t fence-multi    1 $'```\nls\npwd\n```'
t empty          1 $'   \n '
t esc-seq        1 $'ls \e[31m-la'
t embedded-cr    1 $'ls\rpwd'
t non-ascii      1 $'echo résumé'
t oversize       1 "echo ${(l:500::x:)}"

# --- scrub ---
s=$(_zai_scrub_text $'a\e[2Jb\x01c')
[[ $s == 'a[2Jbc' ]] && print "ok: scrub-controls" || { print -r -- "FAIL: scrub-controls -> ${(q)s}"; (( fails++ )) }
s=$(_zai_scrub_text $'line1\nline2\ttab')
[[ $s == $'line1\nline2\ttab' ]] && print "ok: scrub-keeps-nl-tab" || { print -r -- "FAIL: scrub-keeps-nl-tab -> ${(q)s}"; (( fails++ )) }

# --- backends: the real adapters, launched against recording fake CLIs ---
# tests/fake-cli stands in for all three CLIs (first on PATH) and writes down
# its argv, cwd, environment and stdin, so the isolation flags are asserted
# without a live call.
export ZAI_FAKE_LOG=$(mktemp -d)
realcodex=$(mktemp -d)
print '{}' > "$realcodex/auth.json"
export CODEX_HOME=$realcodex
export TMPDIR=$(mktemp -d)
trap 'rm -rf "$_zai_cache" "$bindir" "$ZAI_FAKE_LOG" "$realcodex" "$TMPDIR"' EXIT

for b in claude codex opencode; do
  cp "${0:A:h}/fake-cli" "$bindir/$b"
  chmod +x "$bindir/$b"
done
path=("$bindir" $path)
hash -r

typeset -a argv_seen
typeset out rc

ask() { # backend mode
  rm -f "$ZAI_FAKE_LOG"/*(N)
  if [[ $1 == unset ]]; then
    out=$(print -r -- 'the request' | ZAI_FAKE_MODE=$2 _zai_query 'the system prompt'); rc=$?
  else
    out=$(print -r -- 'the request' | ZAI_BACKEND=$1 ZAI_FAKE_MODE=$2 _zai_query 'the system prompt'); rc=$?
  fi
  argv_seen=()
  if [[ -r $ZAI_FAKE_LOG/argv ]]; then
    argv_seen=("${(@0)$(<$ZAI_FAKE_LOG/argv)}")
    argv_seen[-1]=()   # the record ends with a NUL, which splits off one empty element
  fi
}
has()    { (( ${argv_seen[(Ie)$1]} )) }
val()    { local i=${argv_seen[(ie)$1]}; print -r -- "${argv_seen[i+1]-}" }
logged() { print -r -- "$(<$ZAI_FAKE_LOG/$1)" }
chk() { # name expression
  if eval "$2"; then print -r -- "ok: $1"
  else print -r -- "FAIL: $1 (rc=$rc out=${(q)out})"; (( fails++ )); fi
}
inline_prompt=$'the system prompt\n\nRequest:\nthe request'

unset ZAI_BACKEND ZAI_CLAUDE_MODEL ZAI_CODEX_MODEL ZAI_OPENCODE_MODEL ZAI_TIMEOUT

ask unset ok
chk dispatch-default  '[[ $(logged calls) == claude && $rc == 0 ]]'

ask claude ok
chk claude-reply          '[[ $rc == 0 && $out == claude-reply ]]'
chk claude-dispatch       '[[ $(logged calls) == claude ]]'
chk claude-model-default  '[[ $(val --model) == haiku ]]'
chk claude-system-prompt  '[[ $(val --system-prompt) == "the system prompt" ]]'
chk claude-request-stdin  '[[ $(logged stdin) == "the request" ]]'
chk claude-no-dynamic-sections 'has --exclude-dynamic-system-prompt-sections'
chk claude-strict-mcp     'has --strict-mcp-config'
chk claude-no-session     'has --no-session-persistence'
chk claude-cwd-is-cache   '[[ $(logged cwd) == ${_zai_cache:A} ]]'
blocked=(${(s:,:)"$(val --disallowedTools)"})
for tool in Bash Edit Write Read Glob Grep WebFetch WebSearch Task NotebookEdit TodoWrite Agent; do
  chk "claude-blocks-$tool" '(( ${blocked[(Ie)$tool]} ))'
done
ZAI_CLAUDE_MODEL=other-model ask claude ok
chk claude-model-override '[[ $(val --model) == other-model ]]'
ZAI_CLAUDE_MODEL= ask claude ok
chk claude-model-empty-uses-default '[[ $(val --model) == haiku ]]'

ask codex ok
chk codex-reply-only-last-message '[[ $rc == 0 && $out == codex-reply ]]'
chk codex-dispatch        '[[ $(logged calls) == codex ]]'
chk codex-model-default   '[[ $(val -m) == gpt-5.3-codex-spark ]]'
chk codex-home-sandboxed  '[[ $(logged env) == *"HOME=$_zai_cache/codex-home"$'"'\n'"'"CODEX_HOME=$_zai_cache/codex-home"$'"'\n'"'* ]]'
chk codex-cwd-is-workdir  '[[ $(logged cwd) == ${TMPDIR:A}/zai-codex-$UID ]]'
chk codex-cwd-not-cache   '[[ $(logged cwd) != ${_zai_cache:A}* ]]'
chk codex-read-only       '[[ $(val -s) == read-only ]]'
chk codex-ephemeral       'has --ephemeral'
chk codex-ignore-rules    'has --ignore-rules'
chk codex-no-project-doc  '(( i = ${argv_seen[(Ie)project_doc_max_bytes=0]} )) && [[ $argv_seen[i-1] == -c ]]'
chk codex-prompt-is-last-arg '[[ $argv_seen[-1] == $inline_prompt && $argv_seen[-2] == -- ]]'
authlink=$_zai_cache/codex-home/auth.json
chk codex-auth-symlink    '[[ -L $authlink && ${authlink:A} == ${realcodex:A}/auth.json ]]'
chk codex-out-file-removed '[[ -z $(print -l $_zai_cache/*codex-out*(N)) ]]'
ZAI_CODEX_MODEL=other-model ask codex ok
chk codex-model-override  '[[ $(val -m) == other-model ]]'
ZAI_CODEX_MODEL= ask codex ok
chk codex-model-empty-uses-default '[[ $(val -m) == gpt-5.3-codex-spark ]]'
ask codex empty
chk codex-empty-fails     '[[ $rc == 1 && -z $out ]]'
chk codex-empty-message   'grep -q "codex produced no output" "$_zai_cache/run.$$.stderr"'

ask opencode ok
chk opencode-reply        '[[ $rc == 0 && $out == opencode-reply ]]'
chk opencode-dispatch     '[[ $(logged calls) == opencode ]]'
chk opencode-model-default '[[ $(val -m) == opencode-go/deepseek-v4-flash ]]'
chk opencode-pure         'has --pure'
chk opencode-no-websearch '[[ $(logged env) == *OPENCODE_ENABLE_EXA=0* ]]'
chk opencode-prompt-is-last-arg '[[ $argv_seen[-1] == $inline_prompt && $argv_seen[-2] == -- ]]'
ZAI_OPENCODE_MODEL=other-model ask opencode ok
chk opencode-model-override '[[ $(val -m) == other-model ]]'
ZAI_OPENCODE_MODEL= ask opencode ok
chk opencode-model-empty-uses-default '[[ $(val -m) == opencode-go/deepseek-v4-flash ]]'

for b in claude codex opencode; do
  ask $b fail
  chk "$b-failure-rc"      '[[ $rc == 3 && -z $out ]]'
  chk "$b-failure-stderr"  'grep -q "$b blew up" "$_zai_cache/run.$$.stderr"'
  started=$SECONDS
  ZAI_TIMEOUT=1 ask $b hang
  chk "$b-timeout"         '[[ $rc == 124 ]] && (( SECONDS - started <= 4 ))'
done

# A child of the CLI that ignores TERM must not outlive a timed-out call and
# write the answer file afterwards.
ZAI_TIMEOUT=1 ask codex orphan
orphan=$(logged child)
chk codex-timeout-rc           '[[ $rc == 124 ]]'
chk codex-timeout-kills-orphan '! kill -0 $orphan 2>/dev/null'
sleep 4
chk codex-timeout-no-late-file '[[ -z $(print -l $_zai_cache/*codex-out*(N)) ]]'

ask bogus ok
chk dispatch-bogus        '[[ $rc == 2 && -z $out && ! -e $ZAI_FAKE_LOG/calls ]]'
chk bogus-writes-stderr   'grep -q "unknown ZAI_BACKEND" "$_zai_cache/run.$$.stderr"'

out=$(
  rm "$bindir/opencode"
  path=(${^path}(N/e:'[[ ! -x $REPLY/opencode ]]':))
  hash -r
  print x | ZAI_BACKEND=opencode _zai_query sys
); rc=$?
chk dispatch-not-installed '[[ $rc == 127 ]]'
chk not-installed-message  'grep -q "CLI not installed" "$_zai_cache/run.$$.stderr"'

# --- stale scratch files are swept when the plugin loads ---
(
  export XDG_CACHE_HOME=$(mktemp -d)
  mkdir -p "$XDG_CACHE_HOME/zai"
  command sleep 0 & dead=$!
  wait $dead
  : > "$XDG_CACHE_HOME/zai/run.$dead.stderr" > "$XDG_CACHE_HOME/zai/run.$dead.codex-out"
  : > "$XDG_CACHE_HOME/zai/run.$$.stderr" > "$XDG_CACHE_HOME/zai/keep.txt"
  source "${0:A:h}/../zai.plugin.zsh"
  left=("$XDG_CACHE_HOME"/zai/*(N:t))
  rm -rf "$XDG_CACHE_HOME"
  [[ ${(j: :)left} == "keep.txt run.$$.stderr" ]]
) && print "ok: sweep-removes-only-dead-shells-files" \
  || { print "FAIL: sweep-removes-only-dead-shells-files"; (( fails++ )) }

# --- zai command ---
zai use opencode >/dev/null
[[ $ZAI_BACKEND == opencode ]] && print "ok: zai-use" || { print "FAIL: zai-use"; (( fails++ )) }
zai use nope 2>/dev/null; (( $? == 2 )) && print "ok: zai-use-invalid" || { print "FAIL: zai-use-invalid"; (( fails++ )) }
st=$(zai status)
[[ $st == *'backend: opencode'* && $st == *claude* && $st == *codex* ]] \
  && print "ok: zai-status" || { print -r -- "FAIL: zai-status -> $st"; (( fails++ )) }
zai model foo >/dev/null
[[ $ZAI_OPENCODE_MODEL == foo ]] && print "ok: zai-model" || { print "FAIL: zai-model"; (( fails++ )) }
unset ZAI_OPENCODE_MODEL
ZAI_BACKEND=bogus
zai model foo > "$_zai_cache/model-out" 2>&1; rc=$?
st=$(<"$_zai_cache/model-out")
[[ $rc == 0 && $st == 'zai: bogus model -> foo (this session)' && -z ${ZAI_CLAUDE_MODEL-}${ZAI_CODEX_MODEL-}${ZAI_OPENCODE_MODEL-} ]] \
  && print "ok: zai-model-unknown-backend" || { print -r -- "FAIL: zai-model-unknown-backend (rc=$rc) -> $st"; (( fails++ )) }
zai bogus-sub 2>/dev/null; (( $? == 2 )) && print "ok: zai-unknown-sub" || { print "FAIL: zai-unknown-sub"; (( fails++ )) }
unset ZAI_BACKEND ZAI_OPENCODE_MODEL

print "fails=$fails"
(( fails == 0 ))
