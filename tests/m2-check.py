"""Integrity of a Maven local repository: every jar a valid zip, every pom well-formed, no partial downloads."""
import pathlib, sys, zipfile
import xml.etree.ElementTree as ET
root = pathlib.Path(sys.argv[1] if len(sys.argv) > 1 else pathlib.Path.home() / ".m2/repository")
bad, jars, poms = [], 0, 0
for j in root.rglob("*.jar"):
    jars += 1
    try:
        with zipfile.ZipFile(j) as z:
            if z.testzip() is not None:
                bad.append(f"jar crc {j}")
    except Exception as e:
        bad.append(f"jar {j}: {e}")
for p in root.rglob("*.pom"):
    poms += 1
    try:
        ET.parse(p)
    except Exception as e:
        bad.append(f"pom {p}: {e}")
partial = [str(p) for p in root.rglob("*") if p.suffix in (".part", ".lastUpdated") or ".tmp" in p.name]
size = sum(p.stat().st_size for p in root.rglob("*") if p.is_file()) // 2**20
print(f"jars={jars} poms={poms} corrupt={len(bad)} partial={len(partial)} size={size}MB")
for line in (bad + partial)[:15]:
    print("  ", line)
