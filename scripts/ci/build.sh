#!/bin/bash
set -e

here=$(cd "$(dirname "${BASH_SOURCE}")"; pwd -P)
. $here/_env.sh

export BUILD_TAG
python build.py
