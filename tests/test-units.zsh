#!/usr/bin/env zsh
# Unit tests for zai's pure functions, dispatcher, and `zai` command.
# No ZLE, no live backends — backend functions are stubbed.
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

# --- dispatcher (stub backends; fake binaries so $+commands passes anywhere) ---
for b in claude codex opencode; do
  print '#!/bin/sh' > "$bindir/$b"
  chmod +x "$bindir/$b"
done
path=("$bindir" $path)
hash -r

_zai_backend_claude()   { print claude-hit }
_zai_backend_codex()    { print codex-hit }
_zai_backend_opencode() { print opencode-hit }

d() { # name backend want_rc want_out
  local name=$1 backend=$2 want=$3 wantout=$4
  local out rc
  if [[ $backend == unset ]]; then
    out=$(print x | _zai_query sys); rc=$?
  else
    out=$(print x | ZAI_BACKEND=$backend _zai_query sys); rc=$?
  fi
  if (( rc != want )) || [[ $out != $wantout ]]; then
    print -r -- "FAIL: $name (rc=$rc out=${(q)out})"; (( fails++ ))
  else
    print -r -- "ok: $name"
  fi
}

unset ZAI_BACKEND
d dispatch-default  unset    0 claude-hit
d dispatch-claude   claude   0 claude-hit
d dispatch-codex    codex    0 codex-hit
d dispatch-opencode opencode 0 opencode-hit
d dispatch-bogus    bogus    2 ''
grep -q 'unknown ZAI_BACKEND' "$_zai_cache/last-stderr" \
  && print "ok: bogus-writes-stderr" \
  || { print "FAIL: bogus-writes-stderr"; (( fails++ )) }

# --- zai command ---
zai use opencode >/dev/null
[[ $ZAI_BACKEND == opencode ]] && print "ok: zai-use" || { print "FAIL: zai-use"; (( fails++ )) }
zai use nope 2>/dev/null; (( $? == 2 )) && print "ok: zai-use-invalid" || { print "FAIL: zai-use-invalid"; (( fails++ )) }
st=$(zai status)
[[ $st == *'backend: opencode'* && $st == *claude* && $st == *codex* ]] \
  && print "ok: zai-status" || { print -r -- "FAIL: zai-status -> $st"; (( fails++ )) }
zai model foo >/dev/null
[[ $ZAI_OPENCODE_MODEL == foo ]] && print "ok: zai-model" || { print "FAIL: zai-model"; (( fails++ )) }
zai bogus-sub 2>/dev/null; (( $? == 2 )) && print "ok: zai-unknown-sub" || { print "FAIL: zai-unknown-sub"; (( fails++ )) }
unset ZAI_BACKEND ZAI_OPENCODE_MODEL

print "fails=$fails"
(( fails == 0 ))
