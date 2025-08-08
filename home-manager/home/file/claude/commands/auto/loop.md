---
name: auto:loop
description: PR URL / 番号を受け取り、auto:review ↔ auto:fix を LGTM まで自動反復
allowed-tools:
  - sc:spawn
---

sc:spawn --seq --ultrathink --verbose --cite "
  set -euo pipefail
  MAX=15
  i=1
  while [ \$i -le \$MAX ]; do
    ################################################################
    # review フェーズ
    ################################################################
    REVIEW_OUT=\$(sc:spawn \"/auto:review $ARGUMENTS --seq --ultrathink --verbose --cite\" || true)
    echo \"\$REVIEW_OUT\"

    # 1) 終了コード0契約を尊重しつつ、2) 文字列LGTMでもブレーク
    LAST_STATUS=\$?
    if [ \$LAST_STATUS -eq 0 ] || echo \"\$REVIEW_OUT\" | grep -qi \"\\bLGTM\\b\"; then
      echo '✅ LGTM – ループ終了'
      break
    fi

    ################################################################
    # fix フェーズ
    ################################################################
    sc:spawn \"/auto:fix $ARGUMENTS --seq --ultrathink --verbose --cite\" \
      || { echo '❌ auto:fix failed'; exit 2; }

    # LLM コンテキストを整理（ベターな収束のため）
    sc:spawn \"/clear\" || true

    # レート制御
    sleep 2
    i=\$((i+1))
  done

  if [ \$i -gt \$MAX ]; then
    echo \"⚠️ 上限(\$MAX回)に達しました。手動確認をお願いします。\"
    exit 3
  fi
"
