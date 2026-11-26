"""Package the Java Build Tools and the pinned standalone R8 release."""

from pathlib import Path
from shutil import copyfile, copytree
import subprocess
import sys
from zipfile import ZipFile

R8 = "9.5.28"
JAR_DATE = "2026-06-05T00:00:00Z"


def build_apksigner(source: Path, work: Path, package: Path) -> None:
    cli = source / "src/apksigner/java"
    library = source / "src/main/java"
    kms = library / "com/android/apksig/kms"
    classes = work / "apksigner-classes"
    classes.mkdir()
    sources = sorted(
        path
        for path in library.rglob("*.java")
        if not path.is_relative_to(kms / "aws") and not path.is_relative_to(kms / "gcp")
    ) + sorted(cli.rglob("*.java"))
    subprocess.run(
        ["javac", "-encoding", "UTF-8", "--release", "8", "-d", classes, *sources],
        check=True,
    )
    for resource in cli.rglob("*.txt"):
        destination = classes / resource.relative_to(cli)
        destination.parent.mkdir(parents=True, exist_ok=True)
        copyfile(resource, destination)
    (classes / "META-INF").mkdir(exist_ok=True)
    copyfile(source / "LICENSE", classes / "META-INF/LICENSE")
    subprocess.run(
        [
            "jar",
            "--create",
            "--file",
            package / "lib/apksigner.jar",
            "--date",
            JAR_DATE,
            "--main-class",
            "com.android.apksigner.ApkSignerTool",
            "-C",
            classes,
            ".",
        ],
        check=True,
    )
    launcher = package / "apksigner"
    copyfile(source / "etc/apksigner", launcher)
    launcher.chmod(0o755)


def build_lambda_stubs(source: Path, work: Path, package: Path) -> None:
    classes = work / "lambda-classes"
    classes.mkdir()
    sources = sorted(source.rglob("*.java"))
    # Libcore's stubs reference annotations from the host JDK while targeting Java 8.
    subprocess.run(
        [
            "javac",
            "-encoding",
            "UTF-8",
            "-source",
            "8",
            "-target",
            "8",
            "-d",
            classes,
            *sources,
        ],
        check=True,
    )
    # Ship the corresponding source with the Classpath-exception stubs.
    for path in sources:
        copyfile(path, classes / path.relative_to(source))
    subprocess.run(
        [
            "jar",
            "--create",
            "--file",
            package / "core-lambda-stubs.jar",
            "--date",
            JAR_DATE,
            "-C",
            classes,
            ".",
        ],
        check=True,
    )


def install_r8(release: Path, package: Path) -> None:
    libraries = package / "lib"
    copytree(release / "lib", libraries, dirs_exist_ok=True)
    for name in ("d8", "r8", "retrace"):
        script = (release / "bin" / name).read_text()
        parent_path = '")/.."'
        if script.count(parent_path) != 1:
            raise ValueError(f"Unexpected standalone {name} launcher layout")
        launcher = package / name
        launcher.write_text(script.replace(parent_path, '")"'))
        launcher.chmod(0o755)

    # The SDK path also supports tools that launch lib/d8.jar directly.
    classpath = " ".join(
        [f"r8-{R8}.jar"]
        + [
            f"r8-runtime/{jar.name}"
            for jar in sorted((libraries / "r8-runtime").glob("*.jar"))
        ]
    )
    attribute = f"Class-Path: {classpath}"
    continuation = [
        f" {attribute[index : index + 69]}" for index in range(70, len(attribute), 69)
    ]
    manifest = "\r\n".join(
        [
            "Manifest-Version: 1.0",
            "Main-Class: com.android.tools.r8.D8",
            attribute[:70],
            *continuation,
            "",
            "",
        ]
    )
    with ZipFile(libraries / "d8.jar", "w") as launcher_jar:
        launcher_jar.writestr("META-INF/MANIFEST.MF", manifest)
    for name in ("LICENSE", "LIBRARY-LICENSE", "inputs.json"):
        copyfile(release / name, package / "licenses" / f"r8-{name}")


def main() -> None:
    work, package = map(Path, sys.argv[1:])
    source = work / "source"
    build_apksigner(source / "tools/apksig", work, package)
    build_lambda_stubs(source / "libcore/ojluni/src/lambda/java", work, package)
    install_r8(work / f"aosstudio-r8-{R8}", package)


if __name__ == "__main__":
    main()
