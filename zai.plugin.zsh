# zai — AI suggest/explain ZLE widgets for zsh, with switchable subscription
# backends (Claude Code, Codex, OpenCode).
#
#   Alt+\  rewrite the natural-language line into a shell command (review, then Enter)
#   Alt+E  print an explanation of the command on the line, leaving it untouched
#
# Responses typically take a few seconds (backend/model dependent). Nothing is
# ever auto-executed: suggestions land in the editing buffer for your review.
#
# Config (set before the plugin loads, or per session via the `zai` command):
#   ZAI_BACKEND         claude | codex | opencode      (default: claude)
#   ZAI_CLAUDE_MODEL    default: haiku
#   ZAI_CODEX_MODEL     default: gpt-5.3-codex-spark
#   ZAI_OPENCODE_MODEL  default: opencode-go/deepseek-v4-flash
#   ZAI_TIMEOUT         seconds (default: 25)
#   ZAI_KEY_SUGGEST     default: '^[\\'  (Alt+\)
#   ZAI_KEY_EXPLAIN     default: '^[e'   (Alt+E)
#
# Trust boundary: backends run from an empty cache dir with tools, rules, MCP,
# and plugins disabled as far as each CLI allows; user-level CLI config and
# hooks still apply. Known deviations: opencode keeps session records (it has
# no ephemeral mode); codex and opencode receive instructions inline in the
# prompt rather than as a true system prompt.

typeset -g ZAI_VERSION=1.0.1
typeset -g _zai_cache=${XDG_CACHE_HOME:-$HOME/.cache}/zai
typeset -g ZAI_KEY_SUGGEST=${ZAI_KEY_SUGGEST:-'^[\\'}
typeset -g ZAI_KEY_EXPLAIN=${ZAI_KEY_EXPLAIN:-'^[e'}

