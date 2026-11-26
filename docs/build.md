# Build SDK Build Tools

The Linux x86-64 build uses Python 3.14, GNU Make, Bash, curl, tar, unzip, CMake, Ninja, Clang 21, LLVM 21, Bison and Flex. Install the libc++ 22, libc++abi 22, libunwind 22, zlib, PNG and Expat development packages.

```sh
make build
make verify
```

`make fetch` prepares the locked inputs separately. The repository's `out/` directory holds the source archives, work directories and output ZIP. Set `BUILD_JOBS` to adjust parallelism. Set `LLVM_ROOT` to the extracted `usr` prefix when the libc++ development packages are installed outside the system prefix.

The [input lock](../locks/inputs.json) records the Android 16 project revisions and the AOSStudio JDK and standalone R8 Release assets. The build compiles the six native tools, builds apksigner and the lambda stubs, and assembles D8, R8 and Retrace using the published R8 9.5.28 JARs. Review new Nightly assets before updating their pinned digests.

The output is `out/dist/aosstudio-build-tools-36.0.0-linux-x86_64.zip`. Its `build-tools/` directory corresponds to the contents of `<sdk>/build-tools/36.0.0/` after SDK installation. The Java launchers use `JAVA_HOME` when set and `java` on `PATH` otherwise.

Verification extracts that ZIP, compiles and selects a resource split, generates AIDL bindings, builds and reads DEX, shrinks a fixture and retraces its stack, and aligns, signs and verifies an APK. The standalone D8 version in this package is 9.5.28. AGP supplies its own D8 and R8 as part of the plugin.
