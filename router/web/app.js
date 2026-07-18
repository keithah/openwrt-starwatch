import {Component, h, render} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {APIError, apiFetch, bootstrapToken, getHistory, LiveClient, storeToken} from './api.js';
import {StatusHeader, GraphCard, ObstructionCard, OutageCard, AlignmentCard, PowerCard, WANCard, ControlsCard, SpeedCard, AlertsCard, HardwareCard, StarlinkRouterCard, ClientManagementCard} from './cards.js';
import {TokenView, SettingsView, EventsView} from './views.js';
import {clientMutationPayload, clientMutationShouldRetry, normalizeCardPreferences, wifiMutationPayload, wifiMutationShouldRetry} from './logic.js';

const html = htm.bind(h);
const graphSeries = {
  throughput: ['dish_down_bps','dish_up_bps','router_down_bps','router_up_bps'],
  latency: ['latency_ms','wan_probe_rtt_ms'], loss: ['drop_rate','wan_probe_loss'], power: ['power_w'],
};
const CARD_PREFERENCES_KEY = 'starwatch.dashboard.cards.v1';

const loadCardPreferences = () => {
  try { return JSON.parse(localStorage.getItem(CARD_PREFERENCES_KEY) || 'null'); } catch (_) { return null; }
};

class CardDrawer extends Component {
  componentDidMount() { this.focusFirst(); }
  focusFirst() { requestAnimationFrame(() => this.closeButton?.focus()); }
  keyDown = event => {
    if (event.key === 'Escape') { event.preventDefault(); this.props.onClose(); return; }
    if (event.key !== 'Tab') return;
    const focusable = [...this.base.querySelectorAll('button:not([disabled]), input:not([disabled])')];
    const first = focusable[0], last = focusable.at(-1);
    if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last?.focus(); }
    else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first?.focus(); }
  };
  pointerDown = (event, id) => { event.preventDefault(); event.currentTarget.setPointerCapture?.(event.pointerId); this.dragging = id; };
  pointerMove = event => {
    if (!this.dragging) return;
    event.preventDefault();
    const target = document.elementFromPoint(event.clientX, event.clientY)?.closest('[data-card-id]')?.dataset.cardId;
    if (target && target !== this.dragging) this.props.onMove(this.dragging, target);
  };
  pointerUp = () => { this.dragging = null; };
  render({cards, preferences, onClose, onToggle, onMove, onReset}) {
    const byID = new Map(cards.map(card => [card.id, card]));
    const ordered = preferences.order.map(id => byID.get(id)).filter(Boolean);
    return html`<div class="drawer-layer" onMouseDown=${event => { if (event.target === event.currentTarget) onClose(); }}>
      <aside class="card-drawer" role="dialog" aria-modal="true" aria-labelledby="card-drawer-title" onKeyDown=${this.keyDown}>
        <header class="drawer-heading"><div><span class="eyebrow">LOCAL VIEW</span><h2 id="card-drawer-title">Customize dashboard</h2></div><button class="drawer-close" type="button" aria-label="Close dashboard customization" onClick=${onClose} ref=${node => { this.closeButton = node; }}>×</button></header>
        <p class="drawer-note">Some cards only show when they have data to present.</p>
        <ol class="drawer-cards" onPointerMove=${this.pointerMove} onPointerUp=${this.pointerUp} onPointerCancel=${this.pointerUp}>${ordered.map((card, index) => html`<li data-card-id=${card.id} class=${card.available ? '' : 'unavailable'}>
          <button class="drag-handle" type="button" aria-label=${`Drag ${card.label} to reorder`} onPointerDown=${event => this.pointerDown(event, card.id)} onPointerUp=${this.pointerUp}>⠿</button>
          <span>${card.label}</span><small>${card.available ? '' : 'Waiting for data'}</small>
          <button class="move-card" type="button" disabled=${index === 0} aria-label=${`Move ${card.label} up`} onClick=${() => onMove(card.id, ordered[index - 1]?.id, false)}>↑</button>
          <button class="move-card" type="button" disabled=${index === ordered.length - 1} aria-label=${`Move ${card.label} down`} onClick=${() => onMove(card.id, ordered[index + 1]?.id, true)}>↓</button>
          <label class="card-toggle"><input type="checkbox" checked=${!preferences.hidden[card.id]} onChange=${() => onToggle(card.id)}/><span class="sr-only">Show ${card.label}</span></label>
        </li>`)}</ol>
        <button class="button subtle drawer-reset" type="button" onClick=${onReset}>Reset to default</button>
      </aside>
    </div>`;
  }
}

