# sandbox-pg: 決まった Postgres コンテナ（digest 固定の公式 postgres 17）を docker で起動・停止するだけの CLI。
#
# Claude Code の sandbox からは docker socket に繋がらない（繋げると API 全体＝ホスト権限を渡す）ので、
# このコマンドだけを claude-code/settings.json の excludedCommands で sandbox 外に出す。
# 実体は nix store（sandbox から書けない）に置き、PATH は runtimeInputs だけに固定する（inheritPath = false）。
# 受け付ける入力と安全条件は ./sandbox-pg.sh の冒頭を参照。sandbox 内で動く PGlite（pglite-server）では
# 拡張や挙動が本番と合わないときに使う、本物の Postgres 用。
{
  writeShellApplication,
  coreutils,
  docker-client,
}:

writeShellApplication {
  name = "sandbox-pg";
  runtimeInputs = [
    coreutils
    docker-client
  ];
  inheritPath = false;
  text = builtins.readFile ./sandbox-pg.sh;
  meta.description = "Start/stop a pinned Postgres container for the Claude Code sandbox";
}
