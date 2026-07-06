# Returns success when claude should launch its interactive UI (both stdin and
# stdout are TTYs). Split out so the test suite can override the TTY probe.
if not functions -q __claude_wrapper_is_interactive
    function __claude_wrapper_is_interactive
        isatty stdin; and isatty stdout
    end
end

function claude --description 'claude wrapped with 1Password service-account secret injection'
    if not command -v op >/dev/null 2>&1
        command claude $argv
        return
    end

    set -l sa_token (security find-generic-password -s claude-op-sa -a "$USER" -w 2>/dev/null)
    if test -z "$sa_token"
        command claude $argv
        return
    end

    set -l env_files
    set -l global_env "$HOME/.config/op/claude.env"
    if test -f "$global_env"
        set -a env_files --env-file=$global_env
    end
    if test -f ./.op.env
        set -a env_files --env-file=./.op.env
    end

    if test (count $env_files) -eq 0
        command claude $argv
        return
    end

    if __claude_wrapper_is_interactive
        # Interactive launch: `op run -- claude` would wrap the child's stdio in
        # pipes for secret masking, stripping claude's controlling TTY and forcing
        # it into non-interactive (--print) mode (see issue #69). Instead resolve
        # the op:// references here and export only the declared secrets into this
        # shell, then exec the real claude with its TTY intact.

        # Collect the variable names declared across the env-files.
        set -l keys
        for ef in $env_files
            set -l path (string replace -- --env-file= '' $ef)
            for line in (cat $path 2>/dev/null)
                set -l k (string match -rg '^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=' -- $line)
                test -n "$k"; and set -a keys $k
            end
        end

        # Snapshot each declared key's prior state so it can be restored once
        # claude exits. Without this, the resolved secrets would stay exported
        # for the rest of this login shell's lifetime and leak into every
        # subsequent child process, not just this claude invocation.
        set -l saved_was_set
        set -l saved_values
        for k in $keys
            if set -q $k
                set -a saved_was_set 1
                set -a saved_values $$k
            else
                set -a saved_was_set 0
                set -a saved_values ''
            end
        end

        # Resolve op:// references once (outside any sandbox) and export only the
        # declared keys. The SA token is dropped via `env -u` and is never a key,
        # so it is never exported into this shell.
        for kv in (OP_SERVICE_ACCOUNT_TOKEN=$sa_token op run $env_files -- env -u OP_SERVICE_ACCOUNT_TOKEN)
            set -l pair (string split -m1 = -- $kv)
            if contains -- $pair[1] $keys
                set -gx $pair[1] $pair[2]
            end
        end

        command claude $argv
        set -l exit_status $status

        # Restore the parent shell's prior environment so the resolved secrets
        # do not outlive this claude invocation.
        for i in (seq (count $keys))
            set -l k $keys[$i]
            if test "$saved_was_set[$i]" = 1
                set -gx $k $saved_values[$i]
            else
                set -e $k
            end
        end

        return $exit_status
    end

    # Non-interactive launch (bg agent / piped): keep op run so its secret masking
    # stays active on the child's stdout/stderr. env inheritance reaches sandboxed
    # child processes even where credential dirs are read-denied (issue #69).
    OP_SERVICE_ACCOUNT_TOKEN=$sa_token op run $env_files -- env -u OP_SERVICE_ACCOUNT_TOKEN command claude $argv
    return $status
end