class App extends Component {
  constructor() {
    super();
    const token=bootstrapToken();
    this.state={token,authNeeded:!token,route:location.hash||'#/',connection:'connecting',snapshot:{},wan:{},outages:[],events:[],speed:{state:'idle'},speedHistory:[],tab:'throughput',span:'3h',graphResponses:[],powerResponses:[],graphLoading:false,notice:'',error:'',cardPreferences:loadCardPreferences(),cardDrawerOpen:false,router:null};
  }

  componentDidMount() {
    this.onHash=()=>this.setState({route:location.hash||'#/'}); addEventListener('hashchange',this.onHash);
    if (this.state.token) this.hydrate();
  }
  componentWillUnmount() { removeEventListener('hashchange',this.onHash); this.live?.stop(); this.graphAbort?.abort(); clearTimeout(this.speedTimer); }

  unauthorized = () => { this.live?.stop(); storeToken(''); this.setState({authNeeded:true,token:'',error:'Token rejected by Starwatch.'}); };
  request = async (path, options) => { try{return await apiFetch(this.state.token,path,options);}catch(error){if(error.status===401)this.unauthorized();throw error;} };

  acceptToken = token => { storeToken(token); this.setState({token,authNeeded:false,error:''},()=>this.hydrate()); };

  async hydrate() {
    this.live?.stop();
    try {
      const [snapshot,wan,outages,events,speed,config,assist,router] = await Promise.all([
        this.request('/api/status'), this.request('/api/wan'), this.request('/api/outages?span=30d'), this.request('/api/events?span=30d'), this.request('/api/speedtest'),
        this.request('/api/config').catch(()=>null), this.request('/api/wan/failover-assist').catch(()=>null), this.request('/api/router').catch(()=>null),
      ]);
      snapshot.wan=wan;
      this.setState({snapshot,wan,outages,events,speed,config,assist,router,authNeeded:false,error:''});
      this.loadGraph(); this.loadPower(); this.loadMap(snapshot);
      this.live=new LiveClient({token:this.state.token,onFrame:this.onFrame,onStatus:connection=>this.setState({connection}),onUnauthorized:this.unauthorized,poll:()=>this.request('/api/status')}); this.live.start();
    } catch(error) { if (!(error instanceof APIError&&error.status===401)) this.setState({error:error.message}); }
  }

  onFrame = frame => {
    if (frame.event) { this.refreshEvents(); return; }
    if (frame.snapshot) { const snapshot={...frame.snapshot,wan:frame.snapshot.wan||this.state.wan}; this.setState({snapshot,wan:snapshot.wan}); return; }
    const snapshot={...this.state.snapshot,dish:frame.dish||this.state.snapshot.dish,wan:frame.wan||this.state.wan};
    this.setState({snapshot,wan:snapshot.wan});
    if (['15m','3h'].includes(this.state.span)) this.appendLive(frame);
  };

