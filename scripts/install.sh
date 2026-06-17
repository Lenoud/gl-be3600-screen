#!/bin/sh
set -eu
TARGET="${1:-root@192.168.3.1}"
DIR="$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)"

# Main screen program.
ssh -o BatchMode=yes -o PasswordAuthentication=no "$TARGET" \
  'cat > /usr/bin/skyris_screen_clients && chmod +x /usr/bin/skyris_screen_clients' \
  < "$DIR/src/skyris_screen_clients.lua"

# Boot autostart via procd init script.
ssh -o BatchMode=yes -o PasswordAuthentication=no "$TARGET" \
  'cat > /etc/init.d/skyris_screen_clients && chmod +x /etc/init.d/skyris_screen_clients' \
  < "$DIR/scripts/skyris_screen_clients.init"

# Enable on boot and (re)start now.
ssh -o BatchMode=yes -o PasswordAuthentication=no "$TARGET" \
  '/etc/init.d/skyris_screen_clients enable && /etc/init.d/skyris_screen_clients restart'

echo "Installed to $TARGET:/usr/bin/skyris_screen_clients (enabled on boot)"
