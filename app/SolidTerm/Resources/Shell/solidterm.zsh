# SolidTerm shell integration — zsh
#
# Emits OSC 133 prompt / preexec / precmd sequences so SolidTerm can
# tag command boundaries in the scrollback. Required for: command
# block tracking, ⌘[/⌘] block jumps, ⌘⇧C "Copy Block", duration HUD,
# OSC 133 accent rule.
#
# Activate by adding to ~/.zshrc:
#   [[ -f ~/.config/solidterm/shell/solidterm.zsh ]] && source ~/.config/solidterm/shell/solidterm.zsh
#
# Safe to source under any terminal — the OSC 133 sequences are
# silently ignored by terminals that don't parse them.

# Guard against double-loading.
[[ -n "$_NEXTTERM_INTEGRATION_LOADED" ]] && return
typeset -g _NEXTTERM_INTEGRATION_LOADED=1

# OSC 133 A — prompt start. Emitted via precmd (runs before each
# prompt is drawn). We inject the marker as a non-printing escape so
# zsh's PS1 width calculation stays correct.
_solidterm_precmd() {
    # Capture exit code of the just-finished command for OSC 133 D.
    local _nt_exit=$?
    if [[ -n "$_NEXTTERM_COMMAND_STARTED" ]]; then
        printf '\e]133;D;%d\a' "$_nt_exit"
        unset _NEXTTERM_COMMAND_STARTED
    fi
    printf '\e]133;A\a'
}

# OSC 133 C — command start (user pressed Enter on the prompt).
_solidterm_preexec() {
    typeset -g _NEXTTERM_COMMAND_STARTED=1
    printf '\e]133;C\a'
}

# Register the hooks. add-zsh-hook is the idiomatic way to chain
# multiple precmd/preexec functions without clobbering existing ones.
autoload -Uz add-zsh-hook
add-zsh-hook precmd _solidterm_precmd
add-zsh-hook preexec _solidterm_preexec
