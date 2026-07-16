'use strict';
'require view';
'require rpc';

var callToken = rpc.declare({
	object: 'starwatch',
	method: 'token',
	expect: { '': {} }
});

function dashboardURL(config) {
	return 'http://' + window.location.hostname + ':' + (config.port || '9633') + '/?token=' + encodeURIComponent(config.token || '');
}

function unavailable(message) {
	return E('div', { 'class': 'cbi-map' }, [
		E('h2', {}, _('Starwatch')),
		E('div', { 'class': 'alert-message warning' }, [
			E('p', {}, message || _('The Starwatch daemon is not responding.')),
			E('p', {}, [_('Install or restart it with '), E('code', {}, 'opkg install starwatchd && /etc/init.d/starwatch restart')])
		])
	]);
}

return view.extend({
	load: function () {
		return callToken().then(function (config) {
			return fetch(dashboardURL(config), { mode: 'no-cors', cache: 'no-store' }).then(function () {
				return { config: config, running: true };
			}, function () {
				return { config: config, running: false };
			});
		}, function (error) {
			return { error: error };
		});
	},

	render: function (state) {
		if (state.error) return unavailable(_('Unable to read the Starwatch access token.'));
		if (!state.running) return unavailable();
		return E('div', { style: 'height:calc(100vh - 110px);min-height:640px' }, [
			E('iframe', {
				src: dashboardURL(state.config),
				title: _('Starwatch dashboard'),
				style: 'width:100%;height:100%;border:0;border-radius:8px;background:#071018'
			})
		]);
	},

	handleSaveApply: null,
	handleSave: null,
	handleReset: null
});
