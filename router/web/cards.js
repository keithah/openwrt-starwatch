import {Component, h} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {assembleSeries, availabilityValue, formatDuration, formatRate, friendlyModel, hasMotors, minutesLabel, outageBarLayout, utcMinutesToLocal, localMinutesToUTC} from './logic.js';
import {mountChart} from './charts.js';

const html = htm.bind(h);
const number = (value, digits = 1) => Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : '—';
const percent = value => Number.isFinite(Number(value)) ? `${(Number(value) * 100).toFixed(1)}%` : '—';
const alignedCache = new WeakMap();
const averageCache = new WeakMap();
const reverseCache = new WeakMap();
function newestFirst(items) {
  if (!items || typeof items !== 'object') return [];
  let result = reverseCache.get(items);
  if (!result) { result = items.slice().reverse(); reverseCache.set(items, result); }
  return result;
}
function averagePower(responses) {
  if (!responses || typeof responses !== 'object') return null;
  if (averageCache.has(responses)) return averageCache.get(responses);
  const points = responses[0]?.points || [];
  const value = points.length ? points.reduce((sum, point) => sum + Number(point.value), 0) / points.length : null;
  averageCache.set(responses, value);
  return value;
}
function alignedSeries(responses) {
  if (!responses || typeof responses !== 'object') return assembleSeries([]);
  let aligned = alignedCache.get(responses);
  if (!aligned) {
    aligned = assembleSeries(responses);
    aligned.series.forEach(item => { item.name = graphLabels[item.name] || item.name; });
    alignedCache.set(responses, aligned);
  }
  return aligned;
}

export function Metric({label, value, unit = '', availability, hint = ''}) {
  const result = availabilityValue(value, availability);
  return html`<div class="metric" title=${result.available ? hint : result.reason}>
    <span class="metric-label">${label}</span><strong>${result.available ? value : '—'}${result.available && unit ? html`<small>${unit}</small>` : ''}</strong>
  </div>`;
}

export function Card({title, eyebrow, className = '', action, children}) {
  return html`<section class=${`card ${className}`}>
    <header class="card-heading"><div>${eyebrow && html`<span class="eyebrow">${eyebrow}</span>`}<h2>${title}</h2></div>${action}</header>
    ${children}
  </section>`;
}

class Plot extends Component {
  componentDidMount() { this.draw(); }
  componentDidUpdate() {
    if (this.props.aligned?.timestamps?.length && this.chart?.update(this.props.aligned, this.props)) return;
    this.chart?.destroy();
    this.chart = null;
    this.draw();
  }
  componentWillUnmount() { this.chart?.destroy(); }
  draw() { if (this.base && this.props.aligned?.timestamps?.length) this.chart = mountChart(this.base, this.props.aligned, this.props); }
  render() { return html`<div class="plot" ref=${node => { this.base = node; }}>${!this.props.aligned?.timestamps?.length && html`<div class="empty">History is collecting…</div>`}</div>`; }
}

const graphLabels = {
  dish_down_bps: 'Dish ↓', dish_up_bps: 'Dish ↑', latency_ms: 'Latency', drop_rate: 'Loss', power_w: 'Power',
};

export function GraphCard({tab, span, responses, onTab, onSpan, loading}) {
  const aligned = alignedSeries(responses || []);
  return html`<${Card} title="Telemetry" eyebrow="1 Hz · dish gRPC" className="graph-card full-width">
    <div class="toolbar"><div class="tabs" role="tablist">${['Throughput','Latency','Loss','Power'].map(name => html`<button key=${name} class=${tab === name.toLowerCase() ? 'active' : ''} onClick=${() => onTab(name.toLowerCase())}>${name}</button>`)}</div>
      <div class="span-picker">${['15m','3h','24h','7d','30d'].map(value => html`<button key=${value} class=${span === value ? 'active' : ''} onClick=${() => onSpan(value)}>${value}</button>`)}</div></div>
    ${loading ? html`<div class="loading-line"></div>` : html`<${Plot} aligned=${aligned} kind=${tab} />`}
    ${tab === 'throughput' && html`<p class="card-note">Throughput comes directly from the Starlink terminal.</p>`}
  </${Card}>`;
}

