#!/bin/bash

# Requirement: 2x GPUs.

# 需要在vllm-mooncake容器中运行；
# 启动容器：docker run -itd --gpus all --network host -v /home/deepseek/lxcheng:/root/data --ipc=host --device=/dev/infiniband/uverbs0 --device=/dev/infiniband/rdma_cm --ulimit memlock=-1 --name mooncake-rdma mooncake-rdma:v2 

# 容器中→先启动etcd服务：（脚本已集成）
# etcd --listen-client-urls http://0.0.0.0:2800 --advertise-client-urls http://localhost:2800 --debug
# 再启动mooncake_master server：
# mooncake_master --port 50001

#------------------------- 常用配置参数 --------------------------
# 控制测试服务类型: 1=MCK_disagg_prefill, 0=chunked_prefill
TEST_SERVICE_TYPE=0

# Model path
MODEL_PATH="/root/data/AItrans/SakuraLLM.Sakura-14B-Qwen2.5-v1.0"
# MODEL_PATH="/root/data/AItrans/DeepSeek-V2-Lite"

# Max-model-length for (Original) disaggregated prefill
MAX_MODEL_LEN=20000

# GPU configurations for MCK disaggregated prefill
MCK_PREFILL_GPU="2"  # GPU for prefill (producer)
MCK_DECODE_GPU="3"   # GPU for decode (consumer)

# Benchmark parameters
QPS_VALUES=(inf)
NUM_PROMPTS_VALUES=(20)
# input-len尽管被配置，但可能不再有意义，因为使用了shareGPT数据集;
INPUT_LEN_VALUES=(128 256 512 1024 2048 4096 8192 16384)
OUTPUT_LEN_VALUES=(256)
PREFIX_LEN_VALUES=(24)

# ------------Goodput configuration parameters--------------
# 每个数组元素表示一组goodput参数
# 设置为空字符串表示不使用goodput参数
# Goodput参数配置（单位，ms）
GOODPUT_TTFT=60000          # 固定的TTFT值
GOODPUT_TPOT_START=45       # TPOT起始值
GOODPUT_TPOT_STEP=3        # TPOT步长
GOODPUT_TPOT_COUNT=10       # 生成的TPOT参数个数

# 自动生成GOODPUT_CONFIGS数组
GOODPUT_CONFIGS=()
for ((i=0; i<GOODPUT_TPOT_COUNT; i++)); do
  tpot_value=$((GOODPUT_TPOT_START + i * GOODPUT_TPOT_STEP))
  GOODPUT_CONFIGS+=("ttft:${GOODPUT_TTFT} tpot:${tpot_value}")
done

# 如果需要包含使用goodput的情况，注释下一行
GOODPUT_CONFIGS=("")

echo "Generated GOODPUT_CONFIGS: ${GOODPUT_CONFIGS[@]}"
#-----------------------------------------------------------------

set -e

get_memory_info() {
  # Get GPU memory usage - properly formatted as JSON array
  gpu_array="["
  while IFS=, read -r gpu_id mem_used mem_total util; do
    if [ -n "$gpu_id" ]; then
      # Add comma if not first entry
      if [ "$gpu_array" != "[" ]; then
        gpu_array+=","
      fi
      gpu_array+="{\"gpu_id\":$gpu_id,\"memory_used_mb\":$mem_used,\"memory_total_mb\":$mem_total,\"utilization_percent\":$util}"
    fi
  done < <(nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits)
  gpu_array+="]"
  
  # Get system memory usage
  mem_info=$(free -m | grep Mem)
  mem_total=$(echo $mem_info | awk '{print $2}')
  mem_used=$(echo $mem_info | awk '{print $3}')
  mem_usage_percent=$(awk "BEGIN {printf \"%.2f\", ($mem_used/$mem_total)*100}")
  
  # Format as valid JSON
  echo "{\"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"gpu_info\": $gpu_array, \"memory_total_mb\": $mem_total, \"memory_used_mb\": $mem_used, \"memory_usage_percent\": $mem_usage_percent}"
}

