#!/usr/bin/env bash
#
# llama-cpp-runpod イメージの検証スクリプト。
#
# GPU 無しの環境で動くことを前提にしている。docker デーモンがリモートでも動くよう、
# bind mount (-v) とポート公開 (-p) には依存せず、docker run -d + docker exec で
# コンテナ内部を検査する。
#
#   IMAGE=llama-cpp-runpod:test ./test/test-image.sh
#
set -uo pipefail

IMAGE="${IMAGE:-llama-cpp-runpod:test}"
TEST_PUBLIC_KEY="${TEST_PUBLIC_KEY:-ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAITESTKEYDONOTUSExxxxxxxxxxxxxxxxxxxxxxxx test@example.invalid}"

PREFIX="llama-cpp-runpod-test-$$"
PASS=0
FAIL=0

# start_container はコマンド置換 (サブシェル) から呼ぶので、起動したコンテナを
# 変数に覚えさせても親には残らない。名前の prefix で引いて消す。
cleanup() {
  local ids
  ids=$(docker ps -aq --filter "name=^${PREFIX}-" 2>/dev/null)
  [ -n "$ids" ] && docker rm -f $ids >/dev/null 2>&1
  return 0
}
trap cleanup EXIT

ok()   { PASS=$((PASS + 1)); printf '  \033[32mok\033[0m   %s\n' "$1"; }
ng()   { FAIL=$((FAIL + 1)); printf '  \033[31mFAIL\033[0m %s\n' "$1"; [ $# -gt 1 ] && printf '       %s\n' "$2"; }
head_() { printf '\n\033[1m%s\033[0m\n' "$1"; }

# check <説明> <期待する終了コード 0> -- コマンド...
check() {
  local desc="$1"; shift
  local out
  if out=$("$@" 2>&1); then
    ok "$desc"
  else
    ng "$desc" "$(printf '%s' "$out" | tail -5 | tr '\n' ' ')"
  fi
}

start_container() {
  local name="$PREFIX-$1"; shift
  docker run -d --name "$name" "$@" "$IMAGE" >/dev/null 2>&1 || return 1
  printf '%s' "$name"
}

wait_running() {
  local name="$1" i
  for i in $(seq 1 30); do
    case "$(docker inspect -f '{{.State.Running}}' "$name" 2>/dev/null)" in
      true) return 0 ;;
    esac
    sleep 1
  done
  return 1
}

cexec() { docker exec "$1" bash -lc "$2"; }

########################################
head_ "0. イメージの存在"
########################################
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  ng "イメージ $IMAGE が存在する" "docker build -t $IMAGE . を先に実行すること"
  printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
  exit 1
fi
ok "イメージ $IMAGE が存在する"

########################################
head_ "1. イメージに焼かれていてはいけないもの"
########################################
# ホスト秘密鍵が焼かれていないこと (public イメージなので致命的)
baked_hostkeys=$(docker run --rm --entrypoint sh "$IMAGE" -c 'ls /etc/ssh/ 2>/dev/null | grep -E "^ssh_host_.*_key$" || true' 2>/dev/null)
if [ -z "$baked_hostkeys" ]; then
  ok "/etc/ssh/ssh_host_*_key がイメージに含まれていない"
else
  ng "/etc/ssh/ssh_host_*_key がイメージに含まれていない" "見つかった: $baked_hostkeys"
fi

# authorized_keys が焼かれていないこと
baked_authkeys=$(docker run --rm --entrypoint sh "$IMAGE" -c 'ls /root/.ssh/authorized_keys 2>/dev/null || true' 2>/dev/null)
if [ -z "$baked_authkeys" ]; then
  ok "authorized_keys がイメージに含まれていない"
else
  ng "authorized_keys がイメージに含まれていない" "見つかった: $baked_authkeys"
fi

# モデルの重みが焼かれていないこと
baked_models=$(docker run --rm --entrypoint sh "$IMAGE" -c 'find / -xdev \( -name "*.gguf" -o -name "*.safetensors" \) -print -quit 2>/dev/null || true' 2>/dev/null)
if [ -z "$baked_models" ]; then
  ok "モデルの重み (*.gguf / *.safetensors) がイメージに含まれていない"
else
  ng "モデルの重みがイメージに含まれていない" "見つかった: $baked_models"
fi

########################################
head_ "2. PUBLIC_KEY ありで起動したとき"
########################################
c_with=$(start_container with -e PUBLIC_KEY="$TEST_PUBLIC_KEY" -e RUNPOD_POD_ID=testpod0123 -e RUNPOD_DC_ID=TEST-DC-1 -e MY_CUSTOM_VAR=hello)
if [ -z "${c_with:-}" ] || ! wait_running "$c_with"; then
  ng "PUBLIC_KEY ありでコンテナが起動する" "$(docker logs "$PREFIX-with" 2>&1 | tail -5 | tr '\n' ' ')"
else
  ok "PUBLIC_KEY ありでコンテナが起動する"

  # authorized_keys に鍵が入る
  if cexec "$c_with" "grep -qF '$TEST_PUBLIC_KEY' /root/.ssh/authorized_keys" >/dev/null 2>&1; then
    ok "~/.ssh/authorized_keys に PUBLIC_KEY が展開される"
  else
    ng "~/.ssh/authorized_keys に PUBLIC_KEY が展開される" \
       "$(cexec "$c_with" 'cat /root/.ssh/authorized_keys 2>&1' | tail -3 | tr '\n' ' ')"
  fi

  # ~/.ssh のパーミッション
  mode=$(cexec "$c_with" 'stat -c %a /root/.ssh' 2>/dev/null | tr -d '\r\n')
  if [ "$mode" = "700" ]; then
    ok "~/.ssh のパーミッションが 700"
  else
    ng "~/.ssh のパーミッションが 700" "実際: ${mode:-なし}"
  fi

  # sshd が 22 番で listen している (ss や netstat に依存せず /proc を読む)
  listening=""
  for _ in $(seq 1 30); do
    if cexec "$c_with" 'cat /proc/net/tcp /proc/net/tcp6 2>/dev/null' 2>/dev/null \
        | awk '{print $2, $4}' | grep -qiE ':0016 0A$'; then
      listening=yes; break
    fi
    sleep 1
  done
  if [ -n "$listening" ]; then
    ok "sshd が 22 番で listen している"
  else
    ng "sshd が 22 番で listen している" "$(docker logs "$c_with" 2>&1 | tail -5 | tr '\n' ' ')"
  fi

  # /etc/rp_environment
  if cexec "$c_with" 'test -s /etc/rp_environment' >/dev/null 2>&1; then
    ok "/etc/rp_environment が生成される"
  else
    ng "/etc/rp_environment が生成される"
  fi

  if cexec "$c_with" 'grep -q PUBLIC_KEY /etc/rp_environment' >/dev/null 2>&1; then
    ng "/etc/rp_environment に PUBLIC_KEY が含まれない" \
       "$(cexec "$c_with" 'grep PUBLIC_KEY /etc/rp_environment' | tr '\n' ' ')"
  else
    ok "/etc/rp_environment に PUBLIC_KEY が含まれない"
  fi

  if cexec "$c_with" 'grep -q "^export RUNPOD_POD_ID=" /etc/rp_environment' >/dev/null 2>&1; then
    ok "/etc/rp_environment に RUNPOD_* が書き出される"
  else
    ng "/etc/rp_environment に RUNPOD_* が書き出される" \
       "$(cexec "$c_with" 'cat /etc/rp_environment' | tr '\n' ' ')"
  fi

  # RunPod のテンプレートでユーザーが自分で設定した任意の環境変数も見えること。
  # 上流は「大文字始まりの変数を全部書き出し PUBLIC_KEY だけ除外」なので、
  # RUNPOD_* だけの許可リストにするとここで落ちる。
  if cexec "$c_with" 'grep -q "^export MY_CUSTOM_VAR=" /etc/rp_environment' >/dev/null 2>&1; then
    ok "/etc/rp_environment に任意のユーザー環境変数が書き出される"
  else
    ng "/etc/rp_environment に任意のユーザー環境変数が書き出される" \
       "$(cexec "$c_with" 'cat /etc/rp_environment' | tr '\n' ' ')"
  fi

  if cexec "$c_with" 'grep -q "/etc/rp_environment" /root/.bashrc' >/dev/null 2>&1; then
    ok "~/.bashrc が /etc/rp_environment を source する"
  else
    ng "~/.bashrc が /etc/rp_environment を source する"
  fi

  # 起動時に生成されたホスト鍵
  if cexec "$c_with" 'ls /etc/ssh/ssh_host_*_key >/dev/null 2>&1' >/dev/null 2>&1; then
    ok "起動時にホスト鍵が生成される"
  else
    ng "起動時にホスト鍵が生成される"
  fi

  ########################################
  head_ "3. 同梱ソフトウェア"
  ########################################
  # CUDA ドライバ (libcuda.so.1) は GPU ホスト上では NVIDIA のコンテナランタイムが
  # 注入するもので、イメージには含まれない。GPU の無い環境で llama.cpp の依存関係を
  # 検査するために、ベースイメージ同梱の CUDA forward-compat 版で解決させる。
  # ここで見たいのは COPY 漏れ (libcurl / libgomp / libggml-*) の方。
  CUDA_STUB='LD_LIBRARY_PATH=/usr/local/cuda/compat:$LD_LIBRARY_PATH'

  check "llama-server --version が動く" cexec "$c_with" "$CUDA_STUB llama-server --version"
  check "llama-cli --version が動く"    cexec "$c_with" "$CUDA_STUB llama-cli --version"

  notfound=$(cexec "$c_with" "$CUDA_STUB ldd \"\$(command -v llama-server)\" 2>&1 | grep -c 'not found'" 2>/dev/null | tr -d '\r\n')
  if [ "$notfound" = "0" ]; then
    ok "ldd \$(which llama-server) に not found が無い"
  else
    ng "ldd \$(which llama-server) に not found が無い" \
       "$(cexec "$c_with" "$CUDA_STUB ldd \"\$(command -v llama-server)\" | grep 'not found'" | tr '\n' ' ')"
  fi

  check "python -c 'import torch' が動く" cexec "$c_with" 'python -c "import torch; print(torch.__version__)"'

  cuda_ok=$(cexec "$c_with" 'python -c "import torch; print(torch.version.cuda)"' 2>/dev/null | tr -d '\r\n')
  if [ -n "$cuda_ok" ] && [ "$cuda_ok" != "None" ]; then
    ok "PyTorch が CUDA ビルドである (torch.version.cuda=$cuda_ok)"
  else
    ng "PyTorch が CUDA ビルドである" "torch.version.cuda=${cuda_ok:-なし}"
  fi

  # hf_transfer は使われなくなり HF_HUB_ENABLE_HF_TRANSFER は deprecated。
  # 後継は Xet の HF_XET_HIGH_PERFORMANCE。
  if cexec "$c_with" 'test "$HF_XET_HIGH_PERFORMANCE" = 1' >/dev/null 2>&1; then
    ok "HF_XET_HIGH_PERFORMANCE=1 が設定されている"
  else
    ng "HF_XET_HIGH_PERFORMANCE=1 が設定されている" \
       "実際: $(cexec "$c_with" 'printenv HF_XET_HIGH_PERFORMANCE' 2>/dev/null | tr -d '\r\n')"
  fi

  if cexec "$c_with" 'test -z "$HF_HUB_ENABLE_HF_TRANSFER"' >/dev/null 2>&1; then
    ok "deprecated な HF_HUB_ENABLE_HF_TRANSFER が設定されていない"
  else
    ng "deprecated な HF_HUB_ENABLE_HF_TRANSFER が設定されていない"
  fi

  # ビルド時にだけ要る変数。イメージに残すと SSH セッションにも漏れて apt が
  # 常に非対話モードになる。
  if cexec "$c_with" 'test -z "$DEBIAN_FRONTEND"' >/dev/null 2>&1; then
    ok "ビルド時専用の DEBIAN_FRONTEND がイメージに残っていない"
  else
    ng "ビルド時専用の DEBIAN_FRONTEND がイメージに残っていない" \
       "実際: $(cexec "$c_with" 'printenv DEBIAN_FRONTEND' 2>/dev/null | tr -d '\r\n')"
  fi

  mode=$(cexec "$c_with" 'stat -c %a /etc/rp_environment' 2>/dev/null | tr -d '\r\n')
  if [ "$mode" = "600" ]; then
    ok "/etc/rp_environment のパーミッションが 600"
  else
    ng "/etc/rp_environment のパーミッションが 600" "実際: ${mode:-なし}"
  fi

  ########################################
  head_ "4. SSH セッションの環境"
  ########################################
  # RunPod での実運用は `ssh <pod> <command>` が中心になる。これは非対話・非ログイン
  # シェルで、しかも sshd は自分の環境を session に渡さないため、PATH は sshd の既定値
  # (/usr/local/bin:/usr/bin:...) になり /opt/llama.cpp/bin が入らない。
  # /etc/rp_environment を ~/.bashrc の末尾で source するだけだと、Ubuntu の .bashrc が
  # 冒頭の `[ -z "$PS1" ] && return` で抜けるのでこの経路では読まれない。
  # コンテナ内から自分自身へ SSH して、その経路を実際に通す。
  if cexec "$c_with" 'ssh-keygen -q -t ed25519 -f /tmp/testkey -N "" && cat /tmp/testkey.pub >> /root/.ssh/authorized_keys && chmod 600 /root/.ssh/authorized_keys' >/dev/null 2>&1; then
    ok "テスト用の鍵を authorized_keys に追加できる"
  else
    ng "テスト用の鍵を authorized_keys に追加できる"
  fi

  # ssh_exec <container> <remote command>   (remote command にシングルクォートは使わない)
  ssh_exec() {
    docker exec "$1" bash -c "ssh -q -i /tmp/testkey -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR -o BatchMode=yes root@127.0.0.1 '$2'" 2>&1
  }

  # 非対話・非ログインシェル: ssh <host> <command>
  out=$(ssh_exec "$c_with" 'command -v llama-server' | tr -d '\r\n')
  if [ "$out" = "/opt/llama.cpp/bin/llama-server" ]; then
    ok "ssh <host> <command> (非対話) から llama-server が引ける"
  else
    ng "ssh <host> <command> (非対話) から llama-server が引ける" "実際: ${out:-なし}"
  fi

  out=$(ssh_exec "$c_with" 'printenv MY_CUSTOM_VAR' | tr -d '\r\n')
  if [ "$out" = "hello" ]; then
    ok "ssh <host> <command> (非対話) からユーザー環境変数が見える"
  else
    ng "ssh <host> <command> (非対話) からユーザー環境変数が見える" "実際: ${out:-なし}"
  fi

  out=$(ssh_exec "$c_with" 'printenv RUNPOD_POD_ID' | tr -d '\r\n')
  if [ "$out" = "testpod0123" ]; then
    ok "ssh <host> <command> (非対話) から RUNPOD_* が見える"
  else
    ng "ssh <host> <command> (非対話) から RUNPOD_* が見える" "実際: ${out:-なし}"
  fi

  # ログインシェル: ssh <host> bash -lc "..."
  out=$(ssh_exec "$c_with" 'bash -lc "command -v llama-server"' | tr -d '\r\n')
  if [ "$out" = "/opt/llama.cpp/bin/llama-server" ]; then
    ok "ログインシェル (bash -lc) から llama-server が引ける"
  else
    ng "ログインシェル (bash -lc) から llama-server が引ける" "実際: ${out:-なし}"
  fi

  out=$(ssh_exec "$c_with" 'bash -lc "printenv MY_CUSTOM_VAR"' | tr -d '\r\n')
  if [ "$out" = "hello" ]; then
    ok "ログインシェル (bash -lc) からユーザー環境変数が見える"
  else
    ng "ログインシェル (bash -lc) からユーザー環境変数が見える" "実際: ${out:-なし}"
  fi

  # 何度 source されても PATH が二重に前置されないこと
  n=$(ssh_exec "$c_with" 'bash -lc "printenv PATH"' | tr ':' '\n' | grep -c '^/opt/llama.cpp/bin$')
  if [ "$n" = "1" ]; then
    ok "PATH に /opt/llama.cpp/bin が二重に入らない"
  else
    ng "PATH に /opt/llama.cpp/bin が二重に入らない" "出現回数: $n"
  fi

  # 起動スクリプトを再実行しても ~/.bashrc に重複追記されないこと
  cexec "$c_with" '/usr/local/bin/start.sh true' >/dev/null 2>&1
  n=$(cexec "$c_with" "grep -v '^[[:space:]]*#' /root/.bashrc | grep -c /etc/rp_environment" 2>/dev/null | tr -d '\r\n')
  if [ "$n" = "1" ]; then
    ok "起動スクリプトを再実行しても ~/.bashrc に重複追記されない"
  else
    ng "起動スクリプトを再実行しても ~/.bashrc に重複追記されない" "出現回数: ${n:-不明}"
  fi
