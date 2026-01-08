import { describe, expect, it } from "bun:test";
import {
  concatTrajectories,
  isOdeTrajectoryMatrix,
  rocketTrajectoryFromMatrix,
  trajectoryFromGraphOutputs,
} from "./trajectory";

describe("graph trajectory helpers", () => {
  it("detects ODE-shaped matrices", () => {
    expect(isOdeTrajectoryMatrix({ rows: 10, cols: 6, data: new Array(60).fill(0) })).toBe(true);
    expect(isOdeTrajectoryMatrix({ rows: 1, cols: 6, data: new Array(6).fill(0) })).toBe(false);
    expect(isOdeTrajectoryMatrix({ rows: 10, cols: 4, data: new Array(40).fill(0) })).toBe(false);
  });

  it("extracts altitude/velocity/gamma from rocket ODE matrix", () => {
    // two rows: t,r,v,m,phi,gamma
    const m = {
      rows: 2,
      cols: 6,
      data: [
        0, 6_371_000, 1, 500_000, 0, Math.PI / 2,
        2, 6_381_000, 100, 490_000, 0.01, 1.5,
      ],
    };
    const t = rocketTrajectoryFromMatrix(m)!;
    expect(t.time).toEqual([0, 2]);
    expect(t.altitude[0]).toBeCloseTo(0, 5);
    expect(t.altitude[1]).toBeCloseTo(10, 5);
    expect(t.velocity).toEqual([1, 100]);
    expect(t.gamma[0]).toBeCloseTo(90, 4);
  });

  it("concatenates multi-stage trajectories in flight order", () => {
    const s1 = {
      rows: 2,
      cols: 6,
      data: [0, 6_371_000, 1, 1, 0, 1.57, 2, 6_372_000, 10, 1, 0, 1.5],
    };
    const inter = {
      rows: 2,
      cols: 6,
      data: [2, 6_373_000, 20, 1, 0, 1.45, 4, 6_374_000, 30, 1, 0, 1.4],
    };
    const s2 = {
      rows: 2,
      cols: 6,
      data: [10, 6_380_000, 100, 1, 0, 1.4, 14, 6_390_000, 200, 1, 0, 1.2],
    };
    // Names intentionally unsorted / all contain "trajectory"
    const traj = trajectoryFromGraphOutputs({
      trajectory_s2: s2,
      trajectory_inter: inter,
      trajectory_s1: s1,
    })!;
    expect(traj.time).toEqual([0, 2, 2, 4, 10, 14]);
    expect(traj.velocity).toEqual([1, 10, 20, 30, 100, 200]);
  });

  it("concatTrajectories joins series", () => {
    const a = { time: [0], altitude: [0], velocity: [1], gamma: [90] };
    const b = { time: [1], altitude: [1], velocity: [2], gamma: [80] };
    expect(concatTrajectories([a, b])!.time).toEqual([0, 1]);
  });
});
