#!/usr/bin/env zsh
# End-to-end: the user's real zshrc (full plugin stack) + ONE live backend
# call. Usage: zsh tests/test-e2e.zsh [claude|codex|opencode]
emulate zsh
zmodload zsh/zpty || exit 2

backend=${1:-claude}

zpty zai zsh -i
trap 'zpty -d zai 2>/dev/null' EXIT
sleep 3

out=''
drain_pty() { local c; while zpty -r -t zai c 2>/dev/null; do out+=$c; done }
wait_for() { # pattern timeout_s
  local pat=$1 deadline=$(( SECONDS + $2 ))
  while (( SECONDS < deadline )); do
    drain_pty
    [[ $out == *$pat* ]] && return 0
    sleep 1
  done
  return 1
}
drain_pty; out=''

fails=0

zpty -w zai "zai use $backend"
if wait_for "backend -> $backend" 10; then print "ok: switched to $backend"
else print "FAIL: zai use $backend"; (( fails++ )); fi
out=''

# Explain a typed command via Alt+E. (Run before the suggest phase: a
# suggested command can pop a completion-menu pager over the line in
# live-menu setups like zsh-autocomplete's, which would eat the keypress —
# a human dismisses that naturally; a pty script can't reliably.)
zpty -w -n zai 'tar -xzvf backup.tar.gz -C /opt'
sleep 1
zpty -w -n zai $'\ee'
if wait_for 'zai explain' 45; then print "ok: [$backend] explain rendered"
else print -r -- "FAIL: [$backend] explain (tail: ${out[-300,-1]})"; (( fails++ )); fi
out=''
zpty -w -n zai $'\x15'   # kill-whole-line to clear the buffer
sleep 1

# Suggest: NL -> command in buffer (not executed)
zpty -w -n zai 'print the current date and time'
zpty -w -n zai $'\e\\'
if wait_for 'date' 45; then print "ok: [$backend] suggest produced a date command"
else print -r -- "FAIL: [$backend] suggest (tail: ${out[-300,-1]})"; (( fails++ )); fi
[[ $out == *'command not found'* ]] && { print "FAIL: stray execution"; (( fails++ )) }

print "fails=$fails"
(( fails == 0 ))
