import {h} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {Card} from './cards.js';

const html = htm.bind(h);
const tidy = value => value == null || value === '' ? '' : Math.round(Number(value) * 1e6) / 1e6;
const optionalNumber = (data, name) => {
  const raw = String(data.get(name) ?? '').trim();
  return raw === '' ? undefined : Number(raw);
};
const setOptionalNumber = (target, key, data, name) => {
  const value = optionalNumber(data, name);
  if (value !== undefined) target[key] = value;
};

export function TokenView({error, onSubmit}) {
  return html`<main class="auth-shell"><form class="token-card" onSubmit=${event => {event.preventDefault();onSubmit(new FormData(event.currentTarget).get('token').trim());}}><span class="brand-mark">✦</span><span class="eyebrow">LOCAL ACCESS</span><h1>Open Starwatch</h1><p>Enter the token from <code>/etc/config/starwatch</code>. It stays in this browser tab only.</p><label>Access token<input name="token" type="password" autocomplete="current-password" autofocus required /></label>${error&&html`<p class="form-error">${error}</p>`}<button class="button primary" type="submit">Connect to dish</button></form></main>`;
}

export function SettingsView({config, onSave, onTest, onRegenerate, onCopyToken, newToken, notice, embedded = false}) {
  const Root = embedded ? 'section' : 'main';
  if (!config) return html`<${Root} class="view"><div class="empty">Settings unavailable.</div></${Root}>`;
  const main = config.main || {};
  const alerts = config.alerts || {};
  const history = config.history || {};
  const configuredRules = alerts.rules || {};
  const submit = event => {
    event.preventDefault();
    const data = new FormData(event.currentTarget);
    const rules = {};
    for (const name of Object.keys(configuredRules)) {
      const rule = {enabled: data.get(`rule-${name}`) === 'on'};
      setOptionalNumber(rule, 'threshold', data, `threshold-${name}`);
      setOptionalNumber(rule, 'threshold2', data, `threshold2-${name}`);
      setOptionalNumber(rule, 'hold_seconds', data, `hold-${name}`);
      setOptionalNumber(rule, 'clear_seconds', data, `clear-${name}`);
      rules[name] = rule;
    }
    const mainUpdate = {
      probe_hosts: String(data.get('probe_hosts') ?? '').split(/[\s,]+/).filter(Boolean),
      location_enabled: data.get('location_enabled') === 'on',
    };
    setOptionalNumber(mainUpdate, 'probe_interval', data, 'probe_interval');
    setOptionalNumber(mainUpdate, 'poll_map', data, 'poll_map');
    const historyUpdate = {};
    setOptionalNumber(historyUpdate, 'minute_days', data, 'minute_days');
    setOptionalNumber(historyUpdate, 'quarter_days', data, 'quarter_days');
    onSave({main: mainUpdate, history: historyUpdate, alerts: {
      webhook_url: String(data.get('webhook_url') ?? ''),
      ntfy_url: String(data.get('ntfy_url') ?? ''),
      rules,
    }});
  };
  return html`<${Root} class="view settings-view"><div class="view-heading"><div><span class="eyebrow">DAEMON CONFIGURATION</span><h1>Settings</h1></div><a href="#/">← Dashboard</a></div>${notice&&html`<div class="notice">${notice}</div>`}<form onSubmit=${submit}>
    <${Card} title="Monitoring" eyebrow="Safe live settings"><div class="form-grid"><label>Probe hosts<input name="probe_hosts" value=${(main.probe_hosts || []).join(', ')} /></label><label>Probe interval (seconds)<input name="probe_interval" type="number" min="1" value=${main.probe_interval ?? ''}/></label><label>Sky-map poll (seconds)<input name="poll_map" type="number" min="1" value=${main.poll_map ?? ''}/></label><label class="toggle"><input name="location_enabled" type="checkbox" checked=${main.location_enabled === true}/><span>Location opt-in</span></label></div><p class="card-note">Location requires enabling local access in the official Starlink app. Permission failures remain marked unavailable.</p></${Card}>
    <${Card} title="Alert delivery" eyebrow="Webhook · ntfy"><div class="form-grid"><label>Webhook URL<input name="webhook_url" type="url" value=${alerts.webhook_url || ''}/></label><label>ntfy URL<input name="ntfy_url" type="url" value=${alerts.ntfy_url || ''}/></label></div><button class="button subtle" type="button" onClick=${onTest}>Send test notification</button></${Card}>
    <${Card} title="Alert rules" eyebrow="Thresholds and hysteresis"><div class="rules">${Object.entries(configuredRules).map(([name,rule])=>html`<div key=${name} class="rule"><label class="toggle"><input name=${`rule-${name}`} type="checkbox" checked=${rule.enabled}/><strong>${name.replaceAll('_',' ')}</strong></label><label>Threshold<input name=${`threshold-${name}`} type="number" step="any" min="0" value=${tidy(rule.threshold)}/></label><label>Second threshold<input name=${`threshold2-${name}`} type="number" step="any" min="0" value=${tidy(rule.threshold2)}/></label><label>Fire after (s)<input name=${`hold-${name}`} type="number" min="0" value=${rule.hold_seconds ?? ''}/></label><label>Clear after (s)<input name=${`clear-${name}`} type="number" min="0" value=${rule.clear_seconds ?? ''}/></label></div>`)}</div></${Card}>
    <${Card} title="History retention" eyebrow="Flash-conscious"><div class="form-grid"><label>Minute tier (days)<input name="minute_days" type="number" min="1" value=${history.minute_days ?? ''}/></label><label>Quarter-hour tier (days)<input name="quarter_days" type="number" min="1" value=${history.quarter_days ?? ''}/></label></div></${Card}>
    <${Card} title="Access token" eyebrow="Restart-safe security"><div class="token-panel"><code>${newToken||main.token||''}</code>${newToken&&html`<button type="button" class="button subtle" onClick=${onCopyToken}>Copy new token</button>`}<button type="button" class="button danger" onClick=${onRegenerate}>Regenerate token</button></div><p class="card-note">${newToken?'Copy this token now. It will not be shown in full again.':'The new token is shown once and takes effect immediately.'}</p></${Card}>
    <div class="sticky-save"><button class="button primary" type="submit">Save safe settings</button></div>
  </form></${Root}>`;
}

export function EventsView({events=[], embedded = false}) {
  const Root = embedded ? 'section' : 'main';
  const filter=(new URLSearchParams(location.hash.split('?')[1]||'')).get('kind')||'all';
  const kinds=['all',...new Set(events.map(item=>item.kind))]; const visible=filter==='all'?events:events.filter(item=>item.kind===filter);
  return html`<${Root} class="view"><div class="view-heading"><div><span class="eyebrow">AUDIT TRAIL</span><h1>Events</h1></div><a href="#/">← Dashboard</a></div><div class="filters">${kinds.map(kind=>html`<a key=${kind} class=${filter===kind?'active':''} href=${kind==='all'?'#/events':`#/events?kind=${encodeURIComponent(kind)}`}>${kind}</a>`)}</div><${Card} title="Recorded activity" eyebrow="Newest first"><div class="audit-log">${visible.slice().reverse().map(item=>html`<article key=${`${item.at}-${item.kind}-${item.detail || ''}`}><time>${new Date(item.at).toLocaleString()}</time><span class="event-kind">${item.kind}</span><pre>${formatDetail(item.detail)}</pre></article>`)}</div></${Card}></${Root}>`;
}

function formatDetail(detail) { try { return JSON.stringify(JSON.parse(detail),null,2); } catch (_) { return detail||''; } }
