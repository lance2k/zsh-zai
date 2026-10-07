#!/usr/bin/env zsh
# Interactive ZLE tests via zpty: dispatcher failure safety, Ctrl-C cleanup,
# queued-Enter drain, wait message, buffer replacement, deliberate accept.
emulate zsh
zmodload zsh/zpty || { print "SKIP: no zpty"; exit 2 }

plugin=${0:A:h}/../zai.plugin.zsh
td=$(mktemp -d)
trap 'zpty -d zai 2>/dev/null; rm -rf $td' EXIT

mkdir -p $td/bin $td/log $td/codex $td/tmp
cp ${0:A:h}/fake-cli $td/bin/codex
chmod +x $td/bin/codex
print '{}' > $td/codex/auth.json

cat > $td/.zshrc <<EOF
PS1='%% '
preexec() { print -r -- "EXEC:\$1" }
path=($td/bin \$path)
export ZAI_FAKE_LOG=$td/log CODEX_HOME=$td/codex TMPDIR=$td/tmp
source $plugin
EOF

zpty zai env ZDOTDIR=$td XDG_CACHE_HOME=$td/cache zsh -i
sleep 1

out=''
drain_pty() { local c; while zpty -r -t zai c 2>/dev/null; do out+=$c; done }
drain_pty; out=''

fails=0
check() { # name pattern should_match(1/0) haystack
  local name=$1 pat=$2 want=$3 hay=$4
  local got=0; [[ $hay == *$pat* ]] && got=1
  if (( got != want )); then print -r -- "FAIL: $name"; (( fails++ ))
  else print -r -- "ok: $name"; fi
}

# Phase D: unknown backend fails cleanly, buffer untouched (real dispatcher)
zpty -w zai 'export ZAI_BACKEND=bogus'
sleep 0.5; drain_pty; out=''
zpty -w -n zai 'echo original'
zpty -w -n zai $'\e\\'
sleep 2
drain_pty; D=$out; out=''
check "D: backend-failed message"   'backend failed' 1 "$D"
check "D: nothing executed"         'EXEC:'          0 "$D"
zpty -w -n zai $'\r'
sleep 1
drain_pty; D2=$out; out=''
check "D: original buffer intact"   'EXEC:echo original' 1 "$D2"
scratch_files() { local -a f; f=($td/cache/zai/*(N.)); print -r -- "files=${#f}" }
check "D: error file removed"       'files=0' 1 "$(scratch_files)"

# Phase E: Ctrl-C during the wait. The fake codex has written its answer file
# and then hangs. Ctrl-C does not cut the wait short today (the call runs on
# to ZAI_TIMEOUT), so the checks are made after the time limit: nothing may be
# left in the cache dir, nothing executed, and the shell usable.
zpty -w zai 'zai use codex; export ZAI_FAKE_MODE=stall ZAI_TIMEOUT=2'
sleep 0.5; drain_pty; out=''
zpty -w -n zai 'echo interrupted'
zpty -w -n zai $'\e\\'
sleep 1.5
mid=$(scratch_files)
answer=($td/cache/zai/run.*.codex-out(N))
zpty -w -n zai $'\x03'
sleep 4
drain_pty; E=$out; out=''
check "E: scratch files exist mid-call"   'files=0' 0 "$mid"
check "E: answer file written mid-call"   'answers=1' 1 "answers=${#answer}"
check "E: Ctrl-C leaves no scratch files" 'files=0' 1 "$(scratch_files)"
check "E: nothing executed"               'EXEC:'   0 "$E"
zpty -w zai 'unset ZAI_FAKE_MODE ZAI_TIMEOUT; echo alive'
sleep 1
drain_pty; E2=$out; out=''
check "E: shell still usable"             'EXEC:unset ZAI_FAKE_MODE ZAI_TIMEOUT; echo alive' 1 "$E2"

# Restore a valid backend and install a slow stub for phases A-C
zpty -w zai 'zai use claude'
sleep 0.5
zpty -w zai '_zai_query() { command sleep 2; print -r -- "echo SAFE" }'
sleep 0.5; drain_pty; out=''

# Phase A: request + Alt+\ , then an impatient Enter DURING the 2s wait
zpty -w -n zai 'list files here'
zpty -w -n zai $'\e\\'
sleep 0.4
zpty -w -n zai $'\r'
sleep 3
drain_pty; A=$out; out=''
check "A: wait-message shown"        'asking claude' 1 "$A"
check "A: queued Enter NOT executed" 'EXEC:'         0 "$A"
check "A: suggestion in buffer"      'echo SAFE'     1 "$A"

# Phase B: deliberate Enter after review -> executes
zpty -w -n zai $'\r'
sleep 1
drain_pty; B=$out; out=''
check "B: deliberate Enter executes" 'EXEC:echo SAFE' 1 "$B"

# Phase C: empty-buffer no-op
zpty -w -n zai $'\e\\'
sleep 1
drain_pty; C=$out; out=''
check "C: empty-buffer message"      'natural-language request' 1 "$C"
check "C: empty-buffer no exec"      'EXEC:'                    0 "$C"

print "fails=$fails"
(( fails == 0 ))
