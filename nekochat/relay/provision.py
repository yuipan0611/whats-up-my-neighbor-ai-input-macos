"""Generate a private relay policy and per-user credentials; never print tokens."""
import argparse
import hashlib
import json
import os
import secrets
from pathlib import Path
from .protocol import UserID
from pydantic import TypeAdapter

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("directory", type=Path, help="New private directory OUTSIDE the repository")
    parser.add_argument("users", nargs="+")
    parser.add_argument("--mode", choices=["lan", "vps"], default="lan")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    destination = args.directory.expanduser().resolve()
    if destination == repo or repo in destination.parents:
        parser.error("Choose a directory outside the repository")
    users = TypeAdapter(list[UserID]).validate_python(args.users)
    if len(users) != len(set(users)) or not 1 <= len(users) <= 100:
        parser.error("Use 1–100 unique user IDs")
    destination.mkdir(mode=0o700, parents=True, exist_ok=False)
    policy = {"mode": args.mode, "users": {}}
    for user in users:
        token = secrets.token_urlsafe(32)
        policy["users"][user] = {"token_sha256": hashlib.sha256(token.encode()).hexdigest(), "friends": []}
        path = destination / f"{user}.credential.txt"
        with path.open("x", opener=lambda p, flags: os.open(p, flags, 0o600)) as f:
            f.write(token + "\n")
    with (destination / "relay.json").open("x", opener=lambda p, flags: os.open(p, flags, 0o600)) as f:
        json.dump(policy, f, indent=2)
    print("Created private files. Grant mutual friends in relay.json before connecting.")

if __name__ == "__main__":
    main()
