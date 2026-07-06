# WOL Relay (OpenWrt router `.1`)

Token-authenticated Wake-on-LAN relay: an HTTP request makes the router run
`etherwake`. Lets you cold-start LAN machines from a browser/curl — e.g. the
`.15` hypervisor, which then boots fully headless via TPM auto-unlock.

## Components
- `wol.cgi` → install to `/usr/share/wol-relay/cgi-bin/wol` on `.1` (`chmod 755`).
- **uhttpd** serves it on the IoT VLAN at `:8800/cgi-bin/wol`.
- **nginx** (`/etc/nginx/conf.d/*.conf`) proxies it with an allowlist:
  ```nginx
  location /wol {
      allow 192.168.1.0/24;    # LAN
      allow 100.64.0.0/10;     # Tailscale
      deny all;                # everything else -> 403
      proxy_pass http://10.0.0.1:8800/cgi-bin/wol;
  }
  ```

## Usage
```
https://<public-host>/wol?token=<TOKEN>&host=15     # wake .15  (via nginx, LAN/Tailscale only)
https://<public-host>/wol?token=<TOKEN>             # wake default target (.3), no host= needed
http://10.0.0.1:8800/cgi-bin/wol?token=<TOKEN>&host=15
```
Token is required — the CGI returns a real **HTTP 403** without it. Add more
targets = one more `case` arm keyed on `host=`.

## Remote (Tailscale) access
Hitting the public hostname from off-LAN fails the allowlist (the request
arrives from your public IP). Reach nginx *over* Tailscale via the router's
Tailscale IP so the source is a `100.x` address (the TLS cert is for the public
host, so accept the name mismatch or configure split-DNS to resolve the public
name to the router's Tailscale IP).

## Secrets
`__WOL_TOKEN__` and the device MACs here are **placeholders** — real values live
in the private memory store, not this public repo. The nginx allowlist is the
primary control; the token is defence-in-depth. Rotate the token if it leaks.
