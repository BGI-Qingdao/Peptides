#!/bin/bash

# ============================================================
# AlphaFold 3 Pipeline Controller
# Author: chunming
# Version: v1.0
# Date: 2026-01-14
# 
# Features:
#   - CPU/GPU stage separation with auto mode
#   - Breakpoint resume (skip processed CPU jobs)
#   - Per-job CPU/GPU time tracking
#   - Standardized output directories (_msa, _af3out, _pipeline)
#   - Queue-based coordination between CPU and GPU stages
# ============================================================

set -e

# === 内置配置 ===
source af_rosetta_config.txt
# === 日志函数 ===
log_info() { echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') $1"; }
log_error() { echo "[ERROR] $(date '+%Y-%m-%d %H:%M:%S') $1" >&2; }
log_time() { echo "[TIME] $(date '+%Y-%m-%d %H:%M:%S') $1"; }

usage() {
    cat <<EOF
AlphaFold 3 Pipeline Controller (v1.0)
Author: chunming
Date: 2026-01-14

Usage: $0 [--cpu_only|--gpu_only|--auto] --input_dir <dir> [--gpu_device <id>]

Options:
  --cpu_only        Run only the CPU data pipeline stage (MSA generation)
  --gpu_only        Run only the GPU inference stage (structure prediction)
  --auto            Run both CPU and GPU stages in parallel (default workflow)
  --input_dir DIR   Input directory containing .json job files (required for CPU/auto)
  --gpu_device ID   GPU device ID to use (default: 0). Note: script uses CUDA_VISIBLE_DEVICES internally.

Output Directories (created under parent of input_dir):
  _msa/           MSA-processed JSON files
  _af3out/        Final AlphaFold 3 prediction results
  _pipeline/      Internal control files (queue, status, timing)

Breakpoint Resume:
  The script skips already processed CPU jobs by checking _pipeline/_status.txt.
  Timing stats are saved to _pipeline/timing_summary.csv.

Example:
  $0 --auto --input_dir /data/proteins --gpu_device 2

EOF
    exit 1
}

# === 参数解析 ===
MODE=""
INPUT_DIR=""
GPU_DEVICE="0"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --cpu_only) MODE="cpu"; shift ;;
        --gpu_only) MODE="gpu"; shift ;;
        --auto) MODE="auto"; shift ;;
        --input_dir) INPUT_DIR="$2"; shift 2 ;;
        --gpu_device) GPU_DEVICE="$2"; shift 2 ;;
        -h|--help) usage ;;
        *) log_error "Unknown option: $1"; usage ;;
    esac
done

if [[ "$MODE" == "cpu" || "$MODE" == "auto" ]]; then
    if [[ -z "$INPUT_DIR" || ! -d "$INPUT_DIR" ]]; then
        log_error "--input_dir must be a valid directory"
        usage
    fi
    INPUT_DIR=$(realpath "$INPUT_DIR")
fi

# === 目录结构 ===
PARENT_DIR=$(dirname "$INPUT_DIR")

MSA_DIR="$PARENT_DIR/_msa"
AF3OUT_DIR="$PARENT_DIR/_af3out"
PIPELINE_DIR="$PARENT_DIR/_pipeline"

mkdir -p "$MSA_DIR" "$AF3OUT_DIR" "$PIPELINE_DIR"

# === 控制文件（无锁）===
QUEUE_FILE="$PIPELINE_DIR/_queue.txt"
CPU_RUNNING_FLAG="$PIPELINE_DIR/cpu_running.flag"

# === 新增：状态与时间统计文件（放在 INPUT_DIR 中）===
STATUS_FILE="$PIPELINE_DIR/_status.txt"
TIMING_FILE="$PIPELINE_DIR/timing_summary.csv"

# 初始化 timing 文件（如果不存在）
if [[ ! -f "$TIMING_FILE" ]]; then
    echo "job_name,cpu_seconds,gpu_seconds,status" > "$TIMING_FILE"
