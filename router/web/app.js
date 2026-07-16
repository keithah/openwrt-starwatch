import {Component, h, render} from './vendor/preact.module.js';
import htm from './vendor/htm.module.js';
import {APIError, apiFetch, bootstrapToken, getHistory, LiveClient, storeToken} from './api.js';
import {StatusHeader, GraphCard, ObstructionCard, OutageCard, AlignmentCard, PowerCard, WANCard, ControlsCard, SpeedCard, AlertsCard, HardwareCard} from './cards.js';
import {TokenView, SettingsView, EventsView} from './views.js';

const html = htm.bind(h);
const graphSeries = {
  throughput: ['dish_down_bps','dish_up_bps','router_down_bps','router_up_bps'],
  latency: ['latency_ms','wan_probe_rtt_ms'], loss: ['drop_rate','wan_probe_loss'], power: ['power_w'],
};

class App extends Component {
  constructor() {
    super();
    const token=bootstrapToken();
    this.state={token,authNeeded:!token,route:location.hash||'#/',connection:'connecting',snapshot:{},wan:{},outages:[],events:[],speed:{state:'idle'},speedHistory:[],tab:'throughput',span:'3h',graphResponses:[],powerResponses:[],graphLoading:false,notice:'',error:''};
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
      const [snapshot,wan,outages,events,speed,config,assist] = await Promise.all([
        this.request('/api/status'), this.request('/api/wan'), this.request('/api/outages?span=30d'), this.request('/api/events?span=30d'), this.request('/api/speedtest'),
        this.request('/api/config').catch(()=>null), this.request('/api/wan/failover-assist').catch(()=>null),
      ]);
      snapshot.wan=wan;
      this.setState({snapshot,wan,outages,events,speed,config,assist,authNeeded:false,error:''});
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

  render(_,state) {
    if(state.authNeeded)return html`<${TokenView} error=${state.error} onSubmit=${this.acceptToken}/>`;
    const route=state.route.split('?')[0];
    return html`<div class="app-shell"><${StatusHeader} snapshot=${state.snapshot} connection=${state.connection}/>${state.notice&&html`<button class="toast" onClick=${()=>this.setState({notice:''})}>${state.notice}<span>×</span></button>`}${route==='#/settings'?html`<${SettingsView} config=${state.config} onSave=${this.saveConfig} onTest=${this.testAlert} onRegenerate=${this.regenerate} onCopyToken=${this.copyToken} newToken=${state.newToken} notice=${state.notice}/>`:route==='#/events'?html`<${EventsView} events=${state.events}/>`:this.dashboard(state)}</div>`;
  }

  dashboard(state){return html`<main id="dashboard" class="dashboard"><nav class="quick-nav"><a href="#/events">Events</a><a href="#/settings">Settings</a></nav><div class="card-grid"><${GraphCard} tab=${state.tab} span=${state.span} responses=${state.graphResponses} onTab=${this.setTab} onSpan=${this.setSpan} loading=${state.graphLoading}/><${ObstructionCard} snapshot=${state.snapshot} grid=${state.grid} onClear=${this.clearMap}/><${OutageCard} outages=${state.outages}/><${AlignmentCard} snapshot=${state.snapshot}/><${PowerCard} snapshot=${state.snapshot} responses=${state.powerResponses}/><${WANCard} wan=${state.wan} assist=${state.assist} onRefreshAssist=${this.refreshAssist} onApplyAssist=${this.applyAssist}/><${ControlsCard} snapshot=${state.snapshot} onControl=${this.control}/><${SpeedCard} speed=${state.speed} history=${state.speedHistory} onRun=${this.runSpeed} reachable=${state.snapshot.dish_reachable}/><${AlertsCard} snapshot=${state.snapshot} events=${state.events}/><${HardwareCard} snapshot=${state.snapshot}/></div></main>`;}
}

render(html`<${App}/>`,document.querySelector('#app'));
