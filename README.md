# Marzban XHTTP Vercel Relay Installer

GitHub-ready installer for a Marzban-managed **VLESS + XHTTP + TLS** origin and a Vercel relay project with a lightweight public landing page.

## What this version fixes

- The installer no longer fails when the Marzban admin import command returns a non-zero exit code after the container is already running.
- The Vercel relay now forwards `GET`, `HEAD`, and `POST` on the relay path. This is important for XHTTP behavior and avoids the earlier simplistic relay that returned `404` for every `GET`/`HEAD` request.
- The Vercel project now contains a normal public website with separate files:
  - `public/index.html`
  - `public/styles.css`
  - `public/app.js`
  - `api/index.js`
- The generated landing page is a small restaurant menu page so the Vercel project looks like a normal lightweight site.
- Final diagnostic commands are saved to:
  - `/root/marzban-xhttp-vercel-output/diagnostic-commands.txt`

## One-line install from your GitHub repo

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/YOUR_REPO/main/install.sh)
```

Or clone and run:

```bash
git clone https://github.com/YOUR_USERNAME/YOUR_REPO.git
cd YOUR_REPO
chmod +x install.sh
sudo ./install.sh
```

## Inputs

The installer validates the important values before continuing:

- Origin domain for Marzban/Xray inbound.
- Marzban panel/subscription domain.
- Let's Encrypt email.
- Marzban panel port.
- Inbound tag preset menu; default is `VLESS XHTTP TLS - VERCEL`.
- Inbound port; default is `443`.
- Relay paths; default `/api`.
- Vercel token; validated using `vercel whoami` before deployment.
- Vercel project name.
- Optional Vercel scope/team slug.
- Marzban sudo admin username/password.
- Address for Marzban Host Settings; default `198.169.2.65`, but the final output also shows the Vercel domain as an alternative.

## Important output files

```text
/root/marzban-xhttp-vercel-output/marzban-inbound.json
/root/marzban-xhttp-vercel-output/marzban-host-settings.txt
/root/marzban-xhttp-vercel-output/summary.txt
/root/marzban-xhttp-vercel-output/vercel-env.txt
/root/marzban-xhttp-vercel-output/diagnostic-commands.txt
/root/marzban-xhttp-vercel-output/marzban-final-start.log
/tmp/marzban-xhttp-vercel-install.log
```

## Marzban setup after installer

Open:

```text
https://YOUR_PANEL_DOMAIN:8000/dashboard/
```

Then:

1. Go to `Settings > Core Settings` and confirm the inbound tag exists.
2. Go to `Settings > Host Settings`.
3. Add a host for that inbound using `/root/marzban-xhttp-vercel-output/marzban-host-settings.txt`.
4. Create a user and enable the generated inbound.
5. Import/update the subscription in v2rayNG.

## If v2rayNG says `fail to detect internet connection EOF`

First test the generated host in two modes:

### Mode A — Vercel domain mode

Use the Vercel relay domain as Address:

```text
Address: relay-xxxx.vercel.app
SNI: relay-xxxx.vercel.app
Host: relay-xxxx.vercel.app
Path: /api
Network: xhttp
Security: TLS
```

### Mode B — pinned IP mode

Use the special IP as Address, but keep SNI/Host as Vercel domain:

```text
Address: 198.169.2.65
SNI: relay-xxxx.vercel.app
Host: relay-xxxx.vercel.app
Path: /api
Network: xhttp
Security: TLS
```

If Mode A works but Mode B fails, the pinned IP is not valid/reachable for that relay domain in your network. Keep Address as the Vercel domain.

If both fail, run:

```bash
cat /root/marzban-xhttp-vercel-output/diagnostic-commands.txt
```

Then execute the commands listed there.

## Notes

- Browser `GET /api` may return 404 or another non-2xx code; that alone does not mean XHTTP is broken.
- HTTP 401 from Vercel usually means Deployment Protection is enabled.
- The Vercel token is never printed in final summaries.
- If a token was exposed in logs/screenshots, revoke it and create a new one.
