#!/bin/bash
# The prompt table's gate: shape, constants, and the Swift maths checked against
# numpy's own numbers for the same table and the same probe vector.
#
# No model, no video, no Xcode — a few hundred milliseconds. Skips (loudly, but
# with exit 0) when the table has not been built on this machine yet, because
# the table is a dev-time artifact until Phase 5's downloader ships it.
#
# Usage: Tests/run_prompt_table.sh
#   FVP_PROMPT_DIR   where siglip2_base_prompts.{json,f32} live (default
#                     ~/fvp-coreml-models,
#                     then ~/fvp/fvp-coreml-models — see the note below)
#   FVP_PARITY_PY    python with numpy (default /opt/anaconda3/bin/python3)
set -e
here=$(cd "$(dirname "$0")" && pwd)
. "$here/harness.sh"

# Two candidate locations, because this workspace nests its scratch dirs under a
# second `fvp/`: the models live in `~/fvp/fvp-coreml-models`, while this script
# used to look only in `~/fvp-coreml-models`. The failure mode was quiet and
# expensive — the stage printed SKIP and the suite still reported all-pass, so a
# gate that had stopped running looked exactly like a gate that passed.
if [ -z "${FVP_PROMPT_DIR:-}" ]; then
    for d in "$HOME/fvp-coreml-models" "$HOME/fvp/fvp-coreml-models"; do
        if [ -f "$d/siglip2_base_prompts.json" ]; then FVP_PROMPT_DIR="$d"; break; fi
    done
fi
table="${FVP_PROMPT_DIR:-$HOME/fvp-coreml-models}"
py="${FVP_PARITY_PY:-/opt/anaconda3/bin/python3}"
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ ! -f "$table/siglip2_base_prompts.json" ] || [ ! -f "$table/siglip2_base_prompts.f32" ]; then
    echo "SKIP prompt table — nothing built at $table"
    echo "     build it with: $py docs/coreml-spike/precompute_text_siglip2.py"
    exit 0
fi

# The table's name is passed, not assumed: the Swift side names its files after
# `PromptTable.slug`, and a rig that reads a different file than the app would
# be a gate that passes on the wrong table.
"$py" "$here/../docs/coreml-spike/table_parity.py" "$table" "$work/parity.json" \
    siglip2_base_prompts

fvp_test "$here/test_prompt_table.swift" "$work/prompt_table"
"$work/prompt_table" "$table" "$work/parity.json"
