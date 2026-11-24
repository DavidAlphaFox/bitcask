#!/usr/bin/env bash
# scripts/detect-llama-backends.sh
#
# **构建期**探测：这台机器有没有 GPU SDK，能编出哪些后端。
#
# ⚠️ **这是一个构建期工具，与运行期无关。** 运行期的决策（用 CUDA / Vulkan /
#    CPU）由 Erlang 侧在目标机上**自己完成**，不需要也不应该依赖脚本：
#
#      bitcask_llama_nifs:gpu_status().        %% 包编了什么 × 这台机器有什么
#      bitcask_llama_nifs:model_load(P, #{}).  %% backend => auto 自动挑
#
#    部署机上不会有这个仓库，也不会有 cmake —— 把运行期决策放进脚本等于要求
#    部署机装一套构建工具，那是错的。
#
# 为什么构建期仍然需要它：CMake 只会说"没找到 CUDA Toolkit"，不会说**缺哪个包**。
# 而 AUTO 找不到 SDK 时是安静地产出纯 CPU 包 —— 与 GPU 包长得一模一样。
#
# 用法：
#   scripts/detect-llama-backends.sh            # 探测 + 给出建议的构建命令
#   scripts/detect-llama-backends.sh --build    # 同上（显式）
#
# 退出码：0 = 探测完成。

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PRIV="$ROOT/priv"

MODE="${1:---all}"

if [ -t 1 ]; then
    B=$'\033[1m'; R=$'\033[31m'; G=$'\033[32m'; Y=$'\033[33m'; D=$'\033[2m'; N=$'\033[0m'
else
    B=''; R=''; G=''; Y=''; D=''; N=''
fi

ok()   { printf '  %s✓%s %s\n'  "$G" "$N" "$*"; }
warn() { printf '  %s!%s %s\n'  "$Y" "$N" "$*"; }
bad()  { printf '  %s✗%s %s\n'  "$R" "$N" "$*"; }
info() { printf '  %s·%s %s\n'  "$D" "$N" "$*"; }
hdr()  { printf '\n%s%s%s\n' "$B" "$*" "$N"; }

HAVE_DRIVER=0
HAVE_GPU=0
HAVE_TOOLKIT=0
HAVE_VULKAN=0
TOOLKIT_VER=""
DRIVER_MAX_CUDA=""

# ===================================================================
# 构建期：这台机器有没有 SDK
# ===================================================================

probe_toolkit() {
    hdr "1. CUDA SDK（NVIDIA）"

    if command -v nvcc >/dev/null 2>&1; then
        local v
        v="$(nvcc --version 2>/dev/null | sed -n 's/.*release \([0-9.]*\).*/\1/p' | head -1)"
        ok "nvcc $v （$(command -v nvcc)）"
    else
        info "PATH 里没有 nvcc"
    fi

    # ⚠️ **以 CMake 的 find_package(CUDAToolkit) 为准**，不是 nvcc 在不在 PATH。
    #    构建走的就是这条，两者不一致时（典型：装了 toolkit 但 nvcc 没进 PATH，
    #    或者反过来只有 nvcc 没有 cublas 开发包）以这条为准。
    if ! command -v cmake >/dev/null 2>&1; then
        bad "没有 cmake，无法做权威探测"
        return
    fi

    local tmp
    tmp="$(mktemp -d)"
    cat > "$tmp/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
# ⚠️ 必须 LANGUAGES CXX，不能用 NONE：find_package 的库探测要靠编译器，
#    NONE 下会报**假阴性**（实测 Vulkan_FOUND 在 NONE 下是 FALSE、CXX 下是 TRUE，
#    而真实构建走的是后者）。探测工程必须与真实构建同条件，否则它给的答案不算数。
project(probe LANGUAGES CXX)
find_package(CUDAToolkit QUIET)
if(CUDAToolkit_FOUND)
  message(STATUS "PROBE_FOUND ${CUDAToolkit_VERSION} ${CUDAToolkit_LIBRARY_ROOT}")
  foreach(t CUDA::cudart CUDA::cublas CUDA::cublasLt)
    if(TARGET ${t})
      message(STATUS "PROBE_LIB ${t} yes")
    else()
      message(STATUS "PROBE_LIB ${t} MISSING")
    endif()
  endforeach()
else()
  message(STATUS "PROBE_NOTFOUND")
endif()
EOF
    local out
    out="$(cmake -S "$tmp" -B "$tmp/b" 2>&1)"
    rm -rf "$tmp"

    if grep -q PROBE_FOUND <<< "$out"; then
        HAVE_TOOLKIT=1
        TOOLKIT_VER="$(sed -n 's/.*PROBE_FOUND \([0-9.]*\) .*/\1/p' <<< "$out" | head -1)"
        local rootdir
        rootdir="$(sed -n 's/.*PROBE_FOUND [0-9.]* \(.*\)/\1/p' <<< "$out" | head -1)"
        ok "find_package(CUDAToolkit) 找到 $TOOLKIT_VER （$rootdir）"
        while IFS= read -r l; do
            case "$l" in
                *MISSING*) bad "缺 $(awk '{print $3}' <<< "$l") —— 装 cublas 开发包（libcublas-dev / cuda-libraries-dev）" ;;
                *yes*)     info "$(awk '{print $3}' <<< "$l") ok" ;;
            esac
        done < <(grep PROBE_LIB <<< "$out")
    else
        bad "find_package(CUDAToolkit) 找不到 CUDA Toolkit —— 构建只会产出纯 CPU 包"
    fi
}

