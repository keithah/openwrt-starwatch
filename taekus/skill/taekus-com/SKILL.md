---
name: taekus-com
description: Use this skill when working with the taekus-api npm package, Taekus session-cookie auth, transaction exports, app.taekus.com account data, or agent instructions for Codex, Claude, and Gemini.
---

# Taekus.com

## Overview

Use the private `taekus-api` Node.js package for Taekus account workflows. Treat it as a package/CLI first; this skill is an agent-facing wrapper around those package commands.

Repository:

```bash
/Users/keith/src/taekus/taekus
https://github.com/keithah/taekus-api
```

Read `README.md` for package setup and agent integration, and `API.md` for the CLI, TypeScript, session, upstream endpoint, pagination, and refresh contract.

## Workflow

1. Work from `/Users/keith/src/taekus/taekus`.
2. Check the local session before reading Taekus data:

```bash
npm run taekus:doctor
```

3. If auth is missing or expired, ask the user to log in to `https://app.taekus.com/` in their normal browser and run:

```bash
npm run taekus:auth
```

The auth command imports a DevTools "Copy as cURL" command, Cookie header, clipboard value, stdin, or browser cookie JSON export into `.taekus/session.json`.

Preferred macOS flow:

```bash
npm run taekus:auth
```

Ask the user to copy a Taekus request as cURL first; the command reads the clipboard after Enter.

Before a long batch, refresh once and save returned cookies:

```bash
npm run taekus:refresh
```

4. Export transactions with direct API requests:

```bash
npm run taekus:transactions -- --last 5
npm run taekus:transactions -- --from YYYY-MM-DD --to YYYY-MM-DD --max-pages 20 --out exports/name.transactions.json
```

5. For broad exports, prefer smaller date windows if Taekus returns 504s. Merge and dedupe locally by transaction `uuid` or `token`.
6. Verify code changes with:

```bash
npm run build
```

## Auth And Refresh

- Session data is stored in `.taekus/session.json`, which is git-ignored.
- Each API command loads the saved cookies, calls `POST /api/user/refresh/`, applies returned `Set-Cookie` values, and writes refreshed cookies back to `.taekus/session.json`.
- `npm run taekus:refresh` performs the same refresh/save step once.
- No browser is needed after a valid session is imported.
- If the refresh cookie expires or Taekus invalidates the session, run `npm run taekus:auth` again.

## Safety

- Do not print raw transaction payloads unless the user explicitly asks.
- Do not commit `.taekus/`, `exports/`, transaction JSON, cookies, or secrets.
- Keep analysis read-only unless the user explicitly asks for a banking mutation in the current turn.
- Do not add transfer, payment, card, or account mutation flows without separate review.
- Treat transaction analysis as bookkeeping assistance, not financial, tax, or legal advice.

## Taekus API Notes

- Base URL: `https://app.taekus.com`
- Refresh: `POST /api/user/refresh/`
- Account: `GET /api/banking/account/?enforceDefault=true`
- Activity: `GET /api/banking/activity/?cardAccountUuid=<uuid>&startIndex=<n>&startDate=<iso>&endDate=<iso>&transactionType=ALL&searchString=`
- Activity pagination starts at `startIndex=0`; continue with `end_index + 1` while `is_more` is true.
