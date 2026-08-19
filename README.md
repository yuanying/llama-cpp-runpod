# llama-cpp-runpod

RunPod で使うための CUDA イメージ。sshd と **ビルド済みの llama.cpp**、PyTorch が入っている。

```
ghcr.io/yuanying/llama-cpp-runpod:latest
```

RunPod の Pod 作成時にこのイメージを指定するだけで、SSH で入れて `llama-server` が即使える。
Pod 内で CUDA toolkit を入れて llama.cpp をビルドする（15分前後）手間と、そのために
Network Volume を維持し続ける費用が要らなくなる。Network Volume はモデルの重み専用にできる。

## 前提

| 項目 | 内容 |
|---|---|
| GPU | **Blackwell (sm_120) 専用**。`-DCMAKE_CUDA_ARCHITECTURES=120` でビルドしてある |
| CUDA | 12.9（ベースイメージ `nvidia/cuda:12.9.2-runtime-ubuntu24.04`） |
| PyTorch | cu129 ホイール |
| プラットフォーム | linux/amd64 のみ |

sm_120 以外の GPU（Ada, Hopper, Ampere など）では llama.cpp の CUDA バックエンドが動かない。
PTX フォールバックも入れていないので、他世代で使うなら `CUDA_ARCHITECTURES` を変えて自分でビルドすること。

## 含まれるもの / 含まれないもの

**含まれるもの**

- `llama-server` / `llama-cli` / `llama-bench` など llama.cpp のビルド済みバイナリ（`/opt/llama.cpp/bin`、PATH 済み）
- PyTorch（CUDA ビルド）
- sshd、`git` / `curl` / `jq` / `tmux` / `rsync`、`python3` + `pip`
- `hf` CLI（`huggingface_hub[cli,hf_transfer]`）

**含まれないもの**