class SkyMap extends Component {
  componentDidMount() { this.draw(); }
  componentDidUpdate(previousProps) { if (previousProps.grid !== this.props.grid) this.draw(); }
  draw() {
    const {grid} = this.props; const canvas = this.canvas;
    if (!grid || !canvas || !grid.rows || !grid.cols) return;
    const size = 300, ratio = devicePixelRatio || 1; canvas.width = size * ratio; canvas.height = size * ratio; canvas.style.width = `${size}px`; canvas.style.height = `${size}px`;
    const ctx = canvas.getContext('2d'); ctx.scale(ratio, ratio); ctx.clearRect(0, 0, size, size); ctx.translate(size/2, size/2);
    const maxR = size * .46;
    for (let row=0; row<grid.rows; row++) for (let col=0; col<grid.cols; col++) {
      const value = grid.snr[row * grid.cols + col]; if (value < 0) continue;
      const a0 = col / grid.cols * Math.PI * 2 - Math.PI/2, a1 = (col+1) / grid.cols * Math.PI * 2 - Math.PI/2;
      const r0 = row / grid.rows * maxR, r1 = (row+1) / grid.rows * maxR;
      ctx.beginPath(); ctx.arc(0,0,r1,a0,a1); ctx.arc(0,0,r0,a1,a0,true); ctx.closePath();
      if (value === 0) ctx.fillStyle = '#ef6b73'; else { const shade=Math.round(Math.min(1,value)*255); ctx.fillStyle=`rgb(${shade},${shade},255)`; } ctx.fill();
    }
    ctx.strokeStyle='#42d3ff66'; for (const r of [.25,.5,.75,1]) {ctx.beginPath();ctx.arc(0,0,maxR*r,0,Math.PI*2);ctx.stroke();}
  }
  render() { return html`<canvas class="sky-map" ref=${node => {this.canvas=node;}} aria-label="Polar obstruction sky map"></canvas>`; }
}

export function ObstructionCard({snapshot, grid, onClear}) {
  const obstruction = snapshot.dish?.obstruction;
  if (!obstruction && !grid) return null;
  const availability = snapshot.field_availability?.obstruction_stats;
  return html`<${Card} title="Obstruction" eyebrow="Sky visibility" action=${html`<button class="button subtle" disabled=${!snapshot.dish_reachable} onClick=${onClear}>Clear map</button>`}>
    <div class="split"><div class="metric-grid"><${Metric} label="Obstructed" value=${percent(obstruction?.fraction_obstructed)} availability=${availability}/><${Metric} label="Time" value=${number(obstruction?.time_obstructed)} unit="s" availability=${availability}/><${Metric} label="Valid" value=${number(obstruction?.valid_seconds,0)} unit="s" availability=${availability}/></div><${SkyMap} grid=${grid}/></div>
  </${Card}>`;
}

export class OutageCard extends Component {
  state = {span: '24h'};

  render({outages = []}, {span}) {
    const spans = {24: 86400, 7: 7 * 86400, 30: 30 * 86400};
    const spanSeconds = spans[span === '24h' ? 24 : Number.parseInt(span, 10)] || spans[24];
    const now = Date.now();
    const bars = outages.map(item => ({item, layout: outageBarLayout(item, now, spanSeconds)})).filter(entry => entry.layout);
    const picker = html`<div class="span-picker" aria-label="Outage timeline span">${['24h', '7d', '30d'].map(value => html`<button key=${value} class=${span === value ? 'active' : ''} onClick=${() => this.setState({span: value})}>${value}</button>`)}</div>`;
    return html`<${Card} title="Outage timeline" eyebrow="Dish · reachability · path" action=${picker}>
      <div class="timeline">${bars.map(({item, layout}) => { const at=new Date(item.start).getTime(); const duration=item.ongoing ? now-at : Number(item.duration)/1e6; return html`<span key=${`${item.start}-${item.source}-${item.cause}`} class=${`outage-bar source-${item.source}`} style=${`left:${layout.leftPercent}%;width:${layout.widthPercent}%`} title=${`${item.source}: ${item.cause} · ${formatDuration(duration/1000)}`}></span>`; })}</div>
      <div class="table-wrap"><table><thead><tr><th>When</th><th>Source</th><th>Cause</th><th>Duration</th></tr></thead><tbody>${newestFirst(outages).slice(0, 8).map(item => html`<tr key=${`${item.start}-${item.source}-${item.cause}`}><td>${new Date(item.start).toLocaleString()}</td><td><span class=${`source-tag source-${item.source}`}>${item.source}</span></td><td>${item.cause}</td><td>${item.ongoing ? 'ongoing' : formatDuration(Number(item.duration)/1e9)}</td></tr>`)}</tbody></table></div>
    </${Card}>`;
  }
}

