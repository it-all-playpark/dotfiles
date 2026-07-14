#!/usr/bin/env bash
# tests/herdr-config.test.sh
# Unit test for herdr package/config wiring (lib/cli-packages.nix + home-manager/home/file/herdr).
# Run from the repo root: bash tests/herdr-config.test.sh
# Requires: awk, grep (tier-1, always run) / nix (with flakes), jq (tier-2, optional)
#
# tier-1: 静的テキスト検証 (awk/grep のみ, nix daemon 不要, 常時実行)
# tier-2: nix eval 検証 (builtins.getFlake で flake を評価, nix daemon 到達時のみ実行)
#
# NOTE: tier-2 は builtins.getFlake で flake を評価するため untracked の新規ファイルは
# 実行前に `git add` しておくこと。untracked のままだと dirty tree の flake fetch に
# 含まれず、path does not exist で eval が失敗する。
# NOTE: sandbox 等で nix daemon に到達できない環境では tier-2 は SKIP される。
# 完全検証は sandbox 外で実行すること。

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_TOML="${REPO_ROOT}/home-manager/home/file/herdr/config.toml"
PASS=0
FAIL=0
SKIP=0
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

skip() {
  echo "  SKIP: $1 ($2)"
  SKIP=$((SKIP + 1))
}

echo "=== herdr config unit tests ==="
echo ""
echo "--- tier-1: static text verification (no nix required) ---"

# ---------------------------------------------------------------------------
# tier-1 (1): hostOnly list in lib/cli-packages.nix includes herdr
# ---------------------------------------------------------------------------
echo "- static_hostOnly_includes_herdr"
if awk '/^  hostOnly = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +herdr$'; then
  pass "static_hostOnly_includes_herdr"
else
  fail "static_hostOnly_includes_herdr" \
    "Expected 'herdr' inside the hostOnly list in ${REPO_ROOT}/lib/cli-packages.nix"
fi

# ---------------------------------------------------------------------------
# tier-1 (2): common / containerOnly lists must NOT include herdr
# (container mode = common ++ containerOnly, so absence in both proves
#  herdr is excluded from container images)
# ---------------------------------------------------------------------------
echo "- static_containerSets_exclude_herdr"
if awk '/^  common = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +herdr$'; then
  fail "static_containerSets_exclude_herdr" \
    "'herdr' must NOT appear in the common list of ${REPO_ROOT}/lib/cli-packages.nix"
elif awk '/^  containerOnly = with pkgs; \[/,/^  \];/' "${REPO_ROOT}/lib/cli-packages.nix" |
  grep -qE '^ +herdr$'; then
  fail "static_containerSets_exclude_herdr" \
    "'herdr' must NOT appear in the containerOnly list of ${REPO_ROOT}/lib/cli-packages.nix"
else
  pass "static_containerSets_exclude_herdr"
fi

# ---------------------------------------------------------------------------
# tier-1 (3): config.toml exists
# ---------------------------------------------------------------------------
echo "- configToml_exists"
if [ -f "${CONFIG_TOML}" ]; then
  pass "configToml_exists"
else
  fail "configToml_exists" "Expected file at ${CONFIG_TOML}"
fi

# ---------------------------------------------------------------------------
# tier-1 (4): 大西配列 primary (alt+t/n/r/s) + fallback (prefix+t/n/r/s) keybindings
# ---------------------------------------------------------------------------
echo "- configToml_has_ohnishi_keybindings"
if [ -f "${CONFIG_TOML}" ] &&
  grep -qE 'focus_pane_left *= *\["alt\+t", *"prefix\+t"\]' "${CONFIG_TOML}" &&
  grep -qE 'focus_pane_down *= *\["alt\+n", *"prefix\+n"\]' "${CONFIG_TOML}" &&
  grep -qE 'focus_pane_up *= *\["alt\+r", *"prefix\+r"\]' "${CONFIG_TOML}" &&
  grep -qE 'focus_pane_right *= *\["alt\+s", *"prefix\+s"\]' "${CONFIG_TOML}"; then
  pass "configToml_has_ohnishi_keybindings"
else
  fail "configToml_has_ohnishi_keybindings" \
    "Expected focus_pane_{left,down,up,right} with alt+{t,n,r,s} + prefix+{t,n,r,s} fallback in ${CONFIG_TOML}"
fi

# ---------------------------------------------------------------------------
# tier-1 (5): collision-avoidance evacuation bindings (settings/next_tab/resize_mode)
# ---------------------------------------------------------------------------
echo "- configToml_has_evacuated_bindings"
if [ -f "${CONFIG_TOML}" ] &&
  grep -Fq 'settings = "prefix+shift+s"' "${CONFIG_TOML}" &&
  grep -qE 'next_tab *= *\["alt\+shift\+s", *"prefix\+\]"\]' "${CONFIG_TOML}" &&
  grep -qE 'resize_mode *= *\["ctrl\+alt\+r", *"prefix\+shift\+e"\]' "${CONFIG_TOML}"; then
  pass "configToml_has_evacuated_bindings"
