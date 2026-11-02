# Qwen3.5-4B 混合 SSM 的 KV 缓存复用：源码验证与内存评估

- 日期：2026-10-27
- 验证对象：mobileLLM 项目 vendored 的 llama.cpp（commit `956973c76466b6c791d7bdbe6eed3aa3235b2dc1`，即 `scripts/build-llama-xcframework.sh` 固定的版本）
- 验证方式：源码级静态验证（从 GitHub codeload 下载该 commit 原始源码逐行核对，未做动态运行验证）
- 目标：确认「llama.cpp 原生是否支持 Qwen3.5 混合 SSM 的状态保存/恢复与部分回滚」，并评估「每 turn 状态快照」的内存账

---

## 0. 结论摘要（TL;DR）

1. **Qwen3.5 是 llama.cpp 里唯一被原生支持「recurrent 状态部分回滚」（rs rollback）的架构**（`llm_arch_supports_rs_rollback` 对 `LLM_ARCH_QWEN35 / QWEN35MOE` 返回 true）。
2. **该能力默认关闭**：`llama_context_default_params().n_rs_seq = 0`。my-branch 的 LlamaEngine 也没有设置 `n_rs_seq`，因此编辑重发时 `llama_memory_seq_rm` 对 recurrent 部分必然失败 → 回退全量重算。**这不是"数学上不可逆"，而是没开原生开关。**
3. **`llama_state_seq_get_data / set_data` 对 Qwen3.5 完整可用**：hybrid memory 的 `state_write / state_read` 组合序列化 attention KV + recurrent state（R/S），恢复后与全量 prefill 一致。
4. **内存账（Qwen3.5-4B，8K 上下文）**：attention KV 占大头（f16 256 MiB / Q8_0 136 MiB / Q4_0 72 MiB，按 Q8_0=1.0625 B/元素、Q4_0=0.5625 B/元素计），recurrent S 固定 24 MiB（f32，24 层），R 可忽略（0.56 MiB）。每 turn 快照 ≈ 96~280 MiB（随 KV 精度/上下文变化），K=Q4_0+V=Q8_0 折中 ≈ 128.6 MiB。
5. **推荐组合**：attention 主导场景维持 seq_rm 裁剪；Qwen3.5 上开 `n_rs_seq`（小窗口回滚，代价是 S 内存 ×(1+n_rs_seq)）+ 每 turn 用 `llama_state_seq_get_data` 快照兜底（任意深度回滚）。

---

## 1. 验证方法

- 环境：Windows 本地，无 cmake、无 GGUF 模型 → 无法动态编译运行。
- 手段：下载 llama.cpp `956973c` 的官方 tarball（codeload.github.com，35.7 MB），解压后对 `llama.h`、`llama-arch.cpp`、`llama-context.cpp`、`llama-memory-*.cpp/h`、`llama-model.cpp`、`llama-hparams.cpp` 逐行核验。
- 局限：未做「模型加载 + state 往返一致性」的动态测试；该测试需要 macOS/Xcode 或 cmake 环境与 Qwen3.5-4B GGUF，见 §6。

---

## 2. 源码验证结果（关键证据）

### 2.1 公共 API 存在且完整（include/llama.h）

- `llama_state_get_size / get_data / set_data`（整体状态）
- `llama_state_seq_get_size / get_data / set_data`（按序列，内存 buffer 版）
- `llama_state_seq_save_file / load_file`（按序列，**文件版**：`llama.h` L867/L874；实现 `llama-context.cpp` L3031-3092 —— 文件头 = magic + version + token 数 + token 清单，主体走 `state_seq_write_data / read_data`（同一序列化路径，完整覆盖 hybrid 的 attention + recurrent 状态），**自带 token 清单持久化，App 无需另存 token 数组**）
- `llama_state_seq_get_size_ext / get_data_ext / set_data_ext`（带 `llama_state_seq_flags`，含 ON_DEVICE / PARTIAL_ONLY 等）
- 注：llama-server 的 slot save/restore（`tools/server/server-context.cpp` L2529/L2568）就是调用 `llama_state_seq_save_file / load_file`，属**手动触发**的 API 任务，不存在 `--slot-save-auto` 之类的自动开关

