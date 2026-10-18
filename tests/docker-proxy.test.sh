#!/usr/bin/env bash
# docker-proxy のテスト（docker_proxy_test.py）を回す。
# 実 docker は使わない。上流の docker.sock は一時ディレクトリの Unix ソケットのスタブが受ける。
# あわせて RULES.md の「使えるもの」に docker-sb の使い方があることを確かめる。
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$REPO_ROOT/home-manager/home/file/docker-proxy"

# -----------------------------------------------------------------------------
# rules_docker_sb: RULES.md の「使えるもの」に docker-sb の項があり、OrbStack の読み取り
# （ps / images / inspect / stats --no-stream / logs）に使うこと、書き込み系（run / stop / rm / rmi /
# prune）は proxy が 403 を返して通らないこと、その場合は docker-vm、ホストのコンテナの停止・削除は
# 人間に頼むことが書かれている
# -----------------------------------------------------------------------------
rules_line="$(awk '/^使えるもの:/ { f = 1; next } f && /^$/ { exit } f && /^- docker-sb:/' "${REPO_ROOT}/claude-code/RULES.md")"
missing=()
# shellcheck disable=SC2016 # 意図的: RULES.md のバッククォートを文字列として探す
for want in "OrbStack" '`docker-sb ps`' '`images`' '`inspect`' '`stats --no-stream`' '`logs`' \
  '`run`' '`stop`' '`rm`' '`rmi`' '`prune`' "403" '`docker-vm`' "停止・削除は人間" '`Config.Env` が取り除かれる'; do
  case "${rules_line}" in
  *"${want}"*) ;;
  *) missing+=("${want}") ;;
  esac
done
if [ -n "${rules_line}" ] && [ "${#missing[@]}" -eq 0 ]; then
  echo "PASS: rules_docker_sb"
else
  echo "FAIL: rules_docker_sb line=${rules_line:-<none>} missing=${missing[*]:-}" >&2
  exit 1
fi

cd "$SRC_DIR"
if python3 -B -m unittest -v docker_proxy_test; then
  echo "PASS: docker-proxy"
else
  echo "FAIL: docker-proxy" >&2
  exit 1
fi
