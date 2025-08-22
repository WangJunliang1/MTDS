# First Party
from MTDS.cache_engine import MTDSEngine
from MTDS.config import MTDSEngineConfig, MTDSEngineMetadata

if __name__ == "__main__":
    config = MTDSEngineConfig.from_file("examples/example.yaml")
    meta = MTDSEngineMetadata(
        "mistralai/Mistral-7B-Instruct-v0.2", 1, 0, "vllm", "bfloat16"
    )
    engine = MTDSEngine(config, meta)
