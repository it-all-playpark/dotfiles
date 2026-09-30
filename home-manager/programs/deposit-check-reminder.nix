{
  config,
  lib,
  pkgs,
  ...
}:
let
  # 月末に売掛金の入金チェックを促すリマインダー。
  # チェック本体は back-office の /deposit-check skill (MF クラウド会計 MCP) が行う。
  # MCP からは口座の一括更新を実行できず、同期前の明細で判断すると
  # 入金済みを未入金と誤判定するため、ここでは人に一括更新を促すだけにとどめる。
  mfUrl = "https://accounting.moneyforward.com/";
in
lib.mkIf pkgs.stdenv.isDarwin {
  launchd.agents.deposit-check-reminder = {
    enable = true;
    config = {
      Label = "com.playpark.deposit-check-reminder";
      ProgramArguments = [
        "/bin/sh"
        "-c"
        ''
          # launchd は「月末日」を表現できないので 28〜31 日に起動し、翌日が 1 日のときだけ動く。
          [ "$(/bin/date -v+1d +%d)" = "01" ] || exit 0
          answer=$(/usr/bin/osascript \
            -e 'display dialog "月末の入金チェックの時間です。\n\n1. クラウド会計で データ連携 > 登録済一覧 から「一括更新」\n2. back-office で /deposit-check を実行" with title "入金チェック" buttons {"あとで", "クラウド会計を開く"} default button 2 giving up after 3600' \
            -e 'button returned of result')
          if [ "$answer" = "クラウド会計を開く" ]; then
            /usr/bin/open "${mfUrl}"
          fi
        ''
      ];
      EnvironmentVariables = {
        HOME = config.home.homeDirectory;
      };
      # 10:00 (ローカルタイム)。スリープ中だった場合は復帰時にまとめて実行される。
      StartCalendarInterval =
        map
          (day: {
            Day = day;
            Hour = 10;
            Minute = 0;
          })
          [
            28
            29
            30
            31
          ];
      ProcessType = "Interactive";
      StandardOutPath = "${config.home.homeDirectory}/.local/state/deposit-check-reminder.out.log";
      StandardErrorPath = "${config.home.homeDirectory}/.local/state/deposit-check-reminder.err.log";
    };
  };
}