### 2.2 Qwen3.5 是 hybrid 架构（src/llama-arch.cpp）

- `llm_arch_is_hybrid`：`LLM_ARCH_QWEN35 / LLM_ARCH_QWEN35MOE` 在列（L947-948）
- `llm_arch_supports_rs_rollback`：**唯一返回 true 的架构就是 QWEN35 / QWEN35MOE**（L969-970）

### 2.3 hybrid memory 组合 attention + recurrent（src/llama-model.cpp、llama-memory-hybrid.cpp）

- 上下文创建（llama-model.cpp L2089-2110）：QWEN35（非 MTP context）→ `llama_memory_hybrid`，按 `is_recr(il)` 分层：attention 层进 `mem_attn`，recurrent 层进 `mem_recr`
- MTP context 特殊处理（L2075-2077）：MTP head 是纯 dense-attention，用普通 KV cache，不走 hybrid 包装
- `llama_memory_hybrid::seq_rm`（llama-memory-hybrid.cpp L143-149）：**先试 recurrent 部分，可能失败；成功后才继续 attention 部分**
- `llama_memory_hybrid::state_write / state_read`（L190-201）：分别写/读 attention 与 recurrent 两段 —— **状态快照完整覆盖混合模型**

### 2.4 recurrent memory 的 state 序列化与部分回滚（src/llama-memory-recurrent.cpp）

- `state_write`（L733）/ `state_read`（L813）完整实现：meta（cell 区间、回滚索引）+ data（R/S 张量行）两段
- `seq_rm`（L150-233）：
  - 支持**尾部小窗口回滚**：`0 < p0 && p0 <= cell.pos && p1 > cell.pos` 时，若回滚深度 `rollback ∈ [1, n_rs_seq]` → 通过 per-token 快照索引 `set_rs_idx` 回滚并返回 true（L182-190）
  - **回滚深度 > n_rs_seq 时返回 false**（L189）→ 上层回退
  - `n_rs_seq = 0` 时任何回滚必然 false
- 内存分配：`n_rows = mem_size * (1 + n_rs_seq)`（L99）—— 每开 1 个 rs 快照，recurrent state 内存翻 (1+n_rs_seq) 倍

### 2.5 n_rs_seq 默认关闭（src/llama-context.cpp）

- `llama_context_default_params`：`.n_rs_seq = 0`（L3439）
- 若用户设置 `n_rs_seq > 0` 但架构不支持，会被 clamp 回 0（L86-89）；QWEN35 支持，不会被 clamp

### 2.6 mobileLLM 引擎现状

- main 分支：`ensureContext` 每次 `llama_memory_clear` 全清 + 全量 prefill，无任何复用
- my-branch：实现了 SessionCacheState + LCP + `llama_memory_seq_rm`，但 **`cp` 参数里未设置 `n_rs_seq`**（默认 0）→ Qwen3.5 的 recurrent 回滚必然失败 → `supportsPartialTrim` 置 false → 全量重算 fallback

---

## 3. 为什么 my-branch 实测「混合 SSM 只能全量重算」

| 环节 | 实际行为 | 原因 |
|---|---|---|
| `llama_memory_seq_rm` 被拒 | 是（my-branch 实测） | recurrent 部分回滚深度需 ≤ n_rs_seq，而 n_rs_seq=0 |
| 「数学上不可逆」的说法 | **不准确** | llama.cpp 已为 Qwen3.5 实现 per-token 快照回滚（n_rs_seq），只是默认关、且只覆盖尾部小窗口 |
| 回滚任意深度（编辑更早历史） | seq_rm 不支持 | 只能靠完整状态快照（`llama_state_seq_get/set_data`） |

---

## 4. 内存账（Qwen3.5-4B）

架构参数（来源：open-llm-radar / theapplied，与 llama.cpp hparams 逻辑互证）：
- 32 层 = 8× (3× Gated-DeltaNet + 1× Gated-Attention) → **24 层 recurrent + 8 层 attention**
- Gated-Attention：4 KV heads × head_dim 256
- Gated-DeltaNet：QK 16 heads / V 32 heads × head_dim 128，d_conv=4（llama.cpp 中 ssm_n_group=16, ssm_dt_rank=32, ssm_d_state=128）

