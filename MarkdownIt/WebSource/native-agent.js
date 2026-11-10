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
    const nativeInputs = (() => {
      const entries = new Map();
      const valueProperty = Object.getOwnPropertyDescriptor(HTMLTextAreaElement.prototype, 'value');
      let applying = false;
      let committing = false;
      let focused = null;
      let previous = '';
      let frame = 0;
      let trackUntil = 0;
      function schedule() { if (!frame) frame = requestAnimationFrame(sync); }
      function trackLayout() { trackUntil = performance.now() + Math.max(motion.modeOut.duration + motion.modeIn.duration, motion.agentPanel.duration, motion.layout.duration); schedule(); }
      function register(field, id) {
        const entry = { field, id, epoch: 0, measurementKey: '' };
        entries.set(id, entry);
        resize.observe(field);
        field.setAttribute('aria-hidden', 'true');
        field.tabIndex = -1;
        field.style.color = 'transparent';
        field.style.caretColor = 'transparent';
        field.style.pointerEvents = 'none';
        Object.defineProperty(field, 'value', {
          get() { return valueProperty.get.call(field); },
          set(text) {
            valueProperty.set.call(field, text);
            if (!applying) {
              ++entry.epoch;
              postNative({ type: 'inputSetText', id, text: field.value, epoch: entry.epoch });
            }
          }
        });
        field.focus = () => {
          document.activeElement?.blur();
          focused = id;
          postNative({ type: 'inputFocus', id });
        };
        postNative({ type: 'inputSetText', id, text: field.value, epoch: entry.epoch });
      }
      function update(payload) {
        const entry = entries.get(payload.id);
        if (!entry || payload.epoch !== entry.epoch) return false;
        if (entry.field.value === payload.text) { resizeInput(payload); return true; }
        notePanelInteraction('agent');
        applying = true;
        entry.field.value = payload.text;
        applying = false;
        resizeInput(payload);
        entry.field.dispatchEvent(new Event('input', { bubbles: true }));
        return true;
      }
      function resizeInput(payload) {
        const entry = entries.get(payload.id);
        if (!entry || payload.epoch !== entry.epoch || entry.field.value !== payload.text ||
            payload.measurementKey !== entry.measurementKey || !Number.isFinite(payload.height) || payload.height <= 0) return;
        entry.field.style.height = payload.height + 'px';
      }
      function commit(payload) {
        if (!update(payload)) return;
        const entry = entries.get(payload.id);
        committing = true;
        entry.field.form.requestSubmit();
        committing = false;
      }
      function sync() {
        frame = 0;
        const states = [];
        for (const entry of entries.values()) {
          const { field, id } = entry;
          const box = field.getBoundingClientRect();
          const panel = field.closest('.mdv-agent');
          const visible = !!box.width && !!box.height && !panel.hidden && !panel.inert;
          const style = getComputedStyle(field);
          const layoutWidth = parseFloat(style.width);
          const metrics = ['fontSize', 'lineHeight', 'paddingTop', 'paddingRight', 'paddingBottom', 'paddingLeft'].map(key => parseFloat(style[key]));
          entry.measurementKey = JSON.stringify([layoutWidth, ...metrics]);
          const opacity = panel.hidden ? 0 : Number(getComputedStyle(panel).opacity);
          states.push({ id, visible, opacity, x: box.x, y: box.y, width: box.width, height: box.height,
            layoutWidth, measurementKey: entry.measurementKey,
            fontSize: parseFloat(style.fontSize), lineHeight: parseFloat(style.lineHeight),
            top: parseFloat(style.paddingTop), right: parseFloat(style.paddingRight), bottom: parseFloat(style.paddingBottom), left: parseFloat(style.paddingLeft) });
        }
        const box = source.getBoundingClientRect();
        const controls = [...app.querySelectorAll('[data-native-agent-control]')].map(slot => {
          const panel = slot.closest('.mdv-agent'), box = slot.getBoundingClientRect();
          return { id: slot.dataset.nativeAgentControl, x: box.x, y: box.y, width: box.width, height: box.height,
            visible: !!box.width && !!box.height && !panel.hidden && !panel.inert,
            opacity: panel.hidden ? 0 : Number(getComputedStyle(panel).opacity),
            enabled: slot.dataset.nativeAgentControl !== 'clear' || panel.hasAttribute('data-agent-has-history'),
            sheet: app.dataset.agentLayout === 'sheet' };
        });
        const sourceState = { type: 'sourceLayout', token: nativeToken,
          visible: displayedMode === 'source', interactive: state.mode === displayedMode && !app.dataset.modeTransition && !source.closest('[inert]'),
          opacity: Number(getComputedStyle(readingLayout).opacity),
          x: box.x, y: box.y, width: box.width, height: box.height };
        const fingerprint = JSON.stringify([states, controls, sourceState]);
        if (fingerprint !== previous) { previous = fingerprint; postNative({ type: 'inputLayout', token: nativeToken, inputs: states, controls }); postNative(sourceState); }
        if (performance.now() < trackUntil) schedule();
      }
      const observer = new MutationObserver(schedule);
      observer.observe(app, { childList: true, subtree: true, attributes: true, attributeFilter: ['hidden', 'inert', 'class', 'style', 'data-modal-active', 'data-agent-layout', 'data-agent-has-history'] });
      const resize = new ResizeObserver(trackLayout);
      resize.observe(app);
      addEventListener('scroll', schedule, { passive: true, capture: true });
      addEventListener('resize', trackLayout);
      window.visualViewport?.addEventListener('resize', trackLayout);
      schedule();
      return { register, update, resize: resizeInput, commit, trackLayout, epoch(id) { return entries.get(id)?.epoch; }, get committing() { return committing; }, requestSubmit(id) { postNative({ type: 'inputSubmit', id }); },
        blur() { focused = null; postNative({ type: 'inputBlur' }); }, clear() { focused = null; for (const entry of entries.values()) entry.field.value = ''; }, focused: () => focused };
    })();