export function AlignmentCard({snapshot}) {
  const a=snapshot.dish?.alignment; if (!a) return null; const av=snapshot.field_availability?.alignment_stats;
  return html`<${Card} title="Alignment" eyebrow="Dish orientation"><div class="alignment"><svg viewBox="0 0 160 160" role="img" aria-label="Dish azimuth"><circle cx="80" cy="80" r="62"/><line x1="80" y1="80" x2="80" y2="24" transform=${`rotate(${a.boresight_azimuth_deg||0} 80 80)`}/><text x="80" y="15">N</text></svg><div class="metric-grid"><${Metric} label="Azimuth" value=${number(a.boresight_azimuth_deg)} unit="°" availability=${av}/><${Metric} label="Elevation" value=${number(a.boresight_elevation_deg)} unit="°" availability=${av}/><${Metric} label="Tilt" value=${number(a.tilt_angle_deg)} unit="°" availability=${av}/></div></div></${Card}>`;
}

export function PowerCard({snapshot, responses}) {
  const power=snapshot.dish?.power_w; if (power == null && !responses?.length) return null;
  const avg=averagePower(responses);
  const availability=snapshot.field_availability?.power_w;
  const aligned = alignedSeries(responses || []);
  return html`<${Card} title="Power" eyebrow="Terminal draw"><div class="power-hero"><${Metric} label="Instant" value=${number(power)} unit="W" availability=${availability}/>${snapshot.dish?.power_source==='history'&&html`<span class="badge amber">via history</span>`}</div><${Plot} aligned=${aligned} height=${170} kind="power"/><p class="derived">${avg==null?'—':(avg*24/1000).toFixed(2)} kWh/day <span>derived from the 24 h average</span></p></${Card}>`;
}

export function WANCard({wan={}, assist, onRefreshAssist, onApplyAssist}) {
  if (!wan.available && !wan.mwan3) return null;
  return html`<${Card} title="WAN health" eyebrow="Router-side truth"><div class="interface-row"><span class=${`state-dot ${wan.up?'online':'offline'}`}></span><strong>${wan.interface||'Starlink WAN'}</strong><span>${wan.up?'up':'down'}</span><span>↓ ${formatRate(wan.router_down_bps)}</span><span>↑ ${formatRate(wan.router_up_bps)}</span></div><div class="metric-grid"><${Metric} label="RTT 30s" value=${number(wan.probe_rtt_30s_ms)} unit="ms"/><${Metric} label="Loss 30s" value=${percent(wan.probe_loss_30s)}/><${Metric} label="RTT 5m" value=${number(wan.probe_rtt_5m_ms)} unit="ms"/><${Metric} label="Loss 5m" value=${percent(wan.probe_loss_5m)}/></div>
    ${wan.mwan3&&html`<div class="mwan"><h3>mwan3 · ${wan.mwan3.active_policy||'no active policy'}</h3>${wan.mwan3.interfaces?.map(item=>html`<div key=${item.name} class="interface-row"><span class=${`state-dot ${item.online?'online':'offline'}`}></span><strong>${item.name}</strong><span>${item.state}</span><span>${item.tracking||'not tracking'}</span></div>`)}</div>`}
    <div class="assist"><div><h3>Failover assist</h3><p>${assist?.available?'Starlink primary, cellular backup. Review the exact changes below.':assist?.reason||'Check availability to inspect a proposed policy.'}</p></div><button class="button subtle" onClick=${onRefreshAssist}>Check</button>${assist?.proposed?.length?html`<div class="diff">${assist.proposed.map(change=>html`<code key=${`${change.package}-${change.section}-${change.option || ''}`}>+ ${change.package}.${change.section}${change.option?'.'+change.option:''} = ${change.value}</code>`)}</div>`:''}${assist?.available&&html`<button class="button warning" onClick=${onApplyAssist}>Apply after typed confirmation</button>`}</div>
  </${Card}>`;
}

function SleepScheduleRow({config, onControl}) {
  return html`<div class="control-row"><label>Sleep schedule <small>router-local · stored UTC ${minutesLabel(config.power_save_start_minutes||0)}</small></label><input id="sleep-start" type="time" value=${minutesLabel(utcMinutesToLocal(config.power_save_start_minutes||0))}/><input id="sleep-duration" type="number" min="0" max="1440" value=${config.power_save_duration_minutes||0}/><button class="button subtle" onClick=${()=>{const [h,m]=document.querySelector('#sleep-start').value.split(':').map(Number);onControl('sleep-schedule',{enabled:true,start_minutes:localMinutesToUTC(h*60+m),duration_minutes:Number(document.querySelector('#sleep-duration').value)});}}>Save schedule</button></div>`;
}

