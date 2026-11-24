(() => {
  const bridge = window.MarkdownItAndroid;
  const copies = new Map();
  window.webkit = { messageHandlers: {
    reader: { postMessage(message) { bridge.postMessage(JSON.stringify(message)); } },
    copyCode: { postMessage(message) {
      const id = crypto.randomUUID();
      return new Promise(resolve => {
        copies.set(id, resolve);
        bridge.postMessage(JSON.stringify({ ...message, type: 'copyCode', id }));
      });
    } }
  } };
  bridge.onmessage = event => {
    const reply = JSON.parse(event.data);
    copies.get(reply.id)?.(reply.copied);
    copies.delete(reply.id);
  };
})();
