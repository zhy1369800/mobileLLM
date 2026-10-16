// SPDX-License-Identifier: MIT

#include "llama_mtp_bridge.h"
#include <vector>
#include <string>
#include <cstring>
#include <cstdio>

struct llama_mtp_runner {
    struct llama_context * ctx;
    struct llama_model * model;
    int32_t n_draft;
    std::vector<llama_token> draft_history;
};

bool llama_mtp_is_available(void) {
    return true;
}

llama_mtp_runner_t * llama_mtp_init(
    struct llama_context * ctx,
    struct llama_model * model,
    int32_t n_draft
) {
    if (!ctx || !model) {
        return nullptr;
    }

    // Check if the loaded model declares nextn/mtp capabilities
    int32_t n_meta = llama_model_meta_count(model);
    bool has_draft_layers = false;
    char key_buf[256] = {0};
    char val_buf[256] = {0};

    for (int32_t i = 0; i < n_meta; ++i) {
        if (llama_model_meta_key_by_index(model, i, key_buf, sizeof(key_buf)) <= 0) continue;
        std::string key(key_buf);
        for (auto & c : key) c = (char)::tolower(c);

        if (key.find("nextn") != std::string::npos ||
            key.find("mtp") != std::string::npos ||
            key.find("multi_token") != std::string::npos) {
            if (llama_model_meta_val_str_by_index(model, i, val_buf, sizeof(val_buf)) > 0) {
                if (std::strcmp(val_buf, "0") != 0 &&
                    std::strcmp(val_buf, "false") != 0 &&
                    val_buf[0] != '\0') {
                    has_draft_layers = true;
                    break;
                }
            }
        }
    }

    if (!has_draft_layers) {
        // Model does not carry MTP layers, do not allocate runner
        return nullptr;
    }

    auto * runner = new llama_mtp_runner();
    runner->ctx = ctx;
    runner->model = model;
    runner->n_draft = (n_draft > 0) ? n_draft : 2;
    return runner;
}

int32_t llama_mtp_predict(
    llama_mtp_runner_t * runner,
    llama_token last_token,
    llama_token * out_drafts,
    int32_t max_drafts
) {
    if (!runner || !out_drafts || max_drafts <= 0) {
        return 0;
    }

    // Native MTP evaluation: forward the hidden state of last_token through nextn layers.
    // In standard llama.cpp upstream, draft predictions are sampled from the nextn logits.
    // If the nextn head produces proposal tokens, copy them to out_drafts.
    // In this initial contract bridge phase, returning 0 signals LlamaEngine to perform
    // seamless fallback to PromptLookupDrafter without stalls.
    int32_t produced = 0;
    runner->draft_history.push_back(last_token);

    return produced;
}

void llama_mtp_free(llama_mtp_runner_t * runner) {
    if (runner) {
        delete runner;
    }
}
