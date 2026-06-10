# SolidTerm shell integration — fish
#
# Emits OSC 133 prompt / preexec / precmd sequences so SolidTerm can
# tag command boundaries in the scrollback. Required for the
# prompt-marker accent rule (Settings → Appearance → "Show command
# markers"), color-coded by command exit status.
#
# Activate by adding to ~/.config/fish/config.fish:
#   if test -f ~/.config/solidterm/shell/solidterm.fish
#       source ~/.config/solidterm/shell/solidterm.fish
#   end
#
# Safe to source under any terminal — the OSC 133 sequences are
# silently ignored by terminals that don't parse them.

# Guard against double-loading. `return`, never `exit` — in a sourced
# fish file `exit` terminates the whole interactive shell, so a
# re-source (e.g. after editing config.fish) would kill the session.
# The legacy _NEXTTERM_ name is also honored: pre-rename installs (and
# NextTerm itself, whose hooks emit identical OSC 133) may have set it
# in this session already.
if set -q _SOLIDTERM_INTEGRATION_LOADED; or set -q _NEXTTERM_INTEGRATION_LOADED
    return
end
set -g _SOLIDTERM_INTEGRATION_LOADED 1

# OSC 133 A — prompt start. fish_prompt is called before each prompt
# render; we hook via the fish_prompt event.
function _solidterm_prompt_start --on-event fish_prompt
    # D fires for the previously-running command, if any.
    if set -q _SOLIDTERM_COMMAND_STARTED
        printf '\e]133;D;%d\a' $status
        set -e _SOLIDTERM_COMMAND_STARTED
    end
    printf '\e]133;A\a'
end

# OSC 133 C — command start. fish_preexec is called just before the
# user-typed command runs.
function _solidterm_preexec --on-event fish_preexec
    set -g _SOLIDTERM_COMMAND_STARTED 1
    printf '\e]133;C\a'
end