export function SleepScheduleCard({snapshot, onControl}) {
  const config = snapshot.config || {};
  return html`<${Card} title="Sleep schedule" eyebrow="Terminal power"><fieldset disabled=${!snapshot.dish_reachable}><${SleepScheduleRow} config=${config} onControl=${onControl}/></fieldset></${Card}>`;
}

export function ControlsCard({snapshot, onControl}) {
  const cfg=snapshot.config||{}; const reachable=snapshot.dish_reachable;
  return html`<${Card} title="Dish controls" eyebrow="Explicit · audited"><div class=${`control-banner ${reachable?'':'disabled'}`}>${reachable?'Writes are sent directly to your dish and recorded.':'Dish unreachable — controls are disabled.'}</div><fieldset disabled=${!reachable}>
    <div class="control-row"><label>Snow melt</label><div class="segments">${['AUTO','ALWAYS_ON','ALWAYS_OFF'].map(mode=>html`<button key=${mode} class=${cfg.snow_melt_mode===mode?'active':''} onClick=${()=>onControl('snow-melt',{snow_melt_mode:mode})}>${mode.replace('_',' ')}</button>`)}</div></div>
    <${SleepScheduleRow} config=${cfg} onControl=${onControl}/>
    <div class="control-actions"><button class="button subtle" onClick=${()=>onControl('gps',{enabled:true},'confirm')}>Enable GPS</button><button class="button subtle" onClick=${()=>onControl('gps',{enabled:false},'confirm')}>Disable GPS</button>${hasMotors(snapshot.device_info?.hardware_version)&&html`<button class="button subtle" onClick=${()=>onControl('stow',{},'confirm')}>Stow</button><button class="button subtle" onClick=${()=>onControl('unstow',{},'confirm')}>Unstow</button>`}<button class="button warning" onClick=${()=>onControl('firmware-update',{},'confirm')}>Firmware update</button><button class="button danger" onClick=${()=>onControl('reboot',{},'typed')}>Reboot dish</button></div>
  </fieldset></${Card}>`;
}

export function SpeedCard({speed={}, history=[], onRun, reachable=true}) {
  return html`<${Card} title="Speed test" eyebrow="Dish diagnostic" action=${html`<button class="button primary" disabled=${!reachable||speed.state==='running'||speed.state==='unsupported'} onClick=${onRun}>${speed.state==='running'?'Running…':'Run test'}</button>`}>${!reachable?html`<div class="control-banner disabled">Dish unreachable — speed test is disabled.</div>`:speed.state==='unsupported'?html`<div class="empty">Unsupported on this dish.</div>`:html`<div class="speed-result"><${Metric} label="Download" value=${formatRate(speed.latest?.down_bps)}/><${Metric} label="Upload" value=${formatRate(speed.latest?.up_bps)}/><${Metric} label="Latency" value=${number(speed.latest?.latency_ms)} unit="ms"/></div>`}${history.length?html`<table><tbody>${history.slice(-4).reverse().map(item=>html`<tr key=${item.at}><td>${new Date(item.at).toLocaleTimeString()}</td><td>${formatRate(item.down_bps)}</td><td>${formatRate(item.up_bps)}</td><td>${number(item.latency_ms)} ms</td></tr>`)}</tbody></table>`:''}</${Card}>`;
}

export function AlertsCard({snapshot, events=[]}) {
  const flags=Object.entries(snapshot.dish?.alerts||{}).filter(([,active])=>active);
  return html`<${Card} title="Alerts" eyebrow="Active flags · history" action=${html`<a class="text-link" href="#/settings">Settings →</a>`}><div class="chips">${flags.length?flags.map(([name])=>html`<span key=${name} class="chip warning">${name.replaceAll('_',' ')}</span>`):html`<span class="chip success">No active dish flags</span>`}</div><div class="event-list">${events.filter(item=>item.kind?.startsWith('alert_')).slice(-6).reverse().map(item=>{let detail={};try{detail=JSON.parse(item.detail)}catch(_){}return html`<div key=${`${item.at}-${item.kind}-${item.detail || ''}`}><span class=${`event-kind ${item.kind}`}>${item.kind}</span><strong>${detail.alert||detail.name||'alert'}</strong><time>${new Date(item.at).toLocaleString()}</time></div>`;})}</div></${Card}>`;
}

