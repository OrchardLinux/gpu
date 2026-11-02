// Frame intervals from requestAnimationFrame for `seconds`, then POST
// {test, frames, fps, mean, p50, p95, p99, max, jank} (ms; jank: > 25 ms)
function probe(test, seconds, step) {
  const t = [];
  const end = performance.now() + seconds * 1000;
  function frame(now) {
    t.push(now);
    if (step) step(now);
    if (now < end) { requestAnimationFrame(frame); return; }
    const d = t.slice(1).map((v, i) => v - t[i]).sort((a, b) => a - b);
    const q = p => d[Math.min(d.length - 1, Math.floor(p * d.length))];
    const mean = d.reduce((a, b) => a + b, 0) / d.length;
    const r = { test, frames: d.length, fps: 1000 / mean, mean, p50: q(0.5), p95: q(0.95),
                p99: q(0.99), max: d[d.length - 1], jank: d.filter(x => x > 25).length,
                load: performance.timing.loadEventEnd - performance.timing.navigationStart };
    // ?next=a.html,b.html: the pages to run after this one, in order
    const next = (new URLSearchParams(location.search).get('next') || '').split(',').filter(Boolean);
    fetch('/result', { method: 'POST', body: JSON.stringify(r) }).then(() => {
      if (next.length)
        location.href = next[0] + (next.length > 1 ? '?next=' + next.slice(1).join(',') : '');
      else
        fetch('/result', { method: 'POST', body: JSON.stringify({ test: 'end' }) });
    });
  }
  requestAnimationFrame(frame);
}
