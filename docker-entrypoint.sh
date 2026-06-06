#!/bin/bash
# docker-entrypoint.sh
# build.sh reads LARCH_OUTPUT_ISO from the environment directly,
# so no patching is needed here — just exec whatever was passed as CMD.
exec "$@"
