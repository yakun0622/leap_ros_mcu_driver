#!/usr/bin/env bash
# leap_ros_mcu_driver 上位机 (W152D / Linux) 一键升级下位机固件脚本
#
# 功能：
#   1. 在线从 GitHub Releases 拉取最新/指定版本固件（带 SHA256 校验），或使用本地 .bin 文件
#   2. 自动识别占用串口的 micro_ros_agent（systemd 服务或普通进程），升级前暂停、升级后自动恢复
#   3. 默认刷入 app.bin (0x10000) 保留板内 NVS 配置；加 --full 则刷入 merged.bin (0x0) 整包

set -euo pipefail

REPO="${MCU_GITHUB_REPO:-yakun0622/leap_ros_mcu_driver}"
PORT=""
BAUD="460800"
TAG="latest"
LOCAL_FILE=""
FULL_FLASH="false"
MIRROR_PREFIX="${GH_MIRROR:-}"
AGENT_SERVICE=""
SKIP_AGENT="false"

usage() {
    cat <<'EOF'
用法: upgrade_mcu.sh [选项]

选项:
  -p, --port <设备>       指定串口设备（如 /dev/ttyUSB0）；默认优先从运行中的 micro_ros_agent 自动识别
  -t, --tag <标签>        指定 GitHub Release 版本标签（如 v2.2）；默认拉取 latest 最新版
  -f, --file <路径>       使用本地固件 .bin 文件离线升级（跳过网络下载）
      --full              整包烧录 (*-merged.bin -> 0x0)，会覆盖分区表；默认仅刷 app.bin (0x10000) 保留 NVS
  -b, --baud <波特率>     烧录波特率（默认: 460800）
  -s, --service <服务名>  指定 micro-ROS Agent 的 systemd 服务名（默认自动检测）
  -m, --mirror <前缀>     GitHub 下载加速前缀（例如 https://ghproxy.net/）
      --no-agent-ctl      不自动停止/恢复 micro_ros_agent
  -h, --help              显示此帮助信息

示例:
  # 在线拉取最新 Release 固件并升级（保留 Wi-Fi / 串口模式 / PID 配置）
  ./scripts/upgrade_mcu.sh

  # 指定串口与版本升级
  ./scripts/upgrade_mcu.sh -p /dev/ttyUSB0 -t v2.2

  # 使用本地下载好的固件离线升级
  ./scripts/upgrade_mcu.sh -p /dev/ttyUSB0 -f ./leap_ros_mcu_driver-v2.2-esp32s3-app.bin
EOF
}

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        -p|--port)
            PORT="${2:-}"
            shift 2
            ;;
        -t|--tag)
            TAG="${2:-}"
            shift 2
            ;;
        -f|--file)
            LOCAL_FILE="${2:-}"
            shift 2
            ;;
        --full)
            FULL_FLASH="true"
            shift
            ;;
        -b|--baud)
            BAUD="${2:-}"
            shift 2
            ;;
        -s|--service)
            AGENT_SERVICE="${2:-}"
            shift 2
            ;;
        -m|--mirror)
            MIRROR_PREFIX="${2:-}"
            shift 2
            ;;
        --no-agent-ctl)
            SKIP_AGENT="true"
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            log_error "未知参数: $1"
            usage
            exit 1
            ;;
    esac
done

# Normalize mirror prefix trailing slash
if [[ -n "$MIRROR_PREFIX" && "${MIRROR_PREFIX: -1}" != "/" ]]; then
    MIRROR_PREFIX="${MIRROR_PREFIX}/"
fi

# 1. 查找可用的 esptool 命令
ESPTOOL_CMD=()
if python3 -m esptool version >/dev/null 2>&1; then
    ESPTOOL_CMD=(python3 -m esptool)
elif command -v esptool.py >/dev/null 2>&1; then
    ESPTOOL_CMD=(esptool.py)
elif command -v esptool >/dev/null 2>&1; then
    ESPTOOL_CMD=(esptool)
else
    log_error "未找到 esptool，请先安装: pip3 install esptool 或 sudo apt install esptool"
    exit 1
fi

# 2. 检测运行中的 micro_ros_agent 服务与绑定的串口
STOPPED_SERVICE=""
STOPPED_RAW_CMD=""
WORK_DIR=""

