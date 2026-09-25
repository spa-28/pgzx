#!/usr/bin/env bash

set -e
set -x
set -o pipefail

: "${PGZX_POSTGRES_VERSION:?run ci/setup.sh from a pgzx PostgreSQL development shell}"
if [[ ! $PGZX_POSTGRES_VERSION =~ ^[0-9]+$ ]]; then
	echo "Invalid PostgreSQL major version: $PGZX_POSTGRES_VERSION" >&2
	exit 1
fi

pglocal
pguse "$PGZX_POSTGRES_VERSION"
pginit
