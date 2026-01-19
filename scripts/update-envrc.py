import os
import pathlib
import re


def main() -> int:
    envrc = os.environ.get("ENVRC", ".envrc")
    new_id = os.environ.get("NEW_ID")
    if not new_id:
        raise SystemExit("NEW_ID is required")

    p = pathlib.Path(envrc)
    s = p.read_text() if p.exists() else ""

    # Replace any existing INSTANCE_ID export; otherwise append.
    pat = re.compile(r"^(\s*export\s+INSTANCE_ID=).*$", re.M)
    out, n = pat.subn(r"\1'" + new_id + r"'", s)
    if n == 0:
        out = s.rstrip("\n") + f"\nexport INSTANCE_ID='{new_id}'\n"

    p.write_text(out)
    print(f"Updated {p} INSTANCE_ID={new_id}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())

