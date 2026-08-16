#!/usr/bin/env bash
set -Eeuo pipefail

###############################################################################
# SDL3 complete installer for Raspberry Pi 4B / Debian arm64
#
# Installs:
#   SDL3
#   SDL3_image
#   SDL3_ttf
#   SDL3_mixer
#   SDL3_net
#
# Source:
#   GitHub official releases
#
# Packaging:
#   checkinstall -> .deb -> dpkg/apt package database
#
# Re-running this script:
#   - same installed version: skip
#   - newer GitHub stable release: build/install
#
# Intended target:
#   Raspberry Pi 4B / aarch64 / Debian
###############################################################################

readonly SCRIPT_NAME="$(basename "$0")"

readonly WORK_ROOT="/tmp/build/sdl3"
readonly SOURCE_ROOT="${WORK_ROOT}/src"
readonly BUILD_ROOT="${WORK_ROOT}/build"
readonly PACKAGE_ROOT="${WORK_ROOT}/packages"
readonly LOG_ROOT="${WORK_ROOT}/logs"

readonly GITHUB_API="https://api.github.com/repos"

readonly JOBS="${SDL_BUILD_JOBS:-2}"

# Keep the package names separate from Debian's own SDL packages.
readonly PKG_SDL="libsdl3-custom"
readonly PKG_IMAGE="libsdl3-image-custom"
readonly PKG_TTF="libsdl3-ttf-custom"
readonly PKG_MIXER="libsdl3-mixer-custom"
readonly PKG_NET="libsdl3-net-custom"

export DEBIAN_FRONTEND=noninteractive

###############################################################################
# Logging
###############################################################################

mkdir -p \
    "$SOURCE_ROOT" \
    "$BUILD_ROOT" \
    "$PACKAGE_ROOT" \
    "$LOG_ROOT"

readonly LOG_FILE="${LOG_ROOT}/install-$(date '+%Y%m%d-%H%M%S').log"

exec > >(tee -a "$LOG_FILE") 2>&1

###############################################################################
# Helpers
###############################################################################

die()
{
    echo
    echo "ERROR: $*" >&2
    exit 1
}

info()
{
    echo
    echo "==> $*"
}

command_exists()
{
    command -v "$1" >/dev/null 2>&1
}

require_root()
{
    if [[ "${EUID}" -ne 0 ]]; then
        die "root privileges are required. Run: sudo ${SCRIPT_NAME}"
    fi
}

check_arch()
{
    local arch
    arch="$(dpkg --print-architecture)"

    case "$arch" in
        arm64)
            ;;
        *)
            die "This script expects Debian arm64/aarch64. Detected: ${arch}"
            ;;
    esac
}

check_pi()
{
    if [[ -r /proc/device-tree/model ]]; then
        local model
        model="$(tr -d '\0' < /proc/device-tree/model)"

        echo "Detected machine: ${model}"

        case "$model" in
            *"Raspberry Pi 4"*)
                ;;
            *)
                echo "WARNING: This is not a Raspberry Pi 4."
                echo "Continuing because the architecture is compatible."
                ;;
        esac
    fi
}

###############################################################################
# Debian packages
###############################################################################

install_build_dependencies()
{
    info "Installing build dependencies"

    apt-get update

    apt-get install -y \
        ca-certificates \
        curl \
        wget \
        git \
        build-essential \
        gcc \
        g++ \
        make \
        cmake \
        ninja-build \
        pkg-config \
        checkinstall \
        file \
        xz-utils \
        tar \
        gzip \
        bzip2 \
        unzip \
        python3 \
        perl \
        \
        libasound2-dev \
        libpulse-dev \
        libaudio-dev \
        libfribidi-dev \
        libjack-dev \
        libsndio-dev \
        \
        libx11-dev \
        libxext-dev \
        libxrandr-dev \
        libxcursor-dev \
        libxfixes-dev \
        libxi-dev \
        libxss-dev \
        libxtst-dev \
        libxkbcommon-dev \
        \
        libdrm-dev \
        libgbm-dev \
        libgl1-mesa-dev \
        libgles2-mesa-dev \
        libegl1-mesa-dev \
        \
        libdbus-1-dev \
        libibus-1.0-dev \
        libudev-dev \
        libusb-1.0-0-dev \
        \
        libwayland-dev \
        wayland-protocols \
        libdecor-0-dev \
        \
        libpipewire-0.3-dev \
        \
        libthai-dev \
        \
        libfreetype-dev \
        libharfbuzz-dev \
        \
        libpng-dev \
        libjpeg-dev \
        libtiff-dev \
        libwebp-dev \
        libavif-dev \
        libjxl-dev \
        \
        libflac-dev \
        libvorbis-dev \
        libopus-dev \
        libmpg123-dev \
        libwavpack-dev \
        libmodplug-dev \
        libfluidsynth-dev \
        libgme-dev \
        libxmp-dev
}

