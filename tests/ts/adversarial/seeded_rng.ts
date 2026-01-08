/** Deterministic xorshift32 for adversarial fuzzers (task-14 / C3). */

export class SeededRng {
  private state: number;

  constructor(seed: number = 0x4d415448) {
    this.state = seed >>> 0 || 1;
  }

  nextU32(): number {
    let x = this.state >>> 0;
    x ^= x << 13;
    x ^= x >>> 17;
    x ^= x << 5;
    this.state = x >>> 0;
    return this.state;
  }

  nextFloat(): number {
    return this.nextU32() / 0x1_0000_0000;
  }

  nextInt(min: number, maxExclusive: number): number {
    const span = maxExclusive - min;
    return min + (this.nextU32() % span);
  }

  pick<T>(xs: readonly T[]): T {
    return xs[this.nextInt(0, xs.length)]!;
  }

  /** Random byte string length in [0, maxLen]. */
  bytes(maxLen: number): Uint8Array {
    const n = this.nextInt(0, maxLen + 1);
    const out = new Uint8Array(n);
    for (let i = 0; i < n; i++) out[i] = this.nextU32() & 0xff;
    return out;
  }

  /** Truncate `base` at a random cut (incl. empty / full). */
  truncate(base: Uint8Array): Uint8Array {
    if (base.length === 0) return base;
    const n = this.nextInt(0, base.length + 1);
    return base.subarray(0, n);
  }

  /** Mutate a valid buffer: flip / insert / delete a few bytes. */
  mutate(base: Uint8Array, maxOps = 4): Uint8Array {
    const out = new Uint8Array(base);
    const ops = this.nextInt(1, maxOps + 1);
    for (let o = 0; o < ops; o++) {
      if (out.length === 0) break;
      const kind = this.nextInt(0, 3);
      const i = this.nextInt(0, out.length);
      if (kind === 0) {
        out[i] = this.nextU32() & 0xff;
      } else if (kind === 1 && out.length < 1 << 16) {
        const next = new Uint8Array(out.length + 1);
        next.set(out.subarray(0, i));
        next[i] = this.nextU32() & 0xff;
        next.set(out.subarray(i), i + 1);
        return this.mutate(next, maxOps - o - 1);
      } else {
        const next = new Uint8Array(out.length - 1);
        next.set(out.subarray(0, i));
        next.set(out.subarray(i + 1), i);
        return this.mutate(next, maxOps - o - 1);
      }
    }
    return out;
  }
}

/** Default gate seed (stable across CI). */
export const DEFAULT_FUZZ_SEED = 0x4d415448;
/** Default iterations in the strict gate (fast). */
export const DEFAULT_FUZZ_COUNT = 64;
