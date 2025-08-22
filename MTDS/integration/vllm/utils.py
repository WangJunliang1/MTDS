# Copyright 2024-2025 MTDS Authors.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Standard
from typing import Union
import os

# First Party
from MTDS.config import MTDSEngineConfig as Config  # type: ignore[assignment]
from MTDS.logging import init_logger
from MTDS.v1.config import (
    MTDSEngineConfig as V1Config,  # type: ignore[assignment]
)

logger = init_logger(__name__)
ENGINE_NAME = "vllm-instance"


def is_false(value: str) -> bool:
    """Check if the given string value is equivalent to 'false'."""
    return value.lower() in ("false", "0", "no", "n", "off")


def MTDS_get_config() -> Union[Config, V1Config]:
    """Get the MTDS configuration from the environment variable
    `MTDS_CONFIG_FILE`. If the environment variable is not set, this
    function will return the default configuration.
    """

    if is_false(os.getenv("MTDS_USE_EXPERIMENTAL", "True")):
        logger.warning(
            "Detected MTDS_USE_EXPERIMENTAL is set to False. "
            "Using legacy configuration is deprecated and will "
            "be remove soon! Please set MTDS_USE_EXPERIMENTAL "
            "to True."
        )
        MTDSEngineConfig = Config  # type: ignore[assignment]
    else:
        MTDSEngineConfig = V1Config  # type: ignore[assignment]

    if "MTDS_CONFIG_FILE" not in os.environ:
        logger.warn(
            "No MTDS configuration file is set. Trying to read"
            " configurations from the environment variables."
        )
        logger.warn(
            "You can set the configuration file through "
            "the environment variable: MTDS_CONFIG_FILE"
        )
        config = MTDSEngineConfig.from_env()
    else:
        config_file = os.environ["MTDS_CONFIG_FILE"]
        logger.info(f"Loading MTDS config file {config_file}")
        config = MTDSEngineConfig.from_file(config_file)

    return config
