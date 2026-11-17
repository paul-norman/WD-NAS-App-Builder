# Tools

Stand-alone scripts to run on the NAS by hand, over SSH, as root - not apps. Each works with the NAS's own shell and tools *(BusyBox)*, on the Intel models and the ARM ones.

## plex2shell-check.sh

Checks the NAS for Plex Media Server's **Plex2Shell** vulnerability *(CVE-2026-96652, -96654, -96655 and -96656: unauthenticated remote code execution in Plex older than 1.43.3.10861, exploited in the wild since October 17, 2026)* and for signs that it was used against it. It's **read-only**: it changes nothing, writes nothing, and connects nowhere but Plex on the NAS itself *(its version, from `http://127.0.0.1:32400/identity`)*.

```sh
sh plex2shell-check.sh
```

Or download it, run it and remove it again in one go, from the NAS's SSH prompt *(to read it first, run the `curl` part on its own, then `less /tmp/plex2shell-check.sh`)*:

```sh
curl -fsSL -o /tmp/plex2shell-check.sh https://raw.githubusercontent.com/paul-norman/WD-NAS-App-Builder/main/tools/plex2shell-check.sh && sh /tmp/plex2shell-check.sh; rm -f /tmp/plex2shell-check.sh
```

It finds Plex wherever it runs on the NAS - Plex's own WD package, or a Docker container *(each through `/proc`: no Docker commands needed)* - and installed but stopped *(its data in `Nas_Prog`)*. Then:

| Check                                                                                             | Result                                                          |
|---------------------------------------------------------------------------------------------------|-----------------------------------------------------------------|
| Plex's version *(its identity, or its own log's first line)*                                      | FAIL older than 1.43.3.10861                                    |
| Plex running as root                                                                              | WARN: an exploit controls the whole NAS                         |
| Programs Plex started that aren't its own                                                         | FAIL from a temporary folder (or deleted since), WARN otherwise |
| The exploit's traces in Plex's logs *(the current one and the rotated ones)*                      | FAIL                                                            |
| Files in Plex's `Codecs` folder that aren't its usual codecs *(the attack drops a library there)* | WARN                                                            |
| Miner / proxy processes *(XMRig, "myawesomeproxy"...)*, or anything running from `/tmp`           | FAIL                                                            |
| Connections to the ports miners use *(3333, 14444, 14433, 45700 - with the program holding each)* | FAIL                                                            |
| Miner / proxy files in `/tmp` or `/var/tmp`                                                       | FAIL                                                            |
| Cron jobs that download something or run from `/tmp`, SSH keys changed in the last 30 days        | WARN *(check that they're yours)*                               |

A check that can't run says SKIP, never PASS. It uses the NAS's own tools *(not Entware's, which come first in the `PATH` when it's installed)*, and first checks that they work - on the ARM models, a program built for other Linux systems can crash on the NAS's kernel, and a crashing `grep` would make every check PASS without looking. A broken one is replaced by BusyBox's own; if that doesn't work either, nothing is checked. It exits with 0 *(patched, nothing found)*, 1 *(vulnerable, version unknown, or a sign of compromise)*, 2 *(Plex not found)* or 3 *(nothing checked: one of the NAS's tools doesn't work)*. The signs it looks for are those of [gmolveau's check-plex2shell.sh](https://gist.github.com/gmolveau/b02c2e58b877cf138e2859dbfb5cc20e), which is written for Debian / Red Hat servers with systemd and GNU tools: on the NAS, it doesn't find Plex's WD package, and some of its checks pass without having run.

It's a first look, not proof that a NAS is clean: an attacker can hide in ways no short list of signs catches. If it finds anything: disconnect the NAS from the network, keep the evidence, update Plex, change your plex.tv password *(signing out every device)*, and reinstall Plex with fresh data.
