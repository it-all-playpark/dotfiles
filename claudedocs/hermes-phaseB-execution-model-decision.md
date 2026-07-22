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

**判定: NO-GO（実機確認済み）— 長寿命 per-job コンテナモデルへの移行が確定要件。**

### 実機再確認の結果（オペレーターによる sandbox 外実行）

下記フォローアップ 1 に基づき、オペレーターが実 docker ソケットにアクセス可能な host shell（`USERnoMac-Studio`, sandbox 外）から `tests/hermes-phaseB-gate.sh` を実行し、AC-2 の実測 PASS/FAIL を取得した:

```
- ac2_dispatch_job_and_capture_manifest
  PASS: ac2_dispatch_job_and_capture_manifest (invocation succeeded)
- ac2_dispatch_container_running_before_kill
  PASS: ac2_dispatch_container_running_before_kill
- ac2_explicit_kill_of_dispatch_container
  PASS: ac2_explicit_kill_of_dispatch_container
- ac2_job_progress_after_kill (poll up to 120s)
  FAIL: ac2_job_progress_after_kill
        no manifest status=done and no matching PR within 120s of killing hermes-claude-job-d726d0df7c74
  AC-2 RESULT: NO-GO -- job did not progress after the dispatch
               container was killed within the poll window.
               -> record no-go in the decision-log.
```

（初回実行時は git clone が SSH 認証エラー(`Permission denied (publickey)`)で失敗し AC-2 全体が FAIL していたが、これは host 側 1Password SSH agent の未セットアップ（1Password 本体アプリ未インストールによる stale agent socket）が原因の環境要因であり、`dispatch.py` 自体の欠陥ではない。1Password アプリの再インストール後、`ssh -T git@github.com` の成功を確認した上で本節の実測を取得した。）

### 実測が下段の分析的暫定判断を覆した理由

`tests/hermes-phaseB-gate.sh` が実際に kill するのは `CONTAINER_NAME="hermes-claude-${JOB_ID}"`——つまり `_docker_run_claude_bg` が `docker run -d` で起動した **per-job コンテナそのもの**であり、それを呼び出す別の「dispatch コンテナ」を kill しているわけではない（そのような別コンテナは現行実装に存在しない）。

下段の分析（旧稿）は「dispatch コンテナ（呼び出し元）」と「per-job コンテナ（`hermes-claude-<job_id>`）」が別物であることを根拠に、前者を kill しても後者は Docker の detach セマンティクスにより生存し続けるはずだ、と論じていた。しかし AC-2 の実験手順が kill する対象は後者（per-job コンテナ自身）であり、そこで `claude --bg` プロセスが実行中のジョブそのものを担っている。per-job コンテナを直接 kill すれば、それを引き継いで処理を再開する仕組み（S5 watchdog）が無い現行実装では、ジョブが進まなくなるのは Docker のセマンティクスとしてむしろ当然の帰結だった。「detach 起動だから親から独立して生き続ける」という分析は、kill 対象の取り違えにより、AC-2 が実際に問うている耐障害性（per-job コンテナ自体が落ちた場合の回復力）とは別の主張になっていた。

実測 NO-GO は、この取り違えを正し、「S5 watchdog（またはそれに相当する reconcile/再起動機構）が実装されるまで、per-job コンテナの異常終了に対してジョブは前進しない」という、より厳しいが正確な結論を確定させた。

### 実行不可だった経緯（本 implementer セッション、参考情報として保持）

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

CLAUDE.md 運用ルール（sandbox で docker/gh 等が塞がれた場合は `dangerouslyDisableSandbox` で勝手に緩めず、失敗を報告して設定調整を提案する）に従い、本セッションでは sandbox を回避せず、この制約をそのまま報告していた。この制約が、オペレーターによる sandbox 外実機再確認（上記）につながった。

### アーキテクチャ分析による暫定判断（旧稿・実測により更新済み）

`hermes/plugins/claude_runner/dispatch.py` の `_docker_run_claude_bg` は per-job コンテナを `docker run -d --rm --name hermes-claude-<job_id> ...` として起動している。ここで重要なのは **`-d`（detach）で起動したコンテナは、それを起動したプロセス（= dispatch_job ハンドラを実行している「dispatch コンテナ」または host プロセス）のライフサイクルとは独立に、Docker daemon (`dockerd`) 自身が supervise する**という Docker の基本仕様である。つまり「dispatch コンテナ」（dispatch_job を呼び出した側の実行コンテキスト）を明示 kill しても、それが `docker run -d` で切り離し起動した子コンテナ（`hermes-claude-<job_id>`）の親プロセスではない限り、子コンテナ自体は生き続け、ジョブは前進しうる。

現行の `dispatch.py` の実装は、まさにこの「各ジョブが専用の `docker run -d` コンテナを持つ」モデルを既に実装している（S2 時点で per-job container が確定済み）。したがって:

