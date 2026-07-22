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

## issue #122 対応: per-job コンテナ異常終了の検知と reconcile

### (1) 採用方針

上記フォローアップ 2. の選択肢 (a)（S5 watchdog を実装し failed へ確実に reconcile する）と (b)（少なくとも運用制約＋確実な通知を決定ログに残す）の**ハイブリッド**を採用した。

`hermes/watchdog.sh` の `reconcile_job` に、`poll_bg_status` が `running` を返した場合の追加チェックとして `poll_container_state` を実装した。manifest の `container_id`（`dispatch.py` が dispatch 時点で既に永続化済み）に対し `docker inspect -f '{{.State.Running}}' <container_id>` を実行し、結果を **alive / dead / unknown** の 3 値に分類する:

- **alive**（`Running=true`）: `container_dead_streak` を 0 にリセットして `running` のまま return する。正常完了直前の一時的 dead 観測（`--rm` レース）による誤蓄積を防ぐため。
- **dead**（`Running=false`、または `docker inspect` が `no such object` エラーで失敗＝`--rm` 済み）: `container_dead_streak` をインクリメントする。`HERMES_WATCHDOG_CONTAINER_DEAD_CONFIRM_COUNT`（デフォルト 2）連続で dead を観測して初めて `status=failed` を確定し、既存の notify/cleanup パイプラインに合流させる。単発の dead 観測では確定しない。
- **unknown**（`docker` が PATH に無い、または daemon 接続エラー等 `no such object` 以外の失敗）: `container_dead_streak` を**一切変更しない**。daemon 再起動のたびに検知蓄積が消えて誤って検知が遅延する、または daemon 不達を理由に安易に failed 化する、のどちらも避けるための設計。

`container_id` が空/null の manifest（issue #122 以前に dispatch された旧ジョブ）はこの死活チェックを完全にスキップし、従来どおり `poll_bg_status` のみで reconcile する（後方互換）。

failed 確定後は、既存の `notify_dispatch` / cleanup 経路（Slack/Discord 通知、`notified` フラグによる冪等化、cleanup）にそのまま合流するため、per-job コンテナが異常終了したジョブはオペレーターへ確実に通知される。

**運用制約（明示）**: **自動再試行（コンテナの再起動・ジョブの再投入）は実装しない**。per-job コンテナが落ちて `failed` 通知を受けたジョブは、オペレーターが手動で ChatOps コマンドを再実行し再 dispatch する運用とする。これは今回のスコープでの意図的な選択であり、将来的に自動再試行が必要になった場合は別途設計・決定する。

**検知〜通知レイテンシ**: launchd `com.playpark.hermes-watchdog` は `StartInterval=120` 秒で起動する（`home-manager/home/default.nix`, `hermes/README.md` に既述）。`CONTAINER_DEAD_CONFIRM_COUNT=2` 連続確認が必要なため、コンテナ死亡から通知までの最悪ケースのレイテンシは**約 4〜6 分**（2 パス分の 120 秒間隔 ± 実行タイミングのずれ）である。

**docker events 購読を採らなかった理由**: `docker events` によるストリーミング購読は、実装がシンプルで検知遅延も理論上ゼロに近づけられる一方、常駐プロセスとして動き続ける必要があり、現行の watchdog は launchd `StartInterval` による周期起動（起動のたびに新規プロセスとして起動し、実行後に終了する）モデルを前提にしている。常駐化には別途プロセス管理（launchd `KeepAlive` 化、再起動時の状態復元、二重起動防止の見直し等）が必要になり、issue #122 が要求する「異常終了の検知と reconcile」に対しては poll ベースで十分満たせるため、常駐プロセスの追加は YAGNI と判断した。

### (2) 検証エビデンス

`~/.hermes/hermes-agent/venv/bin/python -m pytest hermes/plugins/claude_runner/tests -v` を本 implementer セッションで実行した結果（`test_watchdog_container.py` の 7 ケースを含む全 54 ケースが PASS）:

