#!/usr/bin/env bash
# Ставит закреплённые версии git и bash для дифференциальных тестов.
#
# Версии выбраны по README virtual_git (git 2.53) и поведению bash 5.3.
# Скрипт идемпотентен: если бинарники уже есть, сборка пропускается.
set -euo pipefail

GIT_VERSION="2.53.0"
BASH_VERSION="5.3"
PREFIX="${PARITY_TOOLS_PREFIX:-$HOME/.local/parity-tools}"

if [ -x "$PREFIX/git/bin/git" ] && [ -x "$PREFIX/bash/bin/bash" ] &&
    "$PREFIX/git/bin/git" --version | grep -q "git version $GIT_VERSION" &&
    "$PREFIX/bash/bin/bash" --version | grep -q "version $BASH_VERSION"; then
    echo "Parity tools already installed in $PREFIX"
    exit 0
fi

sudo apt-get update
sudo apt-get install -y \
    build-essential \
    libcurl4-openssl-dev \
    libexpat1-dev \
    libncurses-dev \
    libssl-dev \
    gettext \
    zlib1g-dev

TMPDIR_PARITY="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_PARITY"' EXIT
mkdir -p "$PREFIX"

echo "Building bash $BASH_VERSION..."
curl -fsSL "https://ftp.gnu.org/gnu/bash/bash-$BASH_VERSION.tar.gz" \
    -o "$TMPDIR_PARITY/bash.tar.gz"
tar -xzf "$TMPDIR_PARITY/bash.tar.gz" -C "$TMPDIR_PARITY"
(
    cd "$TMPDIR_PARITY/bash-$BASH_VERSION"
    ./configure --prefix="$PREFIX/bash" --without-bash-malloc
    make -j"$(nproc)"
    make install
)

echo "Building git $GIT_VERSION..."
curl -fsSL "https://mirrors.edge.kernel.org/pub/software/scm/git/git-$GIT_VERSION.tar.xz" \
    -o "$TMPDIR_PARITY/git.tar.xz"
tar -xJf "$TMPDIR_PARITY/git.tar.xz" -C "$TMPDIR_PARITY"
(
    cd "$TMPDIR_PARITY/git-$GIT_VERSION"
    make prefix="$PREFIX/git" -j"$(nproc)" \
        NO_GETTEXT=1 NO_TCLTK=1 NO_PERL=1 install
)

"$PREFIX/git/bin/git" --version
"$PREFIX/bash/bin/bash" --version | head -1
