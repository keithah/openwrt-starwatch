import {Component, h} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {assembleSeries, availabilityValue, deriveState, formatDuration, formatRate, friendlyModel, hasMotors, minutesLabel, outageBarLayout, utcMinutesToLocal, localMinutesToUTC} from './logic.js';
import {mountChart} from './charts.js';

const html = htm.bind(h);
const number = (value, digits = 1) => Number.isFinite(Number(value)) ? Number(value).toFixed(digits) : '—';
const percent = value => Number.isFinite(Number(value)) ? `${(Number(value) * 100).toFixed(1)}%` : '—';

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

export function StatusHeader({snapshot = {}, connection, onCustomize}) {
  const state = deriveState(snapshot);
  const dish = snapshot.dish || {};
  const wan = snapshot.wan || {};
  const statusAvailability = snapshot.field_availability?.status;
  return html`<header class="status-header state-${state.toLowerCase().replace(/[^a-z]+/g, '-')}">
    <div class="brand"><span class="brand-mark" aria-hidden="true">✦</span><div><span class="eyebrow">STARLINK OBSERVATORY</span><h1>Starwatch</h1></div></div>
    <div class="status-primary"><span class="state-dot"></span><div><span class="eyebrow">LINK STATE</span><strong>${state}</strong></div></div>
    <div class="header-metrics">
      <${Metric} label="Uptime" value=${formatDuration(dish.uptime_seconds)} availability=${statusAvailability}/>
      <${Metric} label="Down" value=${formatRate(dish.downlink_throughput_bps ?? wan.router_down_bps)} availability=${statusAvailability}/>
      <${Metric} label="Up" value=${formatRate(dish.uplink_throughput_bps ?? wan.router_up_bps)} availability=${statusAvailability}/>
      <${Metric} label="Latency" value=${number(dish.latency_ms)} unit="ms" availability=${statusAvailability}/>
    </div>
    <div class="badges"><span class="badge">${snapshot.topology || 'unknown'}</span><span class=${`badge connection-${connection}`}>${connection}</span><button class="header-customize" type="button" onClick=${onCustomize} aria-label="Customize dashboard cards" title="Customize dashboard cards">⚙<span aria-hidden="true">Customize</span></button></div>
  </header>`;
}

const graphLabels = {
  dish_down_bps: 'Dish ↓', dish_up_bps: 'Dish ↑', router_down_bps: 'Router ↓', router_up_bps: 'Router ↑',
  latency_ms: 'Latency', drop_rate: 'Loss', wan_probe_loss: 'WAN loss', power_w: 'Power',
};

export function GraphCard({tab, span, responses, onTab, onSpan, loading}) {
  const aligned = assembleSeries(responses || []);
  aligned.series.forEach(item => { item.name = graphLabels[item.name] || item.name; });
  return html`<${Card} title="Live telemetry" eyebrow="1 Hz · local dish API" className="graph-card full-width">
    <div class="toolbar"><div class="tabs" role="tablist">${['Throughput','Latency','Loss','Power'].map(name => html`<button class=${tab === name.toLowerCase() ? 'active' : ''} onClick=${() => onTab(name.toLowerCase())}>${name}</button>`)}</div>
      <div class="span-picker">${['15m','3h','24h','7d','30d'].map(value => html`<button class=${span === value ? 'active' : ''} onClick=${() => onSpan(value)}>${value}</button>`)}</div></div>
    ${loading ? html`<div class="loading-line"></div>` : html`<${Plot} aligned=${aligned} kind=${tab} />`}
    ${tab === 'throughput' && html`<p class="card-note">Dish-side rates come from the terminal. Router-side rates come from interface byte counters.</p>`}
  </${Card}>`;
}

class SkyMap extends Component {
  componentDidMount() { this.draw(); }
  componentDidUpdate() { this.draw(); }
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
    const picker = html`<div class="span-picker" aria-label="Outage timeline span">${['24h', '7d', '30d'].map(value => html`<button class=${span === value ? 'active' : ''} onClick=${() => this.setState({span: value})}>${value}</button>`)}</div>`;
    return html`<${Card} title="Outage timeline" eyebrow="Dish · reachability · path" action=${picker}>
      <div class="timeline">${bars.map(({item, layout}) => { const at=new Date(item.start).getTime(); const duration=item.ongoing ? now-at : Number(item.duration)/1e6; return html`<span class=${`outage-bar source-${item.source}`} style=${`left:${layout.leftPercent}%;width:${layout.widthPercent}%`} title=${`${item.source}: ${item.cause} · ${formatDuration(duration/1000)}`}></span>`; })}</div>
      <div class="table-wrap"><table><thead><tr><th>When</th><th>Source</th><th>Cause</th><th>Duration</th></tr></thead><tbody>${outages.slice(-8).reverse().map(item => html`<tr><td>${new Date(item.start).toLocaleString()}</td><td><span class=${`source-tag source-${item.source}`}>${item.source}</span></td><td>${item.cause}</td><td>${item.ongoing ? 'ongoing' : formatDuration(Number(item.duration)/1e9)}</td></tr>`)}</tbody></table></div>
    </${Card}>`;
  }
}

