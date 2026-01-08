import { describe, it, expect, beforeAll, afterAll } from 'bun:test';
import { MathZig, Matrix, Vector, Series, Record, Value, SampleMode, ptr, toArrayBuffer } from '../../../src/ts/mathzig';

describe('Full API Surface & Value Correctness', () => {
    let mz: MathZig;

    beforeAll(() => {
        mz = MathZig.create();
    });

    afterAll(() => {
        mz.destroy();
    });

    describe('MathZig Context', () => {
        it('version should return a semver string', () => {
            expect(mz.version().toString()).toMatch(/^\d+\.\d+\.\d+$/);
        });

        it('should report memory usage', () => {
            expect(mz.getMemoryUsed()).toBeGreaterThanOrEqual(0);
            expect(mz.getMemoryReserved()).toBeGreaterThan(0);
            expect(mz.getMemoryPeak()).toBeGreaterThan(0);
        });

        it('should handle variables by name and index', () => {
            mz.setVariable('v1', 123);
            const idx = mz.addVariableIndexed('v2', 456);
            expect(idx).toBeGreaterThanOrEqual(0);
            
            expect(mz.eval('v1')).toBe(123);
            expect(mz.eval('v2')).toBe(456);

            mz.setByIndex(idx, 789);
            expect(mz.eval('v2')).toBe(789);

            mz.setByIndexFast(idx, 101112);
            expect(mz.eval('v2')).toBe(101112);
        });
    });

    describe('CompiledExpr Operations', () => {
        it('should provide expression metadata', () => {
            const expr = mz.compile('x * 2 + 10');
            expect(expr.getBytecodeSize()).toBeGreaterThan(0);
            expect(expr.getNumInstructions()).toBeGreaterThan(0);
            expect(expr.getStackSize()).toBeGreaterThan(0);
            expr.free();
        });

        it('should evaluate correctly', () => {
            const expr = mz.compile('10 + 20');
            expect(expr.evaluate()).toBe(30);
            expect(expr.evaluateFast()).toBe(30);
            expr.free();
        });

        it('should batch evaluate correctly', () => {
            const mz2 = MathZig.create();
            try {
                console.log("Starting batch eval test with fresh context");
                const xIdx = mz2.addVariableIndexed('x', 0);
                console.log("Added variable x, idx:", xIdx);
                const expr = mz2.compile('x * 2');
                console.log("Compiled expr handle:", expr.handle, "mz handle:", mz2.handle);
                
                const count = 4;
                const inPtr = MathZig.allocAligned(64, count * 8);
                const outPtr = MathZig.allocAligned(64, count * 8);
                console.log("Allocated buffers:", inPtr, outPtr);
                
                expect(Number(BigInt(inPtr)) % 64).toBe(0);
                expect(Number(BigInt(outPtr)) % 64).toBe(0);

                // Manual creation to avoid auto-free
                const inputs = new Float64Array(mz2.backend.toArrayBuffer(inPtr, count * 8), 0, count);
                const outputs = new Float64Array(mz2.backend.toArrayBuffer(outPtr, count * 8), 0, count);
                console.log("Created views");
                
                inputs.set([1, 2, 3, 4]);
                
                console.log("Calling evaluateBatchSIMD");
                expr.evaluateBatchSIMD(xIdx, inPtr, outPtr, count);
                console.log("Called evaluateBatchSIMD");
                expect(Array.from(outputs)).toEqual([2, 4, 6, 8]);

                outputs.fill(0);
                expr.evaluateBatchParallel(xIdx, inPtr, outPtr, count);
                expect(Array.from(outputs)).toEqual([2, 4, 6, 8]);

                MathZig.free(inPtr);
                MathZig.free(outPtr);
                expr.free();
            } finally {
                mz2.destroy();
            }
        });

        it('should batch evaluate complex correctly', () => {
            const zIdx = mz.addVariableIndexed('z', 0);
            const expr = mz.compile('z * 2i');
            
            const count = 4; // Use 4 for alignment
            const reInPtr = MathZig.allocAligned(64, count * 8);
            const imInPtr = MathZig.allocAligned(64, count * 8);
            const reOutPtr = MathZig.allocAligned(64, count * 8);
            const imOutPtr = MathZig.allocAligned(64, count * 8);

            expect(Number(BigInt(reInPtr)) % 64).toBe(0);
            expect(Number(BigInt(imInPtr)) % 64).toBe(0);
            expect(Number(BigInt(reOutPtr)) % 64).toBe(0);
            expect(Number(BigInt(imOutPtr)) % 64).toBe(0);

            // Manual creation to avoid auto-free
            const re_in = new Float64Array(mz.backend.toArrayBuffer(reInPtr, count * 8), 0, count);
            const im_in = new Float64Array(mz.backend.toArrayBuffer(imInPtr, count * 8), 0, count);
            const re_out = new Float64Array(mz.backend.toArrayBuffer(reOutPtr, count * 8), 0, count);
            const im_out = new Float64Array(mz.backend.toArrayBuffer(imOutPtr, count * 8), 0, count);
            
            re_in.set([1, 0, 0, 0]);
            im_in.set([0, 1, 0, 0]);
            
            // (1+0i) * 2i = 2i -> re=0, im=2
            // (0+1i) * 2i = -2 -> re=-2, im=0
            expr.evaluateBatchComplexSIMD(zIdx, reInPtr, imInPtr, reOutPtr, imOutPtr, count);
            
            expect(re_out[0]).toBe(0);
            expect(im_out[0]).toBe(2);
            expect(re_out[1]).toBe(-2);
            expect(im_out[1]).toBe(0);

            MathZig.free(reInPtr);
            MathZig.free(imInPtr);
            MathZig.free(reOutPtr);
            MathZig.free(imOutPtr);
            expr.free();
        });
    });

    describe('Matrix Operations', () => {
        it('should compute Matrix.multiply correctly', () => {
            const a = new Matrix(2, 2);
            a.data.set([1, 2, 3, 4]);
            const b = new Matrix(2, 2);
            b.data.set([5, 6, 7, 8]);
            const c = a.multiply(b, undefined);
            // [1*5+2*7, 1*6+2*8; 3*5+4*7, 3*6+4*8] = [19, 22; 43, 50]
            expect(Array.from(c.data)).toEqual([19, 22, 43, 50]);
        });

        it('should compute Matrix.multiplyParallel correctly', () => {
            const a = new Matrix(2, 2);
            a.data.set([1, 0, 0, 1]);
            const b = new Matrix(2, 2);
            b.data.set([10, 20, 30, 40]);
            const c = a.multiplyParallel(mz, b, undefined);
            expect(Array.from(c.data)).toEqual([10, 20, 30, 40]);
        });

        it('should compute Matrix.inverse correctly', () => {
            const a = new Matrix(2, 2);
            a.data.set([4, 7, 2, 6]);
            // det = 4*6 - 7*2 = 24 - 14 = 10
            // inv = 1/10 * [6, -7; -2, 4] = [0.6, -0.7; -0.2, 0.4]
            const success = a.inverse();
            expect(success).toBe(true);
            expect(a.data[0]).toBeCloseTo(0.6);
            expect(a.data[1]).toBeCloseTo(-0.7);
            expect(a.data[2]).toBeCloseTo(-0.2);
            expect(a.data[3]).toBeCloseTo(0.4);
        });

        it('should compute Matrix.determinant correctly', () => {
            const a = new Matrix(2, 2);
            a.data.set([3, 8, 4, 6]);
            // 3*6 - 8*4 = 18 - 32 = -14
            expect(a.determinant()).toBeCloseTo(-14);
        });

        it('should compute Matrix.sum and Matrix.mean correctly', () => {
            const a = new Matrix(2, 3);
            a.data.set([1, 2, 3, 4, 5, 6]);
            expect(a.sum()).toBe(21);
            expect(a.mean()).toBe(3.5);
        });

        it('should compute Matrix.gemv correctly', () => {
            const a = new Matrix(2, 2);
            a.data.set([1, 2, 3, 4]);
            const x = new Float64Array([10, 20]);
            const y = new Float64Array(2);
            // y = 1.0 * A * x + 0.0 * y
            // y[0] = 1*10 + 2*20 = 50
            // y[1] = 3*10 + 4*20 = 110
            a.gemv(1.0, 2, x, 0.0, y);
            expect(y[0]).toBe(50);
            expect(y[1]).toBe(110);
        });
    });

    describe('Vector Operations', () => {
        it('should compute Vector.add and sub correctly', () => {
            const v1 = new Vector(3);
            v1.data.set([1, 2, 3]);
            const v2 = new Vector(3);
            v2.data.set([10, 20, 30]);
            
            const v3 = v1.add(v2, undefined);
            expect(Array.from(v3.data)).toEqual([11, 22, 33]);
            
            const v4 = v1.sub(v2, undefined);
            expect(Array.from(v4.data)).toEqual([-9, -18, -27]);
        });

        it('should compute Vector.dot correctly', () => {
            const v1 = new Vector(3);
            v1.data.set([1, 2, 3]);
            const v2 = new Vector(3);
            v2.data.set([4, 5, 6]);
            // 1*4 + 2*5 + 3*6 = 4 + 10 + 18 = 32
            expect(v1.dot(v2)).toBe(32);
        });

        it('should compute Vector.norm correctly', () => {
            const v = new Vector(3);
            v.data.set([3, 4, 0]);
            expect(v.norm()).toBe(5);
        });

        it('should compute Vector.scale and scaleInplace correctly', () => {
            const v = new Vector(2);
            v.data.set([10, 20]);
            const v2 = v.scale(0.5, undefined);
            expect(Array.from(v2.data)).toEqual([5, 10]);
            
            v.scaleInplace(2);
            expect(Array.from(v.data)).toEqual([20, 40]);
        });

        it('should compute Vector.axpy correctly', () => {
            const x = new Vector(2);
            x.data.set([1, 2]);
            const y = new Vector(2);
            y.data.set([10, 20]);
            // y = 2*x + y = [2*1+10, 2*2+20] = [12, 24]
            x.axpy(2, y);
            expect(Array.from(y.data)).toEqual([12, 24]);
        });
    });

    describe('Series Operations', () => {
        it('should create and retrieve Series data correctly', () => {
            const ts = new Float64Array([1000, 2000, 3000]);
            const vs = new Float64Array([1.5, 2.5, 3.5]);
            const series = mz.createSeries(ts, vs, SampleMode.Linear);
            
            expect(series.len()).toBe(3);
            expect(series.duration()).toBe(2000);

            const tsPtr = series.getTimestampsPtr();
            const vsPtr = series.getValuesPtr();

            // Manual creation to avoid auto-free (Series owns the memory)
            const tsView = new Float64Array(mz.backend.toArrayBuffer(tsPtr, 3 * 8), 0, 3);
            const vsView = new Float64Array(mz.backend.toArrayBuffer(vsPtr, 3 * 8), 0, 3);

            expect(Array.from(tsView)).toEqual([1000, 2000, 3000]);
            expect(Array.from(vsView)).toEqual([1.5, 2.5, 3.5]);

            series.free();
        });

        it('should set series as a variable', () => {
            const ts = new Float64Array([0, 1, 2]);
            const vs = new Float64Array([10, 20, 30]);
            const series = mz.createSeries(ts, vs, SampleMode.Step);
            
            const success = mz.setSeries('my_series', series.handle);
            expect(success).toBe(true);
            
            const result = mz.eval('mean(my_series)');
            expect(result).toBe(20);

            series.free();
        });
    });

    describe('Value Lifecycle & Conversion', () => {
        it('should handle Value retain/release', () => {
            const matrixValue = mz.eval('[1, 2; 3, 4]');
            expect(matrixValue).toBeDefined();
            if ((matrixValue as any)?.retain) (matrixValue as any).retain();
            if ((matrixValue as any)?.release) {
                (matrixValue as any).release();
                (matrixValue as any).release();
            }
        });

        it('should convert various types to number', () => {
            expect(mz.eval('42')).toBe(42);
            expect(mz.eval('true')).toBe(true);
            expect(mz.eval('false')).toBe(false);
            
            const matrixValue = mz.eval('[10, 20]');
            expect(matrixValue).toBeDefined();
            expect(matrixValue instanceof Matrix).toBe(true);
            const m = matrixValue as Matrix;
            expect(m.rows).toBe(1);
            expect(m.cols).toBe(2);
            expect(m.sum()).toBe(30);
            expect(m.mean()).toBe(15);
            if ((matrixValue as any)?.release) (matrixValue as any).release();
        });
    });

    describe('Record Operations', () => {
        it('should create and retrieve Record fields correctly', () => {
            // Records are currently created via eval/VM
            const record = mz.eval('{ a: 10, b: [1, 2; 3, 4] }');
            expect(record instanceof Record).toBe(true);
            
            const rec = record as Record;
            expect(rec.len()).toBe(2);

            // getField returns unwrapped value
            const aVal = rec.getField('a');
            expect(aVal).toBe(10);

            const bVal = rec.getField('b');
            expect(bVal).toBeDefined();
            expect(bVal instanceof Matrix).toBe(true);
            const bMat = bVal as Matrix;
            expect(bMat.rows).toBe(2);
            expect(bMat.cols).toBe(2);
            expect(bMat.sum()).toBe(10);
            expect(bMat.mean()).toBe(2.5);

            if ((bVal as any)?.release) (bVal as any).release();
            if ((record as any)?.release) (record as any).release();
        });

        it('should handle non-existent fields', () => {
            const record = mz.eval('{ x: 1 }') as Record;
            // Engine returns null_val for a missing field (not an error tag).
            // This used to assert toThrow(), which only passed while the
            // generated getField mistook the null tag (13) for the error tag.
            expect(record.getField('missing')).toBeNull();
            if ((record as any)?.release) (record as any).release();
        });
    });

    describe('Sanity Check', () => {
        it('should live', () => {
            expect(1+1).toBe(2);
        });
    });
});