() {
  typeset -g _ZAI_OS='Linux'
  local line
  if [[ $OSTYPE == darwin* ]]; then
    _ZAI_OS='macOS'
  elif [[ -r /etc/os-release ]]; then
    for line in ${(f)"$(</etc/os-release)"}; do
      [[ $line == PRETTY_NAME=* ]] && { _ZAI_OS=${${line#PRETTY_NAME=}//\"/}; break }
    done
  fi
}

typeset -g _ZAI_SUGGEST_PROMPT="You convert a natural-language request into exactly one zsh command line for ${_ZAI_OS}. Output only the command: a single line, no markdown, no code fences, no commentary. If the input is already a shell command, return it unchanged or fixed."
typeset -g _ZAI_EXPLAIN_PROMPT="Explain the given zsh command for ${_ZAI_OS}: one summary line, then each flag or argument on its own line, briefly. Plain text only, no markdown, at most 20 lines."

# Backend registry. Adding a backend means one entry in each of these three
# plus a _zai_backend_<name> function; dispatch, `zai use|model|status|help`
# and the model lookup all read from here. The first entry is the default.
typeset -ga _zai_backends=(claude codex opencode)
typeset -gA _zai_model_var=(
  claude   ZAI_CLAUDE_MODEL
  codex    ZAI_CODEX_MODEL
  opencode ZAI_OPENCODE_MODEL
)
typeset -gA _zai_model_default=(
  claude   haiku
  codex    gpt-5.3-codex-spark
  opencode opencode-go/deepseek-v4-flash
)
typeset -g _ZAI_DEFAULT_TIMEOUT=25

_zai_model() {
  local backend=${1:-${ZAI_BACKEND:-$_zai_backends[1]}}
  local var=${_zai_model_var[$backend]-}
  if [[ -z $var ]]; then
    print -r -- "?"
    return
  fi
  print -r -- "${(P)var:-$_zai_model_default[$backend]}"
}

# Every backend CLI is launched through this, so the time limit and the exit
# codes that mean "timed out" are defined in one place.
_zai_run() {
  command timeout -k 5 "${ZAI_TIMEOUT:-$_ZAI_DEFAULT_TIMEOUT}" "$@"
}
_zai_timed_out() {
  (( $1 == 124 || $1 == 137 ))
}

# For CLIs with no system-prompt flag: instructions and request in one prompt.
_zai_inline_prompt() {
  print -r -- "$1"$'\n\nRequest:\n'"$2"
}

# Backend contract: system prompt as $1, request on stdin, reply on stdout,
# nonzero rc on failure. stderr is already redirected to this shell's error
# file by the dispatcher. Launch the CLI through _zai_run.

_zai_backend_claude() {
  _zai_run claude -p \
    --model "$(_zai_model claude)" \
    --system-prompt "$1" \
    --exclude-dynamic-system-prompt-sections \
    --disallowedTools 'Bash,Edit,Write,Read,Glob,Grep,WebFetch,WebSearch,Task,NotebookEdit,TodoWrite,Agent' \
    --strict-mcp-config \
    --no-session-persistence
}

# codex has no system-prompt flag and prints transcript chatter to stdout; the
# clean answer only exists via --output-last-message. Isolation needs three
# legs (each probe-verified necessary): fake CODEX_HOME drops ~/.codex/AGENTS.md,
# fake HOME drops $HOME/.agents/skills, and a cwd outside the real home tree
# defeats codex's ancestor-directory skill/doc discovery. Auth rides in as a
# symlink; codex's own bundled skills remain (they ship with the CLI).
_zai_backend_codex() {
  local req rc
  req=$(command cat)
  local sandbox=$_zai_cache/codex-home
  local workdir=${TMPDIR:-/tmp}/zai-codex-$UID
  local out=$_zai_cache/run.$$.codex-out
  command mkdir -p -m 700 -- "$sandbox" "$workdir" || return 1
  [[ -O $workdir ]] || { print -u2 "workdir $workdir not owned by us"; return 1 }
  command ln -sf -- "${CODEX_HOME:-$HOME/.codex}/auth.json" "$sandbox/auth.json"
  cd -- "$workdir" || return 1
  HOME=$sandbox CODEX_HOME=$sandbox _zai_run codex exec \
    -m "$(_zai_model codex)" \
    -c model_reasoning_effort=low \
    -c project_doc_max_bytes=0 \
    -s read-only --ephemeral --skip-git-repo-check \
    --ignore-rules --color never \
    --output-last-message "$out" \
    -- "$(_zai_inline_prompt "$1" "$req")" >/dev/null
  rc=$?
  if (( rc == 0 )); then
    if [[ -s $out ]]; then
      command cat -- "$out"
    else
      rc=1
      print -u2 'codex produced no output'
    fi
  fi
  command rm -f -- "$out"
  return $rc
}

# OPENCODE_ENABLE_EXA=0 keeps the websearch tool disabled even when the user's
# environment enables it; --pure disables external plugins.
_zai_backend_opencode() {
  local req
  req=$(command cat)
  OPENCODE_ENABLE_EXA=0 _zai_run opencode run \
    -m "$(_zai_model opencode)" \
    --pure --log-level ERROR \
    -- "$(_zai_inline_prompt "$1" "$req")"
}

# Runs the active backend from the empty cache dir so no project-level CLI
# config (.claude/, AGENTS.md, git context) can influence the call. Scratch
# files are named run.<pid>.* so two shells never read each other's; $$ is
# still the interactive shell's pid inside the subshells below.
_zai_query() {
  emulate -L zsh
  command mkdir -p -- "$_zai_cache" || return 1
  local backend=${ZAI_BACKEND:-$_zai_backends[1]}
  if (( ! ${_zai_backends[(Ie)$backend]} )); then
    print -r -- "unknown ZAI_BACKEND '$backend' (${(j:|:)_zai_backends})" >| "$_zai_cache/run.$$.stderr"
    return 2
  fi
  if (( ! $+commands[$backend] )); then
    print -r -- "'$backend' CLI not installed" >| "$_zai_cache/run.$$.stderr"
    return 127
  fi
  (
    cd -- "$_zai_cache" || exit 1
    _zai_backend_$backend "$1" 2>run.$$.stderr
  )
}

# Discard keystrokes queued while the backend was blocking, so an impatient
# Enter can't execute the freshly inserted (unreviewed) command.
_zai_drain() {
  local _junk
  while read -t 0 -k 1 _junk 2>/dev/null; do :; done
}

# Strip C0 controls (except newline/tab) and DEL from text destined for
# display, killing ANSI/OSC escape injection; cap length.
_zai_scrub_text() {
  emulate -L zsh
  local s=$1
  s=${s//[$'\x01'-$'\x08'$'\x0b'-$'\x1f'$'\x7f']/}
  print -r -- "${s[1,4000]}"
}

# Validate a suggested command: reject rather than repair (a lone backtick is
# command-substitution syntax — stripping it would change semantics). The only
# transform allowed is unwrapping one complete ```fence``` around the output.
_zai_validate_cmd() {
  emulate -L zsh
  setopt localoptions extendedglob
  local r=$1
  local -a rl
  rl=("${(@f)r}")
  if (( ${#rl} >= 3 )) && [[ $rl[1] == '```'* && ${rl[-1]//[[:space:]]/} == '```' ]]; then
    r=${(pj:\n:)rl[2,-2]}
  fi
  r=${r##[[:space:]]#}
  r=${r%%[[:space:]]#}
  [[ -n $r ]] || return 1
  [[ $r != *$'\n'* ]] || return 1
  (( ${#r} <= 400 )) || return 1
  [[ $r != *[^$'\x20'-$'\x7e']* ]] || return 1
  print -r -- "$r"
}

_zai_error() {
  emulate -L zsh
  local rc=$1 line
  if _zai_timed_out $rc; then
    zle -M "zai: timed out after ${ZAI_TIMEOUT:-$_ZAI_DEFAULT_TIMEOUT}s"
    return
  fi
  line=$(command head -c 200 "$_zai_cache/run.$$.stderr" 2>/dev/null)
  line=${line//$'\n'/ }
  line=$(_zai_scrub_text "$line")
  zle -M "zai: backend failed, exit $rc${line:+ — ${line[1,120]}}"
}

# One round-trip for the line being edited: $1 is the system prompt, $2 the
# message for a blank line. The reply lands in REPLY. Returns 0 when a reply
# is ready, 1 when the backend failed, 2 when the line was blank; in the last
# two cases the message has already been shown.
_zai_ask() {
  emulate -L zsh
  local req=$BUFFER rc
  if [[ -z ${req//[[:space:]]/} ]]; then
    zle -M "$2"
    return 2
  fi
  zle -M "⏳ zai: asking ${ZAI_BACKEND:-$_zai_backends[1]} ($(_zai_model))…"
  zle -R
  {
    REPLY=$(print -r -- "$req" | _zai_query "$1")
    rc=$?
    _zai_drain
    if (( rc != 0 )); then
      _zai_error $rc
      return 1
    fi
  } always {
    # Runs on every way out, including a wait the user interrupted with
    # Ctrl-C, so no call leaves its files behind.
    command rm -f -- "$_zai_cache"/run.$$.*(N)
  }
  return 0
}

_zai_suggest() {
  emulate -L zsh
  local REPLY cmd
  _zai_ask "$_ZAI_SUGGEST_PROMPT" "zai: type a natural-language request first"
  case $? in
    1) return 1 ;;
    2) return 0 ;;
  esac
  if ! cmd=$(_zai_validate_cmd "$REPLY"); then
    zle -M "zai: rejected an unusable response (empty/multi-line/control chars) — try rewording"
    return 1
  fi
  BUFFER=$cmd
  CURSOR=${#BUFFER}
  (( REGION_ACTIVE )) && REGION_ACTIVE=0
  zle -M ""
  return 0
}

_zai_explain() {
  emulate -L zsh
  local REPLY out
  _zai_ask "$_ZAI_EXPLAIN_PROMPT" "zai: nothing on the line to explain"
  case $? in
    1) return 1 ;;
    2) return 0 ;;
  esac
  out=$(_zai_scrub_text "$REPLY")
  local -a lines
  lines=("${(@f)out}")
  (( ${#lines} > 24 )) && lines=("${(@)lines[1,24]}" "…")
  zle -M ""
  zle -I
  print -rl -- "" "── zai explain ──" "${(@)lines}" ""
  return 0
}

zai() {
  emulate -L zsh
  local names=${(j:|:)_zai_backends}
  local cur=${ZAI_BACKEND:-$_zai_backends[1]} b mark inst var
  case ${1:-status} in
    use)
      if (( ! ${_zai_backends[(Ie)${2:-}]} )); then
        print -ru2 -- "zai: usage: zai use <$names>"
        return 2
      fi
      export ZAI_BACKEND=$2
      print -r -- "zai: backend -> $2 (this session; persist with 'export ZAI_BACKEND=$2' in your zshrc)"
      ;;
    model)
      if [[ -z ${2:-} ]]; then
        print -ru2 -- "zai: usage: zai model <model>  (sets the model for the current backend: $cur)"
        return 2
      fi
      var=${_zai_model_var[$cur]-}
      [[ -n $var ]] && export "$var=$2"
      print -r -- "zai: $cur model -> $2 (this session)"
      ;;
    status)
      print -r -- "zai $ZAI_VERSION — backend: $cur ($(_zai_model)), timeout: ${ZAI_TIMEOUT:-$_ZAI_DEFAULT_TIMEOUT}s"
      print -r -- "keys: suggest $ZAI_KEY_SUGGEST  explain $ZAI_KEY_EXPLAIN"
      for b in $_zai_backends; do
        mark=' '
        [[ $b == $cur ]] && mark='*'
        inst='not installed'
        (( $+commands[$b] )) && inst='installed'
        printf ' %s %-9s %-14s %s\n' $mark $b $inst "$(_zai_model $b)"
      done
      ;;
    help|-h|--help)
      print -rl -- \
        "zai $ZAI_VERSION — AI suggest/explain widgets" \
        "  $ZAI_KEY_SUGGEST : turn the natural-language line into a shell command" \
        "  $ZAI_KEY_EXPLAIN : explain the command on the line" \
        "usage: zai [status] | zai use <$names> | zai model <model> | zai help" \
        "env: ZAI_BACKEND ZAI_CLAUDE_MODEL ZAI_CODEX_MODEL ZAI_OPENCODE_MODEL ZAI_TIMEOUT ZAI_KEY_SUGGEST ZAI_KEY_EXPLAIN"
      ;;
    *)
      print -ru2 -- "zai: unknown subcommand '$1' (use|model|status|help)"
      return 2
      ;;
  esac
}

if [[ -o zle ]]; then
  zle -N _zai_suggest
  zle -N _zai_explain
  bindkey -- "$ZAI_KEY_SUGGEST" _zai_suggest
  bindkey -- "$ZAI_KEY_EXPLAIN" _zai_explain
fi
