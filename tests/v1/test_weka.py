# Standard
from pathlib import Path
import asyncio
import os
import shutil
import threading

# Third Party
import torch

# First Party
from mtds.utils import CacheEngineKey
from mtds.v1.cache_engine import MTDSEngineBuilder
from mtds.v1.config import MTDSEngineConfig
from mtds.v1.memory_management import CuFileMemoryAllocator
from mtds.v1.storage_backend import CreateStorageBackends


def test_weka_backend_sanity():
    BASE_DIR = Path(__file__).parent
    WEKA_DIR = "/tmp/weka/test-cache"
    TEST_KEY = CacheEngineKey(
        fmt="vllm",
        model_name="meta-llama/Llama-3.1-70B-Instruct",
        world_size=8,
        worker_id=0,
        chunk_hash="e3229141e680fb413d2c5d3ebb416c4ad300d381e309fc9e417757b91406c157",
    )
    BACKEND_NAME = "WekaGdsBackend"

    try:
        os.makedirs(WEKA_DIR, exist_ok=True)
    config_weka = MTDSEngineConfig.from_file(BASE_DIR / "data/weka.yaml")
        assert config_weka.cufile_buffer_size == 128

        thread_loop = asyncio.new_event_loop()
        thread = threading.Thread(target=thread_loop.run_forever)
        thread.start()

        backends = CreateStorageBackends(
            config_weka,
            None,
            thread_loop,
            MTDSEngineBuilder._Create_memory_allocator(config_weka, None),
        )
        assert len(backends) == 2
        assert BACKEND_NAME in backends

        weka_backend = backends[BACKEND_NAME]
        assert weka_backend is not None
        assert weka_backend.memory_allocator is not None
        assert isinstance(weka_backend.memory_allocator, CuFileMemoryAllocator)

        assert not weka_backend.contains(TEST_KEY, False)
        assert not weka_backend.exists_in_put_tasks(TEST_KEY)

        memory_obj = weka_backend.memory_allocator.allocate(
            [2048, 2048], dtype=torch.uint8
        )
        future = weka_backend.submit_put_task(TEST_KEY, memory_obj)
        assert future is not None
        assert weka_backend.exists_in_put_tasks(TEST_KEY)
        assert not weka_backend.contains(TEST_KEY, False)
        future.result()
        assert weka_backend.contains(TEST_KEY, False)
        assert not weka_backend.exists_in_put_tasks(TEST_KEY)

        returned_memory_obj = weka_backend.get_blocking(TEST_KEY)
        assert returned_memory_obj is not None
        assert returned_memory_obj.get_size() == memory_obj.get_size()
        assert returned_memory_obj.get_shape() == memory_obj.get_shape()
        assert returned_memory_obj.get_dtype() == memory_obj.get_dtype()

        future = weka_backend.get_non_blocking(TEST_KEY)
        assert future is not None
        returned_memory_obj = future.result()
        assert returned_memory_obj is not None
        assert returned_memory_obj.get_size() == memory_obj.get_size()
        assert returned_memory_obj.get_shape() == memory_obj.get_shape()
        assert returned_memory_obj.get_dtype() == memory_obj.get_dtype()
    finally:
        if os.path.exists(WEKA_DIR):
            shutil.rmtree(WEKA_DIR)
        if thread_loop.is_running():
            thread_loop.call_soon_threadsafe(thread_loop.stop)
        if thread.is_alive():
            thread.join()
