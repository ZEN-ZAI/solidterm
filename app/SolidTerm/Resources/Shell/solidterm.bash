# SolidTerm shell integration — bash
#
# Emits OSC 133 prompt / preexec / precmd sequences so SolidTerm can
# tag command boundaries in the scrollback. Required for the
# prompt-marker accent rule (Settings → Appearance → "Show command
# markers"), color-coded by command exit status.
#
# Activate by adding to ~/.bashrc:
#   [ -f ~/.config/solidterm/shell/solidterm.bash ] && source ~/.config/solidterm/shell/solidterm.bash
#
# Safe to source under any terminal — the OSC 133 sequences are
# silently ignored by terminals that don't parse them.
#
# bash doesn't ship a preexec hook out of the box; we use the DEBUG
# trap with the "first trap fire after each prompt" guard pattern
# (same trick bash-preexec.sh uses, paraphrased so this stays a
# single self-contained file).

# Guard against double-loading.
# Legacy _NEXTTERM_ name honored: pre-rename installs may have set it.
{ [ -n "$_SOLIDTERM_INTEGRATION_LOADED" ] || [ -n "$_NEXTTERM_INTEGRATION_LOADED" ]; } && return
_SOLIDTERM_INTEGRATION_LOADED=1

# Suppress PROMPT_COMMAND-driven OSC emission for non-interactive shells.
case $- in
    *i*) ;;
    *) return ;;
esac

# OSC 133 A + D — emitted by PROMPT_COMMAND, which bash runs before
# drawing each PS1. D reports the exit code of the just-finished
# command if one was running.
_solidterm_prompt() {
    local _st_exit=$?
    if [ -n "$_SOLIDTERM_COMMAND_STARTED" ]; then
        printf '\e]133;D;%d\a' "$_st_exit"
        unset _SOLIDTERM_COMMAND_STARTED
    fi
    printf '\e]133;A\a'
}

# OSC 133 C — preexec via DEBUG trap. The trap fires before each
# command; we gate on `BASH_COMMAND` to skip the trap itself.
_solidterm_preexec() {
    # Skip the trap when the function being invoked IS our handler
    # (avoids recursion + duplicate sequences).
    case "$BASH_COMMAND" in
        _solidterm_prompt|*PROMPT_COMMAND*) return ;;
    esac
    _SOLIDTERM_COMMAND_STARTED=1
    printf '\e]133;C\a'
}

# Chain PROMPT_COMMAND so we don't clobber user-defined handlers.
case "$PROMPT_COMMAND" in
    *_solidterm_prompt*) ;;
    "") PROMPT_COMMAND="_solidterm_prompt" ;;
    *) PROMPT_COMMAND="_solidterm_prompt;${PROMPT_COMMAND}" ;;
esac

trap '_solidterm_preexec' DEBUG