fi

# 确保 STATUS_FILE 存在
touch "$STATUS_FILE"

# === 辅助函数：记录时间 ===
record_timing() {
    local job="$1"
    local cpu_sec="$2"
    local gpu_sec="$3"
    local status="$4"

    # 如果已有该 job 行，则更新；否则追加
    if grep -q "^${job}," "$TIMING_FILE"; then
        # 使用 awk 更新对应字段
        awk -F, -v job="$job" -v cpu="$cpu_sec" -v gpu="$gpu_sec" -v st="$status" '
            BEGIN { OFS = "," }
            $1 == job {
                if (cpu != "") $2 = cpu;
                if (gpu != "") $3 = gpu;
                $4 = st;
            }
            { print }
        ' "$TIMING_FILE" > "${TIMING_FILE}.tmp" && mv "${TIMING_FILE}.tmp" "$TIMING_FILE"
    else
        echo "$job,$cpu_sec,$gpu_sec,$status" >> "$TIMING_FILE"
    fi
}

# === CPU 阶段：支持断点续算 + 时间记录 ===
run_cpu_stage() {
    log_info "Starting CPU stage on input dir: $INPUT_DIR"

    TEMP_JSON_LIST=$(mktemp)
    find "$INPUT_DIR" -maxdepth 1 -type f -name "*.json" > "$TEMP_JSON_LIST"
    total=$(wc -l < "$TEMP_JSON_LIST")
    log_info "Found $total JSON files to process."

    > "$QUEUE_FILE"
    touch "$CPU_RUNNING_FLAG"

    while IFS= read -r json_path; do
        [[ -z "$json_path" ]] && continue

        base_name=$(basename "$json_path" .json)

        # === 断点检查：跳过已完成 CPU 的任务 ===
        if grep -q "^${base_name} cpu_done$" "$STATUS_FILE"; then
            log_info "Skipping (already done): $base_name"
            # 重新加入队列（防止 GPU 没跑）
            TARGET_JSON="$MSA_DIR/${base_name}_msa.json"
            if [[ -f "$TARGET_JSON" ]]; then
                echo "$TARGET_JSON" >> "$QUEUE_FILE"
            fi
            continue
        fi

        log_info "Processing (CPU): $base_name"

        LOG_FILE="$MSA_DIR/${base_name}.cpu.log"

        CMD=(
            python run_alphafold.py
            --json_path="$json_path"
            --output_dir="$INPUT_DIR"
            --run_data_pipeline=True
            --run_inference=False
            --db_dir="$DB_DIR"
        )

        start_time=$(date +%s)
        if "${CMD[@]}" > "$LOG_FILE" 2>&1; then
            end_time=$(date +%s)
            duration=$((end_time - start_time))
            log_time "CPU finished $base_name in ${duration}s (log: $LOG_FILE)"

            # 提取完整 JSON 路径
            FULL_JSON_PATH=$(grep -oP 'Writing model input JSON to \K.*\.json' "$LOG_FILE" | head -n1)

            if [[ -n "$FULL_JSON_PATH" && -f "$FULL_JSON_PATH" ]]; then
                TARGET_JSON="$MSA_DIR/${base_name}_msa.json"
                mv "$FULL_JSON_PATH" "$TARGET_JSON"
                rmdir "$(dirname "$FULL_JSON_PATH")" 2>/dev/null || true

                log_info "Moved MSA result to: $TARGET_JSON"

                # 记录状态和时间
                echo "$base_name cpu_done" >> "$STATUS_FILE"
                record_timing "$base_name" "$duration" "" "cpu_done"

                # 加入队列
                echo "$TARGET_JSON" >> "$QUEUE_FILE"
            else
                log_error "Failed to extract JSON path from log: $LOG_FILE"
            fi
        else
            log_error "CPU failed for $base_name (see $LOG_FILE)"
        fi
    done < "$TEMP_JSON_LIST"

    rm -f "$TEMP_JSON_LIST"
    rm -f "$CPU_RUNNING_FLAG"
    log_info "CPU stage completed."
}