get_memory_info_for_gpus() {
  local gpu_ids=$1
  local gpu_id_list=(${gpu_ids//,/ })
  
  # Get GPU memory usage - properly formatted as JSON array
  gpu_array="["
  while IFS=, read -r gpu_id mem_used mem_total util; do
    if [ -n "$gpu_id" ]; then
      # Check if this GPU should be included
      include_gpu=0
      for id in "${gpu_id_list[@]}"; do
        if [ "$gpu_id" = "$id" ]; then
          include_gpu=1
          break
        fi
      done
      
      if [ "$include_gpu" = "1" ]; then
        # Add comma if not first entry
        if [ "$gpu_array" != "[" ]; then
          gpu_array+=","
        fi
        gpu_array+="{\"gpu_id\":$gpu_id,\"memory_used_mb\":$mem_used,\"memory_total_mb\":$mem_total,\"utilization_percent\":$util}"
      fi
    fi
  done < <(nvidia-smi --query-gpu=index,memory.used,memory.total,utilization.gpu --format=csv,noheader,nounits)
  gpu_array+="]"
  
  # Get system memory usage
  mem_info=$(free -m | grep Mem)
  mem_total=$(echo $mem_info | awk '{print $2}')
  mem_used=$(echo $mem_info | awk '{print $3}')
  mem_usage_percent=$(awk "BEGIN {printf \"%.2f\", ($mem_used/$mem_total)*100}")
  
  # Format as valid JSON
  echo "{\"timestamp\": \"$(date '+%Y-%m-%d %H:%M:%S')\", \"gpu_info\": $gpu_array, \"memory_total_mb\": $mem_total, \"memory_used_mb\": $mem_used, \"memory_usage_percent\": $mem_usage_percent}"
}

log_error() {
  echo "[ERROR] $(date) - $1" >> error_log.txt
}

retry_function() {
  # Retry a function a maximum number of times (default 3)
  local retries=3
  local count=0
  local wait_time=5
  local func=$1
  shift
  while [ $count -lt $retries ]; do
    "$func" "$@" && return 0
    count=$((count + 1))
    log_error "Retry $count for $func failed. Waiting for $wait_time seconds..."
    sleep $wait_time
  done
  log_error "Function $func failed after $retries attempts."
  return 1
}

kill_gpu_processes() {
  # kill all processes on GPU.
  # pgrep pt_main_thread | xargs -r kill -9
  # pgrep python3 | xargs -r kill -9
  for port in 7100 7200 7000 7070 8100 8200 8000 2800 50001; do 
    lsof -t -i:$port | xargs -r kill -9; 
  done
  sleep 1
}

wait_for_server() {
  # wait for vllm server to start
  # return 1 if vllm server crashes
  local port=$1
  timeout 1200 bash -c "
    until curl -s localhost:${port}/v1/completions > /dev/null; do
      sleep 1
    done" && return 0 || return 1
}

start_etcd_and_mooncake() {
  local force_restart=${1:-false}  # Optional parameter to force restart
  echo "[$(date)] Starting etcd and mooncake_master services..."
  
  # Handle etcd service
  if lsof -i:2800 > /dev/null 2>&1; then
    if [ "$force_restart" = true ]; then
      echo "Force restarting etcd service..."
      lsof -t -i:2800 | xargs -r kill -9
      sleep 2
      echo "Starting new etcd service..."
      etcd --listen-client-urls http://0.0.0.0:2800 --advertise-client-urls http://localhost:2800 --debug > ./results/etcd.log 2>&1 &
      sleep 2
    else
      echo "etcd is already running on port 2800"
    fi
  else
    echo "Starting etcd service..."
    etcd --listen-client-urls http://0.0.0.0:2800 --advertise-client-urls http://localhost:2800 --debug > ./results/etcd.log 2>&1 &
    sleep 2
  fi
  
  # Handle mooncake_master service
  if lsof -i:50001 > /dev/null 2>&1; then
    if [ "$force_restart" = true ]; then
      echo "Force restarting mooncake_master service..."
      lsof -t -i:50001 | xargs -r kill -9
      sleep 2
      echo "Starting new mooncake_master server..."
      mooncake_master --port 50001 > ./results/mooncake_master.log 2>&1 &
      sleep 2
    else
      echo "mooncake_master is already running on port 50001"
    fi
  else
    echo "Starting mooncake_master server..."
    mooncake_master -v=1 --port 50001 > ./results/mooncake_master.log 2>&1 &
    sleep 2
  fi
  
  # Verify services are running
  if ! lsof -i:2800 > /dev/null 2>&1; then
    log_error "Failed to start etcd service on port 2800"
    return 1
  fi
  
  if ! lsof -i:50001 > /dev/null 2>&1; then
    log_error "Failed to start mooncake_master service on port 50001"
    return 1
  fi
  
  echo "[$(date)] etcd and mooncake_master services started successfully"
  return 0
}

launch_chunked_prefill() {
  # Launch servers with chunked prefill
  # GPU 使用与MCK一致

  echo "[$(date)] Launching chunked prefill servers..."

  CUDA_VISIBLE_DEVICES=$MCK_PREFILL_GPU VLLM_USE_V1=0 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $MODEL_PATH \
    --port 8100 \
    --max-model-len $MAX_MODEL_LEN \
    --enable-chunked-prefill \
    --gpu-memory-utilization 0.9 \
    --trust_remote_code &

  CUDA_VISIBLE_DEVICES=$MCK_DECODE_GPU VLLM_USE_V1=0 python3 \
    -m vllm.entrypoints.openai.api_server \
    --model $MODEL_PATH \
    --port 8200 \
    --max-model-len $MAX_MODEL_LEN \
    --enable-chunked-prefill \
    --gpu-memory-utilization 0.9 \
    --trust_remote_code &

  if ! wait_for_server 8100; then
    log_error "Server on port 8300 failed to start."
    return 1
  fi
  if ! wait_for_server 8200; then
    log_error "Server on port 8400 failed to start."
    return 1
  fi

  python3 round_robin_proxy.py &  # 假设该代理监听8000
  sleep 1

  echo "[$(date)] Chunked prefill servers launched successfully."
  echo "[$(date)] Proxy server launched on port 8000."
}

# # 拉起原始PD分离
# launch_disagg_prefill() {
#   # 使用配置中的 MAX_MODEL_LEN 值
#   local max_model_len=$MAX_MODEL_LEN
  
#   # Launch servers with disaggregated prefill
#   CUDA_VISIBLE_DEVICES=0 python3 \
#     -m vllm.entrypoints.openai.api_server \
#     --model $MODEL_PATH \
#     --port 8100 \
#     --gpu-memory-utilization 0.8 \
#     --trust_remote_code \
#     --enforce-eager \
#     --max-model-len $max_model_len \
#     --swap-space 0 \
#     --no-enable-prefix-caching \
#     --kv-transfer-config \
#     '{"kv_connector":"PyNcclConnector","kv_role":"kv_producer","kv_rank":0,"kv_parallel_size":2,"kv_buffer_size":5e9}' &

#   CUDA_VISIBLE_DEVICES=1 python3 \
#     -m vllm.entrypoints.openai.api_server \
#     --model $MODEL_PATH \
#     --port 8200 \
#     --gpu-memory-utilization 0.9 \
#     --trust_remote_code \
#     --enforce-eager \
#     --max-model-len $max_model_len \
#     --swap-space 0 \
#     --kv-transfer-config \
#     '{"kv_connector":"PyNcclConnector","kv_role":"kv_consumer","kv_rank":1,"kv_parallel_size":2,"kv_buffer_size":5e9}' &

#   if ! wait_for_server 8100; then
#     log_error "Server on port 8100 failed to start."
#     return 1
#   fi
#   if ! wait_for_server 8200; then
#     log_error "Server on port 8200 failed to start."
#     return 1
#   fi

#   python3 disagg_prefill_proxy_server.py &  # 假设该代理监听8000
#   sleep 1
# }

# 拉起基于Mooncake的PD分离
launch_MCK_disagg_prefill() {

  echo "[$(date)] Launching MCK disaggregated prefill servers..."

  # 使用配置中的 MAX_MODEL_LEN 值
  local max_model_len=$MAX_MODEL_LEN
  
  # 创建日志目录
  mkdir -p ./results/mooncake-log
  
  # 启动两个vllm；启动代理。
  
  # Launch the producer server；使用 GLOG_v=1可检测分片处理情况；测试DS模型，VLLM_MLA_DISABLE=0
  VLLM_LOGGING_LEVEL="DEBUG" CUDA_VISIBLE_DEVICES=$MCK_PREFILL_GPU MOONCAKE_CONFIG_PATH=/root/data/mooncake-local.json VLLM_USE_V1=0 \
  MTDS_USE_EXPERIMENTAL=True MTDS_TRACK_USAGE=false MTDS_CONFIG_FILE=/root/data/MTDS-local.yaml MTDS_REMOTE_SERDE=$MTDS_REMOTE_SERDE \
    python3 -m vllm.entrypoints.openai.api_server \
    --model $MODEL_PATH \
    --port 7100 \
    --max-model-len $max_model_len \
    --gpu-memory-utilization 0.8 \
    --trust_remote_code \
    --kv-transfer-config \
    '{"kv_connector":"MTDSConnector","kv_role":"kv_producer"}' 2>&1 | \
    grep -v -E "prompt\"|prompt_token_ids" > ./results/mooncake-log/prefill_7100.log &

  # Launch the consumer server
  VLLM_LOGGING_LEVEL="DEBUG" CUDA_VISIBLE_DEVICES=$MCK_DECODE_GPU MOONCAKE_CONFIG_PATH=/root/data/mooncake-local.json VLLM_USE_V1=0 \
  MTDS_USE_EXPERIMENTAL=True MTDS_TRACK_USAGE=false MTDS_CONFIG_FILE=/root/data/MTDS-local.yaml MTDS_REMOTE_SERDE=$MTDS_REMOTE_SERDE \
    python3 -m vllm.entrypoints.openai.api_server \
    --model $MODEL_PATH \
    --port 7200 \
    --max-model-len $max_model_len \
    --gpu-memory-utilization 0.8 \
    --trust_remote_code \
    --kv-transfer-config \
    '{"kv_connector":"MTDSConnector","kv_role":"kv_consumer"}' 2>&1 | \
    grep -v -E "prompt\"|prompt_token_ids" > ./results/mooncake-log/decode_7200.log &

  if ! wait_for_server 7100; then
    log_error "Server on port 7100 failed to start."
    return 1
  fi
  if ! wait_for_server 7200; then
    log_error "Server on port 7200 failed to start."
    return 1
  fi
  
  # Launch the proxy server
  python3 /root/data/disagg_proxy_demo.py \
    --model $MODEL_PATH \
    --prefill 127.0.0.1:7100 \
    --decode 127.0.0.1:7200 \
    --port 7000 \
    > ./results/mooncake-log/proxy_7000.log 2>&1 &
  sleep 1

  echo "[$(date)] MCK disaggregated prefill servers launched successfully."
  echo "[$(date)] Proxy server launched on port 7000."

}

benchmark() {
  results_folder="./results"
  qps=$1
  num_prompts=$2
  input_len=$3
  output_len=$4
  prefix_len=$5
  tag=$6
  proxy_port=$7
  goodput_config=$8  # 新增goodput参数
  
  # Track relevant GPUs based on benchmark type
  if [ "$tag" = "MCK_disagg_prefill" ]; then
    relevant_gpus="2,3"  # Track GPU 2 and 3 for MCK_disagg_prefill
  elif [ "$tag" = "O_disagg_prefill" ]; then
    relevant_gpus="0,1"  # Track GPU 0 and 1 for O_disagg_prefill
  else
    relevant_gpus="0,1,2,3"  # Track all GPUs for other benchmarks
  fi
  
  # Capture memory info before benchmark - only for relevant GPUs
  pre_benchmark_mem=$(get_memory_info_for_gpus "$relevant_gpus")
  
  # 构建goodput标识符用于文件名
  goodput_suffix=""
  if [ -n "$goodput_config" ]; then
    goodput_suffix="_goodput_$(echo "$goodput_config" | tr ' :' '_-')"
  fi
  
  echo "[$(date)] Starting benchmark: $tag (GPUs: $relevant_gpus) with qps=$qps, num_prompts=$num_prompts, input_len=$input_len, output_len=$output_len, prefix_len=$prefix_len, goodput=$goodput_config"
  
  # 创建临时文件来捕获输出
  log_file="./results/log_${tag}_qps${qps}_prompts${num_prompts}_in${input_len}_out${output_len}_prefix${prefix_len}${goodput_suffix}.txt"
  
  # 构建goodput参数
  goodput_args=""
  if [ -n "$goodput_config" ]; then
    # 将多个goodput参数正确传递给benchmark脚本
    goodput_args="--goodput $goodput_config"
  fi
  
  # 运行 benchmark 并捕获输出
  # 使用shareGPT 需要移除以下sonnet参数：
    # --sonnet-input-len $input_len \
    # --sonnet-output-len $output_len \
    # --sonnet-prefix-len $prefix_len \

  python3 ../benchmark_serving.py \
    --backend vllm \
    --model $MODEL_PATH \
    --dataset-name "sonnet" \
    --dataset-path "../sonnet_4x.txt" \
    --sonnet-input-len $input_len \
    --sonnet-output-len $output_len \
    --sonnet-prefix-len $prefix_len \
    --num-prompts $num_prompts \
    --port $proxy_port \
    --save-result \
    --result-dir ./results/ \
    --seed 50 \
    --result-filename "$tag"-qps-"$qps"-num_prompts-"$num_prompts"-input_len-"$input_len"-output_len-"$output_len"-prefix_len-"$prefix_len"${goodput_suffix}.json \
    --request-rate "$qps" \
    $goodput_args 2>&1 | tee "$log_file" || {
    log_error "Benchmark failed for qps$qps batch$num_prompts input$input_len output$output_len prefix$prefix_len goodput[$goodput_config] with $tag"
    return 1
  }
  
  # 捕获内存信息
  post_benchmark_mem=$(get_memory_info_for_gpus "$relevant_gpus")
  
  # 保存内存信息
  memory_file="./results/$tag-qps-$qps-num_prompts-$num_prompts-input_len-$input_len-output_len-$output_len-prefix_len-$prefix_len${goodput_suffix}-memory.json"
  echo "{\"tag\": \"$tag\", \"qps\": \"$qps\", \"num_prompts\": \"$num_prompts\", \"input_len\": \"$input_len\", \"output_len\": \"$output_len\", \"prefix_len\": \"$prefix_len\", \"goodput_config\": \"$goodput_config\", \"relevant_gpus\": \"$relevant_gpus\", \"pre_benchmark\": $pre_benchmark_mem, \"post_benchmark\": $post_benchmark_mem}" > "$memory_file"
  
  echo "[$(date)] Completed benchmark: $tag with goodput config: $goodput_config"
}

main() {
  # # 安装依赖工具及包
  # (which wget && which curl) || (apt-get update && apt-get install -y wget curl)
  # (which jq) || (apt-get -y install jq)
  # (which socat) || (apt-get -y install socat)
  # (which lsof) || (apt-get -y install lsof)
  # pip install quart httpx matplotlib aiohttp datasets

  # cd "$(dirname "$0")"
  # cd ..
  # echo "" > sonnet_4x.txt
  # for _ in {1..4}; do
  #   cat sonnet.txt >> sonnet_4x.txt
  # done
  # cd disagg_benchmarks

  rm -rf results
  mkdir results
  rm -rf error_log.txt

  export VLLM_HOST_IP=$(hostname -I | awk '{print $1}')
  
  # Start etcd and mooncake_master services with force restart (set to true)
  retry_function start_etcd_and_mooncake true || exit 1

  # Using the parameters from the config section at the top of the file
  qps_values=("${QPS_VALUES[@]}")
  num_prompts_values=("${NUM_PROMPTS_VALUES[@]}")
  input_len_values=("${INPUT_LEN_VALUES[@]}")
  output_len_values=("${OUTPUT_LEN_VALUES[@]}")
  prefix_len_values=("${PREFIX_LEN_VALUES[@]}")
  
  # 根据选择执行对应的服务启动
  if [ "$TEST_SERVICE_TYPE" -eq 1 ]; then
      echo "启动 MCK_disagg_prefill 服务..."
      retry_function launch_MCK_disagg_prefill || exit 1
  else
      echo "启动 chunked_prefill 服务..."
      retry_function launch_chunked_prefill || exit 1
  fi

  # 创建目录存储内存信息
  mkdir -p ./results/memory_logs

  # 记录开始时的内存使用情况
  start_memory_info=$(get_memory_info)
  echo "$start_memory_info" > ./results/memory_logs/start_memory.json

  # benchmark 部分
  if [ "$TEST_SERVICE_TYPE" -eq 1 ]; then
      echo "执行 MCK benchmark (first benchmark)..."
      (
        for qps in "${qps_values[@]}"; do
          for num_prompts in "${num_prompts_values[@]}"; do
            for input_len in "${input_len_values[@]}"; do
              for output_len in "${output_len_values[@]}"; do
                for prefix_len in "${prefix_len_values[@]}"; do
                  for goodput_config in "${GOODPUT_CONFIGS[@]}"; do  # 新增goodput循环
                    # 构建goodput标识符用于内存日志文件名
                    goodput_suffix=""
                    if [ -n "$goodput_config" ]; then
                      goodput_suffix="_goodput_$(echo "$goodput_config" | tr ' :' '_-')"
                    fi
                    
                    # First benchmark: MCK_disagg_prefill (using GPUs 2,3)
                    echo "[$(date)] Starting MCK_disagg_prefill benchmark suite with goodput config: [$goodput_config]..."
                    get_memory_info_for_gpus "2,3" > "./results/memory_logs/before-MCK-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                    benchmark $qps $num_prompts $input_len $output_len $prefix_len MCK_disagg_prefill 7000 "$goodput_config"
                    get_memory_info_for_gpus "2,3" > "./results/memory_logs/after-MCK-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                    
                    # # Second benchmark: launch_chunked_prefill 
                    # echo "[$(date)] Starting launch_chunked_prefill benchmark suite with goodput config: [$goodput_config]..."
                    # get_memory_info_for_gpus "2,3" > "./results/memory_logs/before-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                    # benchmark $qps $num_prompts $input_len $output_len $prefix_len launch_chunked_prefill 8000 "$goodput_config"
                    # get_memory_info_for_gpus "2,3" > "./results/memory_logs/after-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                  done
                done
              done
            done
          done
        done
      )
  else
      echo "执行 chunked benchmark (second benchmark)..."
      (
        for qps in "${qps_values[@]}"; do
          for num_prompts in "${num_prompts_values[@]}"; do
            for input_len in "${input_len_values[@]}"; do
              for output_len in "${output_len_values[@]}"; do
                for prefix_len in "${prefix_len_values[@]}"; do
                  for goodput_config in "${GOODPUT_CONFIGS[@]}"; do  # 新增goodput循环
                    # 构建goodput标识符用于内存日志文件名
                    goodput_suffix=""
                    if [ -n "$goodput_config" ]; then
                      goodput_suffix="_goodput_$(echo "$goodput_config" | tr ' :' '_-')"
                    fi
                    
                    # Second benchmark: launch_chunked_prefill 
                    echo "[$(date)] Starting launch_chunked_prefill benchmark suite with goodput config: [$goodput_config]..."
                    get_memory_info_for_gpus "2,3" > "./results/memory_logs/before-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                    benchmark $qps $num_prompts $input_len $output_len $prefix_len launch_chunked_prefill 8000 "$goodput_config"
                    get_memory_info_for_gpus "2,3" > "./results/memory_logs/after-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}${goodput_suffix}.json"
                  done
                done
              done
            done
          done
        done
      )
  fi

  # 记录结束时的内存使用情况
  end_memory_info=$(get_memory_info)
  echo "$end_memory_info" > ./results/memory_logs/end_memory.json

  kill_gpu_processes
  python3 summary.py

  # 替换脚本末尾的内存汇总部分
  
  # 创建一个汇总的内存结果文件，包含所有测试
  echo "Creating consolidated memory summary..."
  echo "{" > "./results/all_memory_results.json"
  
  # 首先添加开始和结束的内存状态
  echo "\"start_memory\": $(cat ./results/memory_logs/start_memory.json)," >> "./results/all_memory_results.json"
  echo "\"end_memory\": $(cat ./results/memory_logs/end_memory.json)," >> "./results/all_memory_results.json"
  
  # 添加 MCK_disagg_prefill 测试结果 - changed from LM_disagg_prefill
  echo "\"MCK_disagg_prefill_tests\": [" >> "./results/all_memory_results.json"
  first=true
  for file in ./results/MCK_disagg_prefill-*.json; do
    if [ -f "$file" ] && [[ "$file" == *"-memory.json" ]]; then
      if [ "$first" = true ]; then
        first=false
      else
        echo "," >> "./results/all_memory_results.json"
      fi
      cat "$file" >> "./results/all_memory_results.json"
    fi
  done
  echo "]," >> "./results/all_memory_results.json"
  
  # 添加 O_disagg_prefill 测试结果
  echo "\"O_disagg_prefill_tests\": [" >> "./results/all_memory_results.json"
  first=true
  for file in ./results/O_disagg_prefill-*.json; do
    if [ -f "$file" ] && [[ "$file" == *"-memory.json" ]]; then
      if [ "$first" = true ];then
        first=false
      else
        echo "," >> "./results/all_memory_results.json"
      fi
      cat "$file" >> "./results/all_memory_results.json"
    fi
  done
  echo "]," >> "./results/all_memory_results.json"
  
  # 添加每个测试前后的内存详情
  echo "\"benchmark_memory_logs\": {" >> "./results/all_memory_results.json"
  
  first_group=true
  # 处理所有参数组合
  for qps in "${qps_values[@]}"; do
    for num_prompts in "${num_prompts_values[@]}"; do
      for input_len in "${input_len_values[@]}"; do
        for output_len in "${output_len_values[@]}"; do
          for prefix_len in "${prefix_len_values[@]}"; do
            param_key="qps${qps}_prompts${num_prompts}_input${input_len}_output${output_len}_prefix${prefix_len}"
            
            if [ "$first_group" = true ]; then
              first_group=false
            else
              echo "," >> "./results/all_memory_results.json"
            fi
            
            echo "\"$param_key\": {" >> "./results/all_memory_results.json"
            
            # MCK 测试的内存日志 - changed from LM
            echo "\"MCK_before\": $(cat ./results/memory_logs/before-MCK-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}.json 2>/dev/null || echo '{}')," >> "./results/all_memory_results.json"
            echo "\"MCK_after\": $(cat ./results/memory_logs/after-MCK-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}.json 2>/dev/null || echo '{}')," >> "./results/all_memory_results.json"
            
            # O 测试的内存日志
            echo "\"O_before\": $(cat ./results/memory_logs/before-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}.json 2>/dev/null || echo '{}')," >> "./results/all_memory_results.json"
            echo "\"O_after\": $(cat ./results/memory_logs/after-O-${qps}-${num_prompts}-${input_len}-${output_len}-${prefix_len}.json 2>/dev/null || echo '{}')" >> "./results/all_memory_results.json"
            
            echo "}" >> "./results/all_memory_results.json"
          done
        done
      done
    done
  done
  
  echo "}" >> "./results/all_memory_results.json"
  echo "}" >> "./results/all_memory_results.json"
  
  echo "Memory summary created at ./results/all_memory_results.json"
  
  # 创建一个简单的 CSV 格式内存报告，易于导入到电子表格
  echo "Creating memory CSV report..."
  echo "tag,qps,num_prompts,input_len,output_len,prefix_len,gpu_id,memory_before_mb,memory_after_mb,memory_diff_mb,memory_diff_percent,sys_memory_before_mb,sys_memory_after_mb,sys_memory_diff_mb,sys_memory_diff_percent" > "./results/memory_report.csv"
  
  # 处理 MCK_disagg_prefill 文件 - changed from LM_disagg_prefill
  for file in ./results/MCK_disagg_prefill-*-memory.json; do
    if [ -f "$file" ];then
      tag=$(jq -r '.tag' "$file")
      qps=$(jq -r '.qps' "$file")
      num_prompts=$(jq -r '.num_prompts' "$file")
      input_len=$(jq -r '.input_len' "$file")
      output_len=$(jq -r '.output_len' "$file")
      prefix_len=$(jq -r '.prefix_len' "$file")
      
      # 系统内存
      sys_memory_before=$(jq -r '.pre_benchmark.memory_used_mb' "$file")
      sys_memory_after=$(jq -r '.post_benchmark.memory_used_mb' "$file")
      sys_memory_diff=$((sys_memory_after - sys_memory_before))
      sys_memory_diff_percent=$(awk "BEGIN {printf \"%.2f\", ($sys_memory_diff/$sys_memory_before)*100}")
      
      # 处理每个 GPU
      jq -c '.pre_benchmark.gpu_info[]' "$file" | while read -r pre_gpu; do
        gpu_id=$(echo "$pre_gpu" | jq -r '.gpu_id')
        memory_before=$(echo "$pre_gpu" | jq -r '.memory_used_mb')
        
        # 获取对应的 post_benchmark GPU 信息
        post_gpu=$(jq -c ".post_benchmark.gpu_info[] | select(.gpu_id == $gpu_id)" "$file")
        memory_after=$(echo "$post_gpu" | jq -r '.memory_used_mb')
        
        memory_diff=$((memory_after - memory_before))
        memory_diff_percent=$(awk "BEGIN {printf \"%.2f\", ($memory_diff/$memory_before)*100}")
        
        # 写入 CSV
        echo "$tag,$qps,$num_prompts,$input_len,$output_len,$prefix_len,$gpu_id,$memory_before,$memory_after,$memory_diff,$memory_diff_percent,$sys_memory_before,$sys_memory_after,$sys_memory_diff,$sys_memory_diff_percent" >> "./results/memory_report.csv"
      done
    fi
  done
  
  # 处理 O_disagg_prefill 文件
  for file in ./results/O_disagg_prefill-*-memory.json; do
    if [ -f "$file" ]; then
      tag=$(jq -r '.tag' "$file")
      qps=$(jq -r '.qps' "$file")
      num_prompts=$(jq -r '.num_prompts' "$file")
      input_len=$(jq -r '.input_len' "$file")
      output_len=$(jq -r '.output_len' "$file")
      prefix_len=$(jq -r '.prefix_len' "$file")
      
      # 系统内存
      sys_memory_before=$(jq -r '.pre_benchmark.memory_used_mb' "$file")
      sys_memory_after=$(jq -r '.post_benchmark.memory_used_mb' "$file")
      sys_memory_diff=$((sys_memory_after - sys_memory_before))
      sys_memory_diff_percent=$(awk "BEGIN {printf \"%.2f\", ($sys_memory_diff/$sys_memory_before)*100}")
      
      # 处理每个 GPU
      jq -c '.pre_benchmark.gpu_info[]' "$file" | while read -r pre_gpu; do
        gpu_id=$(echo "$pre_gpu" | jq -r '.gpu_id')
        memory_before=$(echo "$pre_gpu" | jq -r '.memory_used_mb')
        
        # 获取对应的 post_benchmark GPU 信息
        post_gpu=$(jq -c ".post_benchmark.gpu_info[] | select(.gpu_id == $gpu_id)" "$file")
        memory_after=$(echo "$post_gpu" | jq -r '.memory_used_mb')
        
        memory_diff=$((memory_after - memory_before))
        memory_diff_percent=$(awk "BEGIN {printf \"%.2f\", ($memory_diff/$memory_before)*100}")
        
        # 写入 CSV
        echo "$tag,$qps,$num_prompts,$input_len,$output_len,$prefix_len,$gpu_id,$memory_before,$memory_after,$memory_diff,$memory_diff_percent,$sys_memory_before,$sys_memory_after,$sys_memory_diff,$sys_memory_diff_percent" >> "./results/memory_report.csv"
      done
    fi
  done
  
  echo "Memory CSV report created at ./results/memory_report.csv"

  echo "----- All Tests Done! -----"
}

# Call the main function to actually execute the script
main "$@"
