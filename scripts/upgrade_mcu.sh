#!/usr/bin/env bash
# leap_ros_mcu_driver 上位机 (W152D / Linux) 一键升级下位机固件脚本
#
# 功能：
#   1. 在线从 GitHub Releases 拉取最新/指定版本固件（带 SHA256 校验），或使用本地 .bin 文件
#   2. 自动兼容内核串口 (/dev/ttyUSB0) 与 W152D 用户态桥接串口 (/dev/ttyUSB0 -> /dev/pts/*)：
#      检测到虚拟终端 pty 或无内核驱动的 CH34x (1a86:7522/7523/5523) 时，自动暂停 w152d-usb-serial，
#      通过 Linux usbdevfs 直连 CH34x 硬件控制 DTR/RTS 免按键自动进下载模式、460800 高速烧录并自动重启，
#      结束后自动拉起 w152d-usb-serial 与 micro_ros_agent。
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
  -p, --port <设备>       指定串口设备（如 /dev/ttyUSB0）；默认自动识别内核串口或 CH34x USB 设备
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
  ./upgrade_mcu.sh

  # 使用本地下载好的固件离线升级（支持 W152D 免按键自动烧录）
  ./upgrade_mcu.sh -f ~/leap_ros_mcu_driver-v2.2-esp32s3-app.bin
EOF
}