  appendLive(frame) {
    const values={dish_down_bps:frame.dish?.downlink_throughput_bps,dish_up_bps:frame.dish?.uplink_throughput_bps,router_down_bps:frame.wan?.router_down_bps,router_up_bps:frame.wan?.router_up_bps,latency_ms:frame.dish?.latency_ms,drop_rate:frame.dish?.drop_rate,wan_probe_rtt_ms:frame.wan?.probe_rtt_30s_ms,wan_probe_loss:frame.wan?.probe_loss_30s,power_w:frame.dish?.power_w};
    const cutoff=(frame.t||Date.now()/1000)-(this.state.span==='15m'?900:10800);
    const responses=this.state.graphResponses.map(response=>({...response,points:[...(response.points||[]),...(values[response.series]==null?[]:[{time:new Date((frame.t||Date.now()/1000)*1000).toISOString(),value:values[response.series]}])].filter(point=>new Date(point.time).getTime()/1000>=cutoff)}));
    this.setState({graphResponses:responses});
  }

  async loadGraph(tab=this.state.tab,span=this.state.span) {
    this.graphAbort?.abort(); const controller=new AbortController(); this.graphAbort=controller; this.setState({graphLoading:true});
    try { const graphResponses=await Promise.all(graphSeries[tab].map(series=>getHistory(this.state.token,series,span,controller.signal))); if(!controller.signal.aborted)this.setState({graphResponses,graphLoading:false}); }
    catch(error){if(error.name!=='AbortError')this.setState({graphLoading:false,notice:`History: ${error.message}`});}
  }
  setTab = tab => this.setState({tab},()=>this.loadGraph());
  setSpan = span => this.setState({span},()=>this.loadGraph());
  async loadPower(){try{this.setState({powerResponses:[await getHistory(this.state.token,'power_w','24h')]});}catch(_){}}
  async loadMap(snapshot=this.state.snapshot){if(!snapshot.dish_reachable)return;try{this.setState({grid:await this.request('/api/obstruction-map')});}catch(_){}}
  async refreshEvents(){try{const [events,outages]=await Promise.all([this.request('/api/events?span=30d'),this.request('/api/outages?span=30d')]);this.setState({events,outages});}catch(_){}}
  refreshRouter = async () => {
    const router = await this.request('/api/router');
    this.setState({router});
    return router;
  };
  mutateRouterClient = async (client, mutation) => {
    const router = this.state.router;
    const payload = clientMutationPayload({configRevision: router?.config_revision, ...mutation});
    try {
      await this.request(`/api/router/clients/${encodeURIComponent(client.mac)}`, {method:'PATCH',body:JSON.stringify(payload)});
      await this.refreshRouter();
    } catch (error) {
      // A 409 means the server rejected the old incarnation. Refresh before
      // allowing an explicit retry; never silently replay a router write.
      if (clientMutationShouldRetry(error)) {
        try { await this.refreshRouter(); } catch (_) {}
        error.retry = true;
        error.message = `${error.message}. Router data was refreshed; review and retry.`;
      }
      throw error;
    }
  };
  mutateRouterWifi = async mutation => {
    const payload = wifiMutationPayload({configRevision: this.state.router?.config_revision, ...mutation});
    try {
      await this.request('/api/router/wifi', {method:'PATCH', body:JSON.stringify(payload)});
      await this.refreshRouter();
    } catch (error) {
      // As with client changes, refresh stale telemetry but require the user to
      // review and explicitly retry the write against the new revision.
      if (wifiMutationShouldRetry(error)) {
        try { await this.refreshRouter(); } catch (_) {}
        error.retry = true;
        error.message = `${error.message}. Router data was refreshed; review and retry.`;
      }
      throw error;
    }
  };