###############################################################################
# GitHub API
###############################################################################

github_latest_release()
{
    local repo="$1"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 2 \
        -H "Accept: application/vnd.github+json" \
        -H "X-GitHub-Api-Version: 2022-11-28" \
        "${GITHUB_API}/${repo}/releases/latest"
}

get_release_tag()
{
    local repo="$1"

    github_latest_release "$repo" |
        python3 -c '
import json
import sys

data = json.load(sys.stdin)

if data.get("draft"):
    raise SystemExit("latest release is a draft")

if data.get("prerelease"):
    raise SystemExit("latest release is a prerelease")

tag = data.get("tag_name")
if not tag:
    raise SystemExit("release tag not found")

print(tag)
'
}

get_release_version()
{
    local tag="$1"

    tag="${tag#release-}"
    tag="${tag#v}"

    printf '%s\n' "$tag"
}

###############################################################################
# Package version comparison
###############################################################################

installed_version()
{
    local package="$1"

    dpkg-query \
        -W \
        -f='${Version}' \
        "$package" 2>/dev/null || true
}

is_version_installed()
{
    local package="$1"
    local version="$2"

    local installed
    installed="$(installed_version "$package")"

    [[ -n "$installed" ]] &&
        dpkg --compare-versions "$installed" ge "$version"
}

###############################################################################
# Download
###############################################################################

download_release()
{
    local repo="$1"
    local tag="$2"
    local name="$3"

    local archive="${SOURCE_ROOT}/${name}-${tag}.tar.gz"
    local url="https://github.com/${repo}/archive/refs/tags/${tag}.tar.gz"

    if [[ -f "$archive" ]]; then
        info "Source archive already exists: ${archive}"
        printf '%s\n' "$archive"
        return
    fi

    info "Downloading ${repo} ${tag}"

    curl \
        --fail \
        --silent \
        --show-error \
        --location \
        --retry 3 \
        --retry-delay 2 \
        -o "$archive" \
        "$url"

    printf '%s\n' "$archive"
}

extract_release()
{
    local archive="$1"
    local name="$2"
    local tag="$3"

    local expected="${SOURCE_ROOT}/${name}-${tag}"

    if [[ -d "$expected" ]]; then
        info "Source already extracted: ${expected}"
        printf '%s\n' "$expected"
        return
    fi

    info "Extracting ${archive}"

    tar \
        -xzf "$archive" \
        -C "$SOURCE_ROOT"

    # GitHub normally extracts:
    # repository-tag
    #
    # Verify instead of guessing silently.
    [[ -d "$expected" ]] ||
        die "Expected extracted directory not found: ${expected}"

    printf '%s\n' "$expected"
}

###############################################################################
# CMake / checkinstall
###############################################################################