cleanup() {
    local exit_code=$?
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi
    if [[ -n "$STOPPED_SERVICE" ]]; then
        log_info "恢复 systemd 服务: ${STOPPED_SERVICE}"
        if [[ $EUID -eq 0 ]]; then
            systemctl start "$STOPPED_SERVICE" || log_warn "启动 ${STOPPED_SERVICE} 失败，请手动检查"
        else
            sudo systemctl start "$STOPPED_SERVICE" || log_warn "启动 ${STOPPED_SERVICE} 失败，请手动检查"
        fi
    elif [[ -n "$STOPPED_RAW_CMD" ]]; then
        log_warn "之前停止了手动运行的 micro_ros_agent，请按需重新执行:"
        log_warn "  ${STOPPED_RAW_CMD}"
    fi
    exit "$exit_code"
}
trap cleanup EXIT

detect_agent_port_from_proc() {
    local pid
    for pid in $(pgrep -f "micro_ros_agent.*serial" 2>/dev/null || true); do
        if [[ -r "/proc/${pid}/cmdline" ]]; then
            local args=()
            while IFS= read -r -d '' arg; do
                args+=("$arg")
            done < "/proc/${pid}/cmdline"
            local i
            for ((i = 0; i < ${#args[@]}; i++)); do
                if [[ "${args[$i]}" == "--dev" || "${args[$i]}" == "-d" ]] && ((i + 1 < ${#args[@]})); then
                    echo "${args[$((i + 1))]}"
                    return 0
                fi
            done
        fi
    done
    return 1
}

if [[ -z "$PORT" ]]; then
    if detected_port="$(detect_agent_port_from_proc)"; then
        PORT="$detected_port"
        log_info "从运行中的 micro_ros_agent 自动识别到下位机串口: ${PORT}"
    fi
fi

# 3. 准备固件文件（本地或从 GitHub Release 下载 + SHA256 校验）
FLASH_OFFSET="0x10000"
if [[ "$FULL_FLASH" == "true" ]]; then
    FLASH_OFFSET="0x0"
fi

if [[ -n "$LOCAL_FILE" ]]; then
    if [[ ! -f "$LOCAL_FILE" ]]; then
        log_error "找不到本地固件文件: ${LOCAL_FILE}"
        exit 1
    fi
    FIRMWARE_BIN="$LOCAL_FILE"
    if [[ "$LOCAL_FILE" == *"-merged.bin" || "$LOCAL_FILE" == *"merged-binary.bin" ]] && [[ "$FULL_FLASH" != "true" ]]; then
        log_info "检测到整包固件文件名，自动切换烧录地址为 0x0"
        FLASH_OFFSET="0x0"
    fi
else
    WORK_DIR="$(mktemp -d /tmp/leap_mcu_upgrade.XXXXXX)"
    if [[ "$TAG" == "latest" ]]; then
        API_URL="https://api.github.com/repos/${REPO}/releases/latest"
    else
        API_URL="https://api.github.com/repos/${REPO}/releases/tags/${TAG}"
    fi

    log_info "正在查询 GitHub Release (${REPO} @ ${TAG})..."
    RELEASE_JSON="${WORK_DIR}/release.json"
    curl -fsSL "$API_URL" -o "$RELEASE_JSON"

    WANT_SUFFIX="-app.bin"
    if [[ "$FULL_FLASH" == "true" ]]; then
        WANT_SUFFIX="-merged.bin"
    fi

    readarray -t ASSET_INFO < <(python3 - "$RELEASE_JSON" "$WANT_SUFFIX" <<'PY'
import json
import sys

data = json.loads(open(sys.argv[1], encoding="utf-8").read())
want_suffix = sys.argv[2]
tag_name = data.get("tag_name", "unknown")
fw_name, fw_url, sum_url = "", "", ""

for asset in data.get("assets", []):
    name = asset.get("name", "")
    url = asset.get("browser_download_url", "")
    if name.endswith(want_suffix):
        fw_name, fw_url = name, url
    elif name == "SHA256SUMS.txt":
        sum_url = url

if not fw_url:
    sys.exit(f"Release {tag_name} 中未找到以 {want_suffix} 结尾的固件附件")

print(tag_name)
print(fw_name)
print(fw_url)
print(sum_url)
PY
    )

    RESOLVED_TAG="${ASSET_INFO[0]}"
    FW_NAME="${ASSET_INFO[1]}"
    FW_URL="${MIRROR_PREFIX}${ASSET_INFO[2]}"
    SUM_URL="${ASSET_INFO[3]:+${MIRROR_PREFIX}${ASSET_INFO[3]}}"

    FIRMWARE_BIN="${WORK_DIR}/${FW_NAME}"
    log_info "下载固件 ${FW_NAME} (${RESOLVED_TAG})..."
    curl -fL --progress-bar "$FW_URL" -o "$FIRMWARE_BIN"

    if [[ -n "$SUM_URL" ]]; then
        SUM_FILE="${WORK_DIR}/SHA256SUMS.txt"
        log_info "正在校验 SHA-256..."
        curl -fsSL "$SUM_URL" -o "$SUM_FILE"
        (
            cd "$WORK_DIR"
            grep "  ${FW_NAME}\$" SHA256SUMS.txt | sha256sum -c -
        )
    else
        log_warn "Release 未包含 SHA256SUMS.txt，跳过哈希校验"
    fi
fi

# 4. 若仍未确定串口，扫描候选串口设备
if [[ -z "$PORT" ]]; then
    shopt -s nullglob
    CANDIDATES=(/dev/ttyUSB* /dev/ttyACM*)
    shopt -u nullglob
    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
        PORT="${CANDIDATES[0]}"
        log_info "自动选择唯一串口设备: ${PORT}"
    elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        log_error "未检测到 /dev/ttyUSB* 或 /dev/ttyACM* 串口设备，请检查 USB 连接或用 -p 指定"
        exit 1
    else
        log_error "检测到多个串口设备: ${CANDIDATES[*]}"
        log_error "为避免误刷雷达或其他外设，请使用 -p <设备> 明确指定下位机串口"
        exit 1
    fi
fi

if [[ ! -e "$PORT" ]]; then
    log_error "串口设备不存在: ${PORT}"
    exit 1
fi

# 5. 暂停占用串口的 micro_ros_agent
stop_agent_if_needed() {
    if [[ "$SKIP_AGENT" == "true" ]]; then
        return 0
    fi

    # 优先检测 systemd 服务
    if command -v systemctl >/dev/null 2>&1; then
        local candidates=()
        if [[ -n "$AGENT_SERVICE" ]]; then
            candidates+=("$AGENT_SERVICE")
        else
            candidates+=(
                "microros-agent.service"
                "micro-ros-agent.service"
                "micro_ros_agent.service"
                "leap-microros-agent.service"
            )
            while IFS= read -r unit; do
                [[ -n "$unit" ]] && candidates+=("$unit")
            done < <(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '/micro[-_]?ros/ {print $1}')
        fi

        local svc
        for svc in "${candidates[@]}"; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                log_info "停止正在运行的 systemd 服务: ${svc}"
                if [[ $EUID -eq 0 ]]; then
                    systemctl stop "$svc"
                else
                    sudo systemctl stop "$svc"
                fi
                STOPPED_SERVICE="$svc"
                sleep 1
                return 0
            fi
        done
    fi

    # 检测普通后台/终端运行的 micro_ros_agent 进程（且使用同一串口或未区分）
    local pids
    pids="$(pgrep -f "micro_ros_agent" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        local first_pid
        first_pid="$(awk '{print $1}' <<<"$pids")"
        if [[ -r "/proc/${first_pid}/cmdline" ]]; then
            STOPPED_RAW_CMD="$(tr '\0' ' ' < "/proc/${first_pid}/cmdline")"
        fi
        log_info "停止运行中的 micro_ros_agent 进程 (PID: ${pids//$'\n'/ })..."
        kill $pids 2>/dev/null || sudo kill $pids
        sleep 1
    fi
}

stop_agent_if_needed

# 6. 执行 esptool 烧录
log_info "开始刷写固件 -> 端口: ${PORT}, 波特率: ${BAUD}, 偏移地址: ${FLASH_OFFSET}"
log_info "固件文件: ${FIRMWARE_BIN}"

FLASH_CMD=("${ESPTOOL_CMD[@]}" --chip esp32s3 --port "$PORT" --baud "$BAUD" write_flash -z "$FLASH_OFFSET" "$FIRMWARE_BIN")

if [[ -w "$PORT" ]]; then
    "${FLASH_CMD[@]}"
else
    log_info "当前用户无 ${PORT} 写权限，使用 sudo 执行烧录..."
    sudo "${FLASH_CMD[@]}"
fi

log_info "下位机固件升级完成！"
