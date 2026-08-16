#!/bin/sh
set -e
mkdir -p "$DSH_HOME/profiles/web"
if [ ! -f "$DSH_HOME/profiles/web/cordis.patch.yml" ]; then
  cp /opt/dsh-profiles/web/cordis.patch.yml "$DSH_HOME/profiles/web/cordis.patch.yml"
fi
exec "$@"