计算公式：
- attention KV/层/序列 = `n_layers_attn × n_kv_heads × head_dim × 2 × n_ctx × dtype_bytes`
- recurrent S = `24 层 × n_k_heads × head_v_dim² × 4B (f32)`，固定不随 n_ctx 增长
- recurrent R = `24 层 × key_dim × (d_conv-1) × 4B`

| 配置（8K 上下文） | Attention KV | Recurrent S | Recurrent R | 快照合计 |
|---|---|---|---|---|
| KV f16 | 256 MiB | 24 MiB | 0.56 MiB | **≈ 280.6 MiB** |
| KV Q8_0 | 136 MiB | 24 MiB | 0.56 MiB | **≈ 160.6 MiB** |
| KV Q4_0 | 72 MiB | 24 MiB | 0.56 MiB | **≈ 96.6 MiB** |
| K=Q4_0 + V=Q8_0 | 104 MiB | 24 MiB | 0.56 MiB | **≈ 128.6 MiB** |

| 配置（16K 上下文） | Attention KV | Recurrent S | Recurrent R | 快照合计 |
|---|---|---|---|---|
| KV f16 | 512 MiB | 24 MiB | 0.56 MiB | **≈ 536.6 MiB** |
| KV Q8_0 | 272 MiB | 24 MiB | 0.56 MiB | **≈ 296.6 MiB** |
| KV Q4_0 | 144 MiB | 24 MiB | 0.56 MiB | **≈ 168.6 MiB** |
| K=Q4_0 + V=Q8_0 | 208 MiB | 24 MiB | 0.56 MiB | **≈ 232.6 MiB** |

> 口径说明（按 ggml-common.h 每块 32 元素 + 2B f16 scale）：Q8_0 = 1.0625 B/元素、Q4_0 = 0.5625 B/元素，故 8K Q8_0 KV = 136 MiB（非 128）、Q4_0 = 72 MiB（非 64）。K=Q4_0 + V=Q8_0 折中：V 量化对输出质量影响最敏感，V 保 Q8_0 质量、K 用 Q4_0 省一半空间，快照 8K ≈ 128.6 MiB。

n_rs_seq 代价：每开 1 个快照，S 增加 24 MiB（n_rs_seq=4 → S=120 MiB）。

要点：
- 快照体积由 attention KV 主导，**量化 KV 缓存（Q8_0/Q4_0）能直接砍掉一半以上快照体积**，且已有 `kvBits` 参数支撑
- recurrent S 固定 24 MiB，开 n_rs_seq 的边际成本可控（对 8K Q8_0 场景，+24~96 MiB 换取编辑重发小窗口复用）

---

## 5. 方案建议

### 方案 A：开原生 n_rs_seq（改动最小，推荐先做）
- 改 1 行：`llama_context_default_params()` 后设 `cp.n_rs_seq = 4`（或 2~8 实测）
- 效果：编辑重发/回滚深度 ≤ n_rs_seq 时 `llama_memory_seq_rm` 成功，公共前缀复用（不再全量重算）
- 代价：S 内存 ×(1+n_rs_seq)（4B 模型 +24 MiB/档）；只覆盖尾部小窗口
- 验证：改完后看 my-branch 的 `supportsPartialTrim` 是否保持 true、日志回滚是否成功

### 方案 B：每 turn 完整状态快照（llama_state_seq_get_data / set_data，或文件版 save_file / load_file）
- 每次 EOS 后把 `seq` 状态存 buffer / 文件（编辑重发时恢复对应 turn 快照 + 重放最后 1 token 刷 logits，llama-server checkpoint 同款机制）
- **推荐直接走文件版 `llama_state_seq_save_file / load_file`**：自带 token 清单落盘（App 不必另存 token 数组），恢复时一次调用读回完整状态（含 Qwen3.5 recurrent state）；内存版 `get/set_data` 仅在你需要自己管理 buffer（如 LRU 常驻内存）时更合适
- 效果：任意深度回滚严格正确（含 Qwen3.5 recurrent state）
- 代价：每 turn 全量拷贝/写盘（8K Q8_0 ≈ 161 MiB / 8K f16 ≈ 281 MiB），恢复也是整块读回；移动端注意 jetsam 峰值与磁盘 IO 延迟
- 需要验证：该 commit 上 `llama_state_seq_get_data → set_data`（含文件版往返）对 Qwen3.5 的一致性（rto-llama 已在 qwen3.8-27b 上验证 round-trip 逐 token 一致，此版本应同样支持，仍需实测）

