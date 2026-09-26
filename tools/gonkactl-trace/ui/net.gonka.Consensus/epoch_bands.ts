import type {Overlay} from '../../public/track';
import type {time} from '../../base/time';

type Event = {kind: string; height: number; temporality: string; trace_ts_ns?: string};
export type EpochBand = {height: number; start: bigint; end: bigint; partial: boolean; logTime: boolean};

// No extrapolated epochs across source gaps. The retained incident evidence has
// adjacent EpochGroupChanged heights separated by 70 blocks.
export function epochBands(events: Event[]): EpochBand[] {
  const headers = new Map<number, bigint>();
  const changes = new Map<number, bigint>();
  for (const e of events) {
    if (e.temporality !== 'historical' || !/^\d+$/.test(e.trace_ts_ns ?? '')) continue;
    const t = BigInt(e.trace_ts_ns!);
    const map = e.kind === 'header.timestamp' ? headers : e.kind === 'epoch.changed' ? changes : undefined;
    if (map && (!map.has(e.height) || t < map.get(e.height)!)) map.set(e.height, t);
  }
  const heights = [...changes.keys()].sort((a, b) => a - b);
  const lastHeight = Math.max(0, ...headers.keys());
  const result: EpochBand[] = [];
  for (let i = 0; i < heights.length; i++) {
    const h = heights[i], next = heights[i + 1];
    const partial = next === undefined && lastHeight >= h && lastHeight < h + 70;
    if (next !== h + 70 && !partial) continue;
    const start = headers.get(h) ?? changes.get(h)!;
    const end = partial ? headers.get(lastHeight)! : headers.get(next) ?? changes.get(next)!;
    if (end > start) result.push({height: h, start, end, partial, logTime: !headers.has(h) || (!partial && !headers.has(next))});
  }
  return result;
}

export function epochOverlay(bands: EpochBand[]): Overlay {
  return {render(ctx, timescale, size) {
    const x0 = Math.max(0, timescale.pxBounds.left);
    const x1 = Math.min(size.width, timescale.pxBounds.right);
    ctx.save();
    ctx.beginPath();
    ctx.rect(x0, 0, Math.max(0, x1 - x0), size.height);
    ctx.clip();
    for (const band of bands) {
      const boundary = timescale.timeToPx(band.start as time);
      const left = Math.max(x0, boundary);
      const right = Math.min(x1, timescale.timeToPx(band.end as time));
      if (right <= left) continue;
      // A translucent overlay preserves slice colours, text and hit testing.
      const grey = Math.floor(band.height / 70) % 2 === 0;
      ctx.fillStyle = grey ? 'rgba(90,100,110,0.10)' : 'rgba(255,255,255,0.04)';
      ctx.fillRect(left, 0, right - left, size.height);
      ctx.fillStyle = 'rgba(80,90,100,0.35)';
      if (boundary >= x0) ctx.fillRect(left, 0, 1, size.height);
      if (right - left >= 140) {
        const text = `Epoch H${band.height}${band.partial ? ' · partial' : ''}${band.logTime ? ' · log time' : ''}`;
        ctx.font = '11px sans-serif';
        ctx.fillStyle = 'rgba(255,255,255,0.88)';
        ctx.fillRect(left + 3, 2, Math.min(right - left - 6, ctx.measureText(text).width + 8), 16);
        ctx.save(); ctx.beginPath(); ctx.rect(left, 0, right - left, 20); ctx.clip();
        ctx.fillStyle = '#46515c'; ctx.fillText(text, left + 7, 14); ctx.restore();
      }
    }
    ctx.restore();
  }};
}
