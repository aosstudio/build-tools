#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob

root=$(cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
python=${PYTHON:-python3}
jobs=${BUILD_JOBS:-10}
llvm=${LLVM_ROOT:-/usr}
cache="$root/out/inputs/tool"
test "$(uname -s)" = Linux
test "$(uname -m)" = x86_64
case "$(findmnt -n -o FSTYPE -T out)" in
    tmpfs|ramfs) printf '%s\n' 'Use a disk-backed build directory.' >&2; exit 1 ;;
esac
test -f "$llvm/lib/llvm-22/include/c++/v1/vector"
test -f "$llvm/lib/x86_64-linux-gnu/libc++.a"
version=$("$python" scripts/inputs.py --version)
name="aosstudio-build-tools-$version-linux-x86_64"
work=$(mktemp -d "$root/out/build.XXXXXXXX")
trap 'if (( $? == 0 )); then rm -rf -- "$work"; else printf "Build files kept at %s\n" "$work" >&2; fi' EXIT
export LC_ALL=C TZ=UTC TMPDIR="$work/tmp"
export JAVA_HOME="$work/jdk"
unset JDK_JAVA_OPTIONS JAVA_TOOL_OPTIONS _JAVA_OPTIONS CLASSPATH
source_dir="$work/source"
package="$work/build-tools"
licenses="$package/licenses"
mkdir -p "$TMPDIR" "$JAVA_HOME" "$source_dir" "$licenses" "$package/lib" \
    "$work/generated" "$work/runtime" "$root/out/dist"

"$python" scripts/inputs.py --source "$source_dir"
tar -xzf "$cache/aosstudio-jdk-21.0.13.1-2-linux-x86_64.tar.gz" -C "$JAVA_HOME"
tar -xzf "$cache/aosstudio-r8-9.5.28.tar.gz" -C "$work"
export PATH="$JAVA_HOME/bin:$PATH"
"$python" scripts/java-tools.py "$work" "$package"

generate_operators() {
    local header_root=$1 output=$2
    shift 2
    local headers=("$@")
    "$python" "$cache/generate_operator_out.py" "$header_root" "${headers[@]/#/$header_root/}" > "$output"
}
generate_operators "$source_dir/art/libartbase" "$work/generated/artbase-operators.cc" \
    arch/instruction_set.h base/allocator.h base/unix_file/fd_file.h
generate_operators "$source_dir/art/libdexfile" "$work/generated/dexfile-operators.cc" \
    dex/dex_file.h dex/dex_file_layout.h dex/dex_instruction.h dex/dex_instruction_utils.h dex/invoke_type.h
patch --batch --fuzz=0 -p1 -d "$source_dir/system/libbase" -i "$root/native/const-properties-comparator.patch"

libdir="$llvm/lib/x86_64-linux-gnu"
(
    cd "$work/runtime"
    printf 'CREATE libc++.a\nADDLIB %s/libunwind.a\nADDLIB %s/libc++abi.a\nADDLIB %s/libc++.a\nSAVE\nEND\n' \
        "$libdir" "$libdir" "$libdir" | llvm-ar-21 -M
)
cmake -S native -B "$work/native" -G Ninja \
    -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=clang-21 -DCMAKE_CXX_COMPILER=clang++-21 \
    "-DCMAKE_CXX_FLAGS=-stdlib=libc++ -nostdinc++ -Wno-unused-command-line-argument -isystem \"$llvm/lib/llvm-22/include/c++/v1\"" \
    "-DCMAKE_EXE_LINKER_FLAGS=-L\"$work/runtime\" -static-libstdc++ -Wl,-z,now" \
    -DCMAKE_CXX_FLAGS_RELEASE='-O2 -DNDEBUG' \
    "-DSOURCE_DIR=$source_dir" "-DGENERATED_DIR=$work/generated" "-DJDK_DIR=$JAVA_HOME"
native=(aapt aapt2 aidl dexdump split-select zipalign)
cmake --build "$work/native" --parallel "$jobs" --target "${native[@]}"
for program in "${native[@]}"; do
    install -m 0755 "$work/native/$program" "$package/$program"
done

install -m 0644 "$source_dir/tools/apksig/LICENSE" "$licenses/AOSP"
install -m 0644 "$cache"/libcore-{LICENSE,NOTICE} "$licenses/"
for project in external/{abseil-cpp,fmtlib,googletest,protobuf,protobuf/third_party/utf8_range,tinyxml2,zopfli} \
    frameworks/base/{libs/androidfw,tools/aapt,tools/aapt2,tools/split-select} \
    build/tools/zipalign system/{core/libcutils,core/libutils,incremental_delivery/incfs/util,libbase,libziparchive,logging/liblog,tools/aidl}; do
    for notice in "$source_dir/$project"/{LICENSE*,NOTICE*,COPYING*}; do
        [[ -f "$notice" ]] || continue
        install -m 0644 "$notice" "$licenses/${project//\//-}-${notice##*/}"
    done
done
for library in libc++-22-dev libc++abi-22-dev libunwind-22-dev; do
    install -m 0644 "$llvm/share/doc/$library/copyright" "$licenses/$library"
done
for library in zlib1g-dev libexpat1-dev libpng-dev bison flex; do
    install -m 0644 "/usr/share/doc/$library/copyright" "$licenses/$library"
done
install -m 0644 locks/inputs.json "$package/source-inputs.json"
printf 'Pkg.UserSrc=false\nPkg.Revision=%s\n' "$version" > "$package/source.properties"
"$python" scripts/package.py "$work" "$work/$name.zip"
mv -- "$work/$name.zip" "$root/out/dist/$name.zip"
printf '%s\n' "$root/out/dist/$name.zip"
