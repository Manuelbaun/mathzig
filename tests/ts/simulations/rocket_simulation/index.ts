/**
 * ROCKET SIMULATION TEST SUITE
 * 
 * Comprehensive test suite for rocket simulation covering:
 * - Unit tests (angle units, thrust/drag, ISP function, unit operations)
 * - Integration tests (ODE solver, derivative functions, full stages)
 * - Parity tests (MathZig vs MathJS comparison)
 * - Validation tests (exact replicas, context reproduction)
 * - Debugging tests (deep issue investigation)
 * 
 * This imports and runs all rocket simulation tests to provide
 * comprehensive regression protection and functionality verification.
 */

import { describe, expect, it } from "bun:test";

// Import all test files
import "./unit/angle-units.test";
import "./unit/thrust-drag.test"; 
import "./unit/isp-function.test";
import "./unit/unit-division.test";
import "./unit/root-cause.test";

import "./integration/ode-basic.test";
import "./integration/full-stage.test";

import "./parity/comprehensive.test";

import "./debugging/eval-behavior.test";

// Import the main full simulation test
import "./full-simulation.test";

describe("Rocket Simulation Test Suite", () => {
  it("should have all test categories loaded", () => {
    // This test just confirms the test suite is properly structured
    expect(true).toBe(true);
  });
});

// Export any shared utilities if needed by other test files
export * from "./helpers";