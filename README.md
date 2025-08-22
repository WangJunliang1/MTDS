# MTDS
MTDS (Multi-tier Dynamic Storage) is a novel scheme that moves the KV cache from constrained GPU VRAM to a multilevel storage system, thereby reducing both GPU computational overhead and memory consumption.

### System Requirements
- OS: Linux
- Python: 3.10 -- 3.12
- vllm 0.9.2 or higher
- GPU: NVIDIA compute capability 7.0+ (e.g., V100, T4, RTX20xx, A100, L4, H100, etc.)
- CUDA 12.8+

### Deploy project
* Download the project and place it in a custom directory (such as /home/MTDS/)  <br>
```
cd /home/MTDS/
```

* Configure waf  <br>
```
./waf configure 
./waf 
```

* Run the test:  <br>
Execute Python `./mtds_run.py`  <br>

#### Please Note
Some project files and data are currently under review and will be updated in due course.