- **モデルの重み**（GGUF 等）— Network Volume に置く
- API キー・トークンの類 — Pod の環境変数で渡す（→[Hugging Face のトークンを渡す](#hugging-face-のトークンを渡す)）
- **SSH ホスト鍵** — Pod 起動のたびに生成する（後述）

## Pod を作る

RunPod API v2 の例。`ports` に `8000/http` と `22/tcp`、`startSsh: true`、Network Volume を
`/workspace` にマウントする。

```bash
export RP='https://api.runpod.io/v2'
rp() { curl -sS -H "Authorization: Bearer $RUNPOD_API_KEY" -H 'Content-Type: application/json' "$@"; }

rp -X POST "$RP/pods" -d "$(jq -n \
  --arg img 'ghcr.io/yuanying/llama-cpp-runpod:latest' \
  --arg gpu "$GPU_ID" --arg vol "$VOL" --arg dc "$DC" --arg hf "$HF_TOKEN" '
{
  name:  "llama",
  image: $img,
  cloud: "SECURE",
  dataCenterIds: [$dc],
  gpu:   { id: $gpu, count: 1 },
  disk:  40,
  ports: ["8000/http", "22/tcp"],
  startSsh: true,
  env:   { HF_TOKEN: $hf },
  mounts: { network: [ { volumeId: $vol, path: "/workspace" } ] }
}')" | jq
```

`env` はオブジェクト形式（`{"KEY": "value"}`）。gated / private なモデルを引くなら
ここで `HF_TOKEN` を渡す（→[Hugging Face のトークンを渡す](#hugging-face-のトークンを渡す)）。
不要なら `env` ごと省いてよい。

RunPod API v2 は ENTRYPOINT を上書きできないため、このイメージの ENTRYPOINT は
「`PUBLIC_KEY` を展開して sshd を上げ、あとは常駐するだけ」になっている。
`llama-server` は SSH で入ってから起動する。Pod 作成時に `args` を渡すと、
sshd を起動したあとにそのコマンドを exec する。

## SSH で入る

RunPod は SSH 公開鍵を `PUBLIC_KEY` 環境変数で渡してくるだけで、ファイルは書き込まない。
このイメージの起動スクリプトが `$PUBLIC_KEY` を `~/.ssh/authorized_keys` に展開し、
ホスト鍵を生成して sshd を起動する。

```bash
rp "$RP/pods/$POD" | jq -r '.ssh.direct // .ssh.proxy | "Host runpod-llama\n  HostName \(.host)\n  Port \(.port)\n  User \(.username)\n  IdentityFile ~/.ssh/runpod\n  StrictHostKeyChecking accept-new"' \
  >> ~/.ssh/config

ssh runpod-llama
```

**`StrictHostKeyChecking accept-new` が要る理由**: ホスト鍵をイメージに焼いていないため。
焼くと public イメージ経由で全 Pod の秘密鍵が公開されてしまうので、Pod ごとに生成している。
その結果 Pod を作り直すたびにホスト鍵が変わり、既定の設定だと
`REMOTE HOST IDENTIFICATION HAS CHANGED` で接続を拒否される。

SSH でログインすると `/etc/rp_environment` が `~/.bashrc` から読み込まれ、`RUNPOD_POD_ID` などの
RunPod が注入した環境変数が見えるようになっている（`PUBLIC_KEY` は除外してある）。

## llama-server を動かす

バイナリは `/opt/llama.cpp/bin/llama-server`（PATH に入っているのでフルパス不要）。

```bash
llama-server \
  -m /workspace/models/<model>.gguf \
  --host 0.0.0.0 --port 8000 \
  --api-key "$(openssl rand -hex 16)" \
  -ngl 999 -c 65536 --flash-attn on --jinja
```

**`--api-key` は必ず設定すること。** RunPod の HTTP プロキシ URL
（`https://<POD_ID>-8000.proxy.runpod.net`）も直接 TCP も **RunPod 側の認証が一切なく公開される**。
設定を忘れると LLM が誰でも叩ける状態になる。

外に出したくない場合は `ports` から 8000 を外し、SSH トンネルで手元に持ってくる。
HTTP プロキシは Cloudflare により接続が最大100秒で切れるので、長い非ストリーミング
リクエスト（ベンチマークなど）はトンネル経由のほうが確実。

```bash
ssh -f -N -L 8000:localhost:8000 runpod-llama
```

モデルの取得には `hf` CLI が入っている。GGUF リポジトリは全量子化で数百GBになるので
`--include` を必ず付ける。

```bash
hf download <repo> --include '*Q6_K*' --local-dir /workspace/models/<name>
```

## Hugging Face のトークンを渡す

gated / private なリポジトリを引くにはトークンが要る。**イメージには絶対に焼かないこと。**
このイメージは public なので、焼けばトークンがそのまま世界に公開される。

### 推奨: Pod 作成時の `env` で渡す

上の Pod 作成例の `env: { HF_TOKEN: $hf }` がそれ。Pod にだけ渡り、ディスクには残らない。

これが SSH ログイン後にも効くのは、起動スクリプトが**大文字始まりの環境変数をすべて**
`/etc/rp_environment`（`chmod 600`）に書き出し、`~/.bashrc` からそれを source するため
（`PUBLIC_KEY` だけは除外している）。`RUNPOD_*` に限らずユーザーが `env` で渡した変数も
そのまま見えるので、SSH で入って `hf download` を叩けば認証済みになる。

```bash
ssh runpod-llama
echo "${HF_TOKEN:0:8}..."      # /etc/rp_environment 経由で見える
hf download <repo> --include '*Q6_K*' --local-dir /workspace/models/<name>
```

**Pod に SSH できる人はこのトークンを読める。** `/etc/rp_environment` は root しか読めないが、
SSH で入るのは root なので実質的に筒抜けになる。read 権限のみの fine-grained トークンを使い、
用が済んだら失効させること。

### 代替: `hf auth login`

`HF_HOME=/workspace/hf` なので、一度ログインすればトークンは Network Volume 側に残り、
次回以降の Pod でも効く。

```bash
hf auth login          # 対話でトークンを貼る
```

ただし **トークンは Volume に平文で残る**（`$HF_HOME/token`）。Volume を消し忘れれば残り続け、
その Volume をマウントした別の Pod からも読める。加えて Network Volume はデータセンターに
固定されるので、別 DC で Pod を立てると結局トークンを渡し直すことになる。

**`env` の方を勧める。** Pod の寿命と一致して後片付けが要らず、Volume に秘密が残らないため。
毎回同じトークンを打ち直す手間が惜しい場合だけ `hf auth login` を使う。

## RunPod 公式イメージとの違い

起動スクリプトの挙動は RunPod 公式の
[start.sh](https://github.com/runpod/containers/blob/main/container-template/start.sh)
に合わせてあるが、以下は意図的に変えてある。

- **nginx / JupyterLab を起動しない** — SSH で入って llama.cpp を動かすためのイメージなので不要
- **DSA のホスト鍵を生成しない** — DSA は OpenSSH 9.8 で削除されており、Ubuntu 24.04 の
  `ssh-keygen -t dsa` は失敗する。rsa / ecdsa / ed25519 は生成する
- **`/etc/rp_environment` を chmod 600 にしている** — 上流と同じく大文字始まりの環境変数を
  すべて書き出す（`PUBLIC_KEY` のみ除外）ので、`RUNPOD_API_KEY` のような秘密が入りうるため

また、CUDA ドライバ（`libcuda.so.1`）はイメージに含まれない。GPU ホスト上では NVIDIA の
コンテナランタイムが注入する。このため GPU の無い環境で `llama-server` を実行すると
`libcuda.so.1` が見つからず起動しない（テストではベースイメージ同梱の CUDA forward-compat
版を `LD_LIBRARY_PATH` で見せて依存関係だけを検査している）。

## 開発

### ビルド

```bash
docker build -t llama-cpp-runpod:test .
```

主な build-arg: `CUDA_VERSION` / `UBUNTU_VERSION` / `CUDA_ARCHITECTURES` / `LLAMA_CPP_REF` /
`TORCH_VERSION` / `TORCH_CUDA_INDEX`。llama.cpp は既定で `master` を**非 shallow** で
クローンしてビルドする（`--depth 1` は
[Gated DeltaNet 層が壊れる既知のバグ](https://github.com/ggml-org/llama.cpp/discussions/27164)
を踏むため使わない）。

### テスト

GPU 不要。`docker run -d` + `docker exec` だけで検査するので、docker デーモンがリモートでも動く。

```bash
IMAGE=llama-cpp-runpod:test ./test/test-image.sh
```

確認している内容: `PUBLIC_KEY` の展開、sshd が 22 で listen すること、`PUBLIC_KEY` 無しでも
起動すること、`llama-server --version` と共有ライブラリの解決、PyTorch の import、
`/etc/rp_environment` の生成と `PUBLIC_KEY` の非混入、ホスト鍵・authorized_keys・モデルの重みが
イメージに焼かれていないこと。

### CI と公開

`.github/workflows/build.yml` が push ごとにビルド → テスト → `ghcr.io` へ push する。

タグの付き方:

| 契機 | 付くタグ |
|---|---|
| デフォルトブランチ（`main`）への push | `latest`、`main`、`sha-xxxxxxx` |
| それ以外のブランチへの push | `<ブランチ名>`、`sha-xxxxxxx` |

**`latest` が付くのは `main` への push だけ。** 作業ブランチから push した時点では
`ghcr.io/yuanying/llama-cpp-runpod:latest` は 404 のままで、ブランチ名と短縮 SHA の
タグだけが存在する。

トリガは push（全ブランチ）と `workflow_dispatch` のみで、**`pull_request` では走らない**。
同じコミットのビルドが 2 本走るのを避けるためで（CUDA ビルドは 1 本 40分弱かかる）、
PR のチェックとしてはブランチへの push の run がそのまま表示される。fork からの PR を
受けるようになったら `pull_request` を足す必要がある。

### パッケージの visibility

**public リポジトリから `GITHUB_TOKEN` で push した場合、パッケージも public で作られた**
（2026-08 時点で実測）。手作業は要らなかった。

念のため初回 push 後に確認しておくとよい。private のままだと GitHub Free の無料枠
（500MB ストレージ / 1GB 転送・月）を数GBのイメージが即超えて課金対象になる。

```bash
gh api /user/packages/container/llama-cpp-runpod --jq '{visibility, repository: .repository.full_name}'
```

匿名で pull できるかは docker も認証も無しで確認できる。

```bash
TOKEN=$(curl -s "https://ghcr.io/token?scope=repository:yuanying/llama-cpp-runpod:pull&service=ghcr.io" | jq -r .token)
curl -s -o /dev/null -w '%{http_code}\n' -H "Authorization: Bearer $TOKEN" \
  -H 'Accept: application/vnd.oci.image.index.v1+json,application/vnd.docker.distribution.manifest.list.v2+json' \
  https://ghcr.io/v2/yuanying/llama-cpp-runpod/manifests/latest
```

200 なら public。private なら 401/403 が返る（タグ自体が無い場合も 404 になるので、
`latest` が未作成のうちはブランチ名のタグで確かめる）。

もし private で作られていたら、**Web UI でしか直せない**。REST API には visibility を
変更するエンドポイントが無く、`PATCH /user/packages/container/<pkg>` の類はすべて 404 を返す
（`write:packages` スコープがあっても同じ）。
<https://github.com/users/yuanying/packages/container/llama-cpp-runpod/settings> の
"Change visibility" から Public にする。
