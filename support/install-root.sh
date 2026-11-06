#!/bin/sh
# Root part of the lidwake install: binary + sudoers rule. Run as: sudo support/install-root.sh <user>
set -eu
user="${1:?usage: sudo support/install-root.sh <user>}"
[ "$(id -u)" -eq 0 ] || { echo "run with sudo" >&2; exit 1; }
here="$(cd "$(dirname "$0")/.." && pwd)"

install -d -m 0755 /usr/local/bin
install -m 0755 "$here/.build/release/lidwake" /usr/local/bin/lidwake

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT
sed "s/USERNAME/$user/" "$here/support/sudoers-lidwake" > "$tmp"
visudo -cf "$tmp"
install -o root -g wheel -m 0440 "$tmp" /etc/sudoers.d/lidwake
echo "installed /usr/local/bin/lidwake and /etc/sudoers.d/lidwake for $user"