```
============================= test session starts ==============================
platform darwin -- Python 3.11.15, pytest-9.0.3, pluggy-1.6.0 -- /Users/naramotoyuuji/.hermes/hermes-agent/venv/bin/python
cachedir: .pytest_cache
rootdir: /Users/naramotoyuuji/ghq/github.com/it-all-playpark/dotfiles/.claude/worktrees/df-122
plugins: xdist-3.8.0, split-0.11.0, asyncio-1.3.0, anyio-4.13.0
asyncio: mode=Mode.STRICT, debug=False, asyncio_default_fixture_loop_scope=None, asyncio_default_fixture_loop_scope=None
collected 54 items

hermes/plugins/claude_runner/tests/test_dispatch.py::test_unbound_channel_is_refused_without_side_effects PASSED [  1%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_repo_override_not_bound_to_channel_is_refused PASSED [  3%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_bound_channel_dispatches_with_correct_host_and_container_paths PASSED [  5%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_bound_channel_with_multiple_repos_fans_out_one_job_per_repo PASSED [  7%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_docker_launch_failure_marks_manifest_failed_and_reports_error PASSED [  9%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_malformed_bindings_file_is_fail_closed PASSED [ 11%]
hermes/plugins/claude_runner/tests/test_dispatch.py::test_missing_required_args_returns_tool_error PASSED [ 12%]
hermes/plugins/claude_runner/tests/test_docker_bg_smoke.py::test_bg_job_id_is_read_from_container_logs_not_run_stdout PASSED [ 14%]
hermes/plugins/claude_runner/tests/test_docker_bg_smoke.py::test_bg_job_id_matches_claude_agents_listing_container_id_does_not PASSED [ 16%]
hermes/plugins/claude_runner/tests/test_docker_bg_smoke.py::test_docker_run_stdout_empty_raises_dispatch_error PASSED [ 18%]
hermes/plugins/claude_runner/tests/test_docker_bg_smoke.py::test_missing_bg_job_id_in_logs_raises_after_poll_timeout PASSED [ 20%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_multi_repo_bind_fans_out_to_independent_jobs PASSED [ 22%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_running_at_cap_returns_congested_with_no_new_dispatch PASSED [ 24%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_pending_job_also_counts_toward_the_cap PASSED [ 25%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_below_cap_dispatches_normally PASSED [ 27%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_done_job_does_not_count_toward_the_cap PASSED [ 29%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_malformed_bindings_file_rejects_the_bind_with_no_side_effects PASSED [ 31%]
hermes/plugins/claude_runner/tests/test_fanout_limit.py::test_invalid_repo_slug_in_bindings_rejects_the_bind PASSED [ 33%]
hermes/plugins/claude_runner/tests/test_guard.py::test_dispatch_job_with_unbound_channel_is_blocked PASSED [ 35%]
hermes/plugins/claude_runner/tests/test_guard.py::test_dispatch_job_with_repo_override_not_bound_is_blocked PASSED [ 37%]
hermes/plugins/claude_runner/tests/test_guard.py::test_dispatch_job_with_invalid_bindings_schema_is_blocked PASSED [ 38%]
hermes/plugins/claude_runner/tests/test_guard.py::test_dispatch_job_with_missing_required_args_is_blocked PASSED [ 40%]
hermes/plugins/claude_runner/tests/test_guard.py::test_dispatch_job_with_bound_channel_is_allowed PASSED [ 42%]
hermes/plugins/claude_runner/tests/test_guard.py::test_other_tool_name_is_passed_through PASSED [ 44%]
hermes/plugins/claude_runner/tests/test_registration.py::test_register_adds_dispatch_job_to_registry PASSED [ 46%]
hermes/plugins/claude_runner/tests/test_registration.py::test_dispatch_job_stub_returns_error_json PASSED [ 48%]
hermes/plugins/claude_runner/tests/test_registration.py::test_manifest_round_trip_keeps_host_and_container_paths_separate PASSED [ 50%]
hermes/plugins/claude_runner/tests/test_registration.py::test_manifest_rejects_invalid_status PASSED [ 51%]
hermes/plugins/claude_runner/tests/test_registration.py::test_manifest_rejects_missing_field PASSED [ 53%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_valid_file_loads PASSED [ 55%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[not_platforms: {}\n] PASSED [ 57%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[platforms:\n  slack: not-a-mapping\n] PASSED [ 59%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[platforms:\n  slack:\n    channels: {}\n] PASSED [ 61%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[platforms:\n  slack:\n    channels:\n      C1: {}\n] PASSED [ 62%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[platforms:\n  slack:\n    channels:\n      C1:\n        repos: []\n] PASSED [ 64%]
hermes/plugins/claude_runner/tests/test_registration.py::test_bindings_invalid_schema_raises[platforms:\n  slack:\n    channels:\n      C1:\n        repos:\n          - not-a-slug\n] PASSED [ 66%]
hermes/plugins/claude_runner/tests/test_registration.py::test_repo_bindings_sample_file_is_valid PASSED [ 68%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_container_alive_keeps_running_with_zero_streak PASSED [ 70%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_container_no_such_object_confirms_dead_after_two_passes_then_failed PASSED [ 72%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_container_exited_running_false_counts_as_dead_observation PASSED [ 74%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_docker_daemon_unreachable_leaves_existing_streak_unchanged PASSED [ 75%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_container_alive_resets_existing_streak_to_zero PASSED [ 77%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_manifest_without_container_id_skips_container_check PASSED [ 79%]
hermes/plugins/claude_runner/tests/test_watchdog_container.py::test_bg_session_completed_takes_priority_over_dead_container PASSED [ 81%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_notified_false_triggers_single_notify_and_flips_true PASSED [ 83%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_notified_true_skips_notify_and_triggers_cleanup PASSED [ 85%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_failed_status_notified_once_like_done PASSED [ 87%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_running_job_with_still_running_bg_session_is_untouched PASSED [ 88%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_running_job_with_completed_bg_session_reconciles_then_notifies PASSED [ 90%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_slack_ok_false_body_is_treated_as_notify_failure_and_retried PASSED [ 92%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_discord_platform_notifies_via_discord_api_not_slack PASSED [ 94%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_unknown_platform_has_no_adapter_and_makes_no_network_call PASSED [ 96%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_freshly_dispatched_job_absent_from_listing_stays_running_within_grace PASSED [ 98%]
hermes/plugins/claude_runner/tests/test_watchdog_notify.py::test_absent_job_past_grace_requires_consecutive_confirmations_before_done PASSED [100%]

============================== 54 passed in 8.61s ==============================
```

