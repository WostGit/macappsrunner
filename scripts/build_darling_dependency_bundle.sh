#!/usr/bin/env bash
set -euo pipefail

# Build an offline-ish Darling dependency bundle on Ubuntu GitHub Actions.
# Output:
#   dist/darling_offline_bundle_ubuntu_22_04_amd64.zip
#
# Notes:
# - This is intended to run on ubuntu-22.04 or another apt-based runner.
# - It downloads .deb packages with apt-get download after resolving dependencies.
# - It optionally includes a Darling source tarball. Set INCLUDE_DARLING_SOURCE=false to skip it.
# - GitHub has a 100 MB per-file repository limit, so the workflow may split large ZIPs before committing.

UBUNTU_CODENAME="${UBUNTU_CODENAME:-jammy}"
TARGET_ARCH="${TARGET_ARCH:-amd64}"
INCLUDE_DARLING_SOURCE="${INCLUDE_DARLING_SOURCE:-true}"
BUNDLE_NAME="darling_offline_bundle_ubuntu_22_04_${TARGET_ARCH}"
WORK_DIR="${WORK_DIR:-$PWD/work}"
BUNDLE_DIR="$WORK_DIR/$BUNDLE_NAME"
DIST_DIR="${DIST_DIR:-$PWD/dist}"
ZIP_PATH="$DIST_DIR/$BUNDLE_NAME.zip"

ROOT_PACKAGES=(
  git
  git-lfs
  cmake
  clang
  bison
  flex
  xz-utils
  pkg-config
  make
  gcc
  g++
  libc6-dev
  linux-headers-generic
  libfuse-dev
  libudev-dev
  libcap2-bin
  libcairo2-dev
  libgl1-mesa-dev
  libglu1-mesa-dev
  libtiff-dev
  libfreetype-dev
  libxml2-dev
  libegl1-mesa-dev
  libfontconfig1-dev
  libbsd-dev
  libxrandr-dev
  libxcursor-dev
  libgif-dev
  pulseaudio
  dbus
  xdg-user-dirs
  zip
  ca-certificates
)

log() {
  printf '\n==> %s\n' "$*"
}

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

log "Preparing directories"
rm -rf "$WORK_DIR" "$DIST_DIR"
mkdir -p "$BUNDLE_DIR/debs" "$BUNDLE_DIR/source" "$DIST_DIR"

log "Installing resolver/downloader tools on the runner"
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  apt-utils \
  apt-rdepends \
  ca-certificates \
  curl \
  git \
  git-lfs \
  zip

require_cmd apt-rdepends
require_cmd apt-get
require_cmd zip

log "Writing package request list"
printf '%s\n' "${ROOT_PACKAGES[@]}" | tee "$BUNDLE_DIR/packages_requested.txt"

log "Resolving recursive apt dependencies"
# apt-rdepends output contains relationship labels and indented alternatives; keep package-looking names only.
apt-rdepends "${ROOT_PACKAGES[@]}" \
  | grep -Ev '^( |PreDepends:|Depends:|Conflicts:|Breaks:|Replaces:|Suggests:|Recommends:)' \
  | sed '/^$/d' \
  | sort -u \
  > "$BUNDLE_DIR/packages_resolved.txt"

log "Resolved package count"
wc -l "$BUNDLE_DIR/packages_resolved.txt"

log "Downloading .deb packages"
pushd "$BUNDLE_DIR/debs" >/dev/null
while IFS= read -r pkg; do
  [ -n "$pkg" ] || continue
  echo "Downloading package: $pkg"
  if ! apt-get download "$pkg"; then
    echo "$pkg" >> "$BUNDLE_DIR/packages_failed_download.txt"
  fi
done < "$BUNDLE_DIR/packages_resolved.txt"
popd >/dev/null

if [ ! -f "$BUNDLE_DIR/packages_failed_download.txt" ]; then
  touch "$BUNDLE_DIR/packages_failed_download.txt"
fi

log "Downloaded .deb count"
find "$BUNDLE_DIR/debs" -type f -name '*.deb' | wc -l

if [ "$INCLUDE_DARLING_SOURCE" = "true" ]; then
  log "Downloading Darling source archive"
  curl -L --retry 5 --fail \
    -o "$BUNDLE_DIR/source/darling-master.tar.gz" \
    https://github.com/darlinghq/darling/archive/refs/heads/master.tar.gz
else
  log "Skipping Darling source archive"
fi

log "Writing target-machine helper scripts"
cat > "$BUNDLE_DIR/install_debs_on_ubuntu.sh" <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail
cd "$(dirname "$0")"

sudo dpkg -i debs/*.deb || sudo apt-get install -f -y
EOF
chmod +x "$BUNDLE_DIR/install_debs_on_ubuntu.sh"

cat > "$BUNDLE_DIR/build_darling_on_ubuntu.sh" <<'EOF'
#!/usr/bin/env bash
set -euxo pipefail
cd "$(dirname "$0")"

if [ ! -f source/darling-master.tar.gz ]; then
  echo "source/darling-master.tar.gz not found. This bundle may contain dependencies only."
  exit 1
fi

mkdir -p source/extracted
tar -xzf source/darling-master.tar.gz -C source/extracted --strip-components=1
cd source/extracted

git submodule update --init --recursive || true
mkdir -p build
cd build
cmake ..
make -j"$(nproc)"
sudo make install
make lkm
sudo make lkm_install

echo "Darling installed. Try: darling shell"
EOF
chmod +x "$BUNDLE_DIR/build_darling_on_ubuntu.sh"

cat > "$BUNDLE_DIR/README.txt" <<EOF
Darling Offline Dependency Bundle

Built by GitHub Actions in WostGit/macappsrunner.
Target Ubuntu codename: $UBUNTU_CODENAME
Target architecture: $TARGET_ARCH
Includes Darling source archive: $INCLUDE_DARLING_SOURCE

Use on an Ubuntu/Debian Linux target machine:

1. Unzip this archive.
2. Run:
   ./install_debs_on_ubuntu.sh
3. Optional, if source is included:
   ./build_darling_on_ubuntu.sh
4. Try:
   darling shell

Important:
- Darling is for Linux, not macOS.
- These .deb files are specific to the Ubuntu release/architecture used by the runner.
- Kernel module installation requires sudo and matching Linux headers.
- If some package install steps still need online repair, run:
  sudo apt-get install -f -y

Files:
- debs/: downloaded .deb packages
- source/: optional Darling source archive
- packages_requested.txt: direct package list
- packages_resolved.txt: recursive package list
- packages_failed_download.txt: packages apt could not download
EOF

log "Creating ZIP"
pushd "$WORK_DIR" >/dev/null
zip -r "$ZIP_PATH" "$BUNDLE_NAME"
popd >/dev/null

log "Bundle created"
ls -lh "$ZIP_PATH"
sha256sum "$ZIP_PATH" | tee "$ZIP_PATH.sha256"