  control = async (action, params={}, confirmation='') => {
    if (confirmation==='typed'&&prompt('Type REBOOT to confirm. The dish will be offline 2–5 minutes.')!=='REBOOT')return;
    if (confirmation==='confirm'&&!confirm(`Confirm ${action.replaceAll('-',' ')}?`))return;
    try { const result=await this.request(`/api/control/${action}`,{method:'POST',body:JSON.stringify(params)}); const snapshot={...this.state.snapshot,config:result.config||this.state.snapshot.config};this.setState({snapshot,notice:`${action.replaceAll('-',' ')} accepted.`}); }
    catch(error){this.setState({notice:error.message});}
  };
  clearMap = async()=>{if(!confirm('Clear the obstruction map? The map rebuilds over approximately 12 hours.'))return;await this.control('clear-obstruction-map');this.setState({grid:null});};
  runSpeed = async()=>{try{const speed=await this.request('/api/speedtest',{method:'POST'});this.setState({speed});this.pollSpeed();}catch(error){if(error.status===409)this.pollSpeed();else this.setState({notice:error.message});}};
  pollSpeed=async()=>{try{const speed=await this.request('/api/speedtest');let history=this.state.speedHistory;if(speed.state==='done'&&speed.latest&&!history.some(item=>item.at===speed.latest.at))history=[...history,speed.latest];this.setState({speed,speedHistory:history});if(speed.state==='running')this.speedTimer=setTimeout(this.pollSpeed,1000);}catch(error){this.setState({notice:error.message});}};
  refreshAssist=async()=>{try{this.setState({assist:await this.request('/api/wan/failover-assist')});}catch(error){this.setState({notice:error.message});}};
  applyAssist=async()=>{if(prompt('Type APPLY to write the displayed mwan3 changes.')!=='APPLY')return;try{this.setState({assist:await this.request('/api/wan/failover-assist',{method:'POST'}),notice:'Failover policy applied.'});}catch(error){this.setState({notice:error.message});}};
  saveConfig=async update=>{try{const config=await this.request('/api/config',{method:'PUT',body:JSON.stringify(update)});this.setState({config,notice:'Settings saved and applied.'});}catch(error){this.setState({notice:error.message});}};
  testAlert=async()=>{try{await this.request('/api/alerts/test',{method:'POST'});this.setState({notice:'Test notification queued.'});}catch(error){this.setState({notice:error.message});}};
  regenerate=async()=>{if(!confirm('Regenerate the access token? Existing dashboard sessions will stop working.'))return;try{const {token}=await this.request('/api/config/regenerate-token',{method:'POST'});storeToken(token);this.setState({token,newToken:token,notice:'Token regenerated. Copy the full value now.'},()=>this.hydrate());}catch(error){this.setState({notice:error.message});}};
  copyToken=async()=>{try{await navigator.clipboard.writeText(this.state.newToken);this.setState({notice:'New token copied.'});}catch(_){this.setState({notice:'Clipboard access was denied; select and copy the token manually.'});}};
  setCardPreferences = updater => this.setState(state => {
    const cardPreferences = updater(state.cardPreferences || {order: [], hidden: {}});
    try { localStorage.setItem(CARD_PREFERENCES_KEY, JSON.stringify(cardPreferences)); } catch (_) {}
    return {cardPreferences};
  });
  moveCard = (id, target, after = null) => { if (!target) return; this.setCardPreferences(preferences => { const original = normalizeCardPreferences(this.cardRegistry(this.state), preferences).order; const from = original.indexOf(id), targetIndex = original.indexOf(target); const order = original.filter(item => item !== id); const placeAfter = after === null ? from < targetIndex : after; const index = order.indexOf(target) + (placeAfter ? 1 : 0); order.splice(Math.max(0, index), 0, id); return {...preferences, order}; }); };
  toggleCard = id => this.setCardPreferences(preferences => ({...preferences, hidden: {...preferences.hidden, [id]: !preferences.hidden?.[id]}}));
  resetCards = () => { try { localStorage.removeItem(CARD_PREFERENCES_KEY); } catch (_) {} this.setState({cardPreferences:null}); };