export function HardwareCard({snapshot}) {
  const info=snapshot.device_info; if (!info) return null;
  const av=snapshot.field_availability?.device_info; const show=value=>availabilityValue(value,av).available?value:'—';
  return html`<${Card} title="Hardware" eyebrow="Terminal identity"><dl class="details"><dt>Model</dt><dd title=${av?.reason||''}>${show(friendlyModel(info.hardware_version))}</dd><dt>Hardware</dt><dd>${show(info.hardware_version)}</dd><dt>Firmware</dt><dd>${show(info.software_version)}</dd><dt>Dish ID</dt><dd>${show(info.id)}</dd><dt>Country</dt><dd>${show(info.country_code)}</dd><dt>Mobility</dt><dd>${show(snapshot.dish?.mobility_class)}</dd></dl></${Card}>`;
}

const wifiBSS = router => (router?.networks || []).flatMap(network => (network.basic_service_sets || []).map(bss => ({...bss, domain: network.domain})));
const radioLabel = radio => `${radio.band || 'Radio'} · ch ${radio.channel ?? 'auto'} · ${radio.channel_width_mhz ?? '—'} MHz`;

export class WifiEditor extends Component {
  constructor(props) {
    super(props);
    const bss = wifiBSS(props.router)[0] || {};
    this.state = {selected: bss.ssid ? `${bss.ssid}::${bss.band}` : '', ssid: bss.ssid || '', passphrase: '', security: bss.security || '', hidden: !!bss.hidden, disabled: !!bss.disabled, pending: null, typedConfirmation: '', error: '', retry: null, busy: false};
  }

