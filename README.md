# ace-step-mac

在 Mac（Apple Silicon）上一键跑 [ACE-Step 1.5](https://github.com/ace-step/ACE-Step-1.5) 本地音乐生成。

底层用的是社区 C++ 实现 [acestep.cpp](https://github.com/ServeurpersoCom/acestep.cpp)（GGUF/GGML，Metal GPU + Accelerate BLAS），比官方 Python 版更轻更快。

## 一键运行

```bash
git clone https://github.com/RayMorTwinkle/ace-step-mac.git
cd ace-step-mac
./ace-step.sh            # 自动装依赖 → 编译 → 下模型 → 开 WebUI
```

然后打开 http://localhost:8085 ，写描述 → 生成 → 播放/下载。

> **后端选择是自动的**：真机 Mac → Metal GPU；Mac 虚拟机（Devin/UTM/Parallels 的 Apple Paravirtual GPU）→ CPU (Accelerate BLAS)。虚拟机的 Metal 反而比 CPU 慢且会因 BF16 张量崩溃，脚本已自动处理。也可以手动 `BACKEND=blas` 或 `BACKEND=metal` 覆盖。

命令行直出一首歌（不开服务器）：

```bash
./ace-step.sh --cli
```

## 可调参数（环境变量）

```bash
LM=1.7B DIT=sft ./ace-step.sh        # 更大 LM + 高质量 DiT
QUANT=Q4_K_M ./ace-step.sh           # 最小模型文件
DURATION=120 CAPTION="sad lo-fi piano ballad" ./ace-step.sh --cli
BACKEND=blas ./ace-step.sh           # 强制 CPU/Accelerate
```

| 变量 | 可选值 | 默认 | 说明 |
|---|---|---|---|
| `LM` | `0.6B` / `1.7B` / `4B` | `0.6B` | 歌词+结构规划器，越大写得越好也越慢 |
| `DIT` | `turbo` / `sft` | `turbo` | DiT 扩散模型：turbo=8步(快) / sft=50步(质量略高) |
| `QUANT` | `Q4_K_M`/`Q5_K_M`/`Q6_K`/`Q8_0`/`BF16` | `Q8_0` | 量化级别，CPU 上 Q8_0 反而比 Q4_K_M 快 |
| `BACKEND` | `auto`/`metal`/`blas`/`cpu` | `auto` | 自动检测：真机→Metal，虚拟机→BLAS |

**注意 turbo/sft 和 0.6B/4B 是两个不同维度**：前者是 DiT 变体（生成步数），后者是 LM 大小（规划质量）。推荐组合：turbo + 0.6B（速度优先）/ turbo + 1.7B（平衡）。

## 实测速度（M4 Pro 虚拟机 16GB，CPU/Accelerate）

| 阶段 | 时间 |
|---|---|
| LM 0.6B（歌词+音频码，30s 歌） | ~3s（90-155 tok/s） |
| DiT turbo 8步（88s 音频） | ~23s |
| VAE 解码（88s 音频） | ~45s |
| **整首 88s 歌端到端** | **~80s ≈ 实时** |

真机 Metal GPU 上 DiT 比这台 VM 快约 3 倍（官方 CI：88s 音频 DiT 仅 7.1s）。

## 已经踩过的坑

- **虚拟机 / 无 bf16 的旧 GPU**：GGUF 里的 BF16 张量会让 Metal 直接崩（scheduler abort）。脚本自动检测虚拟 GPU，用 `tools/bf16_to_f32.py` 把 BF16 张量无损转 F32 存到 `models-f32/`，并切到 BLAS 后端。
- **VM 上 Metal 比 CPU 慢**：Apple Paravirtual GPU 没有 simdgroup 矩阵单元，别强行开。
- **内存**：Q8_0 全家桶（0.6B LM + turbo + VAE）约 4GB 权重，16GB 够用；换 4B LM + XL DiT 需要 20GB+。

## 其他方案（备选）

| 方案 | 适合 |
|---|---|
| [官方 ACE-Step-1.5](https://github.com/ace-step/ACE-Step-1.5) `uv run acestep`（MLX/MPS） | 要完整功能：LoRA 训练、cover、repaint |
| [mlx-community/ACE-Step1.5-MLX](https://huggingface.co/mlx-community/ACE-Step1.5-MLX) + `mlx-audio` | 嵌进自己 Python 代码，几行调用 |

## 文件

```
ace-step.sh            一键脚本
tools/bf16_to_f32.py   GGUF BF16→F32 张量转换器（无 bf16 GPU 用）
acestep.cpp/           首次运行时自动 clone（gitignored）
```
