#!/bin/sh
# Install tapedeck. Usage:
#   curl -fsSL https://raw.githubusercontent.com/getsolmo/tapedeck/main/packaging/install.sh | sh
set -eu

REPO="getsolmo/tapedeck"
VERSION="${TAPEDECK_VERSION:-latest}"

detect_target() {
    os=$(uname -s)
    arch=$(uname -m)
    case "$os" in
        Darwin) os_part="macos" ;;
        Linux)  os_part="linux-musl" ;;
        *) echo "unsupported operating system: $os" >&2; exit 1 ;;
    esac
    case "$arch" in
        x86_64|amd64)  arch_part="x86_64" ;;
        arm64|aarch64) arch_part="aarch64" ;;
        *) echo "unsupported architecture: $arch" >&2; exit 1 ;;
    esac
    echo "${arch_part}-${os_part}"
}

install_dir() {
    # Prefer a system path, fall back to the user's without needing sudo.
    if [ -w /usr/local/bin ] 2>/dev/null; then
        echo /usr/local/bin
    else
        echo "$HOME/.local/bin"
    fi
}

main() {
    target=$(detect_target)
    dest=$(install_dir)
    mkdir -p "$dest"

    if [ "$VERSION" = "latest" ]; then
        base="https://github.com/$REPO/releases/latest/download"
    else
        base="https://github.com/$REPO/releases/download/$VERSION"
    fi

    tmp=$(mktemp -d)
    trap 'rm -rf "$tmp"' EXIT
    tarball="tapedeck-${target}.tar.gz"

    echo "downloading $tarball"
    curl -fsSL "$base/$tarball" -o "$tmp/$tarball"
    curl -fsSL "$base/SHA256SUMS" -o "$tmp/SHA256SUMS"

    # An unverified binary is not worth installing. No checksum, no install.
    ( cd "$tmp" && grep " $tarball\$" SHA256SUMS > expected.txt )
    if command -v sha256sum >/dev/null 2>&1; then
        ( cd "$tmp" && sha256sum -c expected.txt )
    elif command -v shasum >/dev/null 2>&1; then
        ( cd "$tmp" && shasum -a 256 -c expected.txt )
    else
        echo "no sha256 tool available; refusing to install unverified" >&2
        exit 1
    fi

    tar -C "$tmp" -xzf "$tmp/$tarball"
    install -m 755 "$tmp/tapedeck" "$dest/tapedeck"

    echo "installed $dest/tapedeck"
    case ":$PATH:" in
        *":$dest:"*) ;;
        *) echo "note: $dest is not on your PATH" ;;
    esac
}

main "$@"