  componentDidUpdate(previousProps, previousState) {
    if (previousProps.router !== this.props.router && !this.state.pending) this.selectDefault(this.props.router);
    if (!previousState.pending && this.state.pending) this.confirmInput?.focus();
  }
  selectDefault = router => {
    const bss = wifiBSS(router)[0];
    if (bss) this.selectBSS(bss);
  };
  selectBSS = bss => this.setState({selected: `${bss.ssid}::${bss.band}`, ssid: bss.ssid || '', passphrase: '', security: bss.security || '', hidden: !!bss.hidden, disabled: !!bss.disabled, error: '', retry: null});
  currentBSS = router => wifiBSS(router).find(item => `${item.ssid}::${item.band}` === this.state.selected);
  openConfirm = (mutation, label, trigger, openNetwork = false) => {
    this.trigger = trigger;
    this.setState({pending: {mutation, label, openNetwork}, typedConfirmation: '', error: '', retry: null});
  };
  closeConfirm = () => this.setState({pending: null, typedConfirmation: '', error: '', retry: null}, () => this.trigger?.focus());
  dialogKeyDown = event => {
    if (event.key === 'Escape') { event.preventDefault(); this.closeConfirm(); return; }
    if (event.key !== 'Tab') return;
    const focusable = [...this.confirmDialog?.querySelectorAll('button:not([disabled]), input:not([disabled])') || []];
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  };
  submit = async pending => {
    const expected = pending.openNetwork ? 'CREATE OPEN NETWORK' : 'APPLY WIFI CHANGES';
    if ((this.confirmInput?.value ?? this.state.typedConfirmation) !== expected) { this.setState({error: `Type ${expected} to confirm.`}); return; }
    this.setState({busy: true, error: '', retry: null});
    try {
      await this.props.onMutate(pending.mutation);
      this.setState({pending: null, passphrase: '', typedConfirmation: ''}, () => this.trigger?.focus());
    } catch (error) {
      this.setState({error: error.message || 'Wi-Fi update failed.', retry: error.retry ? pending : null});
    } finally { this.setState({busy: false}); }
  };
  openBSS = event => {
    const bss = this.currentBSS(this.props.router);
    if (!bss) return;
    const network = {ssid: bss.ssid, band: bss.band, newSSID: this.state.ssid.trim(), passphrase: this.state.passphrase, security: this.state.security, hidden: this.state.hidden, disabled: this.state.disabled};
    this.openConfirm({network}, `Update ${bss.ssid} (${bss.band})`, event.currentTarget, this.state.security === 'OPEN');
  };
  render({router}, state) {
    if (!router?.reachable && router?.reachable !== undefined) return null;
    const bsses = wifiBSS(router), current = this.currentBSS(router);
    const radios = router.radios || [];
    return html`<section class="wifi-editor" aria-labelledby="wifi-editor-title">
      <div class="wifi-editor-heading"><div><span class="eyebrow">TOPOLOGY B · GUARDED WRITES</span><h3 id="wifi-editor-title">Wi-Fi configuration</h3></div><span class="badge">revision ${router.config_revision || 'unavailable'}</span></div>
      <p class="card-note">Each change is confirmed by the router. Passphrases are write-only and are never read back.</p>
      ${state.error && !state.pending && html`<div class="control-banner disabled" role="status" aria-live="polite">${state.error}${state.retry && html` <button class="button subtle" type="button" onClick=${() => this.openConfirm(state.retry.mutation, state.retry.label, this.trigger, state.retry.openNetwork)}>Retry with refreshed revision</button>`}</div>`}
      ${bsses.length ? html`<fieldset class="wifi-panel"><legend>Network</legend><label>Wi-Fi network<select value=${state.selected} onChange=${event => this.selectBSS(bsses.find(item => `${item.ssid}::${item.band}` === event.currentTarget.value))}>${bsses.map(bss => html`<option key=${`${bss.ssid}-${bss.band}`} value=${`${bss.ssid}::${bss.band}`}>${bss.ssid} · ${bss.band}</option>`)}</select></label>
        <div class="wifi-fields"><label>Network name<input value=${state.ssid} maxlength="128" onInput=${event => this.setState({ssid: event.currentTarget.value})}/></label><label>Passphrase <small>write-only</small><input type="password" autocomplete="new-password" placeholder="Unchanged" value=${state.passphrase} onInput=${event => this.setState({passphrase: event.currentTarget.value})}/></label><label>Security<select value=${state.security} onChange=${event => this.setState({security: event.currentTarget.value})}>${['OPEN','WPA2','WPA3','WPA2_WPA3'].map(value => html`<option key=${value} value=${value}>${value}</option>`)}</select></label></div>
        <div class="wifi-toggles"><label><input type="checkbox" checked=${state.hidden} onChange=${event => this.setState({hidden: event.currentTarget.checked})}/> Hidden network</label><label><input type="checkbox" checked=${state.disabled} onChange=${event => this.setState({disabled: event.currentTarget.checked})}/> Disable network</label></div><button data-wifi-edit class="button primary" type="button" disabled=${!current || state.busy} onClick=${this.openBSS}>Review network change</button>
      </fieldset>` : html`<div class="empty">No Wi-Fi networks reported yet.</div>`}
      ${radios.length ? html`<fieldset class="wifi-panel"><legend>Radios</legend><div class="wifi-radio-list">${radios.map(radio => html`<div key=${radio.band} class="wifi-radio-row"><strong>${radioLabel(radio)}</strong><span>${radio.tx_power_level || 'Power unavailable'}</span><button class="button subtle" type="button" disabled=${state.busy} onClick=${event => this.openConfirm({radio: {band: radio.band, disabled: !radio.disabled}}, `${radio.disabled ? 'Enable' : 'Disable'} ${radio.band}`, event.currentTarget)}> ${radio.disabled ? 'Enable' : 'Disable'} </button></div>`)}</div></fieldset>` : ''}
      <fieldset class="wifi-panel"><legend>Router options</legend><div class="wifi-options"><button class="button subtle" type="button" disabled=${state.busy} onClick=${event => this.openConfirm({steering: !(router.disable_band_steering || false)}, 'Toggle band steering', event.currentTarget)}>Band steering</button><button class="button subtle" type="button" disabled=${state.busy} onClick=${event => this.openConfirm({outdoorMode: !router.outdoor_mode}, 'Toggle outdoor mode', event.currentTarget)}>Outdoor mode</button><button class="button subtle" type="button" disabled=${state.busy} onClick=${event => this.openConfirm({secureDNS: !router.secure_dns}, 'Toggle secure DNS', event.currentTarget)}>Secure DNS</button></div></fieldset>
      ${state.pending && html`<div class="wifi-confirm-layer" role="presentation"><section class="wifi-confirm" role="dialog" aria-modal="true" aria-labelledby="wifi-confirm-title" onKeyDown=${this.dialogKeyDown} ref=${node => { this.confirmDialog = node; }}><span class="eyebrow">ROUTER WI-FI</span><h3 id="wifi-confirm-title">${state.pending.label}?</h3>${state.pending.openNetwork && html`<p class="wifi-open-warning">OPEN NETWORK — nearby devices can join without a passphrase.</p>`}<p>Type <code>${state.pending.openNetwork ? 'CREATE OPEN NETWORK' : 'APPLY WIFI CHANGES'}</code> to confirm. This uses revision <code>${router.config_revision || 'unavailable'}</code>.</p>${state.error && html`<div class="client-confirm-error" role="status" aria-live="polite">${state.error}</div>`}<label>Confirmation<input autocomplete="off" value=${state.typedConfirmation} onInput=${event => this.setState({typedConfirmation: event.currentTarget.value, error: ''})} ref=${node => { this.confirmInput = node; }}/></label><div class="control-actions"><button class="button warning" type="button" disabled=${state.busy} onClick=${() => this.submit(state.pending)}>Apply Wi-Fi change</button><button class="button subtle" type="button" disabled=${state.busy} onClick=${this.closeConfirm}>Cancel</button></div></section></div>`}
    </section>`;
  }
}