log_info()  { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn()  { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }

run_root() {
    if [[ $EUID -eq 0 ]]; then
        "$@"
    else
        sudo "$@"
    fi
}

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

if [[ -n "$MIRROR_PREFIX" && "${MIRROR_PREFIX: -1}" != "/" ]]; then
    MIRROR_PREFIX="${MIRROR_PREFIX}/"
fi

# 1. 查找可用的 esptool
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

# 2. 状态记录与退出恢复钩子
STOPPED_SERVICE=""
STOPPED_W152D_AGENT="false"
STOPPED_RAW_CMD=""
STOPPED_BRIDGE_SERVICE=""
STOPPED_BRIDGE_ARGV=()
BRIDGE_SYMLINK_PATH=""
WORK_DIR=""

cleanup() {
    local exit_code=$?
    if [[ -n "$WORK_DIR" && -d "$WORK_DIR" ]]; then
        rm -rf "$WORK_DIR"
    fi

    # 先恢复用户态 USB 转串口桥接服务（如 w152d-usb-serial），再恢复 micro_ros_agent
    if [[ -n "$STOPPED_BRIDGE_SERVICE" ]]; then
        log_info "恢复 USB 串口桥接服务: ${STOPPED_BRIDGE_SERVICE}"
        run_root systemctl start "$STOPPED_BRIDGE_SERVICE" || log_warn "启动 ${STOPPED_BRIDGE_SERVICE} 失败，请手动检查"
        sleep 1
    elif [[ ${#STOPPED_BRIDGE_ARGV[@]} -gt 0 ]]; then
        log_info "恢复后台 USB 串口桥接进程: ${STOPPED_BRIDGE_ARGV[*]}"
        if [[ $EUID -eq 0 ]]; then
            nohup "${STOPPED_BRIDGE_ARGV[@]}" >/dev/null 2>&1 </dev/null &
        else
            sudo sh -c 'nohup "$@" >/dev/null 2>&1 </dev/null &' _ "${STOPPED_BRIDGE_ARGV[@]}"
        fi
        if [[ -n "$BRIDGE_SYMLINK_PATH" ]]; then
            local i
            for ((i = 0; i < 20; i++)); do
                [[ -e "$BRIDGE_SYMLINK_PATH" ]] && break
                sleep 0.1
            done
        fi
    fi

    if [[ "$STOPPED_W152D_AGENT" == "true" ]]; then
        log_info "恢复 W152D micro-ROS Agent 守护进程..."
        run_root /usr/local/sbin/w152d-microros-agent start || log_warn "启动 w152d-microros-agent 失败，请手动检查"
    elif [[ -n "$STOPPED_SERVICE" ]]; then
        log_info "恢复 systemd 服务: ${STOPPED_SERVICE}"
        run_root systemctl start "$STOPPED_SERVICE" || log_warn "启动 ${STOPPED_SERVICE} 失败，请手动检查"
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

detect_ch34x_sysfs() {
    local d vid pid
    for d in /sys/bus/usb/devices/*; do
        [[ -f "${d}/idVendor" && -f "${d}/idProduct" ]] || continue
        vid="$(tr '[:upper:]' '[:lower:]' < "${d}/idVendor")"
        pid="$(tr '[:upper:]' '[:lower:]' < "${d}/idProduct")"
        case "${vid}:${pid}" in
            1a86:7522|1a86:7523|1a86:5523|4348:5523|9986:7523)
                echo "${vid}:${pid}"
                return 0
                ;;
        esac
    done
    return 1
}

if [[ -z "$PORT" ]]; then
    if detected_port="$(detect_agent_port_from_proc)"; then
        PORT="$detected_port"
        log_info "从运行中的 micro_ros_agent 自动识别到下位机串口: ${PORT}"
    fi
fi

# 3. 判断使用内核串口模式还是 Linux usbdevfs CH34x 直连模式
USE_USBDEVFS_CH34X="false"
CH34X_ID=""

if [[ -z "$PORT" ]]; then
    shopt -s nullglob
    CANDIDATES=(/dev/ttyUSB* /dev/ttyACM*)
    shopt -u nullglob
    if [[ ${#CANDIDATES[@]} -eq 1 ]]; then
        PORT="${CANDIDATES[0]}"
        log_info "自动选择唯一串口设备: ${PORT}"
    elif [[ ${#CANDIDATES[@]} -eq 0 ]]; then
        if CH34X_ID="$(detect_ch34x_sysfs)"; then
            USE_USBDEVFS_CH34X="true"
            log_info "检测到未绑定内核串口驱动的 CH34x 设备 (${CH34X_ID})，将使用 USB 直连烧录模式"
        else
            log_error "未检测到 /dev/ttyUSB*、/dev/ttyACM* 或 CH34x USB 设备，请检查 USB 连接或用 -p 指定"
            exit 1
        fi
    else
        log_error "检测到多个串口设备: ${CANDIDATES[*]}"
        log_error "为避免误刷雷达或其他外设，请使用 -p <设备> 明确指定下位机串口"
        exit 1
    fi
fi

if [[ "$USE_USBDEVFS_CH34X" != "true" ]]; then
    if [[ ! -e "$PORT" && ! -L "$PORT" ]]; then
        if CH34X_ID="$(detect_ch34x_sysfs)"; then
            USE_USBDEVFS_CH34X="true"
            log_info "串口节点 ${PORT} 不存在，但检测到 CH34x USB 设备 (${CH34X_ID})，切换为 USB 直连烧录模式"
        else
            log_error "串口设备不存在: ${PORT}"
            exit 1
        fi
    else
        REAL_PORT="$(readlink -f "$PORT" 2>/dev/null || echo "$PORT")"
        if [[ "$REAL_PORT" == /dev/pts/* ]]; then
            if CH34X_ID="$(detect_ch34x_sysfs)"; then
                USE_USBDEVFS_CH34X="true"
                BRIDGE_SYMLINK_PATH="$PORT"
                log_info "检测到 ${PORT} -> ${REAL_PORT} 为用户态虚拟串口，自动启用 CH34x (${CH34X_ID}) USB 硬件直连免按键烧录模式"
            else
                log_error "${PORT} 指向虚拟终端 ${REAL_PORT}，且未发现 CH34x USB 设备，无法执行硬件复位烧录"
                exit 1
            fi
        fi
    fi
fi

# 4. 准备固件文件（本地或从 GitHub Release 下载 + SHA256 校验）
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

    ASSET_META="${WORK_DIR}/asset_meta.txt"
    python3 - "$RELEASE_JSON" "$WANT_SUFFIX" > "$ASSET_META" <<'PY'
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
    readarray -t ASSET_INFO < "$ASSET_META"

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

# 5. 暂停占用串口的 micro_ros_agent 与用户态 USB 串口桥接进程
stop_agent_if_needed() {
    if [[ "$SKIP_AGENT" == "true" ]]; then
        return 0
    fi

    if [[ -x /usr/local/sbin/w152d-microros-agent ]] && /usr/local/sbin/w152d-microros-agent status >/dev/null 2>&1; then
        log_info "暂停 W152D micro-ROS Agent 守护进程..."
        run_root /usr/local/sbin/w152d-microros-agent stop
        STOPPED_W152D_AGENT="true"
        sleep 0.5
        return 0
    fi

    if command -v systemctl >/dev/null 2>&1 && [[ -d /run/systemd/system ]]; then
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
            local active_units
            active_units="$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '/micro[-_]?ros/ {print $1}' || true)"
            local unit
            for unit in $active_units; do
                [[ -n "$unit" ]] && candidates+=("$unit")
            done
        fi

        local svc
        for svc in "${candidates[@]}"; do
            if systemctl is-active --quiet "$svc" 2>/dev/null; then
                log_info "停止正在运行的 systemd 服务: ${svc}"
                run_root systemctl stop "$svc"
                STOPPED_SERVICE="$svc"
                sleep 1
                return 0
            fi
        done
    fi

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

stop_usb_bridge_if_needed() {
    [[ "$USE_USBDEVFS_CH34X" == "true" ]] || return 0

    if command -v systemctl >/dev/null 2>&1; then
        local active_bridge_units
        active_bridge_units="$(systemctl list-units --type=service --state=active --no-legend 2>/dev/null | awk '/usb[-_]?serial|ch34/ {print $1}' || true)"
        local svc
        for svc in $active_bridge_units; do
            if [[ -n "$svc" ]] && systemctl is-active --quiet "$svc" 2>/dev/null; then
                log_info "暂停 USB 串口桥接 systemd 服务: ${svc}"
                run_root systemctl stop "$svc"
                STOPPED_BRIDGE_SERVICE="$svc"
                sleep 0.5
                return 0
            fi
        done
    fi

    local pids
    pids="$(pgrep -f "w152d-usb-serial" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        local first_pid
        first_pid="$(awk '{print $1}' <<<"$pids")"
        if [[ -r "/proc/${first_pid}/cmdline" ]]; then
            STOPPED_BRIDGE_ARGV=()
            while IFS= read -r -d '' arg; do
                STOPPED_BRIDGE_ARGV+=("$arg")
            done < "/proc/${first_pid}/cmdline"
        fi
        log_info "暂停后台 w152d-usb-serial 进程 (PID: ${pids//$'\n'/ }) 以释放 USB 接口..."
        run_root kill $pids 2>/dev/null || true
        local i
        for ((i = 0; i < 20; i++)); do
            pgrep -f "w152d-usb-serial" >/dev/null 2>&1 || break
            sleep 0.1
        done
        if pgrep -f "w152d-usb-serial" >/dev/null 2>&1; then
            run_root kill -9 $pids 2>/dev/null || true
            sleep 0.2
        fi
        if [[ -n "$BRIDGE_SYMLINK_PATH" && -L "$BRIDGE_SYMLINK_PATH" && ! -e "$BRIDGE_SYMLINK_PATH" ]]; then
            run_root rm -f "$BRIDGE_SYMLINK_PATH"
        fi
    fi
}

stop_agent_if_needed
stop_usb_bridge_if_needed

# 6. 执行烧录
if [[ "$USE_USBDEVFS_CH34X" == "true" ]]; then
    log_info "开始通过 USB 直连刷写 CH34x (${CH34X_ID}) -> 波特率: ${BAUD}, 偏移地址: ${FLASH_OFFSET}"
    log_info "固件文件: ${FIRMWARE_BIN}"

    run_root python3 - "$BAUD" "$FLASH_OFFSET" "$FIRMWARE_BIN" <<'PY'
import ctypes
import errno
import fcntl
import glob
import os
import sys
import time

import serial
import esptool
import esptool.reset

baud = sys.argv[1]
flash_offset = sys.argv[2]
firmware_bin = sys.argv[3]

CH34X_IDS = {
    (0x1A86, 0x7522),
    (0x1A86, 0x7523),
    (0x1A86, 0x5523),
    (0x4348, 0x5523),
    (0x9986, 0x7523),
}


class UsbCtrlTransfer(ctypes.Structure):
    _fields_ = [
        ("bRequestType", ctypes.c_uint8),
        ("bRequest", ctypes.c_uint8),
        ("wValue", ctypes.c_uint16),
        ("wIndex", ctypes.c_uint16),
        ("wLength", ctypes.c_uint16),
        ("timeout", ctypes.c_uint32),
        ("data", ctypes.c_void_p),
    ]


class UsbBulkTransfer(ctypes.Structure):
    _fields_ = [
        ("ep", ctypes.c_uint),
        ("len", ctypes.c_uint),
        ("timeout", ctypes.c_uint),
        ("data", ctypes.c_void_p),
    ]


class UsbDisconnectClaim(ctypes.Structure):
    _fields_ = [
        ("interface", ctypes.c_uint),
        ("flags", ctypes.c_uint),
        ("driver", ctypes.c_char * 256),
    ]


def _ioc(dir_, type_, nr, size):
    return (dir_ << 30) | (size << 16) | (ord(type_) << 8) | nr


USBDEVFS_CONTROL = _ioc(3, "U", 0, ctypes.sizeof(UsbCtrlTransfer))
USBDEVFS_BULK = _ioc(3, "U", 2, ctypes.sizeof(UsbBulkTransfer))
USBDEVFS_SETCONFIGURATION = _ioc(2, "U", 5, ctypes.sizeof(ctypes.c_uint))
USBDEVFS_CLAIMINTERFACE = _ioc(2, "U", 15, ctypes.sizeof(ctypes.c_uint))
USBDEVFS_RELEASEINTERFACE = _ioc(2, "U", 16, ctypes.sizeof(ctypes.c_uint))
USBDEVFS_DISCONNECT_CLAIM = _ioc(2, "U", 27, ctypes.sizeof(UsbDisconnectClaim))
USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER = 0x02

CH341_REQ_READ_VERSION = 0x5F
CH341_REQ_WRITE_REG = 0x9A
CH341_REQ_READ_REG = 0x95
CH341_REQ_SERIAL_INIT = 0xA1
CH341_REQ_MODEM_CTRL = 0xA4

CH341_BIT_DTR = 1 << 5
CH341_BIT_RTS = 1 << 6
CH341_LCR_8N1 = 0xC3  # RX + TX + CS8

CLKRATE = 48000000


def _clk_div(ps, fact):
    return 1 << (12 - 3 * ps - fact)


MIN_RATES = [CLKRATE // (_clk_div(ps, 1) * 512) for ps in range(4)]
MIN_BPS = (CLKRATE + _clk_div(0, 0) * 256 - 1) // (_clk_div(0, 0) * 256)
MAX_BPS = CLKRATE // (_clk_div(3, 0) * 2)


def find_ch34x_usb():
    for d in sorted(glob.glob("/sys/bus/usb/devices/*")):
        vid_f = os.path.join(d, "idVendor")
        pid_f = os.path.join(d, "idProduct")
        if not (os.path.isfile(vid_f) and os.path.isfile(pid_f)):
            continue
        vid = int(open(vid_f).read().strip(), 16)
        pid = int(open(pid_f).read().strip(), 16)
        if (vid, pid) not in CH34X_IDS:
            continue
        bus = int(open(os.path.join(d, "busnum")).read().strip())
        dev = int(open(os.path.join(d, "devnum")).read().strip())
        cfg_f = os.path.join(d, "bConfigurationValue")
        cfg_val = open(cfg_f).read().strip() if os.path.isfile(cfg_f) else ""
        ep_in, ep_out = 0x82, 0x02
        for ep_d in sorted(glob.glob(os.path.join(d, "*:1.0", "ep_*"))):
            etype = open(os.path.join(ep_d, "type")).read().strip()
            if etype != "Bulk":
                continue
            addr = int(open(os.path.join(ep_d, "bEndpointAddress")).read().strip(), 16)
            if addr & 0x80:
                ep_in = addr
            else:
                ep_out = addr
        return f"/dev/bus/usb/{bus:03d}/{dev:03d}", cfg_val, ep_in, ep_out
    raise RuntimeError("未找到 CH34x USB 设备 (/sys/bus/usb/devices)")


class Ch34xUsbSerial:
    def __init__(self, url, baudrate=115200, timeout=3.0, **kwargs):
        self.port = url
        self.name = url
        self.timeout = timeout
        self.write_timeout = kwargs.get("write_timeout", 10.0)
        self._baudrate = int(baudrate)
        self._dtr = False
        self._rts = False
        self._rx_buf = bytearray()
        self._usb_rx_buf = ctypes.create_string_buffer(512)
        self._just_reset = False
        self._limited_prescaler = False
        self._version = 0x30

        dev_path, cfg_val, self._ep_in, self._ep_out = find_ch34x_usb()
        self._fd = os.open(dev_path, os.O_RDWR)
        if not cfg_val or cfg_val == "0":
            fcntl.ioctl(self._fd, USBDEVFS_SETCONFIGURATION, ctypes.c_uint(1))
        try:
            dc = UsbDisconnectClaim(0, USBDEVFS_DISCONNECT_CLAIM_EXCEPT_DRIVER, b"usbfs")
            fcntl.ioctl(self._fd, USBDEVFS_DISCONNECT_CLAIM, dc)
        except OSError:
            fcntl.ioctl(self._fd, USBDEVFS_CLAIMINTERFACE, ctypes.c_uint(0))

        self.is_open = True
        self._init_chip()

    def _ctrl_out(self, req, val, idx, timeout_ms=1000):
        ctrl = UsbCtrlTransfer(0x40, req, val & 0xFFFF, idx & 0xFFFF, 0, timeout_ms, None)
        fcntl.ioctl(self._fd, USBDEVFS_CONTROL, ctrl)

    def _ctrl_in(self, req, val, idx, length, timeout_ms=1000):
        buf = ctypes.create_string_buffer(length)
        ctrl = UsbCtrlTransfer(
            0xC0, req, val & 0xFFFF, idx & 0xFFFF, length, timeout_ms, ctypes.addressof(buf)
        )
        n = fcntl.ioctl(self._fd, USBDEVFS_CONTROL, ctrl)
        return buf.raw[:n]

    def _init_chip(self):
        ver = self._ctrl_in(CH341_REQ_READ_VERSION, 0, 0, 2)
        if ver:
            self._version = ver[0]
        try:
            self._ctrl_in(CH341_REQ_READ_REG, 0x0005, 0, 2)
        except OSError as e:
            if e.errno == errno.EPIPE:
                self._limited_prescaler = True
        self._ctrl_out(CH341_REQ_SERIAL_INIT, 0, 0)
        self._apply_baudrate(self._baudrate)
        self.set_dtr_rts(self._dtr, self._rts)
        # Disable hardware flow control
        try:
            self._ctrl_out(CH341_REQ_WRITE_REG, 0x2727, 0x0000)
        except OSError:
            pass

    def _calc_divisor(self, speed):
        speed = max(MIN_BPS, min(MAX_BPS, int(speed)))
        fact = 1
        ps = -1
        for p in (3, 2, 1, 0):
            if speed > MIN_RATES[p]:
                ps = p
                break
        if ps < 0:
            raise IOError(f"Unsupported baud rate: {speed}")
        cdiv = _clk_div(ps, fact)
        div = CLKRATE // (cdiv * speed)
        if div < 9 or div > 255 or (ps < 3 and self._limited_prescaler):
            div //= 2
            cdiv *= 2
            fact = 0
        if div < 2:
            raise IOError(f"Invalid divisor for baud rate: {speed}")
        if 16 * CLKRATE // (cdiv * div) - 16 * speed >= 16 * speed - 16 * CLKRATE // (cdiv * (div + 1)):
            div += 1
        if fact == 1 and div % 2 == 0:
            div //= 2
            fact = 0
        val = ((0x100 - div) << 8) | (fact << 2) | ps
        if self._version > 0x27:
            val |= 0x80
        return val

    def _apply_baudrate(self, speed):
        val = self._calc_divisor(speed)
        self._ctrl_out(CH341_REQ_WRITE_REG, 0x1312, val)
        if self._version >= 0x30:
            self._ctrl_out(CH341_REQ_WRITE_REG, 0x2518, CH341_LCR_8N1)

    @property
    def baudrate(self):
        return self._baudrate

    @baudrate.setter
    def baudrate(self, value):
        value = int(value)
        self._apply_baudrate(value)
        self._baudrate = value

    @property
    def dtr(self):
        return self._dtr

    @dtr.setter
    def dtr(self, value):
        self.setDTR(value)

    @property
    def rts(self):
        return self._rts

    @rts.setter
    def rts(self, value):
        self.setRTS(value)

    def setDTR(self, value):
        self.set_dtr_rts(bool(value), self._rts)

    def setRTS(self, value):
        self.set_dtr_rts(self._dtr, bool(value))

    def set_dtr_rts(self, dtr, rts):
        self._dtr = bool(dtr)
        self._rts = bool(rts)
        mcr = (CH341_BIT_DTR if self._dtr else 0) | (CH341_BIT_RTS if self._rts else 0)
        self._ctrl_out(CH341_REQ_MODEM_CTRL, (~mcr) & 0xFFFF, 0)
        self._just_reset = True

    def _poll_rx(self, timeout_ms):
        bulk = UsbBulkTransfer(
            self._ep_in,
            len(self._usb_rx_buf),
            max(1, int(timeout_ms)),
            ctypes.addressof(self._usb_rx_buf),
        )
        try:
            n = fcntl.ioctl(self._fd, USBDEVFS_BULK, bulk)
        except OSError as e:
            if e.errno in (errno.ETIMEDOUT, errno.EAGAIN, errno.EINTR):
                return 0
            raise
        if n > 0:
            self._rx_buf.extend(self._usb_rx_buf.raw[:n])
        return n

    @property
    def in_waiting(self):
        if not self._rx_buf and self._just_reset:
            self._just_reset = False
            self._poll_rx(15)
        return len(self._rx_buf)

    def inWaiting(self):
        return self.in_waiting

    def reset_input_buffer(self):
        self._rx_buf.clear()
        for _ in range(16):
            if self._poll_rx(5) == 0:
                break
        self._rx_buf.clear()

    def flushInput(self):
        self.reset_input_buffer()

    def reset_output_buffer(self):
        pass

    def flushOutput(self):
        pass

    def flush(self):
        pass

    def read(self, size=1):
        if size <= 0:
            return b""
        if self.timeout is None:
            deadline = None
        elif self.timeout == 0:
            deadline = time.monotonic()
        else:
            deadline = time.monotonic() + float(self.timeout)

        while len(self._rx_buf) < size:
            if deadline is not None:
                rem = deadline - time.monotonic()
                if rem <= 0:
                    break
                wait_ms = max(2, min(50, int(rem * 1000)))
            else:
                wait_ms = 50
            got = self._poll_rx(wait_ms)
            if self.timeout == 0 and got == 0:
                break

        out = bytes(self._rx_buf[:size])
        del self._rx_buf[:size]
        return out

    def write(self, data):
        buf = bytes(data)
        total = len(buf)
        timeout_ms = int((self.write_timeout or 10.0) * 1000)
        offset = 0
        while offset < total:
            chunk = buf[offset : offset + 512]
            cbuf = ctypes.create_string_buffer(chunk, len(chunk))
            bulk = UsbBulkTransfer(self._ep_out, len(chunk), timeout_ms, ctypes.addressof(cbuf))
            sent = fcntl.ioctl(self._fd, USBDEVFS_BULK, bulk)
            if sent <= 0:
                raise serial.SerialTimeoutException("CH34x USB bulk write timeout")
            offset += sent
        return total

    def close(self):
        if getattr(self, "_fd", -1) >= 0:
            try:
                fcntl.ioctl(self._fd, USBDEVFS_RELEASEINTERFACE, ctypes.c_uint(0))
            except OSError:
                pass
            os.close(self._fd)
            self._fd = -1
        self.is_open = False


_active_ports = []
_orig_serial_for_url = serial.serial_for_url
_orig_set_dtr_rts = esptool.reset.ResetStrategy._setDTRandRTS


def _patched_serial_for_url(url, *args, **kwargs):
    if isinstance(url, str) and url.startswith("ch34x://"):
        inst = Ch34xUsbSerial(url, *args, **kwargs)
        _active_ports.append(inst)
        return inst
    return _orig_serial_for_url(url, *args, **kwargs)


def _patched_set_dtr_rts(self, dtr=False, rts=False):
    if hasattr(self.port, "set_dtr_rts"):
        self.port.set_dtr_rts(dtr, rts)
    else:
        _orig_set_dtr_rts(self, dtr, rts)


serial.serial_for_url = _patched_serial_for_url
esptool.reset.ResetStrategy._setDTRandRTS = _patched_set_dtr_rts

try:
    esptool.main(
        [
            "--chip",
            "esp32s3",
            "--port",
            "ch34x://auto",
            "--baud",
            str(baud),
            "write_flash",
            "-z",
            flash_offset,
            firmware_bin,
        ]
    )
finally:
    for p in _active_ports:
        p.close()
PY
else
    log_info "开始刷写固件 -> 端口: ${PORT}, 波特率: ${BAUD}, 偏移地址: ${FLASH_OFFSET}"
    log_info "固件文件: ${FIRMWARE_BIN}"

    FLASH_CMD=("${ESPTOOL_CMD[@]}" --chip esp32s3 --port "$PORT" --baud "$BAUD" write_flash -z "$FLASH_OFFSET" "$FIRMWARE_BIN")
    if [[ -w "$PORT" ]]; then
        "${FLASH_CMD[@]}"
    else
        log_info "当前用户无 ${PORT} 写权限，使用 sudo 执行烧录..."
        sudo "${FLASH_CMD[@]}"
    fi
fi

log_info "下位机固件升级完成！"
