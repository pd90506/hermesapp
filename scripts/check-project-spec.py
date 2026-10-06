#!/usr/bin/env python3
"""Linux-side sanity check for project.yml (XcodeGen does not run here).

Checks that the spec parses as YAML, that every source path, config file and
local package it references exists, that package products named in target
dependencies are declared in the package manifest, and that no Swift file
under Apps/ is left out of every target. It does NOT replace running
`xcodegen generate` on the Mac.

Usage: python3 scripts/check-project-spec.py   (needs PyYAML)
"""
import pathlib
import re
import sys

try:
    import yaml
except ModuleNotFoundError:
    sys.exit(f"check-project-spec.py needs PyYAML, which {sys.executable} cannot import.\n"
             f"Install it with:  {sys.executable} -m pip install --user pyyaml\n"
             "(Debian/Ubuntu: sudo apt install python3-yaml)")

ROOT = pathlib.Path(__file__).resolve().parent.parent
errors: list[str] = []


def need(path: str, what: str) -> pathlib.Path:
    p = ROOT / path
    if not p.exists():
        errors.append(f"{what} does not exist: {path}")
    return p


spec = yaml.safe_load((ROOT / "project.yml").read_text())
for key in ("name", "targets", "packages"):
    if key not in spec:
        errors.append(f"missing top-level key: {key}")

for config, path in (spec.get("configFiles") or {}).items():
    need(path, f"configFiles.{config}")

products: dict[str, set[str]] = {}
for name, package in (spec.get("packages") or {}).items():
    manifest = need(f"{package['path']}/Package.swift", f"package {name} manifest")
    if manifest.exists():
        products[name] = set(re.findall(r'\.library\(name:\s*"([^"]+)"', manifest.read_text()))

covered: set[pathlib.Path] = set()
for target_name, target in spec["targets"].items():
    for key in ("type", "platform", "sources"):
        if key not in target:
            errors.append(f"target {target_name}: missing {key}")
    for source in target.get("sources", []):
        path = source["path"] if isinstance(source, dict) else source
        src = need(path, f"target {target_name} source")
        covered.update(p.resolve() for p in src.rglob("*.swift"))
    for dep in target.get("dependencies", []):
        if "package" in dep:
            pkg, product = dep["package"], dep.get("product", dep["package"])
            if pkg not in products:
                errors.append(f"target {target_name}: unknown package {pkg}")
            elif product not in products[pkg]:
                errors.append(f"target {target_name}: package {pkg} has no product {product}")
    if "PRODUCT_BUNDLE_IDENTIFIER" not in target.get("settings", {}).get("base", {}):
        errors.append(f"target {target_name}: no PRODUCT_BUNDLE_IDENTIFIER")

for swift in (ROOT / "Apps").rglob("*.swift"):
    if swift.resolve() not in covered:
        errors.append(f"Swift file not in any target: {swift.relative_to(ROOT)}")

if errors:
    print("project.yml check FAILED:")
    for e in errors:
        print("  -", e)
    sys.exit(1)
print(f"project.yml OK: {len(spec['targets'])} targets, packages {sorted(products)}, "
      f"{len(covered)} app Swift files covered")
