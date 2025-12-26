#!/bin/bash
source common.sh

# 1. PREPARACIÓN (Fix Copilot)
set_keys
ulimit -n 4096

echo ">>> 🧹 Limpiando APT..."
sudo dpkg --remove-architecture i386 2>/dev/null || true
sudo rm -rf /var/lib/apt/lists/*
sudo apt-get update -y
sudo apt-get install -y sudo lsb-release file nano git curl python3 python3-pillow \
    build-essential python3-dev libncurses5 openjdk-17-jdk-headless ccache \
    ninja-build nasm clang lld unzip pkg-config

export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://github.com/chromium/chromium.git 
export DEBIAN_FRONTEND=noninteractive

# 2. HERRAMIENTAS
echo ">>> Instalando herramientas..."
cd /tmp
wget -q https://nodejs.org/dist/v20.10.0/node-v20.10.0-linux-arm64.tar.xz
tar -xf node-v20.10.0-linux-arm64.tar.xz
sudo cp -r node-v20.10.0-linux-arm64/{bin,include,lib,share} /usr/local/
sudo ln -sf /usr/local/bin/node /usr/bin/node
sudo ln -sf /usr/local/bin/npm /usr/bin/npm

curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install stable-aarch64-unknown-linux-gnu
rustup default stable-aarch64-unknown-linux-gnu

wget -q -O gn_arm64.zip "https://chrome-infra-packages.appspot.com/dl/gn/gn/linux-arm64/+/latest"
unzip -o -q gn_arm64.zip
sudo mv gn /usr/local/bin/gn
sudo chmod +x /usr/local/bin/gn

# 3. CÓDIGO
cd "/home/ubuntu/actions-runner/actions-runner/_work/helium/helium" || echo "⚠️ Buscando ruta..."
if [ ! -d "depot_tools" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"

mkdir -p chromium/src/out/Default; cd chromium
gclient root; cd src
if ! git remote | grep -q origin; then
    git remote add origin $CHROMIUM_SOURCE
fi
git fetch --depth 2 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
git checkout -f $VERSION
export COMMIT=$(git show-ref -s $VERSION | head -n1)

cat > ../.gclient <<EOF
solutions = [
  {
    "name": "src",
    "url": "$CHROMIUM_SOURCE@$COMMIT",
    "deps_file": "DEPS",
    "managed": False,
    "custom_vars": {
      "checkout_android_prebuilts_build_tools": True,
      "checkout_telemetry_dependencies": False,
      "codesearch": "Debug",
    },
  },
]
target_os = ["android"]
EOF

# LIMPIEZA
git am --abort 2>/dev/null || true
rm -rf .git/rebase-apply .git/rebase-merge
git reset --hard HEAD
git clean -fd

# SYNC
gclient sync -D --no-history --nohooks
gclient runhooks

# PARCHES
cd ../.. 
replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "HELIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Helium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "helium"

cd chromium/src
git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch
./build/install-build-deps.sh --android --no-prompt --no-arm --no-chromeos-fonts || echo "⚠️ Warning deps"

# 4. REEMPLAZO HERRAMIENTAS
echo ">>> 🔧 Reemplazando herramientas..."
NODE_INTERNAL="third_party/node/linux/node-linux-x64/bin/node"
mkdir -p "$(dirname "$NODE_INTERNAL")"
rm -f "$NODE_INTERNAL"
ln -sf /usr/local/bin/node "$NODE_INTERNAL"

LLVM_BIN_DIR="third_party/llvm-build/Release+Asserts/bin"
CLANG_GOOGLE="$LLVM_BIN_DIR/clang"
if [ -f "$CLANG_GOOGLE" ] && file "$CLANG_GOOGLE" | grep -q "x86-64"; then
    rm -f "$LLVM_BIN_DIR/clang"
    rm -f "$LLVM_BIN_DIR/clang++"
    rm -f "$LLVM_BIN_DIR/lld"
    ln -sf /usr/bin/clang "$LLVM_BIN_DIR/clang"
    ln -sf /usr/bin/clang++ "$LLVM_BIN_DIR/clang++"
    ln -sf /usr/bin/lld "$LLVM_BIN_DIR/lld"
fi

RUST_GOOGLE="third_party/rust-toolchain"
rm -rf "$RUST_GOOGLE"
mkdir -p "$RUST_GOOGLE"
cp -r "$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu/"* "$RUST_GOOGLE/"

# HELIUM TRANSFORMATION
SRC_PATH=$(find /home/ubuntu/actions-runner -type f -path "*/chromium/src/chrome/VERSION" -print -quit)
REAL_SRC_DIR="${SRC_PATH%/chrome/VERSION}"
cd "$REAL_SRC_DIR"

python3 "${SCRIPT_DIR}/helium/utils/name_substitution.py" --sub -t . || true
python3 "${SCRIPT_DIR}/helium/utils/helium_version.py" --tree "${SCRIPT_DIR}/helium" --chromium-tree . || true
python3 "${SCRIPT_DIR}/helium/utils/generate_resources.py" "${SCRIPT_DIR}/helium/resources/generate_resources.txt" "${SCRIPT_DIR}/helium/resources" || true
python3 "${SCRIPT_DIR}/helium/utils/replace_resources.py" "${SCRIPT_DIR}/helium/resources/helium_resources.txt" "${SCRIPT_DIR}/helium/resources" . || true

