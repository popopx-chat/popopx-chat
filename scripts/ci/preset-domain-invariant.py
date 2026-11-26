#!/usr/bin/env python3
"""Check the preset invariant that keeps the app from aborting on its second launch.

`operatorPopopxChat.serverDomains` decides which operator group `groupByOperator'` files a stored
row into, while `updatedUserServers` compares the operator's whole offered list against that group
only. A row offered from `popopxChatSMPServers` whose hosts fall outside `serverDomains` is therefore
never found, comes back as `AUS SDBNew`, and reaches `insertProtocolServer` for a row the store
already holds: UNIQUE(user_id, host, port) on protocol_servers, raised out of `newChatController` on
every start after the one that stored the row.

usage: preset-domain-invariant.py [rev]   # default: the working tree; pass HEAD to check a revision
exit: 0 when every offered host is covered by serverDomains, 1 otherwise. Reading no offered rows is
      also exit 1 - this census went silently vacuous once, over a definition that had been renamed.
"""
import re
import subprocess
import sys

PATH = "src/Popopx/Chat/Operators/Presets.hs"


def blob(rev):
    if not rev or rev == ".":
        with open(PATH, encoding="utf-8") as handle:
            return handle.read().splitlines()
    return subprocess.run(
        ["git", "show", f"{rev}:{PATH}"], capture_output=True, text=True, check=True
    ).stdout.splitlines()


def block(lines, name):
    """The assignment of `name`: its `= ` line plus every following indented line."""
    out, take = [], False
    for line in lines:
        if re.match(rf"^{name} =", line):
            take = True
        elif take and line and not line[0].isspace():
            break
        if take:
            out.append(line)
    return "\n".join(out)


def main():
    rev = sys.argv[1] if len(sys.argv) > 1 else "."
    lines = blob(rev)
    offered = block(lines, "popopxChatSMPServers")
    # the offered rows come from the lists that definition names, so the census follows the code
    lists = re.findall(r"\b(\w*(?:SMPServers|ChatRelays))\b", offered)
    domains = re.findall(
        r'"([^"]+)"', re.search(r"serverDomains = \[([^\]]*)\]", "\n".join(lines)).group(1)
    )
    hosts = set()
    for name in lists:
        for address in re.findall(r'"smp://[^"]+"', block(lines, name)):
            for host in re.findall(r"@([\w.-]+)", address):
                if not host.endswith(".onion"):
                    hosts.add(host)
    if not lists or not hosts:
        # The vacuous case must not read as a pass: an empty block used to exit 0 forever.
        print(f"{rev:9} FAILED: read no offered SMP rows from {PATH} (lists={lists})")
        return 1
    outside = sorted(
        host for host in hosts if not any(host == d or host.endswith("." + d) for d in domains)
    )
    print(f"{rev:9} lists={lists} offered_hosts={len(hosts)} domains={domains} outside={outside}")
    return 1 if outside else 0


if __name__ == "__main__":
    sys.exit(main())
