# syntax=docker/dockerfile:1

# RunPod で使うための CUDA イメージ。
#   builder : nvidia/cuda devel で llama.cpp を CUDA ビルド
#   runtime : nvidia/cuda runtime に成果物だけを COPY し、sshd と PyTorch を足す
# devel を最終イメージに残さないことでサイズを抑える。

ARG CUDA_VERSION=12.9.2
ARG UBUNTU_VERSION=24.04

########################################
# builder: llama.cpp を CUDA ビルドする
########################################
FROM nvidia/cuda:${CUDA_VERSION}-devel-ubuntu${UBUNTU_VERSION} AS builder

ARG LLAMA_CPP_REPO=https://github.com/ggml-org/llama.cpp.git
ARG LLAMA_CPP_REF=master
# Blackwell (sm_120) 専用。PTX の JIT フォールバックに頼らない。
ARG CUDA_ARCHITECTURES=120

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        build-essential \
        ca-certificates \
        cmake \
        git \
        libcurl4-openssl-dev \
        ninja-build \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# --depth 1 は使わない。shallow clone だと Gated DeltaNet 層が壊れる既知のバグを踏む。
#   https://github.com/ggml-org/llama.cpp/discussions/27164
RUN git clone "${LLAMA_CPP_REPO}" . \
    && git checkout "${LLAMA_CPP_REF}" \
    && git rev-parse HEAD > /tmp/llama-cpp-commit

# GGML_NATIVE=OFF: ビルドマシン (CI ランナー) の CPU 命令に依存させない。
# --allow-shlib-undefined: libggml-cuda.so が参照する CUDA ドライバ API
# (libcuda.so.1) は devel イメージに実体が無く、実行時に NVIDIA の
# コンテナランタイムが注入する。上流の .devops/cuda.Dockerfile と同じ対処。
RUN cmake -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_CUDA=ON \
        -DGGML_CUDA_GRAPHS=ON \
        -DGGML_NATIVE=OFF \
        -DCMAKE_CUDA_ARCHITECTURES="${CUDA_ARCHITECTURES}" \
        -DLLAMA_CURL=ON \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
        -DCMAKE_EXE_LINKER_FLAGS=-Wl,--allow-shlib-undefined \
    && cmake --build build --config Release -j"$(nproc)"

# 実行ファイルと共有ライブラリを分けて取り出す。runtime 側では
# /opt/llama.cpp/lib を ldconfig に登録して解決させる。
RUN mkdir -p /opt/llama.cpp/bin /opt/llama.cpp/lib \
    && find build -name '*.so*' -exec cp -P {} /opt/llama.cpp/lib/ \; \
    && find build/bin -maxdepth 1 -type f ! -name '*.so*' -exec cp {} /opt/llama.cpp/bin/ \; \
    && cp /tmp/llama-cpp-commit /opt/llama.cpp/COMMIT \
    && chmod -R a+rX /opt/llama.cpp

########################################
# runtime: RunPod に渡す最終イメージ
########################################
FROM nvidia/cuda:${CUDA_VERSION}-runtime-ubuntu${UBUNTU_VERSION} AS runtime

ARG TORCH_VERSION=2.9.1
# ベースの CUDA に合わせた PyTorch ホイールを使う (12.9 -> cu129)
ARG TORCH_CUDA_INDEX=cu129

LABEL org.opencontainers.image.source="https://github.com/yuanying/llama-cpp-runpod" \
      org.opencontainers.image.description="RunPod-ready CUDA image with sshd, PyTorch and a prebuilt llama.cpp (sm_120)" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        git \
        jq \
        less \
        libcurl4t64 \
        libgomp1 \
        openssh-server \
        python-is-python3 \
        python3 \
        python3-pip \
        rsync \
        tmux \
        vim-tiny \
        wget \
    && rm -rf /var/lib/apt/lists/* \
    # openssh-server の postinst が生成したホスト鍵をイメージに残さない。
    # public イメージなので焼くと全 Pod の秘密鍵が公開されることになる。
    && rm -f /etc/ssh/ssh_host_*_key /etc/ssh/ssh_host_*_key.pub

RUN mkdir -p /run/sshd /etc/ssh/sshd_config.d \
    && printf '%s\n' \
        'PermitRootLogin prohibit-password' \
        'PasswordAuthentication no' \
        'ClientAliveInterval 60' \
        'ClientAliveCountMax 10' \
        > /etc/ssh/sshd_config.d/10-runpod.conf

# PyTorch (CUDA ビルド) と、モデル取得に使う huggingface CLI
RUN pip install --no-cache-dir --break-system-packages \
        --index-url "https://download.pytorch.org/whl/${TORCH_CUDA_INDEX}" \
        "torch==${TORCH_VERSION}" \
    && pip install --no-cache-dir --break-system-packages \
        "huggingface_hub[cli,hf_transfer]"

COPY --from=builder /opt/llama.cpp /opt/llama.cpp
RUN echo /opt/llama.cpp/lib > /etc/ld.so.conf.d/llama-cpp.conf && ldconfig

COPY docker/start.sh /usr/local/bin/start.sh
RUN chmod +x /usr/local/bin/start.sh

ENV PATH=/opt/llama.cpp/bin:${PATH} \
    HF_HOME=/workspace/hf \
    HF_HUB_ENABLE_HF_TRANSFER=1

# RunPod の Network Volume のマウント先
WORKDIR /workspace

# ドキュメント目的。RunPod 側は Pod 作成時の ports 指定で公開する。
EXPOSE 22 8000

ENTRYPOINT ["/usr/local/bin/start.sh"]
CMD ["sleep", "infinity"]