else
  fail "configToml_has_evacuated_bindings" \
    "Expected settings=\"prefix+shift+s\", next_tab=[\"alt+shift+s\", \"prefix+]\"], resize_mode=[\"ctrl+alt+r\", \"prefix+shift+e\"] in ${CONFIG_TOML}"
fi

# ---------------------------------------------------------------------------
# tier-1 (5b): zellij-ported bindings (prefix / splits / pane ops / tabs /
# copy mode / session ops / navigate-mode 大西配列)
# ---------------------------------------------------------------------------
echo "- configToml_has_zellij_ported_bindings"
if [ -f "${CONFIG_TOML}" ] &&
  grep -Fq 'prefix = "ctrl+a"' "${CONFIG_TOML}" &&
  grep -qE 'split_vertical *= *\["alt\+right", *"prefix\+v"\]' "${CONFIG_TOML}" &&
  grep -qE 'split_horizontal *= *\["alt\+down", *"prefix\+minus"\]' "${CONFIG_TOML}" &&
  grep -qE 'close_pane *= *\["alt\+q", *"prefix\+x"\]' "${CONFIG_TOML}" &&
  grep -qE 'zoom *= *\["alt\+z", *"prefix\+z"\]' "${CONFIG_TOML}" &&
  grep -qE 'previous_tab *= *\["alt\+shift\+t", *"prefix\+p"\]' "${CONFIG_TOML}" &&
  grep -qE 'new_tab *= *\["alt\+y", *"prefix\+c"\]' "${CONFIG_TOML}" &&
  grep -qE 'close_tab *= *\["alt\+shift\+q", *"prefix\+shift\+x"\]' "${CONFIG_TOML}" &&
  grep -Fq 'switch_tab = "alt+1..9"' "${CONFIG_TOML}" &&
  grep -qE 'copy_mode *= *\["alt\+i", *"prefix\+\["\]' "${CONFIG_TOML}" &&
  grep -qE 'detach *= *\["alt\+d", *"prefix\+q"\]' "${CONFIG_TOML}" &&
  grep -qE 'goto *= *\["alt\+w", *"prefix\+g"\]' "${CONFIG_TOML}" &&
  grep -qE 'navigate_pane_left *= *"t"' "${CONFIG_TOML}" &&
  grep -qE 'navigate_pane_down *= *"n"' "${CONFIG_TOML}" &&
  grep -qE 'navigate_pane_up *= *"r"' "${CONFIG_TOML}" &&
  grep -qE 'navigate_pane_right *= *"s"' "${CONFIG_TOML}"; then
  pass "configToml_has_zellij_ported_bindings"
else
  fail "configToml_has_zellij_ported_bindings" \
    "Expected zellij-ported bindings (prefix=ctrl+a, split_*, close_pane, zoom, tab ops, switch_tab, copy_mode, detach, goto, navigate_pane_* 大西配列) in ${CONFIG_TOML}"
fi

# ---------------------------------------------------------------------------
# tier-1 (5c): [terminal] default_shell = "fish" (zellij config.kdl と同じ)
# ---------------------------------------------------------------------------
echo "- configToml_sets_default_shell_fish"
if [ -f "${CONFIG_TOML}" ] &&
  awk '/^\[terminal\]/{f=1;next} /^\[/{f=0} f' "${CONFIG_TOML}" |
  grep -qE '^default_shell *= *"fish"'; then
  pass "configToml_sets_default_shell_fish"
else
  fail "configToml_sets_default_shell_fish" \
    "Expected default_shell = \"fish\" inside [terminal] section in ${CONFIG_TOML}"
fi

# ---------------------------------------------------------------------------
# tier-1 (6): reload_config must NOT be overridden (keep herdr default prefix+shift+r)
# ---------------------------------------------------------------------------
echo "- configToml_does_not_set_reload_config"
if [ -f "${CONFIG_TOML}" ]; then
  reload_count="$(grep -c '^reload_config' "${CONFIG_TOML}" || true)"
  if [ "${reload_count}" -eq 0 ]; then
    pass "configToml_does_not_set_reload_config"
  else
    fail "configToml_does_not_set_reload_config" \
      "reload_config must not be set in ${CONFIG_TOML} (found ${reload_count} occurrence(s))"
  fi
else
  fail "configToml_does_not_set_reload_config" "Cannot check: ${CONFIG_TOML} does not exist"
fi