  render(_,state) {
    if(state.authNeeded)return html`<${TokenView} error=${state.error} onSubmit=${this.acceptToken}/>`;
    const route=state.route.split('?')[0];
    return html`<div class="app-shell"><${StatusHeader} snapshot=${state.snapshot} connection=${state.connection} onCustomize=${() => this.setState({cardDrawerOpen:true})}/>${state.notice&&html`<button class="toast" onClick=${()=>this.setState({notice:''})}>${state.notice}<span>×</span></button>`}${route==='#/settings'?html`<${SettingsView} config=${state.config} onSave=${this.saveConfig} onTest=${this.testAlert} onRegenerate=${this.regenerate} onCopyToken=${this.copyToken} newToken=${state.newToken} notice=${state.notice}/>`:route==='#/events'?html`<${EventsView} events=${state.events}/>`:this.dashboard(state)}${state.cardDrawerOpen&&html`<${CardDrawer} cards=${this.cardRegistry(state)} preferences=${normalizeCardPreferences(this.cardRegistry(state), state.cardPreferences)} onClose=${() => this.setState({cardDrawerOpen:false}, () => document.querySelector('.header-customize')?.focus())} onToggle=${this.toggleCard} onMove=${this.moveCard} onReset=${this.resetCards}/>`}</div>`;
  }

  cardRegistry(state) { return [
    {id:'live-telemetry',label:'Live telemetry',available:true,render:()=>html`<${GraphCard} tab=${state.tab} span=${state.span} responses=${state.graphResponses} onTab=${this.setTab} onSpan=${this.setSpan} loading=${state.graphLoading}/>`},
    {id:'obstruction',label:'Obstruction',available:!!(state.snapshot.dish?.obstruction || state.grid),render:()=>html`<${ObstructionCard} snapshot=${state.snapshot} grid=${state.grid} onClear=${this.clearMap}/>`},
    {id:'outage-timeline',label:'Outage timeline',available:true,render:()=>html`<${OutageCard} outages=${state.outages}/>`},
    {id:'alignment',label:'Alignment',available:!!state.snapshot.dish?.alignment,render:()=>html`<${AlignmentCard} snapshot=${state.snapshot}/>`},
    {id:'power',label:'Power',available:state.snapshot.dish?.power_w != null || !!state.powerResponses?.length,render:()=>html`<${PowerCard} snapshot=${state.snapshot} responses=${state.powerResponses}/>`},
    {id:'wan-health',label:'WAN health',available:!!(state.wan?.available || state.wan?.mwan3),render:()=>html`<${WANCard} wan=${state.wan} assist=${state.assist} onRefreshAssist=${this.refreshAssist} onApplyAssist=${this.applyAssist}/>`},
    {id:'dish-controls',label:'Dish controls',available:true,render:()=>html`<${ControlsCard} snapshot=${state.snapshot} onControl=${this.control}/>`},
    {id:'speed-test',label:'Speed test',available:true,render:()=>html`<${SpeedCard} speed=${state.speed} history=${state.speedHistory} onRun=${this.runSpeed} reachable=${state.snapshot.dish_reachable}/>`},
    {id:'alerts',label:'Alerts',available:true,render:()=>html`<${AlertsCard} snapshot=${state.snapshot} events=${state.events}/>`},
    {id:'hardware',label:'Hardware',available:!!state.snapshot.device_info,render:()=>html`<${HardwareCard} snapshot=${state.snapshot}/>`},
    {id:'starlink-router',label:'Starlink router',available:!!state.router,render:()=>html`<${StarlinkRouterCard} router=${state.router} onMutate=${this.mutateRouterWifi}/>`},
    {id:'client-management',label:'Client management',available:!!state.router,render:()=>html`<${ClientManagementCard} router=${state.router} onMutate=${this.mutateRouterClient}/>`},
  ]; }
  dashboard(state) { const cards=this.cardRegistry(state); const preferences=normalizeCardPreferences(cards,state.cardPreferences); const byID=new Map(cards.map(card=>[card.id,card])); return html`<main id="dashboard" class="dashboard"><nav class="quick-nav"><a href="#/events">Events</a><a href="#/settings">Settings</a></nav><div class="card-grid">${preferences.order.filter(id=>!preferences.hidden[id]).map(id=>byID.get(id)).filter(card=>card?.available).map(card=>card.render())}</div></main>`; }
}

render(html`<${App}/>`,document.querySelector('#app'));