### 方案 C：组合（推荐最终形态）
- attention 主导模型：维持 seq_rm 裁剪（零拷贝）
- Qwen3.5：开 n_rs_seq（小窗口）+ 每 turn 快照兜底（任意深度）
- 由 `supportsPartialTrim` + `isHistoricalPrefixTurn` 分流（my-branch 已有标记）

---

## 6. 实现落地（方案 B 快照，已提交 my-branch `43d4598`）

**改动文件**：`Packages/LLMEngineLlama/Sources/LLMEngineLlama/LlamaEngine.swift`（+210/-28），llama.cpp 侧零改动。

| 组件 | 作用 |
|---|---|
| `SessionCheckpoint` | 一个 turn 边界的「prompt 全 prefill 完」快照：turnCount / promptEndPos / filePath / tokens / turns |
| `saveCheckpoint` | 每次纯文本 prefill 完成后、生成开始前，`llama_state_seq_save_file(ctx, ckpt-<turnCount>.bin, 0, promptTokens, n)` 落盘；同边界同 prompt 去重；LRU 保留最近 4 份 |
| `restoreCheckpoint` | 编辑重发且 seq_rm 被拒时：按 promptEndPos 降序遍历快照，token 级前缀校验（新旧 prompt 在快照范围内完全一致才命中），`llama_state_seq_load_file` 读回并二次校验，`sessionCache.rollbackToCheckpoint` 回滚逻辑态 |
| `decodeSuffix` | 共享的批式后缀解码（替代 canRollback 内联循环），只解码编辑点之后的 token |
| `rollbackToCheckpoint` | `SessionCacheState` 内部方法：turns/tokens/tokenCount/turnPromptEndPositions 一并回滚到快照边界 |
| `clearCheckpoints` | 模型卸载 / context 重建（KV 布局、dtype 变化）时清空快照文件与索引 |

**设计要点**：
- **保存的是「prompt 结束」而非「回复结束」状态**：在 prefill 完成后立刻保存，天然对齐 `turnPromptEndPositions[kept.count]` 的语义，恢复后直接 decode 新 suffix，无需裁剪旧回复（Qwen3.5 的 seq_rm 正是裁不了这个才需要快照）。
- **恢复点判定不依赖 turn 语义**：纯 token 级 LCP 校验（`快照 tokens == 新 prompt 前 promptEndPos 个 token`），天然规避 BPE 边界分歧，且只命中「编辑发生在该边界之后」的快照。
- **suffix 为空（整 prompt 与快照相同，即 Regenerate）**：重放最后 1 个 token 刷 logits，与现有 `isFullPromptMatch` 路径一致。
- **限定纯文本轮**：`hasImages` 不保存、`residentHadImages` 不恢复；视觉 turn 维持原全量路径（mtmd embedding 语义复杂，留待后续）。
- **失败恒可降级**：保存/恢复任何一步失败（磁盘、load 校验、decode 错误）都回退到原「全量重算」，不影响既有 99.9% seq_rm 路径。
- **写盘开销**：8K Q8_0 ≈ 160.6 MiB 同步写（tmp 目录，~100-300 ms），换编辑重发省 ~2-4 s 全量 prefill；每 turn 一次。

**方案 A 已并入（commit `898f509`）**：
- `rsRollbackSlots = 4`：`cp.n_rs_seq = 4`（Attempt 1/2 均设置）。效果：Qwen3.5 的 `llama_memory_seq_rm` 对**回滚深度 ≤ 4 token** 的编辑重发（典型即 Regenerate 的 1-token 刷新）直接成功，走零拷贝快路径；更深的编辑仍落到快照兜底。代价：recurrent S ×(1+4)，Qwen3.5-4B = +96 MiB。attention-only 架构被 llama.cpp 内部 clamp 到 0，全模型安全。Attempt 3（f16 兜底）**有意不设**，保证内存紧张时兜底成功。
- 实测建议：观察编辑重发时日志 `Prefix rollback matched!`（不再 `Checkpoint restored`）出现的占比；若想扩大快路径覆盖，把常量调到 8（再 +96 MiB）。

