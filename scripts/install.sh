#!/bin/sh
set -eu
TARGET="${1:-root@192.168.3.1}"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"
ssh -o BatchMode=yes -o PasswordAuthentication=no "$TARGET" 'cat > /usr/bin/skyris_screen_clients && chmod +x /usr/bin/skyris_screen_clients' < "$DIR/src/skyris_screen_clients.lua"
echo "Installed to $TARGET:/usr/bin/skyris_screen_clients"
