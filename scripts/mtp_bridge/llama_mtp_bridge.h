// SPDX-License-Identifier: MIT
#pragma once

#include <stdint.h>
#include <stdbool.h>
#include "llama.h"

#ifdef __cplusplus
extern "C" {
#endif

/// Opaque handle for native MTP (Multi-Token Prediction / nextn) draft runner.
typedef struct llama_mtp_runner llama_mtp_runner_t;

/// Returns true if native MTP symbols are compiled and available in the current runtime.
LLAMA_API bool llama_mtp_is_available(void);

/// Initialize native MTP runner for a given model and context.
/// Returns NULL if the model does not declare next-n / MTP draft layers or initialization fails.
LLAMA_API llama_mtp_runner_t * llama_mtp_init(
    struct llama_context * ctx,
    struct llama_model * model,
    int32_t n_draft
);

/// Predict draft candidate tokens using the model's embedded next-n / MTP prediction heads.
/// NOTE: In the experimental bridge phase, when native nextn tensor evaluation is not linked or
/// does not produce proposal tokens, this returns 0, signaling the engine to safely fallback
/// to Prompt Lookup without interrupting generation.
/// Returns the number of proposed draft tokens (written to out_drafts).
LLAMA_API int32_t llama_mtp_predict(
    llama_mtp_runner_t * runner,
    llama_token last_token,
    llama_token * out_drafts,
    int32_t max_drafts
);

/// Free resources allocated by the MTP runner.
LLAMA_API void llama_mtp_free(llama_mtp_runner_t * runner);

#ifdef __cplusplus
}
#endif
