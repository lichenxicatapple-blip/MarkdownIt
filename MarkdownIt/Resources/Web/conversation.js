/* Conversation state and rich content; native owns the containing panel. */
(() => {
  const {t, apply:localize} = window.MarkdownItLocalization;
  const app = document.querySelector('.mdv-app');
  const panel = app.querySelector('.mdv-agent');
  const motion = JSON.parse(document.getElementById('mdv-motion-spec').textContent);
  const reducedMotion = matchMedia('(prefers-reduced-motion: reduce)');
  let nativeToken = '', nativeDocumentName = '', currentDocument = {text:'', markdown:'', images:[]};
  let recovering = false, open = false, modal = false, presentationRevision = -1;
  const frozenImageIDs = new Set();
  function postNative(message) { window.webkit.messageHandlers.reader.postMessage({token:nativeToken,...message}); }
  function checkpoint() { if (!recovering && nativeToken) postNative({type:'recoveryChanged'}); }
  function prepareLocalResources(fragment) {
    fragment.querySelectorAll('img').forEach(image => {
      const path = image.getAttribute('data-source-path') || image.getAttribute('src') || '';
      if (path && !/^(https?:|data:|blob:)/i.test(path)) image.src = `jm-resource://${nativeToken}/image?path=${encodeURIComponent(path)}`;
    });
  }
  const rendering = window.MarkdownItRendering.create({app, token:()=>nativeToken, prepareLocalResources, frozenImageIDs});
  function freezeImages(ids) {
    ids.forEach(id => frozenImageIDs.add(id));
    app.querySelectorAll('img[data-agent-image-id]').forEach(image => {
      if (frozenImageIDs.has(image.dataset.agentImageId)) image.src = `jm-image://${nativeToken}/${image.dataset.agentImageId}`;
    });
  }
    // Native transport and text input adapters. No model endpoint or credential enters JavaScript.
    const nativeRequests = new Map();
    const nativeUndoRequests = new Map();
    let nativeRequestSequence = 0;
    let pendingNativeAgentEntry = null;
    let pendingNativeAgentConsent = null;
    function ensureNativeAgentConfigured(resume) {
      const id = nativeToken + '-entry-' + (++nativeRequestSequence);
      pendingNativeAgentEntry = { id, token: nativeToken, resume };
      postNative({ type: 'agentEntry', id, token: nativeToken });
    }
    function createNativeAgentTransport() {
      return {
        authorize() {
          if (pendingNativeAgentConsent) return Promise.resolve(false);
          const id = nativeToken + '-consent-' + (++nativeRequestSequence);
          return new Promise(resolve => {
            pendingNativeAgentConsent = { id, token: nativeToken, resolve };
            postNative({ type: 'agentConsent', id, token: nativeToken });
          });
        },
        stream(snapshot, intent, callbacks) {
          const id = nativeToken + '-' + (++nativeRequestSequence);
          nativeRequests.set(id, callbacks);
          postNative({ type: 'agentRequest', id, token: nativeToken, snapshot: JSON.parse(JSON.stringify(snapshot)), intent });
          return () => { postNative({ type: 'agentCancel', id, token: nativeToken }); };
        },
        undo(change) {
          const id = nativeToken + '-undo-' + (++nativeRequestSequence);
          return new Promise(resolve => {
            nativeUndoRequests.set(id, resolve);
            postNative({type: 'agentUndo', id, change, token: nativeToken});
          });
        }
      };
    }

    // The hidden textarea is a draft adapter only. UIKit owns all input geometry.
    const nativeInputs = (() => {
      let field, epoch = 0, applying = false, committing = false;
      const valueProperty = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
      return {
        register(value) {
          field = value;
          Object.defineProperty(field, 'value', { get() { return valueProperty.get.call(field); }, set(text) {
            valueProperty.set.call(field, text);
            if (!applying) postNative({type:'inputSetText', text:field.value, epoch:++epoch});
          }});
          field.focus = () => postNative({type:'inputFocus'});
        },
        update(payload) {
          if (payload.epoch !== epoch) return false;
          applying = true; field.value = payload.text; applying = false;
          field.dispatchEvent(new Event('input', {bubbles:true})); return true;
        },
        commit(payload) {
          if (!this.update(payload)) return;
          committing = true; field.form.requestSubmit(); committing = false;
        },
        publish() { postNative({type:'inputSetText',text:field.value,epoch}); },
        get committing() { return committing; }, epoch() { return epoch; },
        requestSubmit() { postNative({type:'inputSubmit'}); },
        blur() { postNative({type:'inputBlur'}); }, clear() { field.value = ''; }
      };
    })();

  const experience = window.MarkdownItAgent.create({app, panel, motion, reducedMotion, nativeInputs,
    renderMarkdown:rendering.render, enhance:rendering.enhance, fragmentIdentifier:rendering.fragmentIdentifier,
    documentAttachment:()=>({...currentDocument, images:currentDocument.images.map(image=>({...image}))}),
    ensureConfigured:ensureNativeAgentConfigured, provider:createNativeAgentTransport(), onCheckpoint:checkpoint,
    onLifecycle(event,count) { postNative({type:'agentLifecycle',event,count}); },
    onControls(value) { postNative({type:'agentControls',...value}); },
    onToggle(shown) { if(!recovering) postNative({type:'agentToggle',open:shown}); }
  });
  ['pointerdown','wheel','keydown'].forEach(type=>app.addEventListener(type,()=>postNative({type:'panelInteraction',panel:'agent'}),{passive:true,capture:true}));
  localize(app);
  app.addEventListener('click', event => {
    const link = event.target.closest('a[href]:not([href^="#"])');
    if (link) { event.preventDefault(); postNative({type:'link',href:link.getAttribute('href')}); }
  }, true);
  window.MarkdownIt = {
    async openDocument(document) {
      recovering = true;
      pendingNativeAgentConsent?.resolve(false); pendingNativeAgentConsent = null;
      pendingNativeAgentEntry = null; nativeRequests.clear(); nativeUndoRequests.clear();
      experience.reset(); nativeToken = document.token; nativeDocumentName = document.name;
      currentDocument = document.background;
      nativeInputs.publish();
      frozenImageIDs.clear();
      const saved = document.recovery || document.conversation;
      nativeRequestSequence = saved?.nativeRequestSequence || 0;
      if (saved) { freezeImages(saved.frozenImages || []); experience.restore(saved.conversation || {}); }
      if (saved) experience.finishRestore(saved.conversation || {});
      recovering = false; checkpoint(); return true;
    },
    documentBackground(value) { currentDocument = value; },
    presentation(value) {
      if (value.revision < presentationRevision) return;
      presentationRevision = value.revision;
      open = value.open; modal = value.modal;
      app.dataset.agentLayout = value.modal ? 'sheet' : 'side';
      experience.present(open);
    },
    attach(value) { experience.attach(value, value.rect); },
    openAgent() { experience.openGlobal(); },
    resolveAgentEntry(payload) {
      const entry = pendingNativeAgentEntry;
      if (!entry || entry.id !== payload.id || entry.token !== nativeToken) return;
      pendingNativeAgentEntry = null;
      if (payload.allowed) entry.resume();
    },
    resolveAgentConsent(payload) {
      const pending = pendingNativeAgentConsent;
      if (!pending || pending.id !== payload.id || pending.token !== payload.token || pending.token !== nativeToken) return;
      pendingNativeAgentConsent = null; pending.resolve(payload.allowed === true);
    },
    updateAgentInput(payload) { nativeInputs.update(payload); },
    commitAgentInput(payload) { nativeInputs.commit(payload); },
    sendAgentInput() { panel.querySelector('.mdv-agent-send').click(); },
    clearAgentHistory(payload) {
      if (payload.token !== nativeToken) return false;
      const retained = experience.clearHistory(), ids = new Set(retained);
      for (const id of frozenImageIDs) if (!ids.has(id)) frozenImageIDs.delete(id);
      return retained;
    },
    sourceHistory(events) { for (const detail of events) app.dispatchEvent(new CustomEvent('mdv-source-history',{detail})); },
    agentEvent(event) {
      if (event.token !== nativeToken) return;
      const request = nativeRequests.get(event.id);
      if (!request) return;
      if (event.type === 'images') { freezeImages(event.imageIDs || []); return; }
      if (event.type === 'change') request.change(event.change);
      else if (event.type === 'text') request.text(event.text);
      else {
        nativeRequests.delete(event.id);
        if (event.type === 'complete') request.complete(event);
        else if (event.type !== 'cancelled') request.fail(event.failure || {kind:'service'});
      }
    },
    agentUndoResult(payload) { const resolve=nativeUndoRequests.get(payload.id); nativeUndoRequests.delete(payload.id); resolve?.(payload.result); },
    captureRecovery() { return {nativeRequestSequence, composerEpoch:nativeInputs.epoch(), frozenImages:[...frozenImageIDs], conversation:experience.capture()}; },
    agentDiagnostics() {
      return {open, modal, draft:panel.querySelector('textarea').value,
        reference:panel.querySelector('.mdv-composer-reference').textContent, referenceHTML:panel.querySelector('.mdv-composer-reference').innerHTML,
        turns:[...panel.querySelectorAll('.mdv-turn')].map(turn=>({role:turn.dataset.role,state:turn.dataset.state,text:turn.textContent,html:turn.innerHTML})), markup:panel.innerHTML};
    },
    theme(value) { rendering.theme(value); }
  };
  app.dataset.ready='true'; postNative({type:'conversationReady'});
})();
