# After Install: Marzban Host Settings and Debugging

## 1. Confirm Marzban is reachable

Open:

```text
https://YOUR_PANEL_DOMAIN:8000/dashboard/
```

If it opens and login works, Marzban itself is running.

## 2. Confirm inbound exists

Go to:

```text
Settings > Core Settings
```

Find the tag printed by the installer, usually:

```text
VLESS XHTTP TLS - VERCEL
```

The inbound must be:

```text
Protocol: vless
Network: xhttp
Security: tls
Path: /api
Port: 443
```

## 3. Add Host Settings

Go to:

```text
Settings > Host Settings
```

Add a host for the generated inbound.

Recommended first test:

```text
Address: relay-xxxx.vercel.app
Port: 443
SNI: relay-xxxx.vercel.app
Host: relay-xxxx.vercel.app
Path: /api
Security Layer: TLS
ALPN: h2,http/1.1
Fingerprint: chrome
Allow Insecure: false
Network: xhttp
Mode: auto
Extra: {"xPaddingBytes":"100-1000"}
```

Then, if you specifically need pinned-IP mode, change only Address:

```text
Address: 198.169.2.65
```

Do not change SNI or Host to the IP.

## 4. Create user

Create a user and enable the generated inbound.

Then import/update the subscription in v2rayNG.

## 5. EOF troubleshooting

`fail to detect internet connection EOF` usually means the TCP/TLS/XHTTP chain closed before a valid proxy response. The most common causes are:

1. Address is wrong. Test with the Vercel domain first, then try the pinned IP.
2. SNI/Host is wrong. They must be the Vercel relay domain, not the origin domain and not the pinned IP.
3. Path mismatch. Host Settings path must match `PUBLIC_RELAY_PATH`, usually `/api`.
4. Vercel Deployment Protection is enabled. Relay returns 401.
5. Marzban inbound did not load after restart. Check Core Settings and Docker logs.
6. User was created without enabling the generated inbound.

Run diagnostics:

```bash
cat /root/marzban-xhttp-vercel-output/diagnostic-commands.txt
```

