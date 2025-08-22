# Standard
from pathlib import Path
import os

# First Party
from MTDS.v1.config import MTDSEngineConfig

BASE_DIR = Path(__file__).parent


def test_get_extra_config_from_file():
    config = MTDSEngineConfig.from_file(BASE_DIR / "data/test_config.yaml")
    check_extra_config(config)


def test_get_extra_config_from_env():
    config = MTDSEngineConfig.from_env()
    assert config.extra_config is None

    # set env of extra_config
    os.environ["MTDS_EXTRA_CONFIG"] = '{"key1": "value1", "key2": "value2"}'

    new_config = MTDSEngineConfig.from_env()
    check_extra_config(new_config)


def check_extra_config(config: "MTDSEngineConfig"):
    assert config.extra_config is not None
    assert isinstance(config.extra_config, dict)
    assert len(config.extra_config) == 2
    assert config.extra_config["key1"] == "value1"
    assert config.extra_config["key2"] == "value2"
