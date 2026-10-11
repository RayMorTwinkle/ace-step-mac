#!/bin/bash
# ============================================================
# ACE-Step 1.5 一键安装 + 运行脚本（macOS Apple Silicon）
#
# 用法：
#   ./ace-step.sh              # 装依赖 → 编译 → 下模型 → 开 WebUI
#   ./ace-step.sh --cli        # 命令行直接生成一首歌（不开服务器）
#
# 可选环境变量（都有默认值，直接跑就行）：
#   LM=0.6B        LM 规划器大小：0.6B(最快) / 1.7B / 4B(质量最好)
#   DIT=turbo      DiT 变体：turbo(8步,快) / sft(50步,质量略高)
#   QUANT=Q8_0     量化：Q4_K_M(最小) / Q5_K_M / Q6_K / Q8_0(推荐) / BF16
#   BACKEND=auto   后端：auto / metal / blas / cpu
#   PORT=8085      WebUI 端口
#   DURATION=60    --cli 模式生成秒数
#   CAPTION="..."  --cli 模式曲风描述（英文效果更好）
# ============================================================

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
REPO="$ROOT/acestep.cpp"

LM="${LM:-0.6B}"
DIT="${DIT:-turbo}"
QUANT="${QUANT:-Q8_0}"
BACKEND="${BACKEND:-auto}"
PORT="${PORT:-8085}"
DURATION="${DURATION:-60}"
CAPTION="${CAPTION:-Upbeat electronic dance music with energetic synthesizers, punchy four-on-the-floor drums, catchy female vocal hooks}"
CLI=0
[ "${1:-}" = "--cli" ] && CLI=1

info() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[1;33m[!]\033[0m %s\n' "$*"; }

# ---------- 1. 依赖 ----------
if ! xcode-select -p >/dev/null 2>&1; then
    info "安装 Xcode Command Line Tools（弹窗里点 Install）"
    xcode-select --install || true
    warn "装完 CLT 后重新运行本脚本"; exit 1
fi

if ! command -v cmake >/dev/null 2>&1; then
    if command -v brew >/dev/null 2>&1; then
        info "安装 cmake"; brew install cmake
    else
        warn "没有 cmake 也没有 brew。请先装 Homebrew: https://brew.sh"; exit 1
    fi
fi

PYBIN="$(command -v python3)"
export PATH="$HOME/Library/Python/3.9/bin:$HOME/Library/Python/3.*/bin:$PATH"
if ! command -v hf >/dev/null 2>&1; then
    info "安装 huggingface_hub (hf CLI)"
    "$PYBIN" -m pip install --user huggingface_hub
fi
# BF16→F32 转换工具依赖 numpy（只有无 bf16 的机器才用到，装一下也无妨）
"$PYBIN" -c "import numpy" 2>/dev/null || "$PYBIN" -m pip install --user numpy

# ---------- 2. 拉代码 ----------
if [ ! -d "$REPO/.git" ]; then
    info "克隆 acestep.cpp"
    git clone --recurse-submodules https://github.com/ServeurpersoCom/acestep.cpp.git "$REPO"
else
    info "acestep.cpp 已存在，跳过克隆"
fi
cd "$REPO"

# ---------- 3. 编译 ----------
if [ ! -x build/ace-server ]; then
    info "编译（macOS 自动启用 Metal GPU + Accelerate BLAS）"
    ./buildcpu.sh
else
    info "已有编译产物，跳过"
fi

# ---------- 4. 下载模型 ----------
info "下载模型：DiT=$DIT-$QUANT, LM=$LM, Embedding+VAE"
EXTRA=""
[ "$DIT" = "sft" ] && EXTRA="--sft"
./models.sh --quant "$QUANT" --lm "$LM" $EXTRA

# ---------- 5. 选后端 ----------
# Devin/UTM 等虚拟机的 Apple Paravirtual GPU 没有 simdgroup 矩阵单元和 bf16：
#   - BF16 张量的 GGUF 在 Metal 上直接崩（scheduler abort）
#   - 即使转了 F32，Metal 也比 CPU 慢
# 真机 M1 及以上一律走 Metal，不用管。
MODELDIR="models"
IS_VM=0
if sysctl -n machdep.cpu.brand_string 2>/dev/null | grep -qi "virtual"; then
    IS_VM=1
fi
if system_profiler SPDisplaysDataType 2>/dev/null | grep -qi "paravirtual"; then
    IS_VM=1
fi

if [ "$BACKEND" = "auto" ]; then
    if [ "$IS_VM" = "1" ]; then
        BACKEND="blas"
        warn "检测到虚拟化 GPU → 用 Accelerate CPU（这台机器上比 Metal 更快）"
    else
        BACKEND="metal"
        info "真机 GPU → Metal"
    fi
fi

# 只有「无 bf16 的设备 + 强制 Metal」才需要把 BF16 张量转 F32；
# BLAS/CPU 不挑张量类型，自动路径下不用转。
NEED_F32=0
if [ "$IS_VM" = "1" ] && [ "$BACKEND" = "metal" ]; then
    NEED_F32=1
fi
if [ "$NEED_F32" = "1" ]; then
    info "转换 BF16 张量 → F32（无损，VM 必需）"
    mkdir -p models-f32
    for f in models/*.gguf; do
        b="$(basename "$f")"
        [ -f "models-f32/$b" ] && continue
        if python3 "$ROOT/tools/bf16_to_f32.py" --check "$f"; then
            python3 "$ROOT/tools/bf16_to_f32.py" "$f" "models-f32/$b"
        else
            cp "$f" "models-f32/$b"
        fi
    done
    MODELDIR="models-f32"
fi

export GGML_BACKEND="$BACKEND"
info "后端: $BACKEND  模型目录: $MODELDIR"

# ---------- 6. 运行 ----------
if [ "$CLI" = "1" ]; then
    cat > /tmp/ace-req.json <<EOF
{
    "lm_model": "acestep-5Hz-lm-${LM}-${QUANT}.gguf",
    "synth_model": "acestep-v15-${DIT}-${QUANT}.gguf",
    "caption": "$CAPTION",
    "vocal_language": "en",
    "duration": $DURATION,
    "inference_steps": $([ "$DIT" = "turbo" ] && echo 8 || echo 50),
    "guidance_scale": 1.0,
    "shift": 3.0
}
EOF
    info "LM 生成歌词+音频码..."
    ./build/ace-lm --models "$MODELDIR" --request /tmp/ace-req.json
    REQ_OUT="$(ls -t /tmp/ace-req*.json | grep -v 'ace-req.json' | head -1)"
    info "DiT+VAE 合成音频..."
    ./build/ace-synth --models "$MODELDIR" --request "$REQ_OUT"
    info "完成，输出文件："
    ls -t /tmp/ace-req*.mp3 /tmp/ace-req*.wav 2>/dev/null | head -3 || true
else
    info "启动 WebUI → http://localhost:$PORT"
    exec ./build/ace-server --models "$MODELDIR" --adapters ./adapters \
        --host 0.0.0.0 --port "$PORT" --keep-loaded
fi