fi

########################################
head_ "5. PUBLIC_KEY なしで起動したとき"
########################################
c_without=$(start_container without)
if [ -z "${c_without:-}" ] || ! wait_running "$c_without"; then
  ng "PUBLIC_KEY なしでもコンテナが起動する" "$(docker logs "$PREFIX-without" 2>&1 | tail -5 | tr '\n' ' ')"
else
  sleep 5
  if [ "$(docker inspect -f '{{.State.Running}}' "$c_without" 2>/dev/null)" = "true" ]; then
    ok "PUBLIC_KEY なしでもコンテナが起動し常駐する"
  else
    ng "PUBLIC_KEY なしでもコンテナが起動し常駐する" "$(docker logs "$c_without" 2>&1 | tail -5 | tr '\n' ' ')"
  fi

  if cexec "$c_without" 'test -e /root/.ssh/authorized_keys' >/dev/null 2>&1; then
    ng "PUBLIC_KEY なしのとき authorized_keys が作られない"
  else
    ok "PUBLIC_KEY なしのとき authorized_keys が作られない"
  fi

  if cexec "$c_without" 'test -s /etc/rp_environment' >/dev/null 2>&1; then
    ok "PUBLIC_KEY なしでも /etc/rp_environment が生成される"
  else
    ng "PUBLIC_KEY なしでも /etc/rp_environment が生成される"
  fi
fi

printf '\n\033[1m%d passed, %d failed\033[0m\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
