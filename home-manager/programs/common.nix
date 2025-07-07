{
  shellSortcuts = {
    # ezaをlsとして利用
    ls = ''eza --icons --git --time-style relative -la'';
    lt = ''eza --icons --git --time-style relative --tree -aI "node_modules|.git|.cache"'';
    ltl = ''eza --icons --git --time-style relative --tree -alI "node_modules|.git|.cache"'';
    # batをcatとして利用
    cat = ''bat'';
    # ripをrmとして利用
    rm = ''rip'';
    # 選択した過去の実行コマンドをクリップボードにコピー
    h = ''echo -n $(history | fzf +s --layout=reverse) | pbcopy'';
    # 選択したローカルリポジトリリストへの移動をgと定義
    g = ''cd "$(ghq list --full-path | fzf --layout=reverse --preview 'eza --icons --git --time-style relative -la {1}')"'';
    # git
    # ローカルブランチを選択してコピー
    B = ''echo -n "$(git branch -av | fzf --layout=reverse --prompt "GIT BRANCH>"| sd "\*" "" |awk '{print $1}')" | pbcopy'';
    S = ''git switch "$(git branch -av | fzf --layout=reverse --prompt "GIT BRANCH>" | sd "\*" "" |awk '{print $1}')"'';
    # gh
    # githubブラウザページを開く
    ghb = ''gh browse'';
    # lazigit
    lg = ''lazygit'';
    # lazydocker
    ld = ''lazydocker'';
    # yazi
    y = ''yazi'';
    # カレントディレクトリのパスをクリップボードにコピー 
    pwdc = ''echo -n "$(pwd)" | pbcopy; pbpaste'';
    # 選択したディレクトリ配下の指定したディレクトリ配下のファイルパスと中身を一括取得
    fl = ''fd --type f . "$(eza -DR | sd ':$' \'\' | rg '^./' | fzf)" -x sh -c 'echo "==== $1 ===="; cat "$1"' _ {} | pbcopy; pbpaste'';
    # MySqlのDBを選択して接続
    mdb = ''cat ~/.myclirc ~/.myclirc.local > ~/.myclirc_combined ; mycli --myclirc=~/.myclirc_combined "$(mycli --list-dsn --myclirc=~/.myclirc_combined | fzf --layout=reverse --prompt 'DSN>')" ; rm ~/.myclirc_combined'';
    # lastpassでuser/passなどをクリップボードにコピー
    lp = ''lpass show $(lpass ls -l | fzf | awk "{print $5}" | sd ']$' \'\') | fzf | awk '{print $2}'| sd 'n' \'\' | pbcopy ; pbpaste'';
    # docker
    # finch利用時にdockerコマンドをfinchに変換
    #docker="finch
    # 選択した起動中コンテナに入る
    d = ''docker exec -it $(docker ps | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs {1}'| awk '{print $1}') sh'';
    # 選択したlogを表示する
    dl = ''docker logs --follow --tail=100 $(docker ps -a | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs --details {1}' | awk '{print $1}')'';
    # 選択したコンテナを停止する
    ds = ''docker stop $(docker ps -a | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs {1}'| awk '{print $1}')'';
    # 選択したコンテナを削除する
    dr = ''docker rm $(docker ps -a | fzf --layout=reverse --prompt "Docker Container>" --preview-window 'bottom:70%' --preview 'docker logs {1}'| awk '{print $1}')'';
    # 選択したコンテナイメージを削除する
    dir = ''docker image rm $(docker image ls | fzf --layout=reverse --prompt "Docker Image>" --preview 'docker image inspect {3}'| awk '{print $3}')'';
    # 選択したコンテナボリュームを削除する
    dvr = ''docker volume rm $(docker volume ls | fzf --layout=reverse --prompt "Docker Volume>" --preview 'docker volume inspect {2}'| awk '{print $2}')'';
    dp = ''docker ps'';
    dpr = ''docker system prune -f'';
    # docker composeの略記
    dc = ''docker compose'';
    dcb = ''docker compose build --no-cache'';
    dcu = ''docker compose up -d'';
    dcd = ''docker compose down'';
    dcp = ''docker compose ps'';
    # devcontainer
    dvcb = ''devcontainer build --workspace-folder . --no-cache'';
    dvcu = ''devcontainer up --workspace-folder .'';
    dvcur = ''devcontainer up --workspace-folder . --remove-existing-container'';
    dvce = ''vt devcontainer exec --workspace-folder . bash'';
    dvcc = ''vt devcontainer exec --workspace-folder . claude --dangerously-skip-permissions -r'';
    # gcloud
    # config切り替え
    gca = ''gcloud config configurations activate $(gcloud config configurations list | fzf --layout=reverse --prompt 'config>' | awk '{print $1}')'';
    gcp = ''gcloud config set project $(gcloud projects list | fzf --layout=reverse --prompt 'config>' | awk '{print $1}')'';
    # global ip確認
    ip = ''echo -n $(dig myip.opendns.com @208.67.222.222 +short) | pbcopy ; pbpaste'';
    # deepl
    tre = ''deepl text --to en-us '';
    trj = ''deepl text --to ja '';
  };
  shellAleases = { };
}
