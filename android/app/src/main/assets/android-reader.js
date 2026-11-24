(() => {
  const bridge = window.MarkdownItAndroid;
  const send = (type, payload = {}) => bridge.postMessage(JSON.stringify({ type, ...payload }));
  let token = '', layoutRevision = 0, outline = false, find = null;
  let opening = Promise.resolve();
  const pendingCopies = new Map();
  const reader = () => window.MarkdownIt;

  function applyLayout() {
    reader().panelLayout({ revision: ++layoutRevision, outline, overlay: true, compact: true, agent: false });
    send('outline', { token, open: outline });
  }

  window.MarkdownItPlatform = {
    localResourceURL(id, path) { return `/resource/${id}?path=${encodeURIComponent(path)}`; },
  };
  // The shared reader already speaks these channels on iOS. Only the transport
  // and native actions differ here.
  window.webkit = { messageHandlers: {
    conversation: { postMessage(message) {
      send('selectionReference', message);
    } },
    reader: { postMessage(message) {
      switch (message.type) {
        case 'panelRequest':
          if (message.panel === 'outline') {
            outline = message.toggle ? !outline : message.open;
            applyLayout();
          }
          break;
        case 'recoveryChanged':
          if (message.token === token) send('position', { token, snapshot: reader().captureRecovery() });
          break;
        case 'ready':
        case 'state':
        case 'link':
        case 'localResources':
        case 'imageMenu':
          bridge.postMessage(JSON.stringify({ token, ...message }));
          break;
      }
    } },
    copyCode: { postMessage(payload) {
      const id = crypto.randomUUID();
      return new Promise(resolve => {
        pendingCopies.set(id, resolve);
        send('copyCode', { ...payload, id });
      });
    } },
  } };
  bridge.onmessage = event => {
    const reply = JSON.parse(event.data);
    pendingCopies.get(reply.id)?.(reply.copied);
    pendingCopies.delete(reply.id);
  };

  function showMatch(delta) {
    if (!find?.ranges.length) return;
    const { id, ranges, active } = find;
    find.active = (active + delta + ranges.length) % ranges.length;
    const visible = ranges[find.active];
    reader().findDecorate({ id, ranges: [
      ...(active >= 0 && active !== find.active ? [{ ...ranges[active], style: 1 }] : []),
      { ...visible, style: 2 },
    ] });
    reader().findReveal({ id, ...visible });
    send('find', { token, count: ranges.length, active: find.active + 1 });
  }

  window.AndroidMarkdownIt = {
    open(id, recovery) {
      token = id;
      opening = opening.then(async () => {
        if (token !== id) return;
        try {
          const response = await fetch(`/document/${id}`);
          if (!response.ok) throw new Error('Document unavailable');
          const document = await response.json();
          if (token !== id) return;
          await reader().openDocument({ ...document, token: id, revision: 0, mode: 'preview', recovery });
          if (token !== id) return;
          outline = Boolean(recovery?.outline);
          find = null;
          applyLayout();
          reader().finishOpening();
          send('opened', { token, hasOutline: reader().diagnostics().headings.length > 0 });
        } catch {
          if (token === id) send('renderFailed', { token });
        }
      });
    },
    outline(open) { outline = open; applyLayout(); },
    toggleOutline() { reader().toggleOutline(); },
    reloadResources() { reader().reloadResources(); },
    setFind(query) {
      find = null;
      if (!query.trim()) { reader().findClear(); send('find', { token, count: 0, active: 0 }); return; }
      const { id, text } = reader().findCapture();
      const literal = query.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
      const ranges = Array.from(text.matchAll(new RegExp(literal, 'giu')), match => ({ start: match.index, length: match[0].length }));
      find = { id, ranges, active: -1 };
      if (!ranges.length) { send('find', { token, count: 0, active: 0 }); return; }
      reader().findDecorate({ id, ranges: ranges.map(range => ({ ...range, style: 1 })) });
      showMatch(1);
    },
    showMatch,
  };
  if (!window.Highlight || !window.CSS?.highlights || !crypto.randomUUID || !Array.prototype.at) send('unsupported');
})();