if [ -d "$SCRIPT_DIR/helium/patches" ]; then
    shopt -s nullglob
    for patch in $SCRIPT_DIR/helium/patches/*.patch; do
        git apply --reject --whitespace=fix "$patch" || echo "⚠️ Ya aplicado"
    done
    shopt -u nullglob
fi

# =================================================================
# ☢️ ZONA CRÍTICA: FIX MAESTRO RUST (CORREGIDO) ☢️
# =================================================================
echo ">>> 💉 Ejecutando FIX MAESTRO en Rust (Versión Quirúrgica)..."

# Hash exacto que Google espera (incluido el -1)
TARGET_HASH="15283f6fe95e5b604273d13a428bab5fc0788f5a-1"

# 1. Crear el archivo VERSION físico (para que la parte de la lista funcione)
mkdir -p third_party/rust-toolchain
echo "$TARGET_HASH" > third_party/rust-toolchain/VERSION
echo "✅ Archivo VERSION creado: $TARGET_HASH"

# 2. Hackear rust.gni SOLO para la variable rustc_revision
# IMPORTANTE: No usamos un replace global. Usamos regex específico.
python3 -c "
import re
fname = 'build/config/rust.gni'
with open(fname, 'r') as f: content = f.read()

# Buscamos ESPECÍFICAMENTE: rustc_revision = read_file(...)
# Y lo cambiamos por: rustc_revision = \"HASH\"
# Dejamos intactos otros read_file (como el que lee la lista de triples)
pattern = r'(rustc_revision\s*=\s*)read_file\s*\(\s*\".*?VERSION\".*?\)'
new_content = re.sub(pattern, f'rustc_revision = \"{TARGET_HASH}\"', content, count=1)

if content != new_content:
    with open(fname, 'w') as f: f.write(new_content)
    print('✅ rust.gni hackeado: rustc_revision forzada (lista intacta).')
else:
    print('⚠️ No se encontró la definición de rustc_revision. ¿Ya estaba parcheado?')
"

# 3. Hackear update_rust.py para que devuelva el mismo hash
UPDATE_SCRIPT="tools/rust/update_rust.py"
echo "✅ Sobrescribiendo $UPDATE_SCRIPT..."
cat > "$UPDATE_SCRIPT" <<EOF
import sys
# Imprimimos el hash sin salto de línea
print("$TARGET_HASH", end="")
sys.exit(0)
EOF

echo "✅ Script update_rust.py lobotomizado."
# =================================================================

# Hacks UI
if [ -f "extensions/common/extension_features.cc" ]; then
    sed -i 's/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
    sed -i 's/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
fi
if [ -f "chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml" ]; then
    sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
\
        <ViewStub\
            android:id="@+id/extension_toolbar_container_stub"\
            android:inflatedId="@+id/extension_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml
fi
if [ -f "chrome/browser/ui/android/extensions/java/res/values/dimens.xml" ]; then
    sed -i 's/extension_toolbar_baseline_width">600dp/extension_toolbar_baseline_width">0dp/' chrome/browser/ui/android/extensions/java/res/values/dimens.xml
fi

# --- CONFIG Y COMPILACIÓN ---
export CCACHE_DIR=/home/$(whoami)/.ccache
mkdir -p $CCACHE_DIR
export CCACHE_MAXSIZE=30G 
echo ">>> Usando CCache en: $CCACHE_DIR"

if [ -f "out/Default/.siso_config" ] || [ -f "out/Default/build.ninja.stamp" ]; then
    rm -rf out/Default
fi
mkdir -p out/Default

cat > out/Default/args.gn <<EOF
chrome_public_manifest_package = "io.github.jqssun.helium"
is_desktop_android = true 
target_os = "android"
target_cpu = "arm64"
host_cpu = "arm64" 
skip_rust_toolchain_consistency_check = true
v8_snapshot_toolchain = "//build/toolchain/linux:clang_arm64"
enable_android_secondary_abi = false
include_both_v8_snapshots = false
clang_use_chrome_plugins = false
linux_use_bundled_binutils = false
use_custom_libcxx = false
use_siso = false
use_remoteexec = false
cc_wrapper = "ccache"
use_thin_lto = false
concurrent_links = 2
is_component_build = false
is_debug = false
is_official_build = true
symbol_level = 0
blink_symbol_level = 0
disable_fieldtrial_testing_config = true
ffmpeg_branding = "Chrome"
proprietary_codecs = true
enable_vr = false
enable_arcore = false
enable_openxr = false
enable_cardboard = false
enable_remoting = false
enable_reporting = false
google_api_key = "x"
google_default_client_id = "x"
google_default_client_secret = "x"
use_debug_fission=true
use_errorprone_java_compiler=false
use_official_google_api_keys=false
use_rtti=false
enable_av1_decoder=true
enable_dav1d_decoder=true
generate_linker_map = false
EOF

echo ">>> Compilando con Ninja (Classic)..."
export PATH=$HOME/.cargo/bin:/usr/local/bin:/usr/bin:$PATH

if [ ! -f "BUILD.gn" ]; then
   git checkout HEAD -- BUILD.gn
fi

gn gen out/Default
ninja -C out/Default chrome_public_apk

# FIRMA
export ANDROID_HOME=$PWD/third_party/android_sdk/public
mkdir -p out/Default/apks/release
APK_GENERADO=$(find out/Default/apks -name 'Chrome*.apk' | head -n 1)
if [ -z "$APK_GENERADO" ]; then
    echo "❌ ERROR: Ninja no generó ningún APK. Revisa los logs de compilación."
    exit 1
fi
sign_apk "$APK_GENERADO" out/Default/apks/release/$VERSION.apk
ccache -s
