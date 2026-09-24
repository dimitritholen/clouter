"""API keys for the clouter plugin: the environment first, then one file.

    from lib import keys
    key = keys.get("OPENROUTER_API_KEY")   # raises MissingKey when absent
    keys.set("OPENROUTER_API_KEY", key)    # written once, never asked again

The file is ~/.config/clouter/credentials, NAME=value per line, mode 0600.
A file readable by group or others is refused, so a key never leaks through
a careless chmod (POSIX only: Windows has no such modes, its profile ACL
guards the file). CLOUTER_CREDENTIALS points elsewhere for tests.
Stdlib only.
"""

import os
import stat
import tempfile

DEFAULT_PATH = os.path.join("~", ".config", "clouter", "credentials")


class MissingKey(LookupError):
    """The key is neither in the environment nor in the credentials file."""


class UnsafeFile(PermissionError):
    """The credentials file is readable by group or others."""


def env(name):
    """The environment, then EVAL_<name>: `claude plugin eval` only passes
    EVAL_-prefixed variables through to a case, so every environment read in
    this plugin that a test needs to steer goes through here."""
    return os.environ.get(name) or os.environ.get(f"EVAL_{name}")


def path():
    return os.path.expanduser(env("CLOUTER_CREDENTIALS") or DEFAULT_PATH)


def _check_mode(file_path):
    if os.name == "nt":
        # Windows has no POSIX modes: st_mode reads 0o666 for every file,
        # so this check would refuse them all. The per-user profile ACL
        # on %USERPROFILE%\.config guards the file there instead.
        return
    mode = stat.S_IMODE(os.stat(file_path).st_mode)
    if mode & 0o077:
        raise UnsafeFile(
            f"refusing {file_path}: mode {mode:04o} lets others read it; "
            f"run: chmod 600 {file_path}"
        )


def _read_lines(file_path):
    """Return (name, value) pairs, skipping blanks and comments."""
    pairs = []
    with open(file_path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            name, value = line.split("=", 1)
            pairs.append((name.strip(), value.strip()))
    return pairs


def find(name):
    """The key's value, or None. Raises UnsafeFile on a loose file."""
    value = env(name)
    if value:
        return value
    file_path = path()
    if not os.path.isfile(file_path):
        return None
    _check_mode(file_path)
    for key, value in _read_lines(file_path):
        if key == name and value:
            return value
    return None


def get(name):
    """The key's value. Raises MissingKey when it is nowhere."""
    value = find(name)
    if value is None:
        raise MissingKey(
            f"{name} is not set: export it, or store it once in {path()}"
        )
    return value


def set(name, value):
    """Store NAME=value in the credentials file (mode 0600), replacing any
    earlier line for the same name and keeping the rest."""
    if not name or "=" in name or "\n" in name:
        raise ValueError(f"bad key name: {name!r}")
    if not value or "\n" in value:
        raise ValueError(f"bad value for {name}")
    file_path = path()
    directory = os.path.dirname(file_path)
    os.makedirs(directory, mode=0o700, exist_ok=True)

    pairs = []
    if os.path.isfile(file_path):
        _check_mode(file_path)
        pairs = [(k, v) for k, v in _read_lines(file_path) if k != name]
    pairs.append((name, value))

    fd, tmp = tempfile.mkstemp(dir=directory, prefix=".credentials.")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write("".join(f"{k}={v}\n" for k, v in pairs))
        os.chmod(tmp, 0o600)
        os.replace(tmp, file_path)
    except BaseException:
        os.unlink(tmp)
        raise
    return file_path
