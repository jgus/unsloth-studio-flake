import argparse
import json
import re
import tomllib
from dataclasses import dataclass
from pathlib import Path

from packaging.requirements import Requirement
from packaging.utils import canonicalize_name


MARKER_PATTERN = re.compile(
    r'''^python_version\s*(===|==|!=|<=|>=|<|>)\s*(["'])([^"']+)\2$'''
)


@dataclass(frozen=True, order=True)
class Marker:
    expression: str
    operator: str
    version: str


@dataclass(frozen=True, order=True)
class RequirementRecord:
    name: str
    requirement: str
    marker: Marker | None


def parse_marker(requirement: Requirement) -> Marker | None:
    if requirement.marker is None:
        return None

    expression = str(requirement.marker)
    match = MARKER_PATTERN.fullmatch(expression)
    if match is None:
        raise ValueError(f"unsupported environment marker: {expression}")

    return Marker(
        expression="python_version",
        operator=match.group(1),
        version=match.group(3),
    )


def parse_requirement(value: str) -> RequirementRecord:
    requirement = Requirement(value)
    return RequirementRecord(
        name=canonicalize_name(requirement.name),
        requirement=str(requirement),
        marker=parse_marker(requirement),
    )


def parse_requirements_file(path: Path) -> set[RequirementRecord]:
    requirements = set()
    for line in path.read_text(encoding="utf-8").splitlines():
        value = line.partition("#")[0].strip()
        if value:
            requirements.add(parse_requirement(value))
    return requirements


def parse_pyproject(path: Path) -> set[RequirementRecord]:
    data = tomllib.loads(path.read_text(encoding="utf-8"))
    project = data.get("project", {})
    requirement_values = list(project.get("dependencies", []) or [])
    optional_dependencies = project.get("optional-dependencies", {}) or {}
    for group in ("studio", "huggingfacenotorch"):
        requirement_values.extend(optional_dependencies.get(group, []) or [])
    return {parse_requirement(value) for value in requirement_values}


def nix_string(value: str) -> str:
    return json.dumps(value)


def render_marker(marker: Marker | None) -> str:
    if marker is None:
        return "null"
    return (
        "{ "
        f"expression = {nix_string(marker.expression)}; "
        f"operator = {nix_string(marker.operator)}; "
        f"version = {nix_string(marker.version)}; "
        "}"
    )


def render_requirement(requirement: RequirementRecord) -> str:
    return (
        "  { "
        f"name = {nix_string(requirement.name)}; "
        f"requirement = {nix_string(requirement.requirement)}; "
        f"marker = {render_marker(requirement.marker)}; "
        "}"
    )


def generate(source: Path) -> list[RequirementRecord]:
    requirements = parse_pyproject(source / "pyproject.toml")
    requirements.update(
        parse_requirements_file(
            source / "studio" / "backend" / "requirements" / "studio.txt"
        )
    )
    requirements.update(
        parse_requirements_file(
            source / "studio" / "backend" / "requirements" / "base.txt"
        )
    )
    if not requirements:
        raise ValueError("parsed zero runtime requirements from upstream")
    return sorted(requirements)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("source", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    requirements = generate(args.source)
    body = "\n".join(render_requirement(requirement) for requirement in requirements)
    args.output.write_text(f"[\n{body}\n]\n", encoding="utf-8")
    print(f"  wrote {len(requirements)} requirements to {args.output}")


if __name__ == "__main__":
    main()