# ---------------------------------------------------------------------------
# tier-1 (7): home.file ".config/herdr" is wired with source + recursive = true
# ---------------------------------------------------------------------------
echo "- static_homeFile_herdr_wiring"
home_file_block="$(awk '/"\.config\/herdr" = \{/,/\};/' "${REPO_ROOT}/home-manager/home/default.nix")"
if echo "${home_file_block}" | grep -Fq 'source = ./file/herdr;' &&
  echo "${home_file_block}" | grep -Fq 'recursive = true;'; then
  pass "static_homeFile_herdr_wiring"
else
  fail "static_homeFile_herdr_wiring" \
    "Expected home.file.\".config/herdr\" = { source = ./file/herdr; recursive = true; } in ${REPO_ROOT}/home-manager/home/default.nix"
fi

echo ""
echo "--- tier-2: nix eval verification (requires nix daemon) ---"

# ---------------------------------------------------------------------------
# Helper: evaluate cli-packages.nix and return JSON list of package names
#
# flake の pinned nixpkgs を `builtins.getFlake` 経由で取得することで、
# host の nix-channel 設定 (<nixpkgs>) に依存せず flake.lock と同じ nixpkgs で
# 評価する。これにより CI / 開発環境で評価結果が一致する。
# ---------------------------------------------------------------------------
eval_pkg_names() {
  local mode="$1"
  local system
  system="$(nix eval --impure --raw --expr 'builtins.currentSystem' 2>/dev/null || true)"
  nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
      pkgs = flake.inputs.nixpkgs.legacyPackages.${system};
    in
      map (p: p.pname or p.name) (
        import ${REPO_ROOT}/lib/cli-packages.nix { inherit pkgs; mode = \"${mode}\"; }
      )
  " 2>/dev/null
}

if nix store info >/dev/null 2>&1 && nix eval --impure --raw --expr 'builtins.currentSystem' >/dev/null 2>&1; then
  NIX_AVAILABLE=1
else
  NIX_AVAILABLE=0
fi

if [ "${NIX_AVAILABLE}" -eq 1 ]; then
  # -------------------------------------------------------------------------
  # tier-2 (a): host mode must include herdr
  # -------------------------------------------------------------------------
  echo "- eval_hostMode_includes_herdr"
  host_pkgs="$(eval_pkg_names "host" || true)"
  if echo "${host_pkgs}" | jq -e 'map(select(. == "herdr")) | length > 0' >/dev/null 2>&1; then
    pass "eval_hostMode_includes_herdr"
  else
    fail "eval_hostMode_includes_herdr" \
      "Expected herdr in host mode packages, got: ${host_pkgs}"
  fi

  # -------------------------------------------------------------------------
  # tier-2 (b): container mode must NOT include herdr (hostOnly, not needed in image)
  # -------------------------------------------------------------------------
  echo "- eval_containerMode_excludes_herdr"
  container_pkgs="$(eval_pkg_names "container" || true)"
  if echo "${container_pkgs}" | jq -e 'map(select(. == "herdr")) | length == 0' >/dev/null 2>&1; then
    pass "eval_containerMode_excludes_herdr"
  else
    fail "eval_containerMode_excludes_herdr" \
      "herdr must NOT appear in container mode (hostOnly). Got: ${container_pkgs}"
  fi

  # -------------------------------------------------------------------------
  # tier-2 (c): home.file ".config/herdr" is wired with recursive = true
  # -------------------------------------------------------------------------
  echo "- eval_homeFile_herdr_recursive_true"
  herdr_recursive="$(nix eval --json --impure --expr "
    let
      flake = builtins.getFlake \"${REPO_ROOT}\";
    in
      flake.homeConfigurations.\"naramotoyuuji-darwin\".config.home.file.\".config/herdr\".recursive
  " 2>/dev/null || echo "")"
  if [ "${herdr_recursive}" = "true" ]; then
    pass "eval_homeFile_herdr_recursive_true"
  else
    fail "eval_homeFile_herdr_recursive_true" \
      "Expected homeConfigurations.\"naramotoyuuji-darwin\".config.home.file.\".config/herdr\".recursive == true, got: ${herdr_recursive}"
  fi
else
  skip "eval_hostMode_includes_herdr" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
  skip "eval_containerMode_excludes_herdr" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
  skip "eval_homeFile_herdr_recursive_true" \
    "nix daemon unreachable (sandboxed environment) — run outside sandbox for full verification"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "Results: ${PASS} passed, ${FAIL} failed, ${SKIP} skipped"
if [ "${FAIL}" -gt 0 ]; then
  echo "Failed tests:"
  for err in "${ERRORS[@]}"; do
    echo "  - ${err}"
  done
  exit 1
fi
