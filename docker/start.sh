#!/usr/bin/env bash
#
# RunPod 用の ENTRYPOINT。
#
# RunPod API v2 は ENTRYPOINT を上書きできず、SSH 公開鍵も PUBLIC_KEY 環境変数で
# 渡してくるだけなので、鍵の展開と sshd の起動はイメージ側の責任になる。
# 挙動は RunPod 公式イメージの start.sh に合わせてある。
#   https://github.com/runpod/containers/blob/main/container-template/start.sh
#
set -Eeuo pipefail

log() { printf '[start.sh] %s\n' "$*"; }

# 環境変数を /etc/rp_environment に書き出し、SSH ログイン時にも見えるようにする。
# 上流と同じく「大文字始まりの環境変数をすべて書き出し、PUBLIC_KEY だけ除外」する。
# 許可リストにすると、RunPod のテンプレートでユーザーが自分で設定した変数
# (MODEL_REPO など) が SSH ログイン時に見えなくなる。
#
# 上流と違って chmod 600 にしているのは、全変数を書き出す以上 RUNPOD_API_KEY の
# ような秘密が入りうるため。
export_env_vars() {
    local name value
    : > /etc/rp_environment
    chmod 600 /etc/rp_environment
    while IFS='=' read -r name value; do
        [ "$name" = "PUBLIC_KEY" ] && continue
        # printenv は複数行の値も吐くので、変数名として妥当な行だけを拾う
        [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        printf 'export %s=%q\n' "$name" "$value" >> /etc/rp_environment
    done < <(printenv)

    if ! grep -qF '/etc/rp_environment' "$HOME/.bashrc" 2>/dev/null; then
        printf '\n# shellcheck source=/dev/null\nsource /etc/rp_environment\n' >> "$HOME/.bashrc"
    fi
    log "wrote /etc/rp_environment ($(wc -l < /etc/rp_environment) vars)"
}

# ホスト鍵はイメージに焼かず Pod ごとに生成する。焼くと public イメージ経由で
# 全 Pod の秘密鍵が公開されることになる。
#
# 上流は dsa も生成するが、DSA は OpenSSH 9.8 で削除されており
# Ubuntu 24.04 の ssh-keygen -t dsa は失敗するので生成しない。
generate_host_keys() {
    local type keyfile
    for type in rsa ecdsa ed25519; do
        keyfile="/etc/ssh/ssh_host_${type}_key"
        if [ ! -f "$keyfile" ]; then
            log "generating $type host key"
            ssh-keygen -q -t "$type" -f "$keyfile" -N ''
        fi
    done
}

setup_ssh() {
    if [ -z "${PUBLIC_KEY:-}" ]; then
        log "PUBLIC_KEY is not set; skipping sshd"
        return 0
    fi

    log "installing PUBLIC_KEY into ${HOME}/.ssh/authorized_keys"
    mkdir -p "$HOME/.ssh"
    printf '%s\n' "$PUBLIC_KEY" >> "$HOME/.ssh/authorized_keys"
    chmod 700 -R "$HOME/.ssh"

    generate_host_keys

    mkdir -p /run/sshd
    if /usr/sbin/sshd; then
        log "sshd started on port 22"
    else
        log "WARNING: sshd failed to start; continuing without SSH"
    fi
}

main() {
    export_env_vars
    setup_ssh

    if [ "$#" -eq 0 ]; then
        log "ready (idling)"
        exec sleep infinity
    fi

    log "ready (exec: $*)"
    exec "$@"
}

main "$@"
