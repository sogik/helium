#!/bin/bash
export SCRIPT_DIR=$(realpath $(dirname $0))

replace() {
    export org=$2 new=$3
    find $1 -type f -exec sed -i 's@'$org'@'$new'@g' {} \;
}

set_keys() {
    echo ">>> Configuración de llaves de firma..."
    mkdir -p $SCRIPT_DIR/keys
    
    if [ -z "$LOCAL_TEST_JKS" ] || [ -z "$STORE_TEST_JKS" ]; then
        echo "ADVERTENCIA: Secretos no encontrados. La firma fallará."
        return 1
    fi

    echo "$LOCAL_TEST_JKS" | base64 -d > $SCRIPT_DIR/keys/local.properties
    echo "$STORE_TEST_JKS" | base64 -d > $SCRIPT_DIR/keys/test.jks
    
    unset LOCAL_TEST_JKS
    unset STORE_TEST_JKS
}

sign_apk() {
    echo ">>> Iniciando proceso de firma..."
    
    export apksigner=$(find $ANDROID_HOME/build-tools -name apksigner | sort | tail -n 1)
    
    if [ -z "$apksigner" ]; then
        echo "❌ ERROR: No se encontró 'apksigner'. Verifica la descarga del SDK."
        exit 1
    fi

    if [ -f "$SCRIPT_DIR/keys/local.properties" ]; then
        source $SCRIPT_DIR/keys/local.properties
        
        echo ">>> Firmando con alias: $keyAlias"
        $apksigner sign --verbose \
          --ks $SCRIPT_DIR/keys/test.jks \
          --ks-pass pass:$storePassword \
          --key-pass pass:$keyPassword \
          --ks-key-alias $keyAlias \
          --out $2 $1 || exit 1
          
        echo "APK firmado correctamente: $2"
        
        rm -rf $SCRIPT_DIR/keys
    else
        echo "❌ ERROR: No se encontraron las llaves decodificadas."
        exit 1
    fi
}
