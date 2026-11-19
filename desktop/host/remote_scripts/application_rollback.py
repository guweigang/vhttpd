"""Stage a previous completed release for the existing deployment transaction."""
import hashlib
import json
import re
import shutil
import sys
from pathlib import Path


def read(path, limit=8 * 1024 * 1024):
    if path.is_symlink() or not path.is_file() or path.stat().st_size > limit:
        raise ValueError()
    return json.loads(path.read_bytes())


def operation(history, release):
    if not re.fullmatch(r"[0-9a-f]{24}", release):
        raise ValueError()
    path = history / release
    if path.is_symlink():
        raise ValueError()
    return path


def stage(project, component, current, app_id, destination):
    history = project / ".desktop-deployments"
    app = project / "apps" / component
    if any(p.is_symlink() for p in (history, app.parent, app)):
        raise ValueError()
    active = read(app / ".vhttpd-installation.json")
    if (active["deployment_id"], active["app_id"], active["component"]) != (current, app_id, component):
        raise ValueError()
    config = str(project / "vhttpd.toml")
    current_path = operation(history, current)
    record = read(current_path / "release-record.json", 4096)
    previous = record["parent"]
    previous_path = operation(history, previous)
    for ident, path in ((current, current_path), (previous, previous_path)):
        status = read(path / "status.json")
        if (status["id"], status["config_path"], status["phase"]) != (ident, config, "completed"):
            raise ValueError()
    prior = read(previous_path / "preview.json")["installation"]
    if (prior["id"], prior["app_id"], prior["component"]) != (active["id"], app_id, component):
        raise ValueError()
    artifact = previous_path / "release-payload.json"
    prior_record = read(previous_path / "release-record.json", 4096)
    if artifact.is_symlink() or not artifact.is_file() or artifact.stat().st_size > 96 * 1024 * 1024:
        raise ValueError()
    raw = artifact.read_bytes()
    if hashlib.sha256(raw).hexdigest() != prior_record["sha256"]:
        raise ValueError()
    payload = json.loads(raw)
    if (payload["id"], payload["component_id"]) != (previous, component):
        raise ValueError()
    # Historical adoption is a one-time migration, not part of an update.
    payload.update(id=destination.name, target_installation_id=active["id"], adopt_engines=[])
    raw = json.dumps(payload, separators=(",", ":"), ensure_ascii=False).encode()
    with (destination / "payload.json").open("xb") as output:
        output.write(raw)
    print(hashlib.sha256(raw).hexdigest())


def retain(destination, checksum):
    plan = read(destination / "plan.json")
    parent = json.loads(plan["previous_manifest"])["id"] if plan["previous_manifest"] else ""
    payload = destination / "payload.json"
    if payload.is_symlink() or not payload.is_file():
        raise ValueError()
    with payload.open("rb") as source, (destination / "release-payload.json").open("xb") as target:
        shutil.copyfileobj(source, target)
    with (destination / "release-record.json").open("x") as record:
        json.dump(dict(parent=parent, sha256=checksum), record)


if __name__ == "__main__":
    try:
        if sys.argv[1] == "retain":
            retain(Path(sys.argv[2]), sys.argv[3])
        else:
            root, component, current, app, dest = sys.argv[1:]
            stage(Path(root), component, current, app, Path(dest))
    except (OSError, ValueError, KeyError, TypeError):
        sys.exit("previous_release_unavailable")