build_and_install()
{
    local name="$1"
    local package="$2"
    local version="$3"
    local source="$4"

    local build="${BUILD_ROOT}/${name}-${version}"
    local package_file="${PACKAGE_ROOT}/${package}_${version}_arm64.deb"

    if is_version_installed "$package" "$version"; then
        info "${package} ${version} is already installed. Skipping."

        echo "Installed:"
        dpkg-query -W "$package" || true

        return 0
    fi

    info "Building ${name} ${version}"

    rm -rf "$build"
    mkdir -p "$build"

    case "$name" in

        SDL)
            cmake \
                -S "$source" \
                -B "$build" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
                -DSDL_SHARED=ON \
                -DSDL_STATIC=ON \
                -DSDL_TEST_LIBRARY=ON \
                -DSDL_TESTS=OFF \
                -DSDL_EXAMPLES=OFF \
                -DSDL_INSTALL=ON \
                -DSDL_INSTALL_DOCS=ON \
                -DSDL_PRESEED=ON
            ;;

        SDL_image)
            cmake \
                -S "$source" \
                -B "$build" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
                -DBUILD_SHARED_LIBS=ON \
                -DSDLIMAGE_INSTALL=ON \
                -DSDLIMAGE_SAMPLES=OFF \
                -DSDLIMAGE_TESTS=OFF \
                -DSDLIMAGE_VENDORED=ON \
                -DSDLIMAGE_BACKEND_STB=ON
            ;;

        SDL_ttf)
            cmake \
                -S "$source" \
                -B "$build" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
                -DBUILD_SHARED_LIBS=ON \
                -DSDLTTF_INSTALL=ON \
                -DSDLTTF_SAMPLES=OFF \
                -DSDLTTF_TESTS=OFF
            ;;

        SDL_mixer)
            cmake \
                -S "$source" \
                -B "$build" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
                -DBUILD_SHARED_LIBS=ON \
                -DSDLMIXER_INSTALL=ON \
                -DSDLMIXER_SAMPLES=OFF \
                -DSDLMIXER_TESTS=OFF \
                -DSDLMIXER_VENDORED=ON
            ;;

        SDL_net)
            cmake \
                -S "$source" \
                -B "$build" \
                -G Ninja \
                -DCMAKE_BUILD_TYPE=Release \
                -DCMAKE_INSTALL_PREFIX=/usr \
                -DCMAKE_INSTALL_LIBDIR=lib/aarch64-linux-gnu \
                -DBUILD_SHARED_LIBS=ON \
                -DSDLNET_INSTALL=ON \
                -DSDLNET_SAMPLES=OFF \
                -DSDLNET_TESTS=OFF
            ;;

        *)
            die "Unknown SDL component: ${name}"
            ;;
    esac

    cmake \
        --build "$build" \
        --parallel "$JOBS"

    info "Packaging ${name} ${version} with checkinstall"

    rm -f "$package_file"

    (
        cd "$build"

        checkinstall \
            --install=yes \
            --fstrans=no \
            --backup=no \
            --deldoc=yes \
            --nodoc \
            --strip=no \
            --stripso=no \
            --reset-uids=yes \
            --pakdir="$PACKAGE_ROOT" \
            --pkgname="$package" \
            --pkgversion="$version" \
            --pkgarch=arm64 \
            --pkgrelease=1 \
            --maintainer="local" \
            --summary="SDL3 ${name} locally built from official GitHub release" \
            --requires="" \
            -- \
            cmake --install "$build" --prefix /usr
    )

    ldconfig

    echo
    echo "Package:"
    ls -lh "$PACKAGE_ROOT/${package}"_*.deb 2>/dev/null || true

    echo
    echo "Installed version:"
    dpkg-query -W "$package" || true
}

###############################################################################
# One component
###############################################################################

install_component()
{
    local repo="$1"
    local name="$2"
    local package="$3"

    info "Checking latest stable release: ${repo}"

    local tag
    tag="$(get_release_tag "$repo")"

    local version
    version="$(get_release_version "$tag")"

    echo "Repository : ${repo}"
    echo "Tag        : ${tag}"
    echo "Version    : ${version}"
    echo "Package    : ${package}"

    if is_version_installed "$package" "$version"; then
        info "${package} ${version} already installed"
        return 0
    fi

    local archive
    archive="$(download_release "$repo" "$tag" "$name")"

    local source
    source="$(extract_release "$archive" "$name" "$tag")"

    build_and_install \
        "$name" \
        "$package" \
        "$version" \
        "$source"
}

###############################################################################
# Main
###############################################################################

main()
{
    require_root
    check_arch
    check_pi

    info "SDL3 complete installer"
    echo "Build jobs : ${JOBS}"
    echo "Work root  : ${WORK_ROOT}"
    echo "Log file   : ${LOG_FILE}"

    install_build_dependencies

    #
    # SDL itself must be installed first because all SDL3 extension
    # libraries depend on SDL3.
    #
    install_component \
        "libsdl-org/SDL" \
        "SDL" \
        "$PKG_SDL"

    install_component \
        "libsdl-org/SDL_image" \
        "SDL_image" \
        "$PKG_IMAGE"

    install_component \
        "libsdl-org/SDL_ttf" \
        "SDL_ttf" \
        "$PKG_TTF"

    install_component \
        "libsdl-org/SDL_mixer" \
        "SDL_mixer" \
        "$PKG_MIXER"

    install_component \
        "libsdl-org/SDL_net" \
        "SDL_net" \
        "$PKG_NET"

    ldconfig

    info "Final package list"

    dpkg-query \
        -W \
        -f='${Package}\t${Version}\t${Architecture}\n' \
        "$PKG_SDL" \
        "$PKG_IMAGE" \
        "$PKG_TTF" \
        "$PKG_MIXER" \
        "$PKG_NET" \
        2>/dev/null || true

    echo
    echo "SDL3 installation completed."
    echo
    echo "Packages are registered in the Debian dpkg/apt package database."
    echo "Generated packages are stored under:"
    echo "  ${PACKAGE_ROOT}"
    echo
    echo "Build logs are stored under:"
    echo "  ${LOG_ROOT}"
    echo
}

main "$@"
