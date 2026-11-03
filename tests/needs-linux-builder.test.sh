#!/usr/bin/env bash
# scripts/needs-linux-builder.sh の検証。実際の nix に、build 済みでない Linux 向け / 非 Linux 向けの
# derivation と build 済みの derivation を dry-run させ、Linux 向けの build が要るときだけ 0 を返すこと、
# 評価に失敗したときは 0（VM を起動する側）に倒すことを確かめる。
# Run from the repo root: bash tests/needs-linux-builder.test.sh

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/needs-linux-builder.sh"
TMPROOT="$(mktemp -d "${TMPDIR:-/tmp}/needs-linux-builder-test.XXXXXX")"
trap 'rm -rf "$TMPROOT"' EXIT

PASS=0
FAIL=0
ERRORS=()

pass() {
  echo "  PASS: $1"
  PASS=$((PASS + 1))
}

fail() {
  echo "  FAIL: $1"
  echo "        $2"
  FAIL=$((FAIL + 1))
  ERRORS+=("$1: $2")
}

if ! command -v nix >/dev/null 2>&1; then
  echo "needs-linux-builder.test.sh: nix が見つからない" >&2
  exit 1
fi

# nonce で毎回 store に無い derivation にする（builder は動かさないので host の system と違ってよい）
NONCE="$$-$RANDOM-$(date +%s)"
cat >"$TMPROOT/probe.nix" <<'EOF'
{ nonce }:
let
  mk = name: system: derivation {
    name = "needs-linux-builder-${name}";
    inherit system;
    builder = "/bin/sh";
    args = [ "-c" "echo ${nonce} > $out" ];
  };
in
{
  linux = mk "linux" "aarch64-linux";
  darwin = mk "darwin" "aarch64-darwin";
  # 依存側だけが Linux 向け（linux-builder VM の boot.json → darwin の launchd plist と同じ形）
  darwinOnLinux = derivation {
    name = "needs-linux-builder-darwin-on-linux";
    system = "aarch64-darwin";
    builder = "/bin/sh";
    args = [ "-c" "cat ${mk "dep" "x86_64-linux"} > $out" ];
  };
  local = mk "local" builtins.currentSystem;
  broken = throw "eval error";
}
EOF

# run <attr>...: 各 attr を installable にして script を走らせ、終了コードを RC に入れる
run() {
  local args=()
  for a in "$@"; do
    args+=("$TMPROOT/probe.nix#$a")
  done
  set +e
  OUT="$(bash "$SCRIPT" "${args[@]}" 2>&1)"
  RC=$?
  set -e
}

# installable の flake 参照ではなく -f で渡すため、nix を包む stub を PATH に置く
mkdir -p "$TMPROOT/bin"
REAL_NIX="$(command -v nix)"
cat >"$TMPROOT/bin/nix" <<EOF
#!/usr/bin/env bash
# <file>#<attr> を -f <file> <attr> に直し、nonce を渡す
args=()
file=""
for a in "\$@"; do
  case "\$a" in
    *.nix#*) file="\${a%%#*}"; args+=("\${a#*#}") ;;
    *) args+=("\$a") ;;
  esac
done
if [ -n "\$file" ]; then
  exec "$REAL_NIX" --extra-experimental-features nix-command "\${args[@]}" -f "\$file" --argstr nonce "$NONCE"
fi
exec "$REAL_NIX" --extra-experimental-features nix-command "\${args[@]}"
EOF
chmod +x "$TMPROOT/bin/nix"
export PATH="$TMPROOT/bin:$PATH"

echo "=== needs-linux-builder tests ==="
echo ""

echo "- unbuilt_linux_derivation_needs_builder"
run linux
if [ "$RC" -eq 0 ]; then
  pass "unbuilt_linux_derivation_needs_builder"
else
  fail "unbuilt_linux_derivation_needs_builder" "rc=$RC out=$OUT"
fi

echo "- linux_dependency_of_non_linux_target_needs_builder"
run darwinOnLinux
if [ "$RC" -eq 0 ]; then
  pass "linux_dependency_of_non_linux_target_needs_builder"
else
  fail "linux_dependency_of_non_linux_target_needs_builder" "rc=$RC out=$OUT"
fi

echo "- only_non_linux_derivations_do_not_need_builder"
run darwin
if [ "$RC" -eq 1 ]; then
  pass "only_non_linux_derivations_do_not_need_builder"
else
  fail "only_non_linux_derivations_do_not_need_builder" "rc=$RC out=$OUT"
fi

echo "- nothing_to_build_does_not_need_builder"
nix build --no-link "$TMPROOT/probe.nix#local" >/dev/null 2>&1
run local
if [ "$RC" -eq 1 ]; then
  pass "nothing_to_build_does_not_need_builder"
else
  fail "nothing_to_build_does_not_need_builder" "rc=$RC out=$OUT"
fi

echo "- eval_error_falls_back_to_builder"
run broken
if [ "$RC" -eq 0 ]; then
  pass "eval_error_falls_back_to_builder"
else
  fail "eval_error_falls_back_to_builder" "rc=$RC out=$OUT"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
if [ "$FAIL" -gt 0 ]; then
  printf '  %s\n' "${ERRORS[@]}"
  exit 1
fi
