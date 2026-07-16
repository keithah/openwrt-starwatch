/* Built GL-panel (oui) view for Starwatch. oui loads a view with
   `const component = eval(res.data)`, so this file must evaluate to a Vue 2
   component. It reads token + port through the authenticated panel RPC, then
   embeds the daemon's offline SPA. Keep this built artifact committed. */
(function () {
  function cookie(name) {
    var match = document.cookie.match(new RegExp('(?:^|; )' + name + '=([^;]*)'));
    return match ? decodeURIComponent(match[1]) : '';
  }

  function rpc(object, method, args) {
    return fetch('/rpc', {
      method: 'POST',
      headers: {'Content-Type': 'application/json'},
      body: JSON.stringify({jsonrpc: '2.0', id: 1, method: 'call',
        params: [cookie('Admin-Token'), object, method, args || {}]})
    }).then(function (response) { return response.json(); }).then(function (body) {
      if (body.error) throw new Error(body.error.message);
      return body.result;
    });
  }

  return {
    name: 'starwatch',
    data: function () {
      return {token: '', port: '9633', loaded: false, running: false, error: ''};
    },
    created: function () {
      var self = this;
      rpc('starwatch', 'get_config').then(function (config) {
        self.token = config.token || '';
        self.port = config.port || '9633';
        return fetch(self.dashboardURL(), {mode: 'no-cors', cache: 'no-store'});
      }).then(function () {
        self.running = true;
        self.loaded = true;
      }).catch(function (error) {
        self.error = error.message || String(error);
        self.loaded = true;
      });
    },
    methods: {
      dashboardURL: function () {
        return 'http://' + window.location.hostname + ':' + this.port + '/?token=' + encodeURIComponent(this.token);
      }
    },
    render: function (h) {
      var shellStyle = {fontFamily: '-apple-system,BlinkMacSystemFont,Segoe UI,Roboto,sans-serif',
        minHeight: '640px', height: 'calc(100vh - 120px)'};
      if (!this.loaded) {
        return h('div', {style: shellStyle}, [h('div', {style: {padding: '32px', color: '#8b98a5'}}, 'Loading Starwatch…')]);
      }
      if (!this.running) {
        return h('div', {style: shellStyle}, [h('div', {style: {maxWidth: '560px', margin: '32px auto', padding: '24px',
          borderRadius: '14px', background: '#fff', boxShadow: '0 2px 12px rgba(0,0,0,.12)'}}, [
          h('h2', {style: {marginTop: '0'}}, 'Starwatch daemon unavailable'),
          h('p', {}, 'Install or restart the daemon, then reload this page.'),
          h('code', {}, 'opkg install starwatchd && /etc/init.d/starwatch restart')
        ])]);
      }
      return h('div', {style: shellStyle}, [h('iframe', {
        attrs: {src: this.dashboardURL(), title: 'Starwatch dashboard'},
        style: {width: '100%', height: '100%', border: '0', borderRadius: '8px', background: '#071018'}
      })]);
    }
  };
})()