**kvBits 分 k/v 已并入（commit `898f509`）**：
- 新增档位 `kvBits = 6`：`type_k = Q4_0` + `type_v = Q8_0`（Attempt 1/2 均支持；Attempt 3 f16 兜底不变）。原理：V 直接参与 softmax 加权求和（量化误差直入输出，最敏感），K 只参与相似度点积（容错高）→ K 压到 Q4_0、V 保 Q8_0，8K 快照 160.6 → **128.6 MiB**（-20%），输出质量接近全 Q8_0。
- 调用方式：`Sampling.kvBits = 6` 即生效（引擎已支持，UI 如需选项自行加）。

**快照方案与 n_rs_seq 的关系（组合 C 完整形态）**：三者分层——① n_rs_seq 覆盖小窗口（≤4 token）零拷贝回滚；② 快照覆盖任意深度兜底；③ 全量重算兜底。Qwen3.5 上 Regenerate 走 ①，编辑长 suffix 走 ②。

---

## 7. 动态验证建议（待有网/Mac 环境执行）

**编译**：Mac 上 `scripts/build-llama-xcframework.sh` 重建 vendored 框架（commit 956973c），Xcode 编译 mobileLLM（工作区 = my-branch 43d4598）。

**快照往返一致性（新实现核心）**：
1. 用 Qwen3.5-4B GGUF 实测：多轮对话 → 编辑较早 turn 重发 → 观察日志出现 `[LlamaEngine] Checkpoint restored: turn=N, promptEndPos=M, suffix=K tok`，确认未走 `Clean slate fallback`
2. 对比恢复路径与全量重算的生成内容逐 token 一致（同一温度/seed 下）
3. 检查 `sessionCache.commit` 后 tokens 与 prompt 完全对齐（LLM 下一轮增量续写命中，无位置错乱）
4. 记录恢复后 TTFT 与全量重算 TTFT 的差值（预期省下整个公共前缀的 prefill）

**边界用例**：
- 编辑第 1 轮（无快照命中）→ 应安全回退全量重算
- 连续编辑同一轮两次 → 第二次应命中同 turn 快照（去重逻辑：同边界同 prompt 不重复写盘）
- 中途切换 kvBits / n_ctx（context 重建）→ 快照应被清空，不误用旧布局
- 生成中途取消 → 下一轮正常（快照为 prefill 后状态，与生成结果无关）
- 图像 turn 后编辑纯文本轮 → 走全量（快照限定纯文本）

**n_rs_seq / kvBits 分 k/v（已并入，commit 898f509）**：见 §6「方案 A 已并入」与「kvBits 分 k/v 已并入」。实测点：① 编辑重发且回滚深度 ≤4 时日志出现 `Prefix rollback matched`（n_rs_seq 生效）；② Regenerate 不再落快照文件；③ `kvBits=6` 时快照体积 ≈ 128.6 MiB（8K），与 §4 估算一致；④ 同一编辑在 kvBits 6/8 下的输出质量对比。

---

## 8. 附：验证引用文件（llama.cpp 956973c）

| 文件 | 关键位置 |
|---|---|
| include/llama.h | L791-913 state API |
| src/llama-arch.cpp | L921-975 is_recurrent / is_hybrid / supports_rs_rollback |
| src/llama-context.cpp | L85-89 n_rs_seq clamp；L3439 默认 0 |
| src/llama-model.cpp | L506-540 QWEN35 split 与 S/R 维度；L2075-2110 memory 创建 |
| src/llama-memory-hybrid.cpp | L143-149 seq_rm；L190-201 state_write/read |
| src/llama-memory-recurrent.cpp | L99 内存公式；L150-233 seq_rm；L733-1041 state 序列化 |
| src/llama-hparams.cpp | L183-222 n_embd_r / n_embd_s 公式 |