probe_vulkan() {
    hdr "2. Vulkan SDK（AMD / Intel / 也能跑 N 卡）"

    if command -v glslc >/dev/null 2>&1; then
        ok "glslc $(glslc --version 2>/dev/null | sed -n '1s/.*v\([0-9.]*\).*/\1/p') （$(command -v glslc)）"
    else
        info "PATH 里没有 glslc"
    fi

    if ! command -v cmake >/dev/null 2>&1; then
        bad "没有 cmake，无法做权威探测"
        return
    fi

    # ⚠️ 与 CUDA 那节同理：以 CMake 的 find_package 为准。而且 Vulkan 这边必须
    #    **三个都确认**——ggml-vulkan 里 Vulkan(COMPONENTS glslc) 与 SPIRV-Headers
    #    都是 REQUIRED，缺一个就会让构建当场炸掉，而不是安静地不编。
    local tmp; tmp="$(mktemp -d)"
    cat > "$tmp/CMakeLists.txt" <<'EOF'
cmake_minimum_required(VERSION 3.20)
# ⚠️ LANGUAGES CXX，理由同 CUDA 那段：NONE 下 Vulkan_FOUND 是假阴性。
project(probe LANGUAGES CXX)
if(DEFINED ENV{VULKAN_SDK})
  list(APPEND CMAKE_PREFIX_PATH "$ENV{VULKAN_SDK}")
endif()
find_package(Vulkan QUIET COMPONENTS glslc)
find_package(SPIRV-Headers QUIET CONFIG)
# ⚠️ 布尔要归一：CMake 的 *_FOUND 有的是 TRUE 有的是 1，直接抓字符串会漏。
set(L no)
set(G no)
set(S no)
if(Vulkan_FOUND)
  set(L yes)
endif()
if(Vulkan_glslc_FOUND)
  set(G yes)
endif()
if(SPIRV-Headers_FOUND)
  set(S yes)
endif()
message(STATUS "PROBE_VK loader=${L} glslc=${G} spirv=${S} ver=${Vulkan_VERSION}")
EOF
    local out; out="$(cmake -S "$tmp" -B "$tmp/b" 2>&1)"
    rm -rf "$tmp"

    local line; line="$(grep 'PROBE_VK' <<< "$out" | head -1)"
    local missing=""
    grep -q 'loader=yes' <<< "$line" || missing="$missing Vulkan-loader/headers"
    grep -q 'glslc=yes'  <<< "$line" || missing="$missing glslc(shaderc)"
    grep -q 'spirv=yes'  <<< "$line" || missing="$missing SPIRV-Headers"

    if [ -z "$missing" ]; then
        HAVE_VULKAN=1
        ok "find_package: loader + glslc + SPIRV-Headers 齐全（Vulkan $(sed -n 's/.*ver=//p' <<< "$line")）"
    else
        bad "缺：$missing —— 装 Vulkan SDK 或发行版的 vulkan-headers / shaderc / spirv-headers 开发包"
        info "⚠️ 三个必须齐全：ggml-vulkan 里那两个 find_package 都是 REQUIRED，缺一个会让构建当场炸"
    fi
}

