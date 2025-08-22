# First Party
from MTDS.cache_engine import MTDSEngine
from MTDS.config import MTDSEngineConfig, MTDSEngineMetadata

if __name__ == "__main__":
    config = MTDSEngineConfig.from_file("../examples/example.yaml")
    meta = MTDSEngineMetadata(
        "mistralai/Mistral-7B-Instruct-v0.2", 1, 0, "vllm", "bfloat16"
    )
    engine = MTDSEngine(config, meta)
    hybrid_store = engine.engine_
    remote_store = hybrid_store.remote_store
    keys = remote_store.list()
    for key in keys:
        data = remote_store.connection.get(remote_store._combine_key(key))
    print("Job done")