export function StarlinkRouterCard({router, onMutate}) {
  if (!router) return null;
  const device = router.device || router;
  return html`<${Card} title="Starlink router" eyebrow="Topology B · local read model"><div class="metric-grid"><${Metric} label="Hardware" value=${device.hardware_version}/><${Metric} label="Firmware" value=${device.software_version}/><${Metric} label="Clients" value=${router.clients?.length ?? router.client_count}/><${Metric} label="Uptime" value=${formatDuration(device.uptime_seconds ?? router.uptime_seconds)}/></div>${router.ping&&html`<div class="router-card"><div class="metric-grid"><${Metric} label="Latency" value=${number(router.ping.latency_mean_ms)} unit="ms"/><${Metric} label="Loss" value=${percent(router.ping.drop_rate)}/></div></div>`}<${WifiEditor} router=${router} onMutate=${onMutate}/></${Card}>`;
}

export class ClientManagement extends Component {
  state = {editing: null, givenName: '', pending: null, typedConfirmation: '', error: '', retry: null, busy: false};

  startRename = client => this.setState({editing: client.mac, givenName: client.given_name || client.name || '', error: '', retry: null});
  cancelRename = () => this.setState({editing: null, givenName: '', error: '', retry: null});
  openBlock = (client, trigger) => { this.blockTrigger = trigger; this.blockMAC = client.mac; this.setState({pending: client, typedConfirmation: '', error: '', retry: null}); };
  restoreBlockTrigger = () => {
    const trigger = this.base?.querySelector(`[data-client-block="${this.blockMAC}"]`) || this.blockTrigger;
    trigger?.focus();
  };
  closeBlock = () => this.setState({pending: null, typedConfirmation: '', error: '', retry: null}, () => setTimeout(this.restoreBlockTrigger, 0));
  componentDidUpdate(_, previousState) {
    if (!previousState.pending && this.state.pending) this.confirmInput?.focus();
  }
  dialogKeyDown = event => {
    if (event.key === 'Escape') { event.preventDefault(); this.closeBlock(); return; }
    if (event.key !== 'Tab') return;
    const focusable = [...this.confirmDialog?.querySelectorAll('button:not([disabled]), input:not([disabled])') || []];
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  };

  submit = async (client, mutation) => {
    this.setState({busy: true, error: '', retry: null});
    try {
      await this.props.onMutate(client, mutation);
      const restoreBlockTrigger = !!this.state.pending;
      this.setState({editing: null, givenName: '', pending: null, typedConfirmation: ''}, () => { if (restoreBlockTrigger) this.restoreBlockTrigger(); });
    } catch (error) {
      this.setState({error: error.message || 'Client update failed.', retry: error.retry ? {client, mutation} : null});
    } finally { this.setState({busy: false}); }
  };

  submitRename = client => {
    const givenName = this.state.givenName.trim();
    if (!givenName) { this.setState({error: 'Client name is required.'}); return; }
    this.submit(client, {givenName});
  };
  submitBlock = client => {
    const blocked = !client.blocked;
    const expected = blocked ? 'BLOCK CLIENT' : 'UNBLOCK CLIENT';
    if (this.state.typedConfirmation !== expected) { this.setState({error: `Type ${expected} to confirm.`}); return; }
    this.submit(client, {blocked});
  };

