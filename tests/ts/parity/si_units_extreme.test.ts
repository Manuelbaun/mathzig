import { describe, it, expect } from "bun:test";
import { MathZig } from "../../../src/ts/mathzig";

type Case = {
    expr: string;
    expected: number;
    error?: boolean;
};

function toNum(v: any): number {
    if (typeof v === "number") return v;
    if (v && typeof v.toNumber === "function") return v.toNumber();
    return Number(v);
}

describe("SI Units Extreme Parity", () => {
    it("covers conversions, derived units, and mismatch errors", () => {
        const ctx = MathZig.create();
        const cases: Case[] = [
            { expr: "1 Ym to Zm", expected: 1000 },
            { expr: "1 Zm to Em", expected: 1000 },
            { expr: "1 Em to Pm", expected: 1000 },
            { expr: "1 Pm to Tm", expected: 1000 },
            { expr: "1 Tm to Gm", expected: 1000 },
            { expr: "1 Gm to Mm", expected: 1000 },
            { expr: "1 Mm to km", expected: 1000 },
            { expr: "1 km to hm", expected: 10 },
            { expr: "1 hm to dam", expected: 10 },
            { expr: "1 dam to m", expected: 10 },
            { expr: "1 m to dm", expected: 10 },
            { expr: "1 dm to cm", expected: 10 },
            { expr: "1 cm to mm", expected: 10 },
            { expr: "1 mm to um", expected: 1000 },
            { expr: "1 um to nm", expected: 1000 },
            { expr: "1 nm to pm", expected: 1000 },
            { expr: "1 pm to fm", expected: 1000 },
            { expr: "1 fm to am", expected: 1000 },
            { expr: "1 am to zm", expected: 1000 },
            { expr: "1 zm to ym", expected: 1000 },
            { expr: "1 tonne to kg", expected: 1000 },
            { expr: "1 kg to g", expected: 1000 },
            { expr: "1 g to mg", expected: 1000 },
            { expr: "1 mg to ug", expected: 1000 },
            { expr: "9.81 m/s^2 * 10 kg to N", expected: 98.1 },
            { expr: "100 N to kg * m / s^2", expected: 100 },
            { expr: "1 kJ to J", expected: 1000 },
            { expr: "1 J to mJ", expected: 1000 },
            { expr: "10 N * 5 m to J", expected: 50 },
            { expr: "100 J / 10 s to W", expected: 10 },
            { expr: "1 kW * 1 h to J", expected: 3600000 },
            { expr: "500 W to J/s", expected: 500 },
            { expr: "10 V / 2 A to ohm", expected: 5 },
            { expr: "5 ohm * 3 A to V", expected: 15 },
            { expr: "10 C / 5 s to A", expected: 2 },
            { expr: "12 V * 2 C to J", expected: 24 },
            { expr: "100 uF to F", expected: 0.0001 },
            { expr: "10 mH to H", expected: 0.01 },
            { expr: "2 T * 0.5 m^2 to Wb", expected: 1 },
            { expr: "10 V to J/C", expected: 10 },
            { expr: "100 N / 2 m^2 to Pa", expected: 50 },
            { expr: "1 kPa to Pa", expected: 1000 },
            { expr: "10 Pa * 5 m^2 to N", expected: 50 },
            { expr: "1 h to s", expected: 3600 },
            { expr: "1 day to min", expected: 1440 },
            { expr: "1 week to day", expected: 7 },
            { expr: "1 year to day", expected: 365.25 },
            { expr: "1 inch to mm", expected: 25.4 },
            { expr: "1 ft to cm", expected: 30.48 },
            { expr: "1 yd to m", expected: 0.9144 },
            { expr: "1 mi to m", expected: 1609.344 },
            { expr: "1 mi to ft", expected: 5280 },
            { expr: "1 psi to Pa", expected: 6894.757 },
            { expr: "(10 m/s * 5 s) + 10 m to m", expected: 60 },
            { expr: "1 kg * m/s^2 to N", expected: 1 },
            { expr: "100 W * 2 s / 10 V to C", expected: 20 },
            { expr: "1 m^2 to cm^2", expected: 10000 },
            { expr: "1 m^3 to L", expected: 1000 },
            { expr: "1 km^2 to m^2", expected: 1000000 },
            { expr: "1 m to kg", expected: Number.NaN, error: true },
            { expr: "10 N + 5 m", expected: Number.NaN, error: true },
            { expr: "10 V / 2 s to ohm", expected: Number.NaN, error: true },
            { expr: "100 degC + 10 m", expected: Number.NaN, error: true },
        ];

        try {
            for (const c of cases) {
                let gotNaN = false;
                let got: number = Number.NaN;
                let threw = false;
                try {
                    const v = ctx.eval(c.expr);
                    got = toNum(v);
                    gotNaN = Number.isNaN(got);
                    if ((v as any)?.release) (v as any).release();
                } catch {
                    threw = true;
                }

                if (c.error) {
                    expect(threw || gotNaN).toBe(true);
                    continue;
                }

                const tol = 1e-4 * Math.max(1, Math.abs(c.expected));
                expect(Number.isFinite(got)).toBe(true);
                expect(Math.abs(got - c.expected)).toBeLessThanOrEqual(tol);
            }
        } finally {
            ctx.destroy();
        }
    });
});