- ~~暫定判定: GO~~ → **実測により NO-GO で確定**（上記「実測が下段の分析的暫定判断を覆した理由」参照）。この分析は「dispatch コンテナ」と「per-job コンテナ」を別物として扱っていたが、AC-2 の実験は per-job コンテナ自体を kill 対象としており、分析の前提が実験のシナリオと一致していなかった。
- 実測前は「実機での `docker kill` + 前進観測を伴わない、Docker の detach 起動セマンティクスに基づく分析的判断」であることを明記していた。それを裏付ける実測(`ac2_job_progress_after_kill`)が今回得られ、120秒のポーリング窓内で manifest.status=done にも PR 生成にも至らないことが確認された。

### 未確定事項・要フォローアップ（更新）

1. ~~`tests/hermes-phaseB-gate.sh` を sandbox の外で実行し実測を得ること~~ → **完了**。実測 NO-GO を確定させた（上記）。
2. **フェーズC (S5) の watchdog/reconcile 実装が、AC-2 NO-GO を解消するための必須前提条件であることが確定した。** watchdog 未実装のまま Phase C 以降の per-job コンテナ運用に進む場合、per-job コンテナが(OOM kill、host 再起動、docker daemon 再起動、意図しない `docker kill`/`docker rm` 等で)異常終了すると、そのジョブは自動回復せず `failed` のまま放置される。少なくとも次のいずれかが Phase C 着手前に必要:
   - (a) S5 watchdog を前倒しで実装し、per-job コンテナの異常終了を検知して job を `failed` へ確実に reconcile する（現状 dispatch.py 側の `_dispatch_one` は起動時失敗のみ `failed` へ書き込み、起動後のコンテナ消失は未検知）、または
   - (b) 少なくとも「per-job コンテナが落ちたら自動再試行はしない」ことを明示の運用制約として決定ログに残し、オペレーターへの通知（Slack等）だけは確実に届く設計にする。
3. `--rm` フラグは per-job コンテナ自身の内部プロセス（`claude --bg`）終了時のみコンテナを破棄する用途であり、「per-job コンテナを外部から kill する」シナリオとは無関係。per-job コンテナが `hermes.config.yaml` の `terminal.lifetime_seconds` (S2で1800秒→本ドキュメント下記の通り21600秒に引き上げ済み) より長く実行される場合に途中で強制終了されないことは、実測で別途確認が必要（未着手）。

## config.yaml への反映

`hermes/config.yaml` の `terminal.lifetime_seconds` を 1800 秒（30分）から 21600 秒（6時間）に引き上げた。この変更は AC-2 の GO/NO-GO いずれの分岐でも安全側に働く:

- GO（per-job コンテナが呼び出し元から独立して生存する）の場合でも、hermes 自身の対話ターミナル（`terminal:` backend、dispatch_job 呼び出し元を含む）が長時間の ChatOps セッション中に途中で recycle されないマージンを確保する。
- NO-GO（長寿命 per-job コンテナモデルが必須、と確定した場合）でも、より長い lifetime は前提条件として必要になる。

`terminal.container_persistent` は変更していない（現状 `false` のまま）。これは hermes 自身の対話ターミナルの再利用可否に関する設定であり、per-job dispatch コンテナ（`dispatch.py` が `docker run -d` で都度新規作成するモデル）とは独立した設定項目である。AC-2 が NO-GO で確定した以上、`container_persistent` を導入して per-job コンテナ側にも何らかの持続性/再起動機構を持たせるべきかは、フォローアップ2 (S5 watchdog 設計) の検討時に合わせて再評価する。

## まとめ

| AC | 判定 | 根拠 |
|----|------|------|
| AC-2 | **NO-GO（実機確認済み）** | オペレーターが sandbox 外 host shell で `tests/hermes-phaseB-gate.sh` を実行し、per-job コンテナ (`hermes-claude-<job_id>`) を明示 kill 後、120秒のポーリング窓内で manifest.status=done にも PR 生成にも至らないことを実測。S5 watchdog（reconcile/再起動機構）未実装のため、per-job コンテナの異常終了に対してジョブは前進しないことが確定。長寿命 per-job コンテナモデルへの移行（フォローアップ2参照）が Phase C 着手前の確定要件となった |
| AC-3 | GO（実機確認済み） | `tests/hermes-phaseB-gate.sh` を host 非root (`uid=502`) で実行し、`CLAUDE_CONFIG_DIR` 越しの `claude agents --json --cwd` が exit 0 + JSON 配列を返し、状態ファイルが指定ディレクトリに作成されることを確認 |

**フォローアップ (Phase C 着手前の blocking 要件に格上げ)**: 上記「未確定事項・要フォローアップ」2. のとおり、S5 watchdog/reconcile 機構（または最低限の異常終了検知＋通知）を Phase C 着手前に設計・実装すること。
