# Supply-chain / malicious-package defenses

Added 2026-08-02 in response to the Anthropic PyPI incident (2026-07-30): an agent published a
credential-stealing package to the real PyPI; ~15 systems installed it within an hour and the stolen
credentials were used for lateral movement. No IOCs were published, so these layers target the
**class** — hallucinated/typosquatted package names, payload at install or import time, credential
theft, exfil, pivot.

All five layers were live-fire tested on the day they were built.

---

## 1. Canary AWS credentials (`.13`)

`C:\Users\xndre\.aws\credentials` holds **Canarytokens keys, not real credentials**. Any use of them
anywhere in the world raises an alert — this is the layer that still works when everything upstream
missed the theft.

| Profile | Access key | Alerting | Manage token |
|---|---|---|---|
| `[default]` | `AKIAS2LJVDSGJCGON3DV` | email + Telegram | `9jxztib3zkugax5axhbul0h0n` |
| `[prod]` (decoy) | `AKIAZBUZ6W7DFRMTRD32` | Telegram only | `8qk1uhmj9zu0gdetuldqj1ibe` |

Manage/revoke at `https://canarytokens.org/manage?token=<token>&auth=<auth_token>` (auth tokens are
in the memory store, not here). A decoy `PaperMill\.env` carries the `[default]` pair plus fake
OpenAI/Anthropic keys; PaperMill does not read `.env`, and the file is gitignored — **never commit
it**, that repo is public. The pre-existing key of unknown origin is preserved at `credentials.bak`.

Detection latency is CloudTrail-bound: **~90 s to the webhook**, 5–20 min to email.

**Test:** `python -c "import boto3; print(boto3.client('sts').get_caller_identity()['Arn'])"`
Each run produces one real alert. The alert carries the source IP — that is how you tell your own
test from an actual theft.

## 2. Canarytokens → Telegram relay (`.20`)

Canarytokens posts JSON; the Telegram bot API wants a different shape, so a small relay bridges them.

```
canarytokens.org  ──HTTPS──>  nginx on .1  ──>  .20:8766  ──>  api.telegram.org
                  /canary-hook/<HOOK_SECRET>     /hook/<HOOK_SECRET>
```

| Item | Location |
|---|---|
| Service | `canary-telegram-relay.service` on `.20` (Ansible: `roles/suricata`) |
| Script | `/usr/local/bin/canary-telegram-relay.py` — stdlib only, secret-free |
| Config | `/etc/canary-relay.conf` (0600, **hand-managed**): `TG_TOKEN`, `TG_CHAT`, `HOOK_SECRET` |
| Ingress | `location /canary-hook/` in `.1:/etc/nginx/conf.d/xndrei.conf` (hand-managed; backup `.bak-20260802`) |

The nginx location is deliberately internet-reachable — the secret path *is* the authentication,
because Canarytokens posts from arbitrary AWS egress IPs. A wrong secret returns 404. Telegram send
failures are logged to syslog (`canary-relay`) while the webhook still returns 200, so a Telegram
outage cannot make Canarytokens disable the webhook.

**Test:** `curl -X POST http://192.168.1.20:8766/hook/<HOOK_SECRET> -d '{"memo":"test"}'` → `ok`,
message in Telegram. Send JSON from a file, not an inline shell string — SSH quoting mangles it and
the relay then falls back to a raw dump, which looks like a formatting bug but isn't.

## 3. Wazuh FIM on credential paths

Pushed from the manager, not the agent: `/var/ossec/etc/shared/default/agent.conf`, block
`<agent_config os="Windows">`, realtime syscheck on `.aws`, `.ssh`, `soc-keys`,
`.claude\.credentials.json`, and the PaperMill decoy `.env`. Detects **writes**; reads are what the
canary covers. Hand-managed — not templated by Ansible.

## 4. Suricata exfil / OAST rules (`.20`)

`local.rules` sids **9100001–9100017** (`roles/suricata/files/local.rules`) — DNS and TLS-SNI alerts
for webhook.site, transfer.sh, oastify.com, burpcollaborator.net, interact.sh, file.io, gofile.io,
pastebin.com, paste.ee, ngrok, and **canarytokens.com** (sid 9100016 — a LAN host resolving that
directly means something is triggering a canary from inside).

Alert-only. They cannot trigger soc-contain: it matches on Wazuh rule ids and categories, not
Suricata sids.

## 5. Install-time detection (Sysmon + Wazuh)

| Rule | Level | Fires on |
|---|---|---|
| 100050 | 12 | Shell / LOLBin spawned during a package install (malicious `setup.py`) |
| 100051 | 7 | `pip.exe` / `uv.exe` making an outbound connection |

**The non-obvious part:** modern pip runs `setup.py` through
`pip\_vendor\pyproject_hooks\_in_process\_in_process.py`, so neither `pip install` nor `setup.py`
appears in the child's `parentCommandLine`. Matching only those strings produces a rule that never
fires. The regex therefore also matches `pyproject_hooks|_in_process\.py`.

100051 rarely fires in practice — `pip.exe` delegates the network work to `python.exe`, so the real
coverage comes from python being in the Sysmon EID 3 include list (see the `windows-13` runbook).

**Test:** install a throwaway package whose `setup.py` calls `os.system("cmd /c echo ...")`; rule
100050 should fire within seconds.

## 6. pip hygiene (PaperMill)

`requirements.lock.txt` is a `pip-compile --generate-hashes` lock (torch/torchvision excluded — they
come from the CUDA index). Install with:

```
pip install --require-hashes -r requirements.lock.txt
```

Hash-pinning means an unexpected package substituted anywhere in the dependency tree fails to install
rather than executing its `setup.py`. Regenerate after editing `requirements.txt`:

```
pip-compile --generate-hashes --strip-extras --unsafe-package torch --unsafe-package torchvision \
  -o requirements.lock.txt requirements.txt
```

---

## Operating notes

- **Cooldown rule.** Do not install a package published within the last ~30 days, and verify any
  AI-suggested package name actually exists and is established before installing it. Slopsquatting —
  registering a plausible name an assistant hallucinated — is exactly the incident above, and a
  cooldown alone would have prevented it.
- **If a canary alert arrives that you did not cause:** treat the source IP in the message as the
  attacker's egress and `.13` as compromised. Do **not** run containment from `.13` — soc-contain
  would isolate the host you are working from.
- Known gap: first-hour exfil over HTTPS to an unremarkable new domain beats every network layer
  here. The install-side hygiene and the canary are what actually close this class; the rest shortens
  time-to-detect.

## Open items

- `pip-audit` on 2026-08-02 found 108 known vulnerabilities across 19 packages in the global
  environment. Upgrades were not applied (untested); `transformers` is pinned `<5` so its two are
  unfixable while that pin stands.
- 57 MISP-generated Suricata rules fail to parse on every ruleset reload (bad pcre from the MISP
  pull) — pre-existing, cosmetic, worth fixing in the generator.
- fail2ban EVE→router-BanIP drift on `.20`: the repo wants it enabled, the live host has it partially
  deployed. Deliberately not converged — doing so newly activates automatic banning.
