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

RP_ENV=/etc/rp_environment
RP_MARK='# rp_environment (installed by start.sh)'
RP_HOOK="[ -r $RP_ENV ] && . $RP_ENV"

# 環境変数を /etc/rp_environment に書き出し、SSH ログイン時にも見えるようにする。
# 上流と同じく「大文字始まりの環境変数をすべて書き出し、PUBLIC_KEY だけ除外」する。
# 許可リストにすると、RunPod のテンプレートでユーザーが自分で設定した変数
# (MODEL_REPO など) が SSH ログイン時に見えなくなる。
#
# 上流と違って chmod 600 にしているのは、全変数を書き出す以上 RUNPOD_API_KEY の
# ような秘密が入りうるため。
export_env_vars() {
    local name value
    : > "$RP_ENV"
    chmod 600 "$RP_ENV"
    while IFS='=' read -r name value; do
        case "$name" in
            # 公開鍵は書き出す必要がない
            PUBLIC_KEY) continue ;;
            # シェルが自分で管理する変数。SSH セッションごとに正しい値が入るので、
            # コンテナ起動時の値を上書きさせない (TERM を固定すると SSH 越しの
            # vim / tmux が壊れる)。
            PWD|OLDPWD|SHLVL|TERM|_) continue ;;
        esac
        # printenv は複数行の値も吐くので、変数名として妥当な行だけを拾う
        [[ "$name" =~ ^[A-Z_][A-Z0-9_]*$ ]] || continue
        printf 'export %s=%q\n' "$name" "$value" >> "$RP_ENV"
    done < <(printenv)

    install_env_hooks
    log "wrote $RP_ENV ($(wc -l < "$RP_ENV") vars)"
}

# /etc/rp_environment を読ませる仕掛けを 2 箇所に置く。sshd は自分の環境を session に
# 渡さないため、これが無いと SSH セッションの PATH は sshd の既定値になり
# /opt/llama.cpp/bin が入らない (llama-server が引けない)。
#
#   /etc/profile.d/   … ログインシェル (SSH で入った後の対話シェル、bash -lc)
#   ~/.bashrc の先頭  … `ssh <host> <command>` の非対話シェル。bash は sshd 経由で
#                       起動されたときは非対話でも ~/.bashrc を読むが、Ubuntu の
#                       .bashrc は冒頭の `[ -z "$PS1" ] && return` で抜けるため、
#                       末尾に追記しても読まれない。先頭に入れる必要がある。
#
# /etc/rp_environment は PATH を絶対値で書き出すので、何度 source されても PATH が
# 二重に前置されることはない。
install_env_hooks() {
    local rc="$HOME/.bashrc" tmp

    printf '%s\n%s\n' "$RP_MARK" "$RP_HOOK" > /etc/profile.d/rp_environment.sh
    chmod 644 /etc/profile.d/rp_environment.sh

    [ -f "$rc" ] || : > "$rc"
    if ! grep -qF "$RP_MARK" "$rc"; then
        tmp=$(mktemp)
        { printf '%s\n%s\n\n' "$RP_MARK" "$RP_HOOK"; cat "$rc"; } > "$tmp"
        cat "$tmp" > "$rc"
        rm -f "$tmp"
    fi
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
