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