export function AlignmentCard({snapshot}) {
  const a=snapshot.dish?.alignment; if (!a) return null; const av=snapshot.field_availability?.alignment_stats;
  return html`<${Card} title="Alignment" eyebrow="Dish orientation"><div class="alignment"><svg viewBox="0 0 160 160" role="img" aria-label="Dish azimuth"><circle cx="80" cy="80" r="62"/><line x1="80" y1="80" x2="80" y2="24" transform=${`rotate(${a.boresight_azimuth_deg||0} 80 80)`}/><text x="80" y="15">N</text></svg><div class="metric-grid"><${Metric} label="Azimuth" value=${number(a.boresight_azimuth_deg)} unit="°" availability=${av}/><${Metric} label="Elevation" value=${number(a.boresight_elevation_deg)} unit="°" availability=${av}/><${Metric} label="Tilt" value=${number(a.tilt_angle_deg)} unit="°" availability=${av}/></div></div></${Card}>`;
}

export function PowerCard({snapshot, responses}) {
  const power=snapshot.dish?.power_w; if (power == null && !responses?.length) return null;
  const points=responses?.[0]?.points||[]; const avg=points.length?points.reduce((sum,p)=>sum+Number(p.value),0)/points.length:null;
  const availability=snapshot.field_availability?.power_w;
  const aligned = assembleSeries(responses || []);
  aligned.series.forEach(item => { item.name = graphLabels[item.name] || item.name; });
  return html`<${Card} title="Power" eyebrow="Terminal draw"><div class="power-hero"><${Metric} label="Instant" value=${number(power)} unit="W" availability=${availability}/>${snapshot.dish?.power_source==='history'&&html`<span class="badge amber">via history</span>`}</div><${Plot} aligned=${aligned} height=${170} kind="power"/><p class="derived">${avg==null?'—':(avg*24/1000).toFixed(2)} kWh/day <span>derived from the 24 h average</span></p></${Card}>`;
}

export function WANCard({wan={}, assist, onRefreshAssist, onApplyAssist}) {
  if (!wan.available && !wan.mwan3) return null;
  return html`<${Card} title="WAN health" eyebrow="Router-side truth"><div class="interface-row"><span class=${`state-dot ${wan.up?'online':'offline'}`}></span><strong>${wan.interface||'Starlink WAN'}</strong><span>${wan.up?'up':'down'}</span><span>↓ ${formatRate(wan.router_down_bps)}</span><span>↑ ${formatRate(wan.router_up_bps)}</span></div><div class="metric-grid"><${Metric} label="RTT 30s" value=${number(wan.probe_rtt_30s_ms)} unit="ms"/><${Metric} label="Loss 30s" value=${percent(wan.probe_loss_30s)}/><${Metric} label="RTT 5m" value=${number(wan.probe_rtt_5m_ms)} unit="ms"/><${Metric} label="Loss 5m" value=${percent(wan.probe_loss_5m)}/></div>
    ${wan.mwan3&&html`<div class="mwan"><h3>mwan3 · ${wan.mwan3.active_policy||'no active policy'}</h3>${wan.mwan3.interfaces?.map(item=>html`<div class="interface-row"><span class=${`state-dot ${item.online?'online':'offline'}`}></span><strong>${item.name}</strong><span>${item.state}</span><span>${item.tracking||'not tracking'}</span></div>`)}</div>`}
    <div class="assist"><div><h3>Failover assist</h3><p>${assist?.available?'Starlink primary, cellular backup. Review the exact changes below.':assist?.reason||'Check availability to inspect a proposed policy.'}</p></div><button class="button subtle" onClick=${onRefreshAssist}>Check</button>${assist?.proposed?.length?html`<div class="diff">${assist.proposed.map(change=>html`<code>+ ${change.package}.${change.section}${change.option?'.'+change.option:''} = ${change.value}</code>`)}</div>`:''}${assist?.available&&html`<button class="button warning" onClick=${onApplyAssist}>Apply after typed confirmation</button>`}</div>
  </${Card}>`;
}