check_versions() {
    [ "$HAVE_TOOLKIT" = 1 ] || return 0
    # 驱动信息只有在同一台机器上既有 SDK 又有驱动时才拿得到 —— 构建机通常没有
    # 卡，那时这一节整个跳过是对的，不是缺陷。
    if [ -z "$DRIVER_MAX_CUDA" ]; then
        DRIVER_MAX_CUDA="$(nvidia-smi 2>/dev/null | sed -n 's/.*CUDA Version: *\([0-9.]*\).*/\1/p' | head -1)"
    fi
    [ -n "$DRIVER_MAX_CUDA" ] || return 0
    hdr "3. 版本匹配"
    # 驱动支持的 CUDA 版本必须 >= toolkit 版本，否则运行时 cudaErrorInsufficientDriver。
    local a b
    a="$(cut -d. -f1 <<< "$TOOLKIT_VER")"; b="$(cut -d. -f1 <<< "$DRIVER_MAX_CUDA")"
    if [ "${a:-0}" -gt "${b:-0}" ] 2>/dev/null; then
        bad "toolkit CUDA $TOOLKIT_VER > 驱动支持的 CUDA $DRIVER_MAX_CUDA —— 编得出来但跑不起来"
        info "升驱动，或者装一个 <= $DRIVER_MAX_CUDA 的 toolkit"
    else
        ok "toolkit CUDA $TOOLKIT_VER ≤ 驱动支持的 CUDA $DRIVER_MAX_CUDA"
    fi

    # ggml 在 GGML_NATIVE=OFF 下编 50/61/70/75/80-virtual + 86/89-real + 90-virtual
    # （+ Blackwell，取决于 toolkit 版本），覆盖 Maxwell 到 Blackwell。
    local caps
    caps="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | tr -d ' ' | sort -u)"
    if [ -n "$caps" ]; then
        while IFS= read -r c; do
            [ -z "$c" ] && continue
            local n; n="$(tr -d '.' <<< "$c")"
            if [ "${n:-0}" -lt 50 ] 2>/dev/null; then
                bad "compute capability $c 低于 ggml 编译覆盖的最低档（5.0）"
            else
                ok "compute capability $c 在默认编译覆盖范围内"
            fi
        done <<< "$caps"
    fi
}

recommend() {
    hdr "4. 建议的构建命令"
    local flags=""
    [ "$HAVE_TOOLKIT" = 1 ] && flags="$flags -DBITCASK_LLAMA_CUDA=ON"
    [ "$HAVE_VULKAN"  = 1 ] && flags="$flags -DBITCASK_LLAMA_VULKAN=ON"

    if [ -n "$flags" ]; then
        cat <<EOF
  ${G}可用的 GPU 后端：$([ "$HAVE_TOOLKIT" = 1 ] && printf 'CUDA ')$([ "$HAVE_VULKAN" = 1 ] && printf 'Vulkan')${N}

  日常（AUTO：探到什么编什么）：

    BITCASK_WITH_LLAMA=1 rebar3 compile

  ${B}发布构建请用 ON 而不是 AUTO${N} —— AUTO 在缺 SDK 的机器上会**悄悄**产出纯
  CPU 的包，而两种包长得一模一样：

    cmake -S . -B _build/cmake -DCMAKE_BUILD_TYPE=Release -DBUILD_TESTING=OFF \\
          -DBITCASK_WITH_LLAMA=ON$flags
    cmake --build _build/cmake --target bitcask_llama -j

  ${D}CUDA 架构默认覆盖 Maxwell..Blackwell（体积换可移植性，服务器产品的正确取舍）。
  要收窄成本机： -DCMAKE_CUDA_ARCHITECTURES=native${N}
EOF
    else
        cat <<EOF
  ${Y}没有任何 GPU SDK${N}，只能编 CPU 后端：

    BITCASK_WITH_LLAMA=1 rebar3 compile

  ${D}要上 GPU：装 CUDA Toolkit（nvcc + cublas 开发包）或 Vulkan SDK（glslc +
  SPIRV-Headers），再用 -DBITCASK_LLAMA_CUDA=ON / -DBITCASK_LLAMA_VULKAN=ON
  让缺失当场报错而不是静默降级。${N}
EOF
    fi
}

# ===================================================================

printf '%sbitcask 本地嵌入后端 —— 环境探测%s\n' "$B" "$N"
printf '%s%s%s\n' "$D" "$ROOT" "$N"

case "$MODE" in
    --build|--pre|--all|"")
        probe_toolkit; probe_vulkan; check_versions; recommend ;;
    --runtime|--post)
        echo "运行期决策已移到 Erlang 侧，不再需要脚本：" >&2
        echo "  bitcask_llama_nifs:gpu_status()." >&2
        echo "  bitcask_llama_nifs:model_load(Path, #{})   %% backend => auto" >&2
        exit 0 ;;
    *)
        echo "用法: $0 [--build]" >&2; exit 2 ;;
esac

echo
if [ "$HAVE_TOOLKIT" = 1 ] || [ "$HAVE_VULKAN" = 1 ]; then
    printf '%s结论：这台机器能编出带 GPU 后端的包。%s
' "$G" "$N"
else
    printf '%s结论：这台机器只能编出纯 CPU 的包。%s
' "$Y" "$N"
fi
printf '  %s运行期用哪个后端由 Erlang 侧在目标机上自己决定（backend => auto）。%s
' "$D" "$N"
exit 0