# === GPU 阶段：记录 GPU 时间 ===
run_gpu_stage() {
    log_info "Starting GPU stage (device: $GPU_DEVICE)"

    waiting_message_shown=false

    while true; do
        if [[ -s "$QUEUE_FILE" ]]; then
            waiting_message_shown=false

            first_line=$(head -n1 "$QUEUE_FILE")
            if [[ -n "$first_line" && -f "$first_line" ]]; then
                base_name=$(basename "$first_line" _msa.json)
                log_info "Processing (GPU): $base_name"

                LOG_FILE="$AF3OUT_DIR/${base_name}.gpu.log"
                OUTPUT_JSON="$AF3OUT_DIR/${base_name}_af3.json"

                CMD=(
                    python run_alphafold.py
                    --json_path="$first_line"
                    --output_dir="$AF3OUT_DIR"
                    --run_data_pipeline=False
                    --run_inference=True
                    --model_dir="$MODEL_DIR"
                    --gpu_device="$GPU_DEVICE"
                )

                start_time=$(date +%s)
                if "${CMD[@]}" > "$LOG_FILE" 2>&1; then
                    end_time=$(date +%s)
                    duration=$((end_time - start_time))
                    log_time "GPU finished $base_name in ${duration}s (log: $LOG_FILE)"

                    latest_out=$(find "$AF3OUT_DIR" -maxdepth 1 -type d -name "20[0-9][0-9]-[0-1][0-9]-[0-3][0-9]_[0-2][0-9][0-5][0-9]" | sort | tail -n1)
                    if [[ -n "$latest_out" ]]; then
                        result_json=$(find "$latest_out" -name "*.json" | head -n1)
                        if [[ -f "$result_json" ]]; then
                            mv "$result_json" "$OUTPUT_JSON"
                            rmdir "$latest_out" 2>/dev/null || true
                            log_info "Final result saved to: $OUTPUT_JSON"
                        fi
                    fi

                    # 记录 GPU 时间和状态
                    record_timing "$base_name" "" "$duration" "gpu_done"

                    # 更新队列
                    if [[ $(wc -l < "$QUEUE_FILE") -eq 1 ]]; then
                        > "$QUEUE_FILE"
                    else
                        tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
                    fi
                else
                    log_error "GPU failed for $base_name (see $LOG_FILE)"
                    record_timing "$base_name" "" "" "gpu_failed"

                    if [[ $(wc -l < "$QUEUE_FILE") -eq 1 ]]; then
                        > "$QUEUE_FILE"
                    else
                        tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
                    fi
                fi
            else
                # 清理无效行
                if [[ $(wc -l < "$QUEUE_FILE") -eq 1 ]]; then
                    > "$QUEUE_FILE"
                else
                    tail -n +2 "$QUEUE_FILE" > "$QUEUE_FILE.tmp" && mv "$QUEUE_FILE.tmp" "$QUEUE_FILE"
                fi
            fi
        else
            if [[ ! -f "$CPU_RUNNING_FLAG" ]]; then
                log_info "Queue empty and CPU finished. GPU stage exiting."
                break
            else
                if [[ "$waiting_message_shown" == false ]]; then
                    log_info "Queue is empty. Waiting for CPU to produce MSA files..."
                    waiting_message_shown=true
                fi
                sleep 60
            fi
        fi
    done
}

# === 主逻辑 ===
case "$MODE" in
    cpu)   run_cpu_stage ;;
    gpu)   run_gpu_stage ;;
    auto)
        log_info "Launching CPU and GPU stages in parallel..."
        run_cpu_stage &
        CPU_PID=$!
        sleep 5
        run_gpu_stage
        wait $CPU_PID
        log_info "Pipeline completed. Timing summary: $TIMING_FILE"
        ;;
    *)
        log_error "Mode not specified"
        usage
        ;;
esac
