#!/usr/bin/env bash
# Installs a pinned cocogitto (cog) binary for the current OS/arch.
# Usage: install-cog.sh [INSTALL_DIR]   (default: $HOME/.local/bin)
#        COG_VERSION=7.0.0 install-cog.sh
set -euo pipefail

COG_VERSION="${COG_VERSION:-7.0.0}"
INSTALL_DIR="${1:-$HOME/.local/bin}"

os="$(uname -s)"
arch="$(uname -m)"
case "${os}-${arch}" in
  Darwin-arm64)   asset="cocogitto-${COG_VERSION}-aarch64-apple-darwin.tar.gz" ;;
  Darwin-x86_64)  asset="cocogitto-${COG_VERSION}-x86_64-apple-darwin.tar.gz" ;;
  Linux-x86_64)   asset="cocogitto-${COG_VERSION}-x86_64-unknown-linux-musl.tar.gz" ;;
  Linux-aarch64)  asset="cocogitto-${COG_VERSION}-aarch64-unknown-linux-gnu.tar.gz" ;;
  *) echo "Unsupported platform: ${os}-${arch}" >&2; exit 1 ;;
esac

url="https://github.com/cocogitto/cocogitto/releases/download/${COG_VERSION}/${asset}"
tmp="$(mktemp -d)"
trap 'rm -rf "${tmp}"' EXIT

echo "Downloading ${url}"
curl -fsSL --max-time 120 "${url}" -o "${tmp}/cog.tar.gz"
tar -xzf "${tmp}/cog.tar.gz" -C "${tmp}"

bin="$(find "${tmp}" -type f -name cog -print -quit)"
if [ -z "${bin}" ]; then
  echo "cog binary not found in archive" >&2
  exit 1
fi

mkdir -p "${INSTALL_DIR}"
install "${bin}" "${INSTALL_DIR}/cog"
echo "Installed cog ${COG_VERSION} to ${INSTALL_DIR}/cog"
"${INSTALL_DIR}/cog" --version
