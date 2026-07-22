# hermes フェーズB 実行モデル go/no-go ゲート decision-log (S4)

対象 issue AC:

- AC-2: 「dispatch コンテナを明示 kill してもジョブが前進し PR が生成される、または no-go と判定され長寿命 per-job コンテナモデルが確定要件として記録される（フェーズB go/no-go ゲート）」
- AC-3: 「per-job `CLAUDE_CONFIG_DIR` を host 非root から `claude agents` で読み取れることを実機確認できる（フェーズB）」

実験ハーネス: `tests/hermes-phaseB-gate.sh`（`nix flake check` 対象外、手動実行スクリプト。S2 の `tests/hermes-dispatch-smoke.sh` と同じ convention）。

## AC-3: per-job `CLAUDE_CONFIG_DIR` の host 非root 読み取り

**判定: GO（実機確認済み）**

`tests/hermes-phaseB-gate.sh` の AC-3 セクションを本 implementer セッション内で実際に実行し、以下を確認した（host 上、非root ユーザー `naramotoyuuji` uid=502 で実行、docker 不使用）:

```
- ac3_claude_agents_reads_per_job_config_dir
  PASS: ac3_claude_agents_reads_per_job_config_dir (uid=502, exit 0, JSON array returned)
  AC-3 RESULT: GO -- non-root host user (uid=502) read
               CLAUDE_CONFIG_DIR=/tmp/claude-502/hermes-phaseB-gate.IgvEZF/claude-state/scratch-job via `claude agents`
               successfully. Record as confirmed in the decision-log.
```

具体的には `CLAUDE_CONFIG_DIR=<scratch-dir> claude agents --json --cwd <workspace-dir>` を host 非root shell から実行し、exit code 0 かつ JSON 配列 (`[]`) が返却されることを確認した。加えて `<scratch-dir>` 配下に `.claude.json` / `.claude.json.lock` / `backups/` が実際に作成され、`claude agents` がデフォルトの `~/.claude` ではなく **指定した `CLAUDE_CONFIG_DIR` を読み書きしている**ことを実ファイルで確認した。

これは manifest.py が定義する `claude_config_host_dir = ~/.hermes/claude-state/<job_id>` パターンと同一の機構であり、per-job の `CLAUDE_CONFIG_DIR` を host 非root から `claude agents --cwd <workspace_host_dir>` で読み取れることの実証として十分である。

**config.yaml への影響**: なし。この結果は per-job container 側の `CLAUDE_CONFIG_DIR` bind mount 設計（S2 で `hermes/config.yaml` の `docker_volumes` に追加済みの `~/.hermes/claude-state:/root/.claude-hermes:rw`）をそのまま裏付けるものであり、追加の config 変更は不要。

## AC-2: dispatch container 明示 kill 後のジョブ前進観測

**判定: 実機での `docker kill` 実験は本 implementer セッションでは実行不可（sandbox 制約）。アーキテクチャ分析に基づく暫定 GO、要オペレーター実機再確認。**

### 実行不可の事実

本 implementer は共有 worktree 上の sandboxed Bash tool から動作しており、docker デーモンへのソケット接続が権限で拒否される:

```
$ docker ps
permission denied while trying to connect to the docker API at unix:///Users/naramotoyuuji/.orbstack/run/docker.sock
```

`tests/hermes-phaseB-gate.sh` を実際にこのセッションで実行した結果も、この制約により AC-2 セクションは SKIP に倒れた（`docker info` 到達不可を検知して安全側にスキップする設計どおり）:

```
NOTE: docker daemon not reachable from this shell -- AC-2 section will
      be SKIPped. Re-run this script from a shell with real docker
      socket access (outside any agent sandbox) to get an AC-2 verdict.
  SKIP: ac2_dispatch_container_kill_and_progress (docker daemon not reachable from this shell)
```

CLAUDE.md 運用ルール（sandbox で docker/gh 等が塞がれた場合は `dangerouslyDisableSandbox` で勝手に緩めず、失敗を報告して設定調整を提案する）に従い、本セッションでは sandbox を回避せず、この制約をそのまま報告する。

### アーキテクチャ分析による暫定判断

