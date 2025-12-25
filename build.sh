#!/bin/bash
source common.sh

set_keys
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*

export VERSION=$(grep -m1 -o '[0-9]\+\(\.[0-9]\+\)\{3\}' vanadium/args.gn)
export CHROMIUM_SOURCE=https://github.com/chromium/chromium.git 
export DEBIAN_FRONTEND=noninteractive

ARCH=$(uname -m)
if [ "$ARCH" = "aarch64" ]; then
    echo ">>> Detectado sistema ARM64 (Oracle Cloud Ampere)"
    sudo apt update
    sudo apt install -y sudo lsb-release file nano git curl python3 python3-pillow \
        build-essential python3-dev libncurses5 openjdk-17-jdk-headless
else
    sudo apt update
    sudo apt install -y sudo lsb-release file nano git curl python3 python3-pillow
fi

if [ ! -d "depot_tools" ]; then
    git clone --depth 1 https://chromium.googlesource.com/chromium/tools/depot_tools.git
fi
export PATH="$PWD/depot_tools:$PATH"
export DEPOT_TOOLS_Metrics=0

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


replace "$SCRIPT_DIR/vanadium/patches" "VANADIUM" "HELIUM"
replace "$SCRIPT_DIR/vanadium/patches" "Vanadium" "Helium"
replace "$SCRIPT_DIR/vanadium/patches" "vanadium" "helium"

echo ">>> Aplicando parches base de Vanadium..."
git am --whitespace=nowarn --keep-non-patch $SCRIPT_DIR/vanadium/patches/*.patch

echo ">>> Sincronizando dependencias de Chromium..."
gclient sync -D --no-history --nohooks
gclient runhooks

rm -rf third_party/angle/third_party/VK-GL-CTS/
./build/install-build-deps.sh --android --no-prompt

echo ">>> Ejecutando scripts de identidad de Helium..."
python3 "${SCRIPT_DIR}/helium/utils/name_substitution.py" --sub -t .
python3 "${SCRIPT_DIR}/helium/utils/helium_version.py" --tree "${SCRIPT_DIR}/helium" --chromium-tree . || echo "Advertencia: Script de versión falló o no encontró tags."
python3 "${SCRIPT_DIR}/helium/utils/generate_resources.py" "${SCRIPT_DIR}/helium/resources/generate_resources.txt" "${SCRIPT_DIR}/helium/resources"
python3 "${SCRIPT_DIR}/helium/utils/replace_resources.py" "${SCRIPT_DIR}/helium/resources/helium_resources.txt" "${SCRIPT_DIR}/helium/resources" .

echo ">>> Aplicando parches específicos de Helium..."
if [ -d "$SCRIPT_DIR/helium/patches" ]; then
    for patch in $SCRIPT_DIR/helium/patches/*.patch; do
        git apply --reject --whitespace=fix "$patch" || echo "CONFLICTO PARCIAL: $patch (revisar archivos .rej)"
    done
fi

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

cat > out/Default/args.gn <<EOF
chrome_public_manifest_package = "io.github.jqssun.helium"
is_desktop_android = true 
target_os = "android"
target_cpu = "arm64"
host_cpu = "arm64" 

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

# Gestión de Memoria (24GB permite 2 enlaces simultáneos seguros)
concurrent_links = 2
use_debug_fission=true
use_errorprone_java_compiler=false
use_official_google_api_keys=false
use_rtti=false
enable_av1_decoder=true
enable_dav1d_decoder=true
include_both_v8_snapshots = false
include_both_v8_snapshots_android_secondary_abi = false
generate_linker_map = false
EOF

echo ">>> Iniciando compilación con Ninja..."
gn gen out/Default
autoninja -C out/Default chrome_public_apk

export PATH=$PWD/third_party/jdk/current/bin/:$PATH
export ANDROID_HOME=$PWD/third_party/android_sdk/public
mkdir -p out/Default/apks/release

sign_apk $(find out/Default/apks -name 'Chrome*.apk') out/Default/apks/release/$VERSION.apk
