function claude --description 'claude wrapped with 1Password service-account GH_TOKEN injection'
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

    OP_SERVICE_ACCOUNT_TOKEN=$sa_token op run $env_files -- env -u OP_SERVICE_ACCOUNT_TOKEN command claude $argv
    return $status
end