`hermes/plugins/claude_runner/dispatch.py` の `_docker_run_claude_bg` は per-job コンテナを `docker run -d --rm --name hermes-claude-<job_id> ...` として起動している。ここで重要なのは **`-d`（detach）で起動したコンテナは、それを起動したプロセス（= dispatch_job ハンドラを実行している「dispatch コンテナ」または host プロセス）のライフサイクルとは独立に、Docker daemon (`dockerd`) 自身が supervise する**という Docker の基本仕様である。つまり「dispatch コンテナ」（dispatch_job を呼び出した側の実行コンテキスト）を明示 kill しても、それが `docker run -d` で切り離し起動した子コンテナ（`hermes-claude-<job_id>`）の親プロセスではない限り、子コンテナ自体は生き続け、ジョブは前進しうる。

現行の `dispatch.py` の実装は、まさにこの「各ジョブが専用の `docker run -d` コンテナを持つ」モデルを既に実装している（S2 時点で per-job container が確定済み）。したがって:

- **暫定判定: GO** — 「dispatch コンテナ（呼び出し元）を kill しても、`docker run -d` で切り離し済みの per-job コンテナ（`hermes-claude-<job_id>`）はジョブを前進させ得る」という長寿命 per-job コンテナモデルは、現行実装のアーキテクチャ的性質として妥当。
- ただしこれは **実機での `docker kill` + 前進観測を伴わない、Docker の detach 起動セマンティクスに基づく分析的判断**であり、`test_plan` が要求する「container kill 後に manifest.status が running→done 遷移」を実際に観測したものではない（S5 watchdog 未実装のため、そもそも running→done への自動 reconcile は本 PR の後続フェーズ C (S5) で実装される）。

### 未確定事項・要フォローアップ

1. `tests/hermes-phaseB-gate.sh` を **sandbox の外**（実 docker ソケットにアクセスできるホスト shell）で実行し、AC-2 セクションの実測 PASS/FAIL を得ること。上記の分析的 GO 判断を実測で裏付ける、または覆すまで、この項目は暫定扱いとする。
2. `--rm` フラグは per-job コンテナ自身の内部プロセス（`claude --bg`）終了時のみコンテナを破棄する用途であり、「dispatch コンテナを外部から kill する」シナリオとは無関係。per-job コンテナが `hermes.config.yaml` の `terminal.lifetime_seconds` (1800秒) より長く実行される場合に途中で強制終了されないことは、実測で別途確認が必要。

## config.yaml への反映

`hermes/config.yaml` の `terminal.lifetime_seconds` を 1800 秒（30分）から 21600 秒（6時間）に引き上げた。この変更は AC-2 の GO/NO-GO いずれの分岐でも安全側に働く:

- GO（per-job コンテナが呼び出し元から独立して生存する）の場合でも、hermes 自身の対話ターミナル（`terminal:` backend、dispatch_job 呼び出し元を含む）が長時間の ChatOps セッション中に途中で recycle されないマージンを確保する。
- NO-GO（長寿命 per-job コンテナモデルが必須、と確定した場合）でも、より長い lifetime は前提条件として必要になる。

`terminal.container_persistent` は変更していない（現状 `false` のまま）。これは hermes 自身の対話ターミナルの再利用可否に関する設定であり、per-job dispatch コンテナ（`dispatch.py` が `docker run -d` で都度新規作成するモデル）とは独立した設定項目のため、AC-2 の実測確認（上記フォローアップ 1）が完了してから、必要であれば別途調整する。

## まとめ

| AC | 判定 | 根拠 |
|----|------|------|
| AC-2 | 暫定 GO（要実機再確認） | Docker `-d` detach セマンティクスに基づく分析。実機 `docker kill` 実験は sandbox 制約 (`permission denied ... docker.sock`) により本セッションでは未実施 |
| AC-3 | GO（実機確認済み） | `tests/hermes-phaseB-gate.sh` を host 非root (`uid=502`) で実行し、`CLAUDE_CONFIG_DIR` 越しの `claude agents --json --cwd` が exit 0 + JSON 配列を返し、状態ファイルが指定ディレクトリに作成されることを確認 |

**フォローアップ (blocking Phase C 着手前ではないが、production 信頼前に必須)**: `tests/hermes-phaseB-gate.sh` を実 docker ソケットにアクセス可能な環境（agent sandbox 外）で再実行し、AC-2 の実測結果を本ファイルに追記すること。
