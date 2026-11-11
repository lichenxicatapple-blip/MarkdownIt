    const sourceProjection = (() => {
      let frame = 0, previous = '', trackUntil = 0;
      function schedule() { if (!frame) frame = requestAnimationFrame(sync); }
      function trackLayout() { trackUntil = performance.now() + Math.max(motion.modeOut.duration + motion.modeIn.duration, motion.layout.duration); schedule(); }
      function sync() {
        frame = 0;
        const box = source.getBoundingClientRect();
        const value = { type:'sourceLayout', token:nativeToken, visible:displayedMode === 'source',
          interactive:state.mode === displayedMode && !app.dataset.modeTransition && !source.closest('[inert]'),
          opacity:Number(getComputedStyle(readingLayout).opacity), x:box.x, y:box.y, width:box.width, height:box.height };
        const fingerprint = JSON.stringify(value);
        if (fingerprint !== previous) { previous = fingerprint; postNative(value); }
        if (performance.now() < trackUntil) schedule();
      }
      new MutationObserver(schedule).observe(app, {subtree:true, attributes:true, attributeFilter:['hidden','inert','class','style','data-mode-transition']});
      new ResizeObserver(trackLayout).observe(app);
      addEventListener('resize', trackLayout);
      schedule();
      return {trackLayout};
    })();
