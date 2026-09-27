{ pkgs, username, ... }:
let
  tailscaleLifeboatPort = 2222;

  tailscaleLifeboatSshd = pkgs.writeShellApplication {
    name = "tailscale-lifeboat-sshd";
    runtimeInputs = with pkgs; [
      coreutils
      tailscale
    ];
    text = ''
      marker="/Users/${username}/.config/dotfiles/.no-sleep-server"
      state_dir="/var/db/playpark-lifeboat-sshd"
      run_dir="/var/run/playpark-lifeboat-sshd"
      config_file="$run_dir/sshd_config"
      host_key="$state_dir/ssh_host_ed25519_key"
      port="${toString tailscaleLifeboatPort}"

      log() {
        printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
      }

      remote_access_server_enabled() {
        if [ -f "$marker" ]; then
          return 0
        fi

        local_host_name="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)"
        computer_name="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)"
        case "$local_host_name $computer_name" in
          *Studio*) return 0 ;;
          *) return 1 ;;
        esac
      }

      if ! remote_access_server_enabled; then
        exit 0
      fi

      attempt=0
      target=""
      while [ "$attempt" -lt 60 ]; do
        target="$(tailscale ip -4 2>/dev/null | /usr/bin/head -n 1)"
        if [ -n "$target" ]; then
          break
        fi
        attempt=$((attempt + 1))
        sleep 5
      done

      if [ -z "$target" ]; then
        log "tailscale IPv4 is not available; lifeboat sshd not started"
        exit 75
      fi

      /usr/bin/install -d -m 0700 "$state_dir"
      /usr/bin/install -d -m 0755 "$run_dir"

      if [ ! -s "$host_key" ]; then
        /usr/bin/ssh-keygen -t ed25519 -f "$host_key" -N "" -C "playpark-lifeboat-sshd" >/dev/null
      fi

      cat >"$config_file" <<EOF
      Port $port
      ListenAddress $target
      HostKey $host_key
      PidFile $run_dir/sshd.pid
      AuthorizedKeysFile .ssh/authorized_keys
      PubkeyAuthentication yes
      PasswordAuthentication yes
      KbdInteractiveAuthentication yes
      UsePAM yes
      PermitRootLogin no
      AllowUsers ${username}
      UseDNS no
      PrintMotd no
      ClientAliveInterval 30
      ClientAliveCountMax 4
      Subsystem sftp /usr/libexec/sftp-server
      EOF

      /usr/sbin/sshd -t -f "$config_file"
      log "starting lifeboat sshd on $target:$port"
      exec /usr/sbin/sshd -D -e -f "$config_file"
    '';
  };

  sshBannerWatchdog = pkgs.writeShellApplication {
    name = "ssh-banner-watchdog";
    runtimeInputs = with pkgs; [
      coreutils
      tailscale
    ];
    text = ''
      marker="/Users/${username}/.config/dotfiles/.no-sleep-server"
      ssh_plist="/System/Library/LaunchDaemons/ssh.plist"

      log() {
        printf '%s %s\n' "$(/bin/date '+%Y-%m-%dT%H:%M:%S%z')" "$*"
      }

      ssh_banner_ok() {
        host="$1"
        port="$2"
        if [ -z "$host" ]; then
          return 1
        fi

        banner="$({ sleep 1; } | /usr/bin/nc -G 3 -w 5 "$host" "$port" 2>/dev/null || true)"
        case "$banner" in
          SSH-2.0-OpenSSH*) return 0 ;;
          *) return 1 ;;
        esac
      }

      repair_remote_login() {
        /bin/launchctl kickstart -k system/com.openssh.sshd >/dev/null 2>&1 || true
        sleep 2
        if ssh_banner_ok "$target" 22; then
          return 0
        fi

        /bin/launchctl bootout system/com.openssh.sshd >/dev/null 2>&1 || true
        /bin/launchctl enable system/com.openssh.sshd >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "$ssh_plist" >/dev/null 2>&1 || true
        sleep 5
        if ssh_banner_ok "$target" 22; then
          return 0
        fi

        /usr/sbin/systemsetup -setremotelogin off >/dev/null 2>&1 || true
        sleep 2
        /usr/sbin/systemsetup -setremotelogin on >/dev/null 2>&1 || true
        sleep 10
        /bin/launchctl enable system/com.openssh.sshd >/dev/null 2>&1 || true
        /bin/launchctl bootstrap system "$ssh_plist" >/dev/null 2>&1 || true
      }

      repair_lifeboat_sshd() {
        /bin/launchctl kickstart -k system/com.playpark.tailscale-lifeboat-sshd >/dev/null 2>&1 || true
      }

      remote_access_server_enabled() {
        if [ -f "$marker" ]; then
          return 0
        fi

        local_host_name="$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)"
        computer_name="$(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)"
        case "$local_host_name $computer_name" in
          *Studio*) return 0 ;;
          *) return 1 ;;
        esac
      }

      if ! remote_access_server_enabled; then
        exit 0
      fi

      target="$(tailscale ip -4 2>/dev/null | /usr/bin/head -n 1)"
      if [ -z "$target" ]; then
        exit 0
      fi

      if ! ssh_banner_ok "$target" "${toString tailscaleLifeboatPort}"; then
        sleep 10
        if ! ssh_banner_ok "$target" "${toString tailscaleLifeboatPort}"; then
          log "target=$target:${toString tailscaleLifeboatPort} lifeboat SSH banner missing; restarting lifeboat sshd"
          repair_lifeboat_sshd
        fi
      fi

      if ssh_banner_ok "$target" 22; then
        exit 0
      fi

      sleep 10
      if ssh_banner_ok "$target" 22; then
        exit 0
      fi

      if ! ssh_banner_ok 127.0.0.1 22; then
        log "target=$target and localhost both failed; leaving Remote Login untouched"
        exit 0
      fi

      log "target=$target stopped returning an SSH banner; repairing Remote Login"
      repair_remote_login

      if ssh_banner_ok "$target" 22; then
        log "target=$target SSH banner recovered"
      else
        log "target=$target still has no SSH banner after repair"
      fi
    '';
  };
