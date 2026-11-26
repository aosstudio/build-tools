#!/usr/bin/env bash
set -euo pipefail

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
python=${PYTHON:-python3}
version=$("$python" scripts/inputs.py --version)
work=$(mktemp -d "$root/out/verify.XXXXXXXX")
trap 'rm -rf -- "$work"' EXIT
bin="$work/build-tools"
export LC_ALL=C TZ=UTC HOME="$work/home" TMPDIR="$work/tmp"
export JAVA_HOME="$work/jdk"
export PATH="$JAVA_HOME/bin:$PATH"
unset JDK_JAVA_OPTIONS JAVA_TOOL_OPTIONS _JAVA_OPTIONS CLASSPATH
mkdir -p "$JAVA_HOME" "$HOME" "$TMPDIR" "$work/classes" "$work/dex" "$work/jar-dex"
tar -xzf out/inputs/tool/aosstudio-jdk-21.0.13.1-2-linux-x86_64.tar.gz -C "$JAVA_HOME"
unzip -q "out/dist/aosstudio-build-tools-$version-linux-x86_64.zip" -d "$work"
grep -Fx "Pkg.Revision=$version" "$bin/source.properties"
cmp locks/inputs.json "$bin/source-inputs.json"
test -s "$bin/licenses/r8-LICENSE"
test -s "$bin/licenses/libcore-LICENSE"

javac --release 11 -d "$work/classes" tests/R8Smoke.java
jar --create --file "$work/input.jar" -C "$work/classes" .
for tool in d8 r8 retrace; do
    "$bin/$tool" --version | grep -F ' 9.5.28 '
done
"$bin/d8" --min-api 24 --output "$work/dex" "$work/input.jar"
"$bin/dexdump" "$work/dex/classes.dex" > "$work/dex.txt"
grep -F "Class descriptor  : 'LR8Smoke;'" "$work/dex.txt"
java -jar "$bin/lib/d8.jar" --min-api 24 --output "$work/jar-dex" "$work/input.jar"
test -s "$work/jar-dex/classes.dex"

"$bin/r8" --classfile --release --lib "$JAVA_HOME" --output "$work/shrunk.jar" \
    --pg-conf "$root/tests/keep.pro" --pg-map-output "$work/mapping.txt" "$work/input.jar"
jar --list --file "$work/shrunk.jar" > "$work/shrunk.txt"
grep -Fx R8Smoke.class "$work/shrunk.txt"
if grep -Fxq Unused.class "$work/shrunk.txt"; then
    printf '%s\n' 'R8 kept the unused fixture class.' >&2
    exit 1
fi
if java -cp "$work/shrunk.jar" R8Smoke crash 2> "$work/stacktrace.txt"; then
    printf '%s\n' 'The fixture did not throw.' >&2
    exit 1
fi
"$bin/retrace" "$work/mapping.txt" "$work/stacktrace.txt" > "$work/retraced.txt"
grep -F 'at Crash.raise(' "$work/retraced.txt"

"$bin/aidl" --lang=java -I "$root/tests/aidl" -o "$work/aidl" "$root/tests/aidl/probe/ITest.aidl"
grep -F 'readVersion' "$work/aidl/probe/ITest.java"
jar --list --file "$bin/core-lambda-stubs.jar" > "$work/lambda.txt"
grep -Fx 'java/lang/invoke/LambdaMetafactory.class' "$work/lambda.txt"
grep -Fx 'java/lang/runtime/SwitchBootstraps.class' "$work/lambda.txt"

"$bin/aapt2" compile --dir tests/framework/res -o "$work/framework-resources.zip"
"$bin/aapt2" link --manifest tests/framework/AndroidManifest.xml \
    -o "$work/framework.apk" "$work/framework-resources.zip"
"$bin/aapt2" compile --dir tests/res -o "$work/resources.zip"
"$bin/aapt2" link -I "$work/framework.apk" --manifest tests/AndroidManifest.xml --split "$work/fr.apk:fr" \
    -o "$work/base.apk" "$work/resources.zip"
"$bin/aapt" list "$work/base.apk" | grep -Fx resources.arsc
"$bin/split-select" --target fr --base "$work/base.apk" --split "$work/fr.apk" | grep -Fx "$work/fr.apk"
jar --update --file "$work/base.apk" -C "$work/dex" classes.dex
"$bin/zipalign" -P 16 -f 4 "$work/base.apk" "$work/aligned.apk"
keytool -genkeypair -keystore "$work/test.p12" -storepass changeit -keypass changeit \
    -alias build-tools-test -keyalg RSA -keysize 2048 -validity 1 -dname 'CN=Build Tools Test'
"$bin/apksigner" sign --ks "$work/test.p12" --ks-pass pass:changeit --min-sdk-version 24 \
    --v1-signing-enabled false --v2-signing-enabled true --out "$work/signed.apk" "$work/aligned.apk"
"$bin/zipalign" -c -P 16 4 "$work/signed.apk"
"$bin/apksigner" verify --min-sdk-version 24 --max-sdk-version 37 --verbose "$work/signed.apk" |
    grep -F 'Verified using v2 scheme (APK Signature Scheme v2): true'
printf 'Build Tools %s package verified\n' "$version"
