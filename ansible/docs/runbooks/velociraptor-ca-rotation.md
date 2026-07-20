# Runbook: Velociraptor CA + Key Rotation (operator-gated)

**Why:** The Velociraptor server config (`roles/suricata/files/server.config.yaml`)
was committed to the public repo with its **CA, Frontend (server), and GUI RSA
private keys** in cleartext (finding C1). The CA private key is the root of trust
for the whole EDR fleet — anyone who cloned the public repo before history was
purged can forge client certs and impersonate the server or any endpoint.
History has been purged and the file removed from the repo, but **the keys must
still be treated as compromised and rotated**, because copies may already exist.

**Status:** STAGED — not yet executed. Rotating the CA invalidates every enrolled
client cert, so the **entire fleet (.120, .13, .133, .130, .140) must be
re-enrolled**, with EDR coverage down during the window. Do this in one sitting
with the operator present.

---

## Blast radius / pre-flight

- Enrolled clients today: `.120` (`C.7ce12e4c591be619`), `.13` Windows
  (`C.ac8c5eec63123b59`), and any others currently shown by `clients()`.
- During rotation, agents on the old CA cannot connect. Hunts/monitoring pause
  until each agent gets the new client config.
- Schedule a maintenance window. Have console/SSH access to every agent host
  (especially the `.13` Windows workstation, which needs a local service action).

```bash
# Snapshot the current fleet first (run on .120)
velociraptor --api_config /etc/velociraptor/automation_api.yaml \
  query "SELECT client_id, os_info.hostname, last_seen_at FROM clients()"
```

---

## 1. Generate a fresh server config (new CA + server/GUI certs)

On `.120`, generate a brand-new deployment config (this mints a new CA and new
Frontend/GUI certs), then port over the **non-secret operational settings** from
the current live config (bind addresses, ports, datastore location,
`expected_clients`, GUI users, logging) — do NOT copy the old keys.

```bash
cd /etc/velociraptor
cp server.config.yaml server.config.yaml.prerotate.$(date +%Y%m%d)   # backup
velociraptor config generate > /root/vr-new-server.config.yaml        # new CA+certs
# Hand-merge the non-secret stanzas from the backup into the new file:
#   Frontend.bind_address/bind_port, GUI.bind_address/bind_port + GUI.authenticator
#   + GUI.initial_users, Datastore.*, Logging.*, Client.server_urls,
#   any Client.use_self_signed_ssl / nonce settings you rely on.
# Keep the NEW CA.private_key, Frontend.private_key, GUI.gw_private_key and the
# matching certificates from the generated file.
```

> Tip: diff the two files (`diff <(grep -vE 'private_key|certificate' …)`) to
> confirm you only changed the cryptographic material, not behaviour.

Install and restart the server:

```bash
install -o root -g root -m 600 /root/vr-new-server.config.yaml /etc/velociraptor/server.config.yaml
systemctl restart velociraptor
journalctl -u velociraptor -n 30 --no-pager     # confirm it starts cleanly
shred -u /root/vr-new-server.config.yaml
```

Re-create the automation API client config against the new CA (the old
`automation_api.yaml` is signed by the old CA and will stop working):

```bash
velociraptor --config /etc/velociraptor/server.config.yaml \
  config api_client --name automation --role administrator \
  /etc/velociraptor/automation_api.yaml
chmod 600 /etc/velociraptor/automation_api.yaml
```

Reset the GUI admin password (hash/secret context changed):

```bash
# vault_velociraptor_admin_password holds the value; read it on-host, do not echo.
P=$(cd /opt/soc-ansible && ansible-vault view inventory/host_vars/suricata-20/vault.yml \
      | awk -F': ' '/^vault_velociraptor_admin_password:/{print $2}' | tr -d '" ')
velociraptor --config /etc/velociraptor/server.config.yaml \
  user add --role administrator admin "$P"; unset P
```

## 2. Build the new client config

```bash
velociraptor --config /etc/velociraptor/server.config.yaml \
  config client > /root/vr-client.config.yaml      # embeds the NEW CA + server_urls
```

## 3. Re-enrol every agent

For each agent, replace its client config with `/root/vr-client.config.yaml` and
restart the agent. The old client_id may change; that is expected — re-approve in
the GUI if needary.

- **.120 (Linux, local):**
  ```bash
  install -m 644 /root/vr-client.config.yaml /etc/velociraptor/client.config.yaml
  systemctl restart velociraptor-client    # or the agent unit name in use
  ```
- **.133 / .130 / .140 (Linux):** scp the client config over and restart the
  agent unit on each (from .120: `scp /root/vr-client.config.yaml root@<host>:/etc/velociraptor/client.config.yaml && ssh root@<host> systemctl restart velociraptor-client`).
  `.130` is T-Pot (SSH port 64295). `.135` does not run a VR agent.
- **.13 (Windows workstation):** copy the new client config to the Velociraptor
  program-data config path and restart the `Velociraptor` service
  (`Restart-Service Velociraptor`), or re-run the MSI/`velociraptor.exe service
  install` with the new config. Confirm in Services that it is Running.

```bash
shred -u /root/vr-client.config.yaml
```

## 4. Verify

```bash
velociraptor --api_config /etc/velociraptor/automation_api.yaml \
  query "SELECT client_id, os_info.hostname, last_seen_at FROM clients()"
# Every host should reappear with a recent last_seen_at.
```

## 5. Re-capture the new config into the vault-encrypted IaC source

As of 2026-06-26 the role tracks the server config as a VAULT-ENCRYPTED file committed to
the repo: `roles/suricata/files/server.config.yaml` (AES256, decrypts with `~/.vault_pass`).
The deploy task **Deploy Velociraptor server config** copies it to
`/etc/velociraptor/server.config.yaml` — the path VR actually runs (`ps` shows
`--config /etc/...`) — with **`force: false`**: it seeds a fresh/DR host but NEVER clobbers
a live config. `ansible.builtin.copy` auto-decrypts the vault source on deploy; the live
file stays plaintext `0600`.

Because steps 1-4 edit `/etc` out-of-band, you MUST refresh the encrypted IaC copy after
every rotation, or the repo silently drifts from live:

```bash
cd /opt/soc-ansible
cp /etc/velociraptor/server.config.yaml roles/suricata/files/server.config.yaml
ansible-vault encrypt roles/suricata/files/server.config.yaml
ansible-vault view roles/suricata/files/server.config.yaml \
  | diff - /etc/velociraptor/server.config.yaml && echo "OK: repo == live"
```

Then publish (operator step — vault material, same handling as `vault.yml`): sync
`/opt/soc-ansible` to the `.13` clone, `git add roles/suricata/files/server.config.yaml`,
commit, push. The AES256 blob is safe in the public repo.

**If you skip this:** the repo keeps the OLD keys; a DR rebuild of `.120` would deploy a
config whose CA no longer matches the enrolled agents, breaking the whole fleet.
