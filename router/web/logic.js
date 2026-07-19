const DAY_MINUTES = 24 * 60;

const wrapMinutes = value => ((Math.round(value) % DAY_MINUTES) + DAY_MINUTES) % DAY_MINUTES;

export function deriveState(snapshot = {}) {
  if (snapshot.topology === 'wan-only' || snapshot.dish_reachable === false) return 'STARLINK DISCONNECTED';
  if (!snapshot.dish_reachable) return 'Unreachable';
  const dish = snapshot.dish || {};
  const cause = String(dish.outage?.cause || '').toUpperCase();
  if (cause.includes('OBSTRUCT')) return 'Obstructed';
  if (cause.includes('SEARCH') || cause.includes('NO_DOWNLINK') || cause.includes('NO_PINGS')) return 'Searching';
  if (dish.outage) return 'Outage';
  if (dish.obstruction?.currently_obstructed) return 'Obstructed';
  return 'Online';
}

export function mergeLiveFrame(snapshot = {}, frame = {}) {
  const hasDish = Object.prototype.hasOwnProperty.call(frame, 'dish');
  return {
    ...snapshot,
    topology: frame.topology ?? snapshot.topology,
    dish_reachable: frame.dish_reachable ?? snapshot.dish_reachable,
    dish: hasDish ? frame.dish : snapshot.dish,
    wan: frame.wan ?? snapshot.wan,
  };
}

export function liveFrameValues(frame = {}) {
  const dish = frame.dish_reachable === false ? null : frame.dish;
  return {
    dish_down_bps: dish?.downlink_throughput_bps,
    dish_up_bps: dish?.uplink_throughput_bps,
    latency_ms: dish?.latency_ms,
    drop_rate: dish?.drop_rate,
    power_w: dish?.power_w,
  };
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
      values[index] = point.value == null ? null : Number(point.value);
      min[index] = point.min == null ? null : Number(point.min);
      max[index] = point.max == null ? null : Number(point.max);
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

// Router writes deliberately have one mutation per request. Keeping the
// confirmation phrase here makes the UI payload observable and testable while
// the server remains the authority for validation.
export function clientMutationPayload({configRevision, givenName, blocked} = {}) {
  const config_revision = String(configRevision || '');
  if (typeof givenName === 'string') {
    return {config_revision, confirmation: 'RENAME CLIENT', given_name: givenName};
  }
  if (typeof blocked === 'boolean') {
    return {
      config_revision,
      confirmation: blocked ? 'BLOCK CLIENT' : 'UNBLOCK CLIENT',
      blocked,
    };
  }
  throw new Error('Select a client rename, block, or unblock action.');
}

export function clientMutationShouldRetry(error) {
  return Number(error?.status) === 409;
}

// Wi-Fi writes use the public, stable selector rather than a router's runtime
// BSSID. Empty write-only credentials deliberately mean "preserve", never
// "clear". Callers pass one mutation category per request.
export function wifiMutationPayload({configRevision, network, radio, steering, outdoorMode, secureDNS} = {}) {
	const payload = {config_revision: String(configRevision || ''), confirmation: 'APPLY WIFI CHANGES'};
	if (network) {
    const selected = {ssid: String(network.ssid || ''), band: String(network.band || '')};
    if (network.newSSID !== undefined && String(network.newSSID) !== selected.ssid) selected.new_ssid = String(network.newSSID);
    if (typeof network.passphrase === 'string' && network.passphrase !== '') selected.passphrase = network.passphrase;
    for (const [source, target] of [['security', 'security'], ['hidden', 'hidden'], ['disabled', 'disabled']]) {
      if (network[source] !== undefined) selected[target] = network[source];
    }
		payload.network = selected;
		if (selected.security === 'OPEN') payload.confirmation = 'CREATE OPEN NETWORK';
	} else if (radio) {
		payload.radio = {band: String(radio.band || '')};
		if (radio.enabled !== undefined) payload.radio.enabled = radio.enabled;
		if (radio.disabled !== undefined) payload.radio.enabled = !radio.disabled;
		if (radio.channel !== undefined) payload.radio.channel = radio.channel;
		if (radio.channel_width_mhz !== undefined) payload.radio.channel_width_mhz = radio.channel_width_mhz;
		if (radio.tx_power_level !== undefined) payload.radio.tx_power_level = radio.tx_power_level;
	} else if (typeof steering === 'boolean') {
		payload.band_steering_enabled = steering;
  } else if (typeof outdoorMode === 'boolean') {
    payload.outdoor_mode = outdoorMode;
	} else if (typeof secureDNS === 'boolean') {
		payload.dns = {secure: secureDNS};
  } else {
    throw new Error('Select one Wi-Fi change to apply.');
  }
  return payload;
}

export function wifiMutationShouldRetry(error) {
  return Number(error?.status) === 409;
}
