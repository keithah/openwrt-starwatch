import {Component, h} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {Metric} from './cards.js';
import {deriveState, formatDuration, formatRate} from './logic.js';
import {DASHBOARD_SECTIONS, normalizeOverviewPreferences, sectionDefinition, starlinkConnected} from './dashboard-model.js';

const html = htm.bind(h);
const overviewKey = 'starwatch.overview.cards';
const densityKey = 'starwatch.density';

export function loadOverviewPreferences() {
  try {
    const saved = JSON.parse(localStorage.getItem(overviewKey) || 'null');
    return normalizeOverviewPreferences({...saved, compact: localStorage.getItem(densityKey) === 'compact'});
  } catch (_) { return normalizeOverviewPreferences(); }
}

export function saveOverviewPreferences(preferences) {
  try {
    localStorage.setItem(overviewKey, JSON.stringify({version: 1, hidden: preferences.hidden}));
    localStorage.setItem(densityKey, preferences.compact ? 'compact' : 'comfortable');
  } catch (_) {}
  return preferences;
}

export function resetOverviewPreferences() {
  try { localStorage.removeItem(overviewKey); localStorage.removeItem(densityKey); } catch (_) {}
  return normalizeOverviewPreferences();
}

export function IconRail({section = 'overview', open = false, onNavigate}) {
  return html`<aside class=${`rail${open ? ' rail-drawer-open' : ''}`}><nav class="rail-panel" aria-label="Dashboard sections"><a class="rail-brand" href="#/" aria-label="Starwatch overview" title="Starwatch" onClick=${onNavigate}>✦</a>${DASHBOARD_SECTIONS.map(item => html`<a class=${`rail-row${section === item.id ? ' active' : ''}`} href=${item.id === 'overview' ? '#/' : `#/${item.id}`} aria-current=${section === item.id ? 'page' : null} title=${item.label} onClick=${onNavigate}><svg aria-hidden="true" viewBox="0 0 24 24" focusable="false" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"><path d=${item.icon}/></svg><span class="rlabel">${item.label}</span></a>`)}</nav></aside>`;
}

export function SectionHeader({section = 'overview', snapshot = {}, connection, onCustomize, fullscreen, onFullscreen, onMenu}) {
  const title = sectionDefinition(section).label;
  const dish = snapshot.dish || {};
  const connected = starlinkConnected(snapshot);
  const number = value => Number.isFinite(Number(value)) ? Number(value).toFixed(1) : '—';
  const liveLabel = connected ? (connection === 'live' ? 'LIVE' : String(connection || 'connecting').toUpperCase()) : 'WAITING FOR DISH';
  const connectionClass = connected ? connection : 'polling';
  return html`<header class=${`section-header state-${deriveState(snapshot).toLowerCase().replace(/[^a-z]+/g, '-')}`}><button class="rail-menu-toggle" type="button" aria-label="Open dashboard sections" onClick=${onMenu}>☰</button><div><span class="eyebrow">DASHBOARD / ${title}</span><h1>${title}</h1></div><div class="status-primary"><span class="state-dot"></span><div><span class="eyebrow">LINK STATE</span><strong>${deriveState(snapshot)}</strong></div></div>${connected && html`<div class="header-metrics"><${Metric} label="Uptime" value=${formatDuration(dish.uptime_seconds)} availability=${snapshot.field_availability?.status}/><${Metric} label="Down" value=${formatRate(dish.downlink_throughput_bps)} availability=${snapshot.field_availability?.status}/><${Metric} label="Up" value=${formatRate(dish.uplink_throughput_bps)} availability=${snapshot.field_availability?.status}/><${Metric} label="Latency" value=${number(dish.latency_ms)} unit="ms" availability=${snapshot.field_availability?.status}/></div>`}<div class="section-actions"><button class="header-customize" type="button" onClick=${onFullscreen} aria-pressed=${!!fullscreen} title=${fullscreen ? 'Exit fullscreen' : 'Enter fullscreen'}>${fullscreen ? 'EXIT' : 'FULL'}</button><span class=${`badge connection-${connectionClass}`}>${liveLabel}</span>${connected && section === 'overview' && html`<button data-customize-overview class="header-customize" type="button" onClick=${onCustomize}>CUSTOMIZE</button>`}</div></header>`;
}

export function DisconnectedState() {
  return html`<section class="card disconnected-state" role="status"><span class="eyebrow">TERMINAL</span><h2>Starlink disconnected</h2><p>No Starlink terminal is reachable over gRPC. Telemetry will resume automatically when the dish reconnects.</p></section>`;
}

export class CustomizePanel extends Component {
  componentDidMount() { requestAnimationFrame(() => this.closeButton?.focus()); }
  keyDown = event => {
    if (event.key === 'Escape') { event.preventDefault(); this.props.onClose(); return; }
    if (event.key !== 'Tab') return;
    const focusable = [...this.base.querySelectorAll('button:not([disabled]), input:not([disabled])')];
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  };
  render({cards, preferences, onClose, onToggle, onDensity, onReset}) {
    return html`<div class="customize-overlay drawer-layer" onMouseDown=${event => { if (event.target === event.currentTarget) onClose(); }}><aside class="customize-panel card-drawer" role="dialog" aria-modal="true" aria-labelledby="card-drawer-title" onKeyDown=${this.keyDown} ref=${node => { this.base = node; }}><header class="drawer-heading"><div><span class="eyebrow">OVERVIEW</span><h2 id="card-drawer-title">Customize Overview</h2></div><button class="drawer-close" type="button" aria-label="Close Overview customization" onClick=${onClose} ref=${node => { this.closeButton = node; }}>×</button></header><p class="drawer-note">Some cards only show when they have data to present.</p><ol class="drawer-cards">${cards.map(card => html`<li data-card-id=${card.id} class=${card.available ? '' : 'unavailable'}><span>${card.label}</span><small>${card.available ? '' : 'Waiting for data'}</small><label class="card-toggle"><input type="checkbox" checked=${!preferences.hidden[card.id]} onChange=${() => onToggle(card.id)}/><span class="toggle-track" aria-hidden="true"><span class="toggle-knob"></span></span><span class="sr-only">Show ${card.label}</span></label></li>`)}</ol><label class="density-toggle"><input type="checkbox" checked=${preferences.compact} onChange=${onDensity}/><span>Compact spacing</span></label><button class="button drawer-reset" type="button" onClick=${onReset}>Reset Overview</button></aside></div>`;
  }
}
