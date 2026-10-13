"""Command-line control, handy for testing or shortcuts.

  python cli.py list
  python cli.py on|off [name]
  python cli.py bright 50 [name]
  python cli.py color 255 0 0 [name]
"""
import sys

from lights import load_bulbs


def main(argv):
    bulbs = load_bulbs()
    if not argv or argv[0] == "list":
        for b in bulbs:
            print(f"{b.name}  ({b.id})  {'LAN' if b.local else ''}{' + cloud' if b.cloud else ''}")
        return
    cmd, rest = argv[0], argv[1:]
    nargs = {"on": 0, "off": 0, "bright": 1, "color": 3}[cmd]
    values, name = rest[:nargs], " ".join(rest[nargs:])
    targets = [b for b in bulbs if not name or b.name.lower() == name.lower()]
    if not targets:
        sys.exit(f"No light named {name!r}")
    for b in targets:
        if cmd in ("on", "off"):
            b.power(cmd == "on")
        elif cmd == "bright":
            b.brightness(int(values[0]))
        else:
            b.colour(*map(int, values))
        print(f"{b.name}: {cmd} OK")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except Exception as e:
        sys.exit(str(e))