export function ControlsCard({snapshot, onControl}) {
  const cfg=snapshot.config||{}; const reachable=snapshot.dish_reachable;
  return html`<${Card} title="Dish controls" eyebrow="Explicit · audited"><div class=${`control-banner ${reachable?'':'disabled'}`}>${reachable?'Writes are sent directly to your dish and recorded.':'Dish unreachable — controls are disabled.'}</div><fieldset disabled=${!reachable}>
    <div class="control-row"><label>Snow melt</label><div class="segments">${['AUTO','ALWAYS_ON','ALWAYS_OFF'].map(mode=>html`<button class=${cfg.snow_melt_mode===mode?'active':''} onClick=${()=>onControl('snow-melt',{snow_melt_mode:mode})}>${mode.replace('_',' ')}</button>`)}</div></div>
    <div class="control-row"><label>Sleep schedule <small>router-local · stored UTC ${minutesLabel(cfg.power_save_start_minutes||0)}</small></label><input id="sleep-start" type="time" value=${minutesLabel(utcMinutesToLocal(cfg.power_save_start_minutes||0))}/><input id="sleep-duration" type="number" min="0" max="1440" value=${cfg.power_save_duration_minutes||0}/><button class="button subtle" onClick=${()=>{const [h,m]=document.querySelector('#sleep-start').value.split(':').map(Number);onControl('sleep-schedule',{enabled:true,start_minutes:localMinutesToUTC(h*60+m),duration_minutes:Number(document.querySelector('#sleep-duration').value)});}}>Save schedule</button></div>
    <div class="control-actions"><button class="button subtle" onClick=${()=>onControl('gps',{enabled:true},'confirm')}>Enable GPS</button><button class="button subtle" onClick=${()=>onControl('gps',{enabled:false},'confirm')}>Disable GPS</button>${hasMotors(snapshot.device_info?.hardware_version)&&html`<button class="button subtle" onClick=${()=>onControl('stow',{},'confirm')}>Stow</button><button class="button subtle" onClick=${()=>onControl('unstow',{},'confirm')}>Unstow</button>`}<button class="button warning" onClick=${()=>onControl('firmware-update',{},'confirm')}>Firmware update</button><button class="button danger" onClick=${()=>onControl('reboot',{},'typed')}>Reboot dish</button></div>
  </fieldset></${Card}>`;
}

export function SpeedCard({speed={}, history=[], onRun, reachable=true}) {
  return html`<${Card} title="Speed test" eyebrow="Dish diagnostic" action=${html`<button class="button primary" disabled=${!reachable||speed.state==='running'||speed.state==='unsupported'} onClick=${onRun}>${speed.state==='running'?'Running…':'Run test'}</button>`}>${!reachable?html`<div class="control-banner disabled">Dish unreachable — speed test is disabled.</div>`:speed.state==='unsupported'?html`<div class="empty">Unsupported on this dish.</div>`:html`<div class="speed-result"><${Metric} label="Download" value=${formatRate(speed.latest?.down_bps)}/><${Metric} label="Upload" value=${formatRate(speed.latest?.up_bps)}/><${Metric} label="Latency" value=${number(speed.latest?.latency_ms)} unit="ms"/></div>`}${history.length?html`<table><tbody>${history.slice(-4).reverse().map(item=>html`<tr><td>${new Date(item.at).toLocaleTimeString()}</td><td>${formatRate(item.down_bps)}</td><td>${formatRate(item.up_bps)}</td><td>${number(item.latency_ms)} ms</td></tr>`)}</tbody></table>`:''}</${Card}>`;
}

export function AlertsCard({snapshot, events=[]}) {
  const flags=Object.entries(snapshot.dish?.alerts||{}).filter(([,active])=>active);
  return html`<${Card} title="Alerts" eyebrow="Active flags · history" action=${html`<a class="text-link" href="#/settings">Settings →</a>`}><div class="chips">${flags.length?flags.map(([name])=>html`<span class="chip warning">${name.replaceAll('_',' ')}</span>`):html`<span class="chip success">No active dish flags</span>`}</div><div class="event-list">${events.filter(item=>item.kind?.startsWith('alert_')).slice(-6).reverse().map(item=>{let detail={};try{detail=JSON.parse(item.detail)}catch(_){}return html`<div><span class=${`event-kind ${item.kind}`}>${item.kind}</span><strong>${detail.alert||detail.name||'alert'}</strong><time>${new Date(item.at).toLocaleString()}</time></div>`;})}</div></${Card}>`;
}

export function HardwareCard({snapshot}) {
  const info=snapshot.device_info; if (!info) return null;
  const av=snapshot.field_availability?.device_info; const show=value=>availabilityValue(value,av).available?value:'—';
  return html`<${Card} title="Hardware" eyebrow="Terminal identity"><dl class="details"><dt>Model</dt><dd title=${av?.reason||''}>${show(friendlyModel(info.hardware_version))}</dd><dt>Hardware</dt><dd>${show(info.hardware_version)}</dd><dt>Firmware</dt><dd>${show(info.software_version)}</dd><dt>Dish ID</dt><dd>${show(info.id)}</dd><dt>Country</dt><dd>${show(info.country_code)}</dd><dt>Mobility</dt><dd>${show(snapshot.dish?.mobility_class)}</dd></dl></${Card}>`;
}

export function StarlinkRouterCard({router}) {
  if (!router) return null;
  const device = router.device || router;
  return html`<${Card} title="Starlink router" eyebrow="Topology B · local read model"><div class="metric-grid"><${Metric} label="Hardware" value=${device.hardware_version}/><${Metric} label="Firmware" value=${device.software_version}/><${Metric} label="Clients" value=${router.clients?.length ?? router.client_count}/><${Metric} label="Uptime" value=${formatDuration(device.uptime_seconds ?? router.uptime_seconds)}/></div>${router.ping&&html`<div class="router-card"><div class="metric-grid"><${Metric} label="Latency" value=${number(router.ping.latency_mean_ms)} unit="ms"/><${Metric} label="Loss" value=${percent(router.ping.drop_rate)}/></div></div>`}</${Card}>`;
}
