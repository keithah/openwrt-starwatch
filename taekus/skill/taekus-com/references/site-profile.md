# Taekus.com Site Profile

Captured with Libretto on 2026-04-25 from session `taekus-skill-build`.

Updated on 2026-04-25 after validating Libretto Codex OAuth snapshot support with `snapshotModel: codex/gpt-5.4` and credential source `codex-auth-json-oauth`.

## Public Site

URL: `https://taekus.com/`

Observed page title: `Home`

Visible text:

- `MEMBERS`
- `Premium banking services`
- `Jobs`
- `Terms and Conditions`
- `Privacy Policy`
- `Press + Inquiries`
- Banking disclosure: DR Bank and First Federal Bank of Kansas City, Members FDIC.
- Phone: `+1 866-282-3587`

Observed links:

- `MEMBERS` -> `https://app.taekus.com/`
- `Jobs` -> `https://jobs.ashbyhq.com/taekus`
- `Terms and Conditions` -> Webflow CDN PDF
- `Privacy Policy` -> `https://taekus.com/legal/privacy-policy-generic`
- `Press + Inquiries` -> `mailto:press@taekus.com`

No buttons, form inputs, iframes, or visible challenge page were observed on the public home page.

## Member App Login

URL: `https://app.taekus.com/`, unauthenticated redirect target `https://app.taekus.com/login`

Observed page title: `Taekus`

Visible text:

- `Log In`
- `Username`
- `Password`
- `Forgot your username or password?`
- `Not registered? Sign up here.`
- Banking disclosure: DR Bank and First Federal Bank of Kansas City, Members FDIC.

Selectors:

- App root container: `#taekus-app-container`
- Login form: `form[autocomplete="off"]`
- Username input: `input[name="username"]`
- Password input: `input[name="password"]`
- Submit button: `button[type="submit"]`
- Account recovery link: `a[href="/account/recovery/"]`
- Signup link: `a[href="/signup/"]`
- Payment card widget container: `#paymentCardWidget`

Workflow notes:

- The submit button starts disabled and should become enabled only after input is accepted.
- The password visibility icon had no button role, id, name, aria-label, or stable selector in the captured DOM. Avoid targeting it unless live inspection finds a better selector.
- No modal, overlay, inline validation message, spinner, or error banner was visible in the captured state.

## Security And Telemetry

Public site:

- Cookies: none observed.
- `window.fetch` and `XMLHttpRequest.prototype.open`: native.
- Scripts: Webfont, jQuery, Webflow CDN assets.
- No challenge page observed.

Member app login:

- Cookies observed: `django_language`, Google Analytics cookies.
- `window.fetch` and `XMLHttpRequest.prototype.open`: native.
- Scripts observed:
  - `https://app.taekus.com/static/js/main.627b51f5.js`
  - `https://mpsnare.iesnare.com/snare.js`
  - `https://mpsnare.iesnare.com/script/logo.js`
  - Cloudflare Insights beacon
  - Google Tag Manager
- No known `_px`, `datadome`, `cf_clearance`, or Akamai `_abck` bot cookie was observed, but `mpsnare.iesnare.com` is fraud/device telemetry. Be conservative with synthetic requests.

## Suggested Libretto Strategy

- Public site metadata and link checks: use `snapshot` for high-level page understanding, then `exec` or workflow code for deterministic extraction.
- Login-page availability checks: use `snapshot` for state/selector review, then Playwright locators for implementation.
- Authenticated member flows: start with normal UI navigation and passive network observation; avoid replaying or inventing banking API requests unless the user explicitly authorizes the exact action.
- Mutating actions require explicit current-turn user confirmation.

## Codex OAuth Snapshot Validation

Validated commands:

```bash
OPENAI_API_KEY='' LIBRETTO_DISABLE_DOTENV=1 npx --yes libretto status
OPENAI_API_KEY='' LIBRETTO_DISABLE_DOTENV=1 npx --yes libretto snapshot --session taekus-codex-oauth-validated --objective "..." --context "..."
```

Results:

- `taekus.com` snapshot succeeded and identified the Members link plus footer links.
- `app.taekus.com/login` snapshot succeeded and identified username, password, submit, recovery, signup, app root, and disabled submit state.
- Use the env wrapper above when the goal is to prove/use Codex OAuth instead of the parent project `.env` API key.
