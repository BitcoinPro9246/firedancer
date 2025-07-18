#!/usr/bin/env bash

set -euo pipefail

# Change into Firedancer root directory
cd "$(dirname "${BASH_SOURCE[0]}")"

# Load OS information
OS="$(uname -s)"
case "$OS" in
  Darwin)
    MAKE=( make -j )
    ID=macos
    ;;
  Linux)
    MAKE=( make -j )
    # Load distro information
    if [[ -f /etc/os-release ]]; then
      source /etc/os-release
    fi
    ;;
  *)
    echo "[!] Unsupported OS $OS"
    ;;
esac

# Figure out how to escalate privileges
SUDO=""
if [[ ! "$(id -u)" -eq "0" ]]; then
  SUDO="sudo"
fi

# Install prefix
PREFIX="$(pwd)/opt"

DEVMODE=0
MSAN=0
_CC="${CC:=gcc}"
_CXX="${CXX:=g++}"
EXTRA_CFLAGS=""
EXTRA_CXXFLAGS=""
EXTRA_LDFLAGS=""

help () {
cat <<EOF

  Usage: $0 [cmd] [args...]

  If cmd is omitted, default is 'install'.

  Commands are:

    help
    - Prints this message

    check
    - Runs system requirement checks for dep build/install
    - Exits with code 0 on success

    nuke
    - Get rid of dependency checkouts
    - Get rid of all third party dependency files
    - Same as 'rm -rf $PREFIX'

    fetch
    - Fetches dependencies from Git repos into $PREFIX/git

    install
    - Builds dependencies
    - Installs all project dependencies into prefix $PREFIX

EOF
  exit 0
}

nuke () {
  rm -rf "$PREFIX"
  echo "[-] Nuked $PREFIX"
  exit 0
}

checkout_repo () {
  # Skip if dir already exists
  if [[ -d "$PREFIX/git/$1" ]]; then
    echo "[~] Skipping $1 fetch as \"$PREFIX/git/$1\" already exists"
  elif [[ -z "$3" ]]; then
    echo "[+] Cloning $1 from $2"
    git -c advice.detachedHead=false clone "$2" "$PREFIX/git/$1" && cd "$PREFIX/git/$1" && git reset --hard "$4"
    echo
  else
    echo "[+] Cloning $1 from $2"
    git -c advice.detachedHead=false clone "$2" "$PREFIX/git/$1" --branch "$3" --depth=1
    echo
  fi

  if [[ ! -z "$3" ]]; then
    # Skip if tag already correct
    if [[ "$(git -C "$PREFIX/git/$1" describe --tags --abbrev=0)" == "$3" ]]; then
      return
    fi

    echo "[~] Checking out $1 $3"
    (
      cd "$PREFIX/git/$1"
      git fetch origin "$3" --tags --depth=1
      git -c advice.detachedHead=false checkout "$3"
    )
    echo
  fi
}

checkout_llvm () {
  if [[ -d "$PREFIX/git/llvm" ]]; then
    echo "[~] Skipping LLVM download; already exists"
    return
  fi

  echo "[+] Downloading LLVM"
  (
    cd "$PREFIX/git"
    curl --proto '=https' -sSLf https://github.com/llvm/llvm-project/releases/download/llvmorg-19.1.0/llvm-project-19.1.0.src.tar.xz \
    | tar -xJ
    mv llvm-project-19.1.0.src llvm
  )
  cd -
}

fetch () {
  git submodule update --init

  mkdir -pv "$PREFIX/git"

  if [[ $MSAN == 1 ]]; then
    checkout_llvm
  fi
  checkout_repo zstd      https://github.com/facebook/zstd          "v1.5.7"
  checkout_repo lz4       https://github.com/lz4/lz4                "v1.10.0"
  checkout_repo s2n       https://github.com/awslabs/s2n-bignum     "" "4d2e22a"
  checkout_repo openssl   https://github.com/openssl/openssl        "openssl-3.5.0"
  checkout_repo secp256k1 https://github.com/bitcoin-core/secp256k1 "v0.6.0"
  if [[ $DEVMODE == 1 ]]; then
    checkout_repo blst      https://github.com/supranational/blst     "v0.3.14"
    checkout_repo rocksdb   https://github.com/facebook/rocksdb       "v10.2.1"
    checkout_repo snappy    https://github.com/google/snappy          "1.2.2"
  fi
}

