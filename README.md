# zsh-zai

AI command **suggest** and **explain** widgets for zsh, backed by the AI
subscription CLIs you already have — switchable between **Claude Code**,
**Codex**, and **OpenCode**. No API keys: if `claude` / `codex` / `opencode`
login works in your terminal, zai works.

```
$ files over 100MB modified this week        ⟵ type plain English
  [Alt+\]
$ find . -type f -size +100M -mtime -7       ⟵ line rewritten; YOU press Enter

$ tar -xzvf backup.tar.gz -C /opt
  [Alt+E]
── zai explain ──
Extract gzipped tar archive into /opt directory
-x  extract ...                              ⟵ printed above the prompt,
-z  gunzip ...                                  command left untouched
```

Nothing is ever auto-executed. Suggestions land in your editing buffer for
review; keystrokes typed while the backend is thinking are discarded so a
queued Enter can't run an unreviewed command.

## Install

Requires zsh and at least one of the backend CLIs
([Claude Code](https://docs.anthropic.com/en/docs/claude-code),
[Codex](https://github.com/openai/codex),
[OpenCode](https://opencode.ai)) installed and authenticated.

**oh-my-zsh**

```sh
git clone https://github.com/lance2k/zsh-zai ${ZSH_CUSTOM:-$HOME/.oh-my-zsh/custom}/plugins/zai
```

then add `zai` to your plugins list in `~/.zshrc`:

```sh
plugins=(... zai)
```

**plain zsh**

```sh
git clone https://github.com/lance2k/zsh-zai ~/.zsh-zai
echo 'source ~/.zsh-zai/zsh-zai.plugin.zsh' >> ~/.zshrc
```

**antigen**: `antigen bundle lance2k/zsh-zai` · **zinit**: `zinit light lance2k/zsh-zai`

## Usage

| Key | Action |
| --- | ------ |
| `Alt+\` | Rewrite the natural-language line into a shell command |
| `Alt+E` | Explain the command on the line (line left untouched) |

The `zai` command manages backends for the current session:

```
$ zai status          # backend, model, timeout, which CLIs are installed
$ zai use codex       # switch backend (session-scoped)
$ zai model gpt-5.4-mini   # set the current backend's model (session-scoped)
$ zai help
```

## Configuration

Set before the plugin loads (e.g. in `~/.zshrc`); all optional.

| Variable | Default | Meaning |
| -------- | ------- | ------- |
| `ZAI_BACKEND` | `claude` | `claude`, `codex`, or `opencode` |
| `ZAI_CLAUDE_MODEL` | `haiku` | Model for the claude backend |
| `ZAI_CODEX_MODEL` | `gpt-5.3-codex-spark` | Model for the codex backend |
| `ZAI_OPENCODE_MODEL` | `opencode-go/deepseek-v4-flash` | Model for the opencode backend (`provider/model`) |
| `ZAI_TIMEOUT` | `25` | Per-request timeout, seconds |
| `ZAI_KEY_SUGGEST` | `^[\\` (Alt+\) | Suggest keybinding |
| `ZAI_KEY_EXPLAIN` | `^[e` (Alt+E) | Explain keybinding |

Fast, cheap models are the right fit here — one-line shell commands don't need
frontier reasoning, and latency is what you feel. Quality alternative for
opencode: `opencode-go/kimi-k2.7-code`.

## Security model

- **Never auto-executes.** Suggestions replace the editing buffer only; you
  review and press Enter. One ZLE undo (`Ctrl+X u`) restores the original line.
- **Typeahead drain.** Keys pressed during the wait are discarded, so an
  impatient Enter can't accept a suggestion you haven't seen.
- **Validate, don't repair.** A suggestion is rejected unless it is a single
  line of printable ASCII ≤400 chars (the only transform allowed is unwrapping
  one complete markdown fence). Rejection beats silently "fixing" output in
  ways that change command semantics.
- **Display scrubbing.** Explanations and error messages are stripped of
  control characters (ANSI/OSC escape injection) and length-capped.
- **Backend isolation.** Every call runs from an empty cache directory
  (`~/.cache/zai`) with each CLI's tools/rules/plugins disabled as far as the
  CLI allows: claude gets `--disallowedTools`/`--strict-mcp-config`/no session
  persistence; codex runs `-s read-only --ephemeral` from a sandboxed
  HOME/CODEX_HOME and a neutral working dir so neither `~/.codex/AGENTS.md`
  nor `~/.agents/skills` ever enters the prompt (probe-verified); opencode
  runs `--pure` with websearch disabled.

Known limits of that boundary: user-level CLI config and hooks still apply
(for codex, only its built-in bundled skills — user files are excluded);
opencode keeps session records (it has no ephemeral mode); codex and opencode
receive instructions inline in the prompt rather than as a true system prompt;
claude's tool-disallow list is tied to CLI 2.x tool names. And as with any AI
tool: read the suggestion before you run it.

## Tests

```sh
zsh tests/test-units.zsh   # validation/scrub/dispatch/command units
zsh tests/test-zpty.zsh    # interactive ZLE behavior in a scripted pty
zsh tests/test-e2e.zsh [claude|codex|opencode]   # live call through your real zshrc
```

## License

MIT © 2026 Lance
