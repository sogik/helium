#!/bin/bash
source common.sh

# 1. Configuración y Optimización de Sistema
set_keys
sudo apt-get clean
ulimit -n 4096

export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://github.com/chromium/chromium.git 
export DEBIAN_FRONTEND=noninteractive

# --- 2. PREPARACIÓN UBUNTU ARM + INSTALACIONES MANUALES ---
echo ">>> Sistema detectado: Ubuntu ARM64 (Ampere)"

# INSTALAMOS HERRAMIENTAS NATIVAS DE UBUNTU PARA REEMPLAZAR LAS DE GOOGLE
sudo apt update || echo "⚠️ Apt update con errores leves"
sudo apt install -y sudo lsb-release file nano git curl python3 python3-pillow \
    build-essential python3-dev libncurses5 openjdk-17-jdk-headless ccache \
    gn ninja-build nasm

# A. INSTALACIÓN MANUAL NODE.JS v20 (Bypass APT)
echo ">>> 🔨 INSTALANDO NODE v20 (Manual)..."
cd /tmp
wget https://nodejs.org/dist/v20.10.0/node-v20.10.0-linux-arm64.tar.xz
tar -xf node-v20.10.0-linux-arm64.tar.xz
sudo cp -r node-v20.10.0-linux-arm64/{bin,include,lib,share} /usr/local/
sudo ln -sf /usr/local/bin/node /usr/bin/node
sudo ln -sf /usr/local/bin/npm /usr/bin/npm
cd -

# B. INSTALACIÓN MANUAL RUST (Oficial)
echo ">>> 🔨 INSTALANDO RUSTUP (Oficial)..."
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
source "$HOME/.cargo/env"
rustup toolchain install stable-aarch64-unknown-linux-gnu
rustup default stable-aarch64-unknown-linux-gnu

echo "✅ Versiones Sistema:"
echo "Node: $(node -v)"
echo "Rust: $(rustc --version)"
echo "Ninja: $(ninja --version)"
echo "GN: $(gn --version)"

