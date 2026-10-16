"""Replace the tweak in an upstream IPA while retaining its existing loader entries."""

import copy
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
import zipfile


def run(*args):
    return subprocess.check_output(args, text=True)


def dependencies(path):
    return [line.split()[0] for line in run("otool", "-L", str(path)).splitlines()[2:]
            if line.startswith("\t")]


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    base, built, bundle, output = map(Path, sys.argv[1:])
    output.parent.mkdir(parents=True, exist_ok=True)
    with zipfile.ZipFile(base) as source, tempfile.TemporaryDirectory() as temp:
        names = set(source.namelist())
        plists = [name for name in names
                  if re.fullmatch(r"Payload/[^/]+\.app/Info\.plist", name)]
        if len(plists) != 1:
            raise ValueError("Expected exactly one app in the upstream IPA")
        app = plists[0].removesuffix("Info.plist")
        info = plistlib.loads(source.read(plists[0]))
        executable_name = app + info["CFBundleExecutable"]
        dylib_name = app + "Frameworks/BHTwitter.dylib"
        bundle_prefix = app + "BHTwitter.bundle/"
        original = source.read(dylib_name)
        executable = source.read(executable_name)
        old = Path(temp) / "original.dylib"
        new = Path(temp) / "BHTwitter.dylib"
        main_binary = Path(temp) / "main-executable"
        old.write_bytes(original)
        main_binary.write_bytes(executable)
        shutil.copy2(built, new)

        cryptids = re.findall(r"^\s*cryptid\s+(\d+)", run("otool", "-l", str(main_binary)), re.M)
        if any(int(value) != 0 for value in cryptids):
            raise ValueError("The upstream app executable is encrypted")

        # Match the injected framework paths already used by the released app.
        old_dependencies = dependencies(old)
        signature = subprocess.run(["codesign", "--display", str(new)], capture_output=True)
        if signature.returncode == 0:
            subprocess.run(["codesign", "--remove-signature", str(new)], check=True)
        for dependency in dependencies(new):
            if "substrate" in dependency.lower():
                matches = [dep for dep in old_dependencies if "substrate" in dep.lower()]
            else:
                matches = [dep for dep in old_dependencies
                           if Path(dep).name == Path(dependency).name]
            replacement = matches[0] if len(matches) == 1 else dependency
            if replacement.startswith("@rpath/"):
                if app + "Frameworks/" + replacement.removeprefix("@rpath/") not in names:
                    raise ValueError(f"Missing runtime dependency: {replacement}")
            elif not replacement.startswith(("/System/Library/", "/usr/lib/")):
                raise ValueError(f"Unexpected runtime dependency: {replacement}")
            if dependency != replacement:
                subprocess.run(["install_name_tool", "-change", dependency, replacement,
                                str(new)], check=True)
        subprocess.run(["codesign", "--force", "--sign", "-", "--timestamp=none",
                        str(new)], check=True)
        subprocess.run(["codesign", "--verify", "--strict", str(new)], check=True)
        replacement_data = new.read_bytes()
        if sha256(original) == sha256(replacement_data):
            raise ValueError("The replacement tweak is identical to the upstream tweak")

        with zipfile.ZipFile(output, "w", compression=zipfile.ZIP_DEFLATED,
                             compresslevel=6) as destination:
            for member in source.infolist():
                if member.filename == dylib_name or member.filename.startswith(bundle_prefix):
                    continue
                with source.open(member) as reader, destination.open(copy.copy(member), "w") as writer:
                    shutil.copyfileobj(reader, writer)
            destination.write(new, dylib_name)
            for resource in sorted(bundle.rglob("*")):
                destination.write(resource, bundle_prefix + resource.relative_to(bundle).as_posix())

    with zipfile.ZipFile(output) as result:
        if result.testzip() is not None:
            raise ValueError("The packaged IPA failed its CRC check")
        if result.read(dylib_name) != replacement_data:
            raise ValueError("The packaged IPA does not contain the newly built tweak")
        if sha256(result.read(executable_name)) != sha256(executable):
            raise ValueError("The main executable changed while repacking")
    digest = sha256(output.read_bytes())
    output.with_suffix(".ipa.sha256").write_text(f"{digest}  {output.name}\n")
    report = {
        "source_commit": os.environ["FIX_COMMIT"],
        "base_ipa_url": os.environ["BASE_IPA_URL"],
        "base_ipa_sha256": os.environ["BASE_IPA_SHA256"],
        "x_version": info["CFBundleShortVersionString"],
        "original_tweak_sha256": sha256(original),
        "fixed_tweak_sha256": sha256(replacement_data),
        "ipa_sha256": digest,
    }
    (output.parent / "build-info.json").write_text(json.dumps(report, indent=2) + "\n")
    print(json.dumps(report, indent=2))


if __name__ == "__main__":
    main()
