# The test harness: the model layer is compiled ONCE, as a module, and every
# test binary is compiled on its own against it.
#
# Every runner used to hand the whole model layer to its own `swiftc -O` — 114 s
# a runner, about 25 runners, most of a full run spent compiling the same files.
# Now the module is built once (about 50 s, whole-module and threaded) and kept
# in build/tests/ until a model file changes; a test compiles in about 2 s.
#
# Tests reach the model layer through `@testable import FVPModel`, so what was
# internal stays reachable without making anything public.
#
# Sourced by every runner. `here` must be set to the Tests directory first.
#
#   fvp_model                 build the module if a model file changed
#   fvp_test <test.swift> <out>   compile one test against it

model="$here/../FolderVideoPlayer/Model"
. "$here/model_sources.sh"
FVP_TEST_BUILD="${FVP_TEST_BUILD:-$here/../build/tests}"

fvp_model() {
    local lib="$FVP_TEST_BUILD/libFVPModel.a"
    local stale=0
    if [ ! -f "$lib" ] || [ ! -f "$FVP_TEST_BUILD/FVPModel.swiftmodule" ]; then
        stale=1
    elif [ -n "$(find "${MODEL_SOURCES[@]}" "$here/model_sources.sh" "$here/harness.sh" \
                   -newer "$lib" 2>/dev/null | head -1)" ]; then
        stale=1
    fi
    [ $stale -eq 0 ] && return 0
    echo "building the model layer once (FVPModel) ..."
    mkdir -p "$FVP_TEST_BUILD"
    # Written beside and moved in, so a failed build never leaves a library
    # newer than the sources it failed on.
    local tmp="$FVP_TEST_BUILD/.partial"
    rm -rf "$tmp"; mkdir -p "$tmp"
    swiftc -O -wmo -num-threads "$(sysctl -n hw.ncpu)" -enable-testing -parse-as-library \
        -module-name FVPModel -emit-module -emit-module-path "$tmp/FVPModel.swiftmodule" \
        -emit-library -static -o "$tmp/libFVPModel.a" \
        "${MODEL_SOURCES[@]}" "${MODEL_FRAMEWORKS[@]}" || { rm -rf "$tmp"; return 1; }
    mv "$tmp"/* "$FVP_TEST_BUILD"/
    rm -rf "$tmp"
}

fvp_test() {
    local src=$1 out=$2
    fvp_model || return 1
    # A file with `@main` is a library file; one with top-level statements is
    # its own main file.
    local flags=()
    grep -q '^@main' "$src" && flags+=(-parse-as-library)
    swiftc -O ${flags[@]+"${flags[@]}"} -I "$FVP_TEST_BUILD" -L "$FVP_TEST_BUILD" -lFVPModel \
        "${MODEL_FRAMEWORKS[@]}" -o "$out" "$src"
}
