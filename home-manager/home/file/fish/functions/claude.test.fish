#!/usr/bin/env fish
# Integration tests for the `claude` fish wrapper function (home-manager/home/file/fish/functions/claude.fish)
#
# Run with: fish home-manager/home/file/fish/functions/claude.test.fish

set -g func_file (dirname (status --current-filename))/claude.fish

set -g failures 0

function assert_eq --argument-names actual expected message
    if test "$actual" != "$expected"
        echo "FAIL: $message (expected: '$expected', actual: '$actual')" >&2
        set -g failures (math $failures + 1)
    else
        echo "PASS: $message"
    end
end

function assert_contains --argument-names haystack needle message
    if string match -q -- "*$needle*" $haystack
        echo "PASS: $message"
    else
        echo "FAIL: $message (needle '$needle' not found)" >&2
        set -g failures (math $failures + 1)
    end
end

function assert_not_contains --argument-names haystack needle message
    if string match -q -- "*$needle*" $haystack
        echo "FAIL: $message (needle '$needle' unexpectedly found)" >&2
        set -g failures (math $failures + 1)
    else
        echo "PASS: $message"
    end
end

function make_fakebin --argument-names dir
    mkdir -p $dir

    # fake `op`: parses `--env-file=path` occurrences before `--`, sources
    # them into the environment, then execs whatever follows `--`.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'env_files=()' \
        'rest=()' \
        'after=0' \
        'for a in "$@"; do' \
        '  if [ $after -eq 1 ]; then' \
        '    rest+=("$a")' \
        '  elif [ "$a" = "--" ]; then' \
        '    after=1' \
        '  elif [[ "$a" == --env-file=* ]]; then' \
        '    env_files+=("${a#--env-file=}")' \
        '  fi' \
        'done' \
        'for f in "${env_files[@]}"; do' \
        '  if [ -f "$f" ]; then' \
        '    while IFS="=" read -r k v; do' \
        '      [ -z "$k" ] && continue' \
        '      export "$k=$v"' \
        '    done < "$f"' \
        '  fi' \
        'done' \
        'exec "${rest[@]}"' \
        > $dir/op
    chmod +x $dir/op

    # fake `security`: emits $FAKE_SA_TOKEN (may be empty) regardless of args.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'if [ -n "$FAKE_SA_TOKEN" ]; then' \
        '  printf "%s" "$FAKE_SA_TOKEN"' \
        'fi' \
        'exit 0' \
        > $dir/security
    chmod +x $dir/security

    # fake `claude`: dumps its environment and argv for inspection.
    printf '%s\n' \
        '#!/usr/bin/env bash' \
        'env > "$FAKE_CLAUDE_ENV_DUMP"' \
        'printf "%s\n" "$@" > "$FAKE_CLAUDE_ARGS_DUMP"' \
        > $dir/claude
    chmod +x $dir/claude
end

# ---------------------------------------------------------------------------
# Test 1: SA token present + env-file layering -> op run injects GH_TOKEN,
# strips OP_SERVICE_ACCOUNT_TOKEN, and passes argv through to real claude.
# ---------------------------------------------------------------------------
function test_with_sa_token
    set -l tmp (mktemp -d)
    set -l fakebin $tmp/bin
    make_fakebin $fakebin
    mkdir -p $tmp/.config/op
    echo "GH_TOKEN=fake-gh" >$tmp/.config/op/claude.env

    set -l fake_token (printf 'FAKE-SA-TOKEN-%.0s0' (seq 200))

    set -lx HOME $tmp
    set -lx PATH $fakebin $PATH
    set -lx FAKE_SA_TOKEN $fake_token
    set -lx FAKE_CLAUDE_ENV_DUMP $tmp/env_dump.txt
    set -lx FAKE_CLAUDE_ARGS_DUMP $tmp/args_dump.txt

    source $func_file

    set -l all_stdout $tmp/all_stdout.txt
    set -l orig_pwd $PWD
    cd $tmp
    claude foo >$all_stdout 2>&1
    set -l claude_status $status

    assert_eq $claude_status 0 "with-token: wrapper exits 0"

    set -l env_dump ""
    if test -f $tmp/env_dump.txt
        set env_dump (cat $tmp/env_dump.txt)
    end
    assert_contains "$env_dump" "GH_TOKEN=fake-gh" "with-token: GH_TOKEN injected via op run --env-file"
    assert_not_contains "$env_dump" "OP_SERVICE_ACCOUNT_TOKEN=" "with-token: OP_SERVICE_ACCOUNT_TOKEN stripped via env -u"

    set -l args_dump ""
    if test -f $tmp/args_dump.txt
        set args_dump (cat $tmp/args_dump.txt)
    end
    assert_contains "$args_dump" "foo" "with-token: argv passed through to real claude"

    set -l stdout_content (cat $all_stdout)
    assert_not_contains "$stdout_content" "FAKE-SA-TOKEN" "with-token: SA token value never printed to stdout/stderr"

    cd $orig_pwd
    rm -rf $tmp
end

# ---------------------------------------------------------------------------
# Test 2: no SA token in Keychain -> wrapper falls back to plain
# `command claude $argv` without ever invoking op run.
# ---------------------------------------------------------------------------
function test_without_sa_token
    set -l tmp (mktemp -d)
    set -l fakebin $tmp/bin
    make_fakebin $fakebin
    mkdir -p $tmp/.config/op
    echo "GH_TOKEN=fake-gh" >$tmp/.config/op/claude.env

    set -lx HOME $tmp
    set -lx PATH $fakebin $PATH
    set -e FAKE_SA_TOKEN
    set -lx FAKE_CLAUDE_ENV_DUMP $tmp/env_dump.txt
    set -lx FAKE_CLAUDE_ARGS_DUMP $tmp/args_dump.txt

    source $func_file

    set -l all_stdout $tmp/all_stdout.txt
    set -l orig_pwd $PWD
    cd $tmp
    claude bar >$all_stdout 2>&1
    set -l claude_status $status

    assert_eq $claude_status 0 "without-token: wrapper exits 0"

    set -l args_dump ""
    if test -f $tmp/args_dump.txt
        set args_dump (cat $tmp/args_dump.txt)
    end
    assert_contains "$args_dump" "bar" "without-token: falls back to plain command claude with argv passthrough"

    set -l stdout_content (cat $all_stdout)
    assert_not_contains "$stdout_content" "FAKE-SA-TOKEN" "without-token: no SA token value ever printed"

    cd $orig_pwd
    rm -rf $tmp
end

test_with_sa_token
test_without_sa_token

if test $failures -eq 0
    echo "All tests passed."
    exit 0
else
    echo "$failures assertion(s) failed."
    exit 1
end