  render({router}, state) {
    if (!router) return null;
    const clients = router.clients || [];
    const revision = router.config_revision || 'unavailable';
    const pending = state.pending;
    return html`<${Card} title="Client management" eyebrow="Topology B · curated router writes" className="client-management-card">
      <p class="card-note">Revision <code>${revision}</code>. Changes are confirmed by the router before they are shown here.</p>
      ${state.error && html`<div class="control-banner disabled" role="status">${state.error}${state.retry && html` <button class="button subtle" type="button" disabled=${state.busy} onClick=${() => this.submit(state.retry.client, state.retry.mutation)}>Retry with refreshed revision</button>`}</div>`}
      ${clients.length ? html`<div class="table-wrap client-table-wrap"><table class="client-table"><thead><tr><th>Client</th><th>Address</th><th>Interface / mode</th><th>Signal</th><th>Rates</th><th>State</th><th>Actions</th></tr></thead><tbody>${clients.map(client => {
        const editing = state.editing === client.mac;
        const label = client.given_name || client.name || 'Unnamed client';
        const link = [client.interface_name || client.interface, client.mode].filter(Boolean).join(' · ') || '—';
        return html`<tr key=${client.mac}><td><strong>${label}</strong>${editing ? html`<div class="client-rename"><label class="sr-only" for=${`rename-${client.mac}`}>New name for ${client.mac}</label><input id=${`rename-${client.mac}`} value=${state.givenName} maxlength="128" onInput=${event => this.setState({givenName: event.currentTarget.value})}/><button class="button primary" type="button" disabled=${state.busy} onClick=${() => this.submitRename(client)}>Save</button><button class="button subtle" type="button" disabled=${state.busy} onClick=${this.cancelRename}>Cancel</button></div>` : html`<small>${client.name && client.given_name ? client.name : ''}</small>`}</td><td><code>${client.mac}</code><small>${client.ipv4 || 'No IPv4'}</small></td><td>${link}</td><td>${number(client.signal_dbm, 0)} dBm<small>${number(client.snr_db, 0)} dB SNR</small></td><td>↓ ${number(client.rx?.rate_mbps)} Mb/s<small>↑ ${number(client.tx?.rate_mbps)} Mb/s</small></td><td><span class=${`chip ${client.blocked ? 'warning' : 'success'}`}>${client.blocked ? 'Blocked' : 'Allowed'}</span><small>${client.active ? 'Connected' : 'Inactive'} · ${formatDuration(client.associated_seconds)}</small></td><td><div class="client-actions"><button class="button subtle" type="button" disabled=${state.busy} onClick=${() => this.startRename(client)}>Rename</button><button data-client-block=${client.mac} class=${`button ${client.blocked ? 'subtle' : 'danger'}`} type="button" disabled=${state.busy} onClick=${event => this.openBlock(client, event.currentTarget)}>${client.blocked ? 'Unblock' : 'Block'}</button></div></td></tr>`;
      })}</tbody></table></div>` : html`<div class="empty">No router clients reported yet.</div>`}
      ${pending && (() => { const blocking = !pending.blocked; const expected = blocking ? 'BLOCK CLIENT' : 'UNBLOCK CLIENT'; return html`<div class="client-confirm-layer" role="presentation"><section class="client-confirm" role="dialog" aria-modal="true" aria-labelledby="client-confirm-title" onKeyDown=${this.dialogKeyDown} ref=${node => { this.confirmDialog = node; }}><span class="eyebrow">ROUTER CLIENT</span><h3 id="client-confirm-title">${blocking ? 'Block' : 'Unblock'} ${pending.given_name || pending.name || pending.mac}?</h3><p>Type <code>${expected}</code> to confirm. This uses revision <code>${revision}</code>.</p>${state.error && html`<div class="client-confirm-error" role="status" aria-live="polite">${state.error}</div>`}<label>Confirmation<input autocomplete="off" value=${state.typedConfirmation} onInput=${event => this.setState({typedConfirmation: event.currentTarget.value, error: ''})} aria-describedby="client-confirm-help" ref=${node => { this.confirmInput = node; }}/></label><small id="client-confirm-help">The phrase must match exactly.</small><div class="control-actions"><button class=${`button ${blocking ? 'danger' : 'primary'}`} type="button" disabled=${state.busy} onClick=${() => this.submitBlock(pending)}>${blocking ? 'Block client' : 'Unblock client'}</button><button class="button subtle" type="button" disabled=${state.busy} onClick=${this.closeBlock}>Cancel</button></div></section></div>`; })()}
    </${Card}>`;
  }
}

// The card is registered only after a successful topology-B router read.
export function ClientManagementCard({router, onMutate}) {
  if (!router) return null;
  return html`<${ClientManagement} router=${router} onMutate=${onMutate}/>`;
}
