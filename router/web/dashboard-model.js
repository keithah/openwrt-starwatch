export const DASHBOARD_SECTIONS = [
  {id: 'overview', label: 'Overview', icon: 'M4 4h6v6H4zM14 4h6v6h-6zM4 14h6v6H4zM14 14h6v6h-6z', cards: ['live-telemetry', 'wan-health', 'power', 'obstruction', 'alignment', 'alerts']},
  {id: 'telemetry', label: 'Telemetry', icon: 'M3 12h4l3-7 4 14 3-7h4', cards: ['live-telemetry', 'obstruction', 'alignment']},
  {id: 'connectivity', label: 'Connectivity', icon: 'M4 18h2v-4H4zm5 0h2V9H9zm5 0h2V5h-2zm5 0h2V2h-2z', cards: ['wan-health', 'outage-timeline']},
  {id: 'power', label: 'Power', icon: 'M13 2 4 14h6l-1 8 9-12h-6z', cards: ['power', 'sleep-schedule']},
  {id: 'controls', label: 'Controls', icon: 'M4 7h10M17 7h3M4 17h3M10 17h10M14 4v6M7 14v6', cards: ['dish-controls', 'speed-test', 'hardware', 'starlink-router', 'client-management']},
  {id: 'events', label: 'Events', icon: 'M6 4h12M6 10h12M6 16h12M3 4h.01M3 10h.01M3 16h.01', cards: ['alerts']},
  {id: 'settings', label: 'Settings', icon: 'M12 8a4 4 0 1 0 0 8 4 4 0 0 0 0-8zm0-5v2m0 14v2m9-9h-2M5 12H3m15.36-6.36-1.42 1.42M7.05 16.95l-1.42 1.42m12.73 0-1.42-1.42M7.05 7.05 5.63 5.63', cards: []},
];

export const DISH_GRAPH_SERIES = Object.freeze({
  throughput: Object.freeze(['dish_down_bps', 'dish_up_bps']),
  latency: Object.freeze(['latency_ms']),
  loss: Object.freeze(['drop_rate']),
  power: Object.freeze(['power_w']),
});

export function starlinkConnected(snapshot = {}) {
  return snapshot.dish_reachable === true;
}

const byID = new Map(DASHBOARD_SECTIONS.map(section => [section.id, section]));
const overviewIDs = new Set(byID.get('overview').cards);

export function dashboardSection(hash = '') {
  const id = String(hash).replace(/^#\//, '').replace(/^#/, '');
  return byID.has(id || 'overview') ? (id || 'overview') : 'overview';
}

export function sectionDefinition(id) { return byID.get(id) || byID.get('overview'); }

export function normalizeOverviewPreferences(saved = null) {
  const hidden = {};
  if (saved?.hidden && typeof saved.hidden === 'object') for (const [id, value] of Object.entries(saved.hidden)) if (overviewIDs.has(id) && value === true) hidden[id] = true;
  return {hidden, compact: saved?.compact === true};
}

export function visibleOverviewCards(cards = [], preferences = {}) {
  return cards.filter(card => overviewIDs.has(card?.id) && !preferences.hidden?.[card.id]);
}