check_fedora_pkgs () {
  local REQUIRED_RPMS=(
    curl               # download rustup
    diffutils          # build system
    make               # build system
    pkgconf            # build system
    patch              # build system
    gcc                # compiler
    gcc-c++            # compiler

    cmake              # Agave (RocksDB)
    clang-devel        # Agave (bindgen)
    systemd-devel      # Agave
    perl               # Agave (OpenSSL)
    protobuf-compiler  # Agave, solfuzz
  )
  if [[ $DEVMODE == 1 ]]; then
    REQUIRED_RPMS+=( autoconf automake bison cmake clang flex gettext-devel gmp-devel lcov )
    if [[ "${ID_LIKE:-}" == *rhel* ]]; then
      REQUIRED_RPMS+=( llvm-toolset )
    fi
  fi

  echo "[~] Checking for required RPM packages"

  local MISSING_RPMS=( )
  for rpm in "${REQUIRED_RPMS[@]}"; do
    if ! rpm -q "$rpm" >/dev/null; then
      MISSING_RPMS+=( "$rpm" )
    fi
  done

  if [[ "${#MISSING_RPMS[@]}" -eq 0 ]]; then
    echo "[~] OK: RPM packages required for build are installed"
    return 0
  fi

  if [[ -z "${SUDO}" ]]; then
    PACKAGE_INSTALL_CMD=( dnf install -y --skip-broken ${MISSING_RPMS[*]} )
  else
    PACKAGE_INSTALL_CMD=( "${SUDO}" dnf install -y --skip-broken ${MISSING_RPMS[*]} )
  fi
}