in
{
  # Tailscale VPN（CLIのみ、インターネット越しSSH用）
  services.tailscale.enable = true;
  services.openssh.enable = true;

  # Mac Studio の Remote Login が外部/Tailscale 側だけ沈黙した時に自動復旧する。
  launchd.daemons.ssh-banner-watchdog = {
    command = "${sshBannerWatchdog}/bin/ssh-banner-watchdog";
    serviceConfig = {
      Label = "com.playpark.ssh-banner-watchdog";
      RunAtLoad = true;
      StartInterval = 300;
      StandardOutPath = "/var/log/ssh-banner-watchdog.log";
      StandardErrorPath = "/var/log/ssh-banner-watchdog.log";
    };
  };

  # Apple Remote Login とは独立した Tailscale 専用の非常用 SSH 経路。
  # Moshi/SSH 側で Port 2222 を指定すれば、Remote Login の launchd 登録が壊れても入れる。
  launchd.daemons.tailscale-lifeboat-sshd = {
    command = "${tailscaleLifeboatSshd}/bin/tailscale-lifeboat-sshd";
    serviceConfig = {
      Label = "com.playpark.tailscale-lifeboat-sshd";
      RunAtLoad = true;
      StartInterval = 300;
      KeepAlive = {
        Crashed = true;
        SuccessfulExit = false;
      };
      ThrottleInterval = 30;
      StandardOutPath = "/var/log/tailscale-lifeboat-sshd.log";
      StandardErrorPath = "/var/log/tailscale-lifeboat-sshd.log";
    };
  };

  # 24/7 稼働のリモートアクセスサーバー (Mac Studio) でのみ sleep を無効化する。
  # LocalHostName/ComputerName に Studio を含む Mac は自動対象にし、マーカーでも明示できる。
  # 明示有効化: touch /Users/${username}/.config/dotfiles/.no-sleep-server
  # 明示無効化する場合は Mac 名から Studio を外すか、この設定を調整してから switch する。
  system.activationScripts.pmsetServerConfig.text = ''
    MARKER="/Users/${username}/.config/dotfiles/.no-sleep-server"
    LOCAL_HOST_NAME=$(/usr/sbin/scutil --get LocalHostName 2>/dev/null || true)
    COMPUTER_NAME=$(/usr/sbin/scutil --get ComputerName 2>/dev/null || true)
    REMOTE_ACCESS_SERVER=
    case "$LOCAL_HOST_NAME $COMPUTER_NAME" in
      *Studio*) REMOTE_ACCESS_SERVER=1 ;;
    esac

    if [ -f "$MARKER" ] || [ -n "$REMOTE_ACCESS_SERVER" ]; then
      echo "pmsetServerConfig: remote access server detected — disabling sleep for 24/7 remote access"
      /usr/bin/pmset -a sleep 0
      /usr/bin/pmset -a disksleep 0
      /usr/bin/pmset -a womp 1
    fi
  '';
}