# --- 3. DEPOT TOOLS ---
if [ ! -d "depot_tools" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"
export DEPOT_TOOLS_Metrics=0

# --- 4. DESCARGA CHROMIUM ---
mkdir -p chromium/src/out/Default; cd chromium
gclient root; cd src
git init
git remote add origin $CHROMIUM_SOURCE
git fetch --depth 2 $CHROMIUM_SOURCE +refs/tags/$VERSION:chromium_$VERSION
git checkout $VERSION
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

git submodule foreach git config -f ./.git/config submodule.$name.ignore all
git config --add remote.origin.fetch '+refs/tags/*:refs/tags/*'

# --- 5. PARCHEO ---
replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "HELIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Helium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "helium"

echo ">>> Aplicando parches Vanadium..."
git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

echo ">>> Sincronizando dependencias..."
gclient sync -D --no-history --nohooks
gclient runhooks

# --- SYSROOTS ---
echo ">>> Instalando Sysroots..."
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=i386
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=amd64
python3 build/linux/sysroot_scripts/install-sysroot.py --arch=arm64

# PARCHE PARA SCRIPT DE GOOGLE
sed -i 's/apt_update(options)/# apt_update(options)/' build/install-build-deps.py
./build/install-build-deps.sh --android --no-prompt || echo "⚠️ Advertencia en dependencias Google"

# ==========================================
# 🛡️ ZONA DE REEMPLAZO DE HERRAMIENTAS (FIX MASIVO)
# ==========================================

# 1. FIX NODE.JS
echo ">>> 🔧 FIX: Reemplazando Node.js..."
NODE_INTERNAL="third_party/node/linux/node-linux-x64/bin/node"
mkdir -p "$(dirname "$NODE_INTERNAL")"
rm -f "$NODE_INTERNAL"
ln -sf /usr/local/bin/node "$NODE_INTERNAL"

# 2. FIX RUST
echo ">>> 🔧 FIX: Reemplazando Rust..."
RUST_GOOGLE="third_party/rust-toolchain"
rm -rf "$RUST_GOOGLE"
mkdir -p "$RUST_GOOGLE"
LOCAL_RUST="$HOME/.rustup/toolchains/stable-aarch64-unknown-linux-gnu"
if [ -d "$LOCAL_RUST" ]; then
    cp -r "$LOCAL_RUST/"* "$RUST_GOOGLE/"
else
    cp -r /usr/lib/rustlib "$RUST_GOOGLE/"
fi

# 3. FIX GN (Nuevo)
echo ">>> 🔧 FIX: Verificando GN..."
GN_GOOGLE="buildtools/linux64/gn"
# Si existe y NO es ARM (file devuelve x86-64), lo reemplazamos
if [ -f "$GN_GOOGLE" ]; then
    if file "$GN_GOOGLE" | grep -q "x86-64"; then
        echo "   ⚠️ GN de Google es incompatible (x86). Reemplazando con el del sistema..."
        rm -f "$GN_GOOGLE"
        ln -sf /usr/bin/gn "$GN_GOOGLE"
    else
        echo "   ✅ GN de Google parece compatible."
    fi
fi

# 4. FIX NINJA (Nuevo)
echo ">>> 🔧 FIX: Verificando Ninja..."
NINJA_GOOGLE="third_party/ninja/ninja"
if [ -f "$NINJA_GOOGLE" ]; then
    if file "$NINJA_GOOGLE" | grep -q "x86-64"; then
        echo "   ⚠️ Ninja de Google es incompatible (x86). Reemplazando con el del sistema..."
        rm -f "$NINJA_GOOGLE"
        ln -sf /usr/bin/ninja "$NINJA_GOOGLE"
    else
        echo "   ✅ Ninja de Google parece compatible."
    fi
fi

# 5. FIX CLANG (Verificación)
echo ">>> 🔧 Verificando Clang..."
CLANG_BIN="third_party/llvm-build/Release+Asserts/bin/clang"
if [ -f "$CLANG_BIN" ]; then
    file "$CLANG_BIN"
    # Nota: Si Clang es incorrecto, el fix es más complejo, pero gclient suele bajar el correcto para ARM.
else
    echo "⚠️ No se encontró Clang, se intentará usar."
fi
# ==========================================

echo ">>> Transformando a Helium..."
python3 "${SCRIPT_DIR}/helium/utils/name_substitution.py" --sub -t .
python3 "${SCRIPT_DIR}/helium/utils/helium_version.py" --tree "${SCRIPT_DIR}/helium" --chromium-tree . || echo "⚠️ Advertencia versión"
python3 "${SCRIPT_DIR}/helium/utils/generate_resources.py" "${SCRIPT_DIR}/helium/resources/generate_resources.txt" "${SCRIPT_DIR}/helium/resources"
python3 "${SCRIPT_DIR}/helium/utils/replace_resources.py" "${SCRIPT_DIR}/helium/resources/helium_resources.txt" "${SCRIPT_DIR}/helium/resources" .

echo ">>> Aplicando parches Helium..."
if [ -d "$SCRIPT_DIR/helium/patches" ]; then
    shopt -s nullglob
    for patch in $SCRIPT_DIR/helium/patches/*.patch; do
        git apply --reject --whitespace=fix "$patch" || echo "⚠️ Conflicto parcial en $patch"
    done
    shopt -u nullglob
fi

# Hacks UI
sed -i 's/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Unsupported, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
sed -i 's/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_ENABLED_BY_DEFAULT);/BASE_FEATURE(kExtensionManifestV2Disabled, base::FEATURE_DISABLED_BY_DEFAULT);/' extensions/common/extension_features.cc
sed -i '/<ViewStub/{N;N;N;N;N;N; /optional_button_stub/a\
\
        <ViewStub\
            android:id="@+id/extension_toolbar_container_stub"\
            android:inflatedId="@+id/extension_toolbar_container"\
            android:layout_width="wrap_content"\
            android:layout_height="match_parent" />
}' chrome/browser/ui/android/toolbar/java/res/layout/toolbar_phone.xml
sed -i 's/extension_toolbar_baseline_width">600dp/extension_toolbar_baseline_width">0dp/' chrome/browser/ui/android/extensions/java/res/values/dimens.xml

# --- 6. CONFIGURACIÓN GN + CCACHE ---
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

# --- CORRECCIONES ARQUITECTURA ---
v8_snapshot_toolchain = "//build/toolchain/linux:clang_arm64"
enable_android_secondary_abi = false
include_both_v8_snapshots = false

# --- MATAR SISO / ACTIVAR NINJA CLASSIC ---
use_siso = false
use_remoteexec = false

# OPTIMIZACIONES
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

# --- 7. COMPILAR Y FIRMAR ---
echo ">>> Compilando con Ninja (Classic)..."
# Forzamos PATH: Cargo(Rust) + Node Local + Sistema + Depot Tools
export PATH=$HOME/.cargo/bin:/usr/local/bin:/usr/bin:$PATH

gn gen out/Default
ninja -C out/Default chrome_public_apk

# USAR JAVA DEL SISTEMA
export ANDROID_HOME=$PWD/third_party/android_sdk/public
mkdir -p out/Default/apks/release

# Buscar y firmar
APK_GENERADO=$(find out/Default/apks -name 'Chrome*.apk' | head -n 1)
if [ -z "$APK_GENERADO" ]; then
    echo "❌ ERROR: Ninja no generó ningún APK. Revisa los logs de compilación."
    exit 1
fi

sign_apk "$APK_GENERADO" out/Default/apks/release/$VERSION.apk

ccache -s