check_debian_pkgs () {
  local REQUIRED_DEBS=(
    curl               # download rustup
    diffutils          # build system
    build-essential    # C/C++ compiler
    pkgconf            # build system

    cmake              # Agave (protobuf-src)
    libclang-dev       # Agave (bindgen)
    libudev-dev        # Agave
    protobuf-compiler  # Agave
  )
  if [[ $DEVMODE == 1 ]]; then
    REQUIRED_DEBS+=( autoconf automake autopoint bison flex gcc-multilib gettext llvm lcov libgmp-dev perl )
  fi

  echo "[~] Checking for required DEB packages"

  local MISSING_DEBS=( )
  for deb in "${REQUIRED_DEBS[@]}"; do
    if ! dpkg -s "$deb" >/dev/null 2>/dev/null; then
      MISSING_DEBS+=( "$deb" )
    fi
  done

  if [[ ${#MISSING_DEBS[@]} -eq 0 ]]; then
    echo "[~] OK: DEB packages required for build are installed"
    return 0
  fi

  if [[ -z "${SUDO}" ]]; then
    PACKAGE_INSTALL_CMD=( apt-get install -y ${MISSING_DEBS[*]} )
  else
    PACKAGE_INSTALL_CMD=( "${SUDO}" apt-get install -y ${MISSING_DEBS[*]} )
  fi
}

check_alpine_pkgs () {
  local REQUIRED_APKS=(
    build-base       # C/C++ compiler
    curl             # download rustup
    linux-headers    # base dependency
    libucontext-dev  # base dependency
    patch            # build system
  )
  if [[ $DEVMODE == 1 ]]; then
    REQUIRED_APKS+=( autoconf automake bison flex gettext perl protobuf-dev )
  fi

  echo "[~] Checking for required APK packages"

  local MISSING_APKS=( )
  for deb in "${REQUIRED_APKS[@]}"; do
    if ! apk info -e "$deb" >/dev/null; then
      MISSING_APKS+=( "$deb" )
    fi
  done

  if [[ ${#MISSING_APKS[@]} -eq 0 ]]; then
    echo "[~] OK: APK packages required for build are installed"
    return 0
  fi

  if [[ -z "${SUDO}" ]]; then
    PACKAGE_INSTALL_CMD=( apk add ${MISSING_APKS[*]} )
  else
    PACKAGE_INSTALL_CMD=( "${SUDO}" apk add ${MISSING_APKS[*]} )
  fi
}

check_macos_pkgs () {
  local REQUIRED_FORMULAE=( perl autoconf gettext automake flex bison protobuf )

  echo "[~] Checking for required brew formulae"

  local MISSING_FORMULAE=( )
  for formula in "${REQUIRED_FORMULAE[@]}"; do
    if [[ ! -d "/usr/local/Cellar/$formula" ]]; then
      MISSING_FORMULAE+=( "$formula" )
    fi
  done

  if [[ ${#MISSING_FORMULAE[@]} -eq 0 ]]; then
    echo "[~] OK: brew formulae required for build are installed"
    return 0
  fi

  PACKAGE_INSTALL_CMD=( brew install ${MISSING_FORMULAE[*]} )
}

check () {
  DISTRO="${ID_LIKE:-${ID:-}}"
  for word in $DISTRO ; do
    case "$word" in
      fedora|debian|alpine|macos)
        check_${word}_pkgs
        ;;
      rhel|centos)
        ;;
      *)
        echo "Unsupported distro $DISTRO. Your mileage may vary."
        ;;
    esac
  done

  if [[ ! -z "${PACKAGE_INSTALL_CMD[@]}" ]]; then
    echo "[!] Found missing system packages"
    echo "[?] This is fixed by the following command:"
    echo "        ${PACKAGE_INSTALL_CMD[@]}"
    if [[ "${FD_AUTO_INSTALL_PACKAGES:-}" == "1" ]]; then
      choice=y
    else
      read -r -p "[?] Install missing system packages? (y/N) " choice
    fi
    case "$choice" in
      y|Y)
        echo "[+] Installing missing packages"
        "${PACKAGE_INSTALL_CMD[@]}"
        echo "[+] Finished installing missing packages"
        ;;
      *)
        echo "[-] Skipping package install"
        ;;
    esac
  fi

  if [[ ! -x "$(command -v cargo)" ]]; then
    echo "[!] cargo is not in PATH"
    source "$HOME/.cargo/env" || true
  fi
  if [[ ! -x "$(command -v cargo)" ]]; then
    if [[ "${FD_AUTO_INSTALL_PACKAGES:-}" == "1" ]]; then
      choice=y
    else
      read -r -p "[?] Install rustup? (y/N) " choice
    fi
    case "$choice" in
      y|Y)
        echo "[+] Installing rustup"
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        source "$HOME/.cargo/env"
        rust_toolchain=$(grep "channel" agave/rust-toolchain.toml | awk '{print $NF}' | tr -d '"')
        if [[ ! $(rustup toolchain list | grep $rust_toolchain) ]]; then
          echo "[+] Updating rustup toolchain"
          rustup toolchain add $rust_toolchain
        fi
        ;;
      *)
        echo "[-] Skipping rustup install"
        ;;
    esac
  fi
}

install_libcxx () {
  cd "$PREFIX/git/llvm"

  echo "[+] Configuring libcxx"
  rm -rf build
  mkdir build
  cd build
  cmake ../runtimes \
    -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR="lib" \
    -DCMAKE_BUILD_TYPE=Release \
    -DLLVM_DIR=".." \
    -DLLVM_ENABLE_RUNTIMES="libcxx;libcxxabi" \
    -DLLVM_USE_SANITIZER=Memory \
    -DLLVM_ENABLE_PIC=ON \
    -DLLVM_INCLUDE_TESTS=OFF \
    -DLIBCXX_INCLUDE_BENCHMARKS=OFF \
    -DLIBCXXABI_USE_LLVM_UNWINDER=OFF

  echo "[+] Building libcxx"
  "${MAKE[@]}" cxx cxxabi

  echo "[+] Installing libcxx to $PREFIX"
  "${MAKE[@]}" install-cxx install-cxxabi
  echo "[+] Successfully installed libcxx"
}

install_zstd () {
  cd "$PREFIX/git/zstd/lib"

  echo "[+] Installing zstd to $PREFIX"
  "${MAKE[@]}" DESTDIR="$PREFIX" PREFIX="" MOREFLAGS="-fPIC $EXTRA_CFLAGS" install-pc install-static install-includes
  echo "[+] Successfully installed zstd"
}

install_lz4 () {
  cd "$PREFIX/git/lz4/lib"

  echo "[+] Installing lz4 to $PREFIX"
  "${MAKE[@]}" PREFIX="$PREFIX" BUILD_SHARED=no CFLAGS="-fPIC $EXTRA_CFLAGS" install
  echo "[+] Successfully installed lz4"
}

install_s2n () {
  cd "$PREFIX/git/s2n"

  echo "[+] Installing s2n-bignum to $PREFIX"
  make -C x86
  cp x86/libs2nbignum.a "$PREFIX/lib"
  cp include/* "$PREFIX/include"
  echo "[+] Successfully installed s2n-bignum"
}

install_blst () {
  cd "$PREFIX/git/blst"

  echo "[+] Installing blst to $PREFIX"

  # this is copied from ./build.sh:27
  CFLAGS=${CFLAGS:--O2 -fno-builtin -fPIC -Wall -Wextra -Werror}
  # this adds our flags, e.g. for MSAN
  CFLAGS+=" $EXTRA_CFLAGS"

  CFLAGS=$CFLAGS ./build.sh
  cp libblst.a "$PREFIX/lib"
  cp bindings/*.h "$PREFIX/include"
  echo "[+] Successfully installed blst"
}

install_secp256k1 () {
  cd "$PREFIX/git/secp256k1"

  echo "[+] Configuring secp256k1"
  rm -rf build
  mkdir build
  cd build
  # https://github.com/bitcoin-core/secp256k1/blob/master/CMakeLists.txt#L59
  cmake .. \
    -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX:PATH="$PREFIX" \
    -DCMAKE_INSTALL_LIBDIR="lib" \
    -DCMAKE_BUILD_TYPE=Release \
    -DSECP256K1_BUILD_TESTS=OFF \
    -DSECP256K1_BUILD_EXHAUSTIVE_TESTS=OFF \
    -DSECP256K1_BUILD_BENCHMARK=OFF \
    -DSECP256K1_DISABLE_SHARED=OFF \
    -DBUILD_SHARED_LIBS=OFF \
    -DSECP256K1_ENABLE_MODULE_ECDH=OFF \
    -DSECP256K1_ENABLE_MODULE_RECOVERY=ON \
    -DSECP256K1_ENABLE_MODULE_EXTRAKEYS=OFF \
    -DSECP256K1_ENABLE_MODULE_SCHNORRSIG=OFF \
    -DSECP256K1_ENABLE_MODULE_ECDH=OFF \
    -DSECP256K1_ENABLE_MODULE_MUSIG=OFF \
    -DSECP256K1_ENABLE_MODULE_ELLSWIFT=OFF \
    -DCMAKE_C_FLAGS_RELEASE="-O3" \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_C_FLAGS="$EXTRA_CFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS_RELEASE="$EXTRA_LDFLAGS"

  echo "[+] Building secp256k1"
  "${MAKE[@]}"
  echo "[+] Successfully built secp256k1"

  echo "[+] Installing secp256k1 to $PREFIX"
  make install
  echo "[+] Successfully installed secp256k1"
}

install_openssl () {
  cd "$PREFIX/git/openssl"

  echo "[+] Configuring OpenSSL"
  ./config \
    -static \
    -fPIC \
    --prefix="$PREFIX" \
    --libdir=lib \
    no-engine \
    no-static-engine \
    no-weak-ssl-ciphers \
    no-autoload-config \
    no-tls1 \
    no-tls1-method \
    no-tls1_1 \
    no-tls1_1-method \
    no-tls1_2 \
    no-tls1_2-method \
    enable-tls1_3 \
    no-shared \
    no-legacy \
    no-tests \
    no-ui-console \
    no-sctp \
    no-ssl3 \
    no-aria \
    no-argon2 \
    no-bf \
    no-blake2 \
    no-camellia \
    no-cast \
    no-cmac \
    no-cmp \
    no-cms \
    no-comp \
    no-ct \
    no-des \
    no-dsa \
    no-dtls \
    no-dtls1-method \
    no-dtls1_2-method \
    no-fips \
    no-gost \
    no-idea \
    no-ktls \
    no-md4 \
    no-nextprotoneg \
    no-ocb \
    no-ocsp \
    no-rc2 \
    no-rc4 \
    no-rc5 \
    no-rmd160 \
    no-scrypt \
    no-seed \
    no-siphash \
    no-siv \
    no-sm3 \
    no-sm4 \
    no-srp \
    no-srtp \
    no-ts \
    no-whirlpool
  echo "[+] Configured OpenSSL"

  echo "[+] Building OpenSSL"
  "${MAKE[@]}" build_libs
  echo "[+] Successfully built OpenSSL"

  echo "[+] Installing OpenSSL to $PREFIX"
  "${MAKE[@]}" install_dev
  echo "[+] Successfully installed OpenSSL"
}

install_rocksdb () {
  cd "$PREFIX/git/rocksdb"
  local NJOBS
  NJOBS=$(( $(nproc) / 2 ))
  NJOBS=$((NJOBS>0 ? NJOBS : 1))
  make clean

  # Fix a random build failure
  git checkout HEAD -- db/blob/blob_file_meta.h
  git apply << EOF
diff --git a/db/blob/blob_file_meta.h b/db/blob/blob_file_meta.h
index d7c8a12..8cfff9b 100644
--- a/db/blob/blob_file_meta.h
+++ b/db/blob/blob_file_meta.h
@@ -5,6 +5,7 @@
 
 #pragma once
 
+#include <cstdint>
 #include <cassert>
 #include <iosfwd>
 #include <memory>
EOF

  ROCKSDB_DISABLE_NUMA=1 \
  ROCKSDB_DISABLE_ZLIB=1 \
  ROCKSDB_DISABLE_BZIP=1 \
  ROCKSDB_DISABLE_GFLAGS=1 \
  CFLAGS="-isystem $(pwd)/../../include -g0 -DSNAPPY -DZSTD -Wno-unknown-warning-option -Wno-uninitialized -Wno-array-bounds -Wno-stringop-overread -fPIC $EXTRA_CXXFLAGS" \
  make -j $NJOBS \
    LITE=1 \
    V=1 \
    static_lib
  make install-static DESTDIR="$PREFIX"/ PREFIX= LIBDIR=lib
}

install_snappy () {
  cd "$PREFIX/git/snappy"

  echo "[+] Configuring snappy"
  mkdir -p build
  cd build
  cmake .. \
    -G"Unix Makefiles" \
    -DCMAKE_INSTALL_PREFIX:PATH="" \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DCMAKE_BUILD_TYPE=Release \
    -DBUILD_SHARED_LIBS=OFF \
    -DSNAPPY_BUILD_TESTS=OFF \
    -DSNAPPY_BUILD_BENCHMARKS=OFF \
    -DCMAKE_POSITION_INDEPENDENT_CODE=ON \
    -DCMAKE_CXX_FLAGS="$EXTRA_CXXFLAGS" \
    -DCMAKE_EXE_LINKER_FLAGS="$EXTRA_LDFLAGS" \
    -DCMAKE_CXX_COMPILER_WORKS=1 # Workaround for CMake bug
  echo "[+] Configured snappy"

  echo "[+] Building snappy"
  make -j
  echo "[+] Successfully built snappy"

  echo "[+] Installing snappy to $PREFIX"
  make install DESTDIR="$PREFIX"
  echo "[+] Successfully installed snappy"
}

install () {
  CC="$(command -v $_CC)"
  cc="$CC"
  export CC
  export cc

  CXX="$(command -v $_CXX)"
  cxx="$CXX"
  export CXX
  export cxx

  mkdir -p "$PREFIX/include" "$PREFIX/lib"

  if [[ $MSAN == 1 ]]; then
    ( install_libcxx    )
  echo
  fi
  ( install_zstd      )
  ( install_lz4       )
  if [[ "$(uname -m)" == x86_64 ]]; then
    ( install_s2n )
  fi
  ( install_openssl   )
  ( install_secp256k1 )
  if [[ $DEVMODE == 1 ]]; then
    ( install_blst      )
    ( install_snappy    )
    ( install_rocksdb   )
  fi

  # Merge lib64 with lib
  if [[ -d "$PREFIX/lib64" ]]; then
    find "$PREFIX/lib64/" -mindepth 1 -exec mv -t "$PREFIX/lib/" {} +
    rm -rf "$PREFIX/lib64"
  fi

  # Remove cmake and pkgconfig files, so we don't accidentally
  # depend on them.
  rm -rf "$PREFIX/lib/cmake" "$PREFIX/lib/pkgconfig"

  echo "[~] Done!"
}

ACTION=0
while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help|help)
      help
      ;;
    "+msan")
      shift
      MSAN=1
      PREFIX="$(pwd)/opt-msan"
      _CC=clang
      _CXX=clang++
      EXTRA_CFLAGS+="-fsanitize=memory -fno-omit-frame-pointer"
      EXTRA_CXXFLAGS+="$EXTRA_CFLAGS -nostdinc++ -nostdlib++ -isystem $PREFIX/include/c++/v1"
      EXTRA_LDFLAGS+="$PREFIX/lib/libc++.a $PREFIX/lib/libc++abi.a"
      ;;
    "+dev")
      shift
      DEVMODE=1
      ;;
    nuke)
      shift
      nuke
      ACTION=1
      ;;
    fetch)
      shift
      fetch
      ACTION=1
      ;;
    check)
      shift
      check
      ACTION=1
      ;;
    install)
      shift
      install
      ACTION=1
      ;;
    *)
      echo "Unknown command: $1" >&2
      exit 1
      ;;
  esac
done

if [[ $ACTION == 0 ]]; then
  echo "[~] This will fetch, build, and install Firedancer's dependencies into $PREFIX"
  echo "[~] For help, run: $0 help"
  echo
  echo "[~] Running $0 fetch check install"

  if [[ "${FD_AUTO_INSTALL_PACKAGES:-}" == "1" ]]; then
    choice=y
  else
    read -r -p "[?] Continue? (y/N) " choice
  fi
  case "$choice" in
    y|Y)
      echo
      fetch
      check
      install
      ;;
    *)
      echo "[!] Stopping." >&2
      exit 1
  esac
fi
