const DAY_MINUTES = 24 * 60;

const wrapMinutes = value => ((Math.round(value) % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES;

export function deriveState(snapshot = {}) {
  if (snapshot.topology === 'wan-only') return 'WAN-only';
  if (!snapshot.dish_reachable) return 'Unreachable';
  const dish = snapshot.dish || {};
  const cause = String(dish.outage?.cause || '').toUpperCase();
  if (cause.includes('OBSTRUCT')) return 'Obstructed';
  if (cause.includes('SEARCH') || cause.includes('NO_DOWNLINK') || cause.includes('NO_PINGS')) return 'Searching';
  if (dish.outage) return 'Outage';
  if (dish.obstruction?.currently_obstructed) return 'Obstructed';
  return 'Online';
}

export function availabilityValue(value, availability) {
  if (availability && availability.available === false) {
    return {available: false, value: null, reason: availability.reason || 'Unavailable on this dish'};
  }
  if (value === null || value === undefined) {
    return {available: false, value: null, reason: availability?.reason || 'No data reported'};
  }
  return {available: true, value, reason: ''};
}

export function localMinutesToUTC(minutes, timezoneOffset = new Date().getTimezoneOffset()) {
  return wrapMinutes(minutes + timezoneOffset);
}

export function utcMinutesToLocal(minutes, timezoneOffset = new Date().getTimezoneOffset()) {
  return wrapMinutes(minutes - timezoneOffset);
}

export function minutesLabel(minutes) {
  const value = wrapMinutes(minutes);
  return `${String(Math.floor(value / 60)).padStart(2, '0')}:${String(value % 60).padStart(2, '0')}`;
}

const MODEL_PREFIXES = [
  ['mini1_panda', 'Starlink Mini'],
  ['rev_mini', 'Starlink Mini'],
  ['rev_hp', 'Flat High Performance'],
  ['rev4', 'Standard (Gen 3)'],
  ['rev3', 'High Performance'],
  ['rev2', 'Standard Actuated'],
  ['rev1', 'Standard Circular'],
];

export function friendlyModel(hardwareVersion) {
  if (!hardwareVersion) return '';
  const normalized = hardwareVersion.toLowerCase();
  return MODEL_PREFIXES.find(([prefix]) => normalized.startsWith(prefix))?.[1] || hardwareVersion;
}

export function assembleSeries(responses = []) {
  const times = new Set();
  for (const response of responses) {
    for (const point of response?.points || []) times.add(new Date(point.time).getTime() / 1000);
  }
  const timestamps = [...times].sort((a, b) => a - b);
  const indexes = new Map(timestamps.map((time, index) => [time, index]));
  const series = responses.map(response => {
    const values = Array(timestamps.length).fill(null);
    const min = Array(timestamps.length).fill(null);
    const max = Array(timestamps.length).fill(null);
    for (const point of response?.points || []) {
      const index = indexes.get(new Date(point.time).getTime() / 1000);
      if (index === undefined) continue;
      values[index] = Number(point.value);
      min[index] = point.min === undefined ? null : Number(point.min);
      max[index] = point.max === undefined ? null : Number(point.max);
    }
    return {name: response.series, tier: response.tier || 'ram', values, min, max};
  });
  return {timestamps, series};
}

export function formatDuration(seconds) {
  if (!Number.isFinite(Number(seconds))) return '—';
  const total = Math.max(0, Math.round(Number(seconds)));
  const days = Math.floor(total / 86400);
  const hours = Math.floor((total % 86400) / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  if (days) return `${days}d ${hours}h`;
  if (hours) return `${hours}h ${minutes}m`;
  if (minutes) return `${minutes}m`;
  return `${total}s`;
}

export function formatRate(bitsPerSecond) {
  if (!Number.isFinite(Number(bitsPerSecond))) return '—';
  const value = Number(bitsPerSecond);
  if (Math.abs(value) >= 1e9) return `${(value / 1e9).toFixed(2)} Gb/s`;
  if (Math.abs(value) >= 1e6) return `${(value / 1e6).toFixed(1)} Mb/s`;
  if (Math.abs(value) >= 1e3) return `${(value / 1e3).toFixed(1)} kb/s`;
  return `${Math.round(value)} b/s`;
}

export function outageBarLayout(outage, nowMilliseconds = Date.now(), spanSeconds = 86400) {
  const startMilliseconds = nowMilliseconds - spanSeconds * 1000;
  const outageStart = new Date(outage.start).getTime();
  const durationMilliseconds = outage.ongoing
    ? Math.max(0, nowMilliseconds - outageStart)
    : Math.max(0, Number(outage.duration) / 1e6);
  const visibleStart = Math.max(startMilliseconds, outageStart);
  const visibleEnd = Math.min(nowMilliseconds, outageStart + durationMilliseconds);
  if (!Number.isFinite(outageStart) || visibleEnd < startMilliseconds || visibleStart > nowMilliseconds) return null;
  const naturalLeft = (visibleStart - startMilliseconds) / (spanSeconds * 1000) * 100;
  const naturalWidth = (visibleEnd - visibleStart) / (spanSeconds * 1000) * 100;
  const widthPercent = Math.min(100, Math.max(.4, naturalWidth));
  return {leftPercent: Math.min(naturalLeft, 100 - widthPercent), widthPercent};
}

export function hasMotors(hardwareVersion = '') {
  const value = hardwareVersion.toLowerCase();
  return !(value.includes('mini') || value.startsWith('rev_hp') || value.startsWith('rev4'));
}