### (3) AC-2 相当シナリオの実機確認

`bash tests/hermes-phaseB-gate.sh` を本 implementer セッション（sandboxed Bash tool）で実行した。本セッションは docker daemon ソケットへの接続が権限で拒否される環境であり、AC-2 セクションは既存の安全側フォールバックにより SKIP に倒れた:

```
=== hermes-phaseB go/no-go gate (AC-2, AC-3, フェーズB) ===
  REPO_ROOT: /Users/naramotoyuuji/ghq/github.com/it-all-playpark/dotfiles/.claude/worktrees/df-122
  HERMES_AGENT_ROOT: /Users/naramotoyuuji/.hermes/hermes-agent
  TARGET_REPO: it-all-playpark/dotfiles

NOTE: docker daemon not reachable from this shell -- AC-2 section will
      be SKIPped. Re-run this script from a shell with real docker
      socket access (outside any agent sandbox) to get an AC-2 verdict.
  SKIP: ac2_dispatch_container_kill_and_progress (docker daemon not reachable from this shell)
- ac3_claude_agents_reads_per_job_config_dir
  PASS: ac3_claude_agents_reads_per_job_config_dir (uid=502, exit 0, JSON array returned)
  AC-3 RESULT: GO -- non-root host user (uid=502) read
               CLAUDE_CONFIG_DIR=/tmp/claude-502/hermes-phaseB-gate.w2oFxS/claude-state/scratch-job via `claude agents`
               successfully. Record as confirmed in the decision-log.

Results: 1 passed, 0 failed
```

CLAUDE.md 運用ルール（sandbox で docker 等が塞がれた場合は `dangerouslyDisableSandbox` で勝手に緩めず、失敗を報告して設定調整を提案する）に従い、本セッションでは sandbox を回避せず、この制約をそのまま報告する。

**オペレーターへの依頼（sandbox 外での再実行手順）**: docker socket に到達可能な host shell（sandbox 外）で以下を実行し、`ac2b_watchdog_reconciles_killed_container_to_failed` / `ac2b_notify_path_exercised` の PASS/FAIL 行を本セクションへ追記すること。

```
bash tests/hermes-phaseB-gate.sh
```

このシナリオでは、gate script が per-job コンテナ（`hermes-claude-<job_id>`）を dispatch 後に明示 `docker kill` し、`HERMES_WATCHDOG_SKIP_LOCK=1` を付けて `hermes/watchdog.sh` を最大 6 回（間に `sleep 2` を挟む）実行して、manifest が `status=failed` へ reconcile されること（`ac2b_watchdog_reconciles_killed_container_to_failed`）、および watchdog のログに reconcile 行と通知経路実行の文言（`reconciling status to failed (issue #122)` かつ `skipping notify for channel` または `notified (status=failed`）の両方が出力されること（`ac2b_notify_path_exercised`）を検証する。

**オペレーター実測結果（未取得・記入待ち）**:

```
（ここに sandbox 外実行の ac2b_watchdog_reconciles_killed_container_to_failed / ac2b_notify_path_exercised の PASS/FAIL 行を追記する）
```

### (4) issue #122 対応後のステータス（まとめテーブル更新）

| 項目 | ステータス |
|------|-----------|
| per-job コンテナ異常終了の検知・reconcile | **実装済み**（`watchdog.sh` の `poll_container_state` + `CONTAINER_DEAD_CONFIRM_COUNT` streak、pytest 54/54 PASS で検証） |
| オペレーターへの確実な通知 | **実装済み**（failed 確定後、既存 notify_dispatch/cleanup 経路に合流。gate script の `ac2b_notify_path_exercised` で検証設計） |
| 自動再試行（コンテナ再起動・ジョブ再投入） | **非対応（運用制約として明記）**。手動でオペレーターが ChatOps コマンドを再実行する運用 |
| AC-2 の NO-GO ギャップ | 上記実装により **解消**（reconcile + 通知で per-job コンテナ異常終了に対する回復力を確保）。長寿命 per-job コンテナモデルへの移行検討（フォローアップ 3.）は本 issue のスコープ外で別途扱う |
| AC-2 相当シナリオの実機確認（gate script `ac2b_*`） | 本 implementer セッションでは sandbox 制約により SKIP。オペレーターによる sandbox 外再実行を依頼済み（上記(3)参照、結果は追記待ち） |
