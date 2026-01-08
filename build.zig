const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_tui = b.option(bool, "tui", "Build TUI artifacts") orelse false;
    const build_perf_tools = b.option(bool, "perf-tools", "Build performance and fuzz runner artifacts") orelse false;

    // ==========================================================================
    // MathZig Core Library Module
    // ==========================================================================
    const mathzig_module = b.createModule(.{
        .root_source_file = b.path("src/mathzig.zig"),
        .target = target,
        .optimize = optimize,
    });

    const diagnostics_module = b.createModule(.{
        .root_source_file = b.path("src/core/diagnostics.zig"),
        .target = target,
        .optimize = optimize,
    });

    // ==========================================================================
    // ABI Smith Kit (Auto-Generation Tools)
    // ==========================================================================

    // Module for API Definition (needs to be its own module to be imported by tool)
    const api_def_module = b.createModule(.{
        .root_source_file = b.path("src/api_definition.zig"),
        .target = target,
        .optimize = .Debug,
        .imports = &.{
            .{ .name = "mathzig", .module = mathzig_module },
        },
    });

    const abi_inspector_exe = b.addExecutable(.{
        .name = "abi_inspector",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/bindings/abi_inspector.zig"),
            .target = b.resolveTargetQuery(.{}), // Host target
            .optimize = .Debug,
            .imports = &.{
                .{ .name = "api_definition", .module = api_def_module },
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });

    const run_inspector = b.addRunArtifact(abi_inspector_exe);
    run_inspector.addArg("src/bindings/generated/api.json");
    const inspect_step = b.step("abi-inspect", "Generate API Schema JSON from Zig source");
    inspect_step.dependOn(&run_inspector.step);

    const run_gen_exports = b.addRunArtifact(abi_inspector_exe);
    run_gen_exports.addArg("src/bindings/generated/exports.zig");
    run_gen_exports.addArg("--exports");
    const gen_exports_step = b.step("abi-exports", "Generate Zig C-ABI exports from api_definition.zig");
    gen_exports_step.dependOn(&run_gen_exports.step);

    const run_aot_abi = b.addRunArtifact(abi_inspector_exe);
    run_aot_abi.addArg("--aot-abi");
    run_aot_abi.addArg("src/bindings/generated/aot_abi.json");
    const abi_aot_step = b.step("abi-aot", "Generate AOT ABI JSON from src/wasm/abi.zig");
    abi_aot_step.dependOn(&run_aot_abi.step);

    const gen_bindings_ts = b.addSystemCommand(&.{ "bun", "tools/bindings/generate_bindings.ts" });
    gen_bindings_ts.step.dependOn(&run_inspector.step);
    gen_bindings_ts.step.dependOn(&run_gen_exports.step);
    gen_bindings_ts.step.dependOn(&run_aot_abi.step);
    const gen_bindings_step = b.step("gen-bindings", "Regenerate all binding artifacts (api.json, exports.zig, aot_abi.json, TS)");
    gen_bindings_step.dependOn(&gen_bindings_ts.step);

    // ==========================================================================
    // Native Library (for FFI)
    // ==========================================================================
    if (target.result.os.tag != .freestanding) {
        const lib = b.addLibrary(.{
            .name = "mathzig",
            .linkage = .dynamic,
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bindings/generated/exports.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                    .{ .name = "api_definition", .module = api_def_module },
                },
            }),
        });
        b.installArtifact(lib);
    }

    // ==========================================================================
    // WebAssembly Target
    // ==========================================================================
    if (target.result.cpu.arch == .wasm32 or target.result.cpu.arch == .wasm64) {
        const wasm = b.addExecutable(.{
            .name = "mathzig_wasm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bindings/generated/exports.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                    .{ .name = "api_definition", .module = api_def_module },
                },
            }),
        });
        wasm.rdynamic = true;
        wasm.entry = .disabled;
        b.installArtifact(wasm);
    }

    // ==========================================================================
    // WASM Build Step (builds and copies to web folder)
    // ==========================================================================
    {
        // Create WASM-specific modules with wasm32-freestanding target
        const wasm_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .freestanding,
        });

        const wasm_mathzig_module = b.createModule(.{
            .root_source_file = b.path("src/mathzig.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });

        const wasm_api_def_module = b.createModule(.{
            .root_source_file = b.path("src/api_definition.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "mathzig", .module = wasm_mathzig_module },
            },
        });

        const wasm_exe = b.addExecutable(.{
            .name = "mathzig_wasm",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/bindings/generated/exports.zig"),
                .target = wasm_target,
                .optimize = .ReleaseSmall,
                .imports = &.{
                    .{ .name = "mathzig", .module = wasm_mathzig_module },
                    .{ .name = "api_definition", .module = wasm_api_def_module },
                },
            }),
        });
        wasm_exe.rdynamic = true;
        wasm_exe.entry = .disabled;

        // Copy to web folder
        const copy_wasm = b.addInstallFile(wasm_exe.getEmittedBin(), "../web/mathzig_wasm.wasm");

        const wasm_step = b.step("wasm", "Build WASM and copy to web folder");
        wasm_step.dependOn(&copy_wasm.step);
    }

    // ==========================================================================
    // MathZig CLI (compile / REPL) — always built on native targets
    // ==========================================================================
    if (target.result.os.tag != .freestanding) {
        const cli = b.addExecutable(.{
            .name = "mathzig",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/main.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(cli);

        const run_repl_cmd = b.addRunArtifact(cli);
        run_repl_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_repl_cmd.addArgs(args);
        }
        const run_repl_step = b.step("repl", "Run the MathZig REPL");
        run_repl_step.dependOn(&run_repl_cmd.step);
    }

    // ==========================================================================
    // TUI Executable (Only for native targets)
    // ==========================================================================
    if (build_tui and target.result.os.tag != .freestanding) {
        // Get dependencies from build.zig.zon
        const zigimg_dep = b.dependency("zigimg", .{
            .target = target,
            .optimize = optimize,
        });
        const uucode_dep = b.dependency("uucode", .{
            .target = target,
            .optimize = optimize,
            .fields = &[_][]const u8{
                "east_asian_width",
                "grapheme_break",
                "general_category",
                "is_emoji_presentation",
            },
        });

        // Create libvaxis module with its dependencies
        const libvaxis_module = b.createModule(.{
            .root_source_file = b.path("libs/libvaxis/src/main.zig"),
            .target = target,
            .optimize = optimize,
        });
        libvaxis_module.addImport("zigimg", zigimg_dep.module("zigimg"));
        libvaxis_module.addImport("uucode", uucode_dep.module("uucode"));

        // Create TUI executable using libvaxis directly
        const tui_main_module = b.createModule(.{
            .root_source_file = b.path("src/tui/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "libvaxis", .module = libvaxis_module },
                .{ .name = "mathzig", .module = mathzig_module },
                .{ .name = "diagnostics", .module = diagnostics_module },
            },
        });

        const tui = b.addExecutable(.{
            .name = "mathzig_tui",
            .root_module = tui_main_module,
        });
        b.installArtifact(tui);

        const run_tui_cmd = b.addRunArtifact(tui);
        run_tui_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_tui_cmd.addArgs(args);
        }
        const run_tui_step = b.step("run", "Run the MathZig TUI");
        run_tui_step.dependOn(&run_tui_cmd.step);

        // Keep tui_test for testing but simplify it too
        const tui_test_exe = b.addExecutable(.{
            .name = "tui_test",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/tui/test_runner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "libvaxis", .module = libvaxis_module },
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(tui_test_exe);

        const run_tui_test = b.addRunArtifact(tui_test_exe);
        if (b.args) |args| {
            run_tui_test.addArgs(args);
        }
        const tui_test_step = b.step("tui-test", "Run the TUI headless test runner");
        tui_test_step.dependOn(&run_tui_test.step);
    }

    // ==========================================================================
    // Tests
    // ==========================================================================
    const main_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/mathzig.zig"),
            .target = target,
            .optimize = optimize,
        }),
    });

    const run_main_tests = b.addRunArtifact(main_tests);
    const test_step = b.step("test", "Run all library tests");
    test_step.dependOn(&run_main_tests.step);

    const vm_baseline_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/core/vm_baseline_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_vm_baseline_tests = b.addRunArtifact(vm_baseline_tests);
    const vm_baseline_step = b.step("vm-baseline", "Run baseline Zig VM tests (must-pass core gate)");
    vm_baseline_step.dependOn(&run_vm_baseline_tests.step);
    test_step.dependOn(&run_vm_baseline_tests.step);

    const fused_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/core/fused_opcodes.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_fused_tests = b.addRunArtifact(fused_tests);
    test_step.dependOn(&run_fused_tests.step);

    const fast_path_parity_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/core/fast_path_parity.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_fast_path_parity_tests = b.addRunArtifact(fast_path_parity_tests);
    test_step.dependOn(&run_fast_path_parity_tests.step);

    const safety_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/core/vm_safety.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_safety_tests = b.addRunArtifact(safety_tests);
    test_step.dependOn(&run_safety_tests.step);

    const shadowing_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/parser/shadowing.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_shadowing_tests = b.addRunArtifact(shadowing_tests);
    test_step.dependOn(&run_shadowing_tests.step);

    const runtime_unit_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/types/runtime_units.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_runtime_unit_tests = b.addRunArtifact(runtime_unit_tests);
    test_step.dependOn(&run_runtime_unit_tests.step);

    const matrix_units_honesty_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/types/matrix_units_honesty.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_matrix_units_honesty_tests = b.addRunArtifact(matrix_units_honesty_tests);
    test_step.dependOn(&run_matrix_units_honesty_tests.step);

    const config_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/configuration/config.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_config_tests = b.addRunArtifact(config_tests);
    test_step.dependOn(&run_config_tests.step);

    const separator_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/parser/custom_separators.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_separator_tests = b.addRunArtifact(separator_tests);
    test_step.dependOn(&run_separator_tests.step);

    const latex_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/parser/latex.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_latex_tests = b.addRunArtifact(latex_tests);
    test_step.dependOn(&run_latex_tests.step);

    const abi_json_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/abi_json_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_abi_json_tests = b.addRunArtifact(abi_json_tests);
    test_step.dependOn(&run_abi_json_tests.step);

    const latex_fold_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/latex_fold_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_latex_fold_tests = b.addRunArtifact(latex_fold_tests);
    test_step.dependOn(&run_latex_fold_tests.step);

    const wasm_compiler_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/wasm_compiler_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_wasm_compiler_tests = b.addRunArtifact(wasm_compiler_tests);
    test_step.dependOn(&run_wasm_compiler_tests.step);

    const standalone_hard_error_lockin_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/standalone_hard_error_lockin.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_standalone_hard_error_lockin_tests = b.addRunArtifact(standalone_hard_error_lockin_tests);
    test_step.dependOn(&run_standalone_hard_error_lockin_tests.step);

    const unit_runtime_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/unit_runtime_manifest.test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_unit_runtime_manifest_tests = b.addRunArtifact(unit_runtime_manifest_tests);
    test_step.dependOn(&run_unit_runtime_manifest_tests.step);

    const graph_manifest_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/graph_manifest_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_manifest_tests = b.addRunArtifact(graph_manifest_tests);
    test_step.dependOn(&run_graph_manifest_tests.step);

    const fuse_codegen_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/backends/wasm/fuse_codegen_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_fuse_codegen_tests = b.addRunArtifact(fuse_codegen_tests);
    test_step.dependOn(&run_fuse_codegen_tests.step);

    // task-19 P3: per-tier native-vs-body edge sweeps
    inline for (.{
        .{ "tier1_scalar_sweep", "tests/zig/backends/wasm/tier1_scalar_sweep.zig" },
        .{ "tier2_matrix_sweep", "tests/zig/backends/wasm/tier2_matrix_sweep.zig" },
        .{ "tier3_ode_sweep", "tests/zig/backends/wasm/tier3_ode_sweep.zig" },
        .{ "tier4_series_sweep", "tests/zig/backends/wasm/tier4_series_sweep.zig" },
    }) |tier| {
        const tier_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path(tier[1]),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        const run_tier = b.addRunArtifact(tier_tests);
        test_step.dependOn(&run_tier.step);
        _ = tier[0];
    }

    // Spec 03 fuse golden fixtures for Bun instantiate tests
    if (target.result.os.tag != .freestanding) {
        const emit_fuse_goldens_exe = b.addExecutable(.{
            .name = "emit_fuse_goldens",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tools/wasm/emit_fuse_goldens.zig"),
                .target = target,
                .optimize = .Debug,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        const run_emit_fuse = b.addRunArtifact(emit_fuse_goldens_exe);
        run_emit_fuse.addArg("tests/artifacts/fuse");
        const emit_fuse_step = b.step("emit-fuse-goldens", "Emit Spec 03 fuse .wasm goldens for Bun tests");
        emit_fuse_step.dependOn(&run_emit_fuse.step);
    }

    const graph_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/native_runner_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_runner_tests = b.addRunArtifact(graph_runner_tests);
    test_step.dependOn(&run_graph_runner_tests.step);

    // task-16 C5: native soak / debugStats / reload / alloc-failure counters
    const graph_soak_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/soak_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_soak_tests = b.addRunArtifact(graph_soak_tests);
    test_step.dependOn(&run_graph_soak_tests.step);

    // task-13 C2: cross-runner corpus (same goldens as Bun adapter)
    const graph_cross_runner_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/cross_runner_parity_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_cross_runner_tests = b.addRunArtifact(graph_cross_runner_tests);
    // Goldens live under tests/graph/goldens; run with project cwd (default).
    test_step.dependOn(&run_graph_cross_runner_tests.step);

    const graph_manifest_parse_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/manifest_parse_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_manifest_parse_tests = b.addRunArtifact(graph_manifest_parse_tests);
    test_step.dependOn(&run_graph_manifest_parse_tests.step);

    // task-14 C3: adversarial inputs (S3/S4 limits + malformed-vs-absent)
    const graph_adversarial_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/adversarial_inputs_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_graph_adversarial_tests = b.addRunArtifact(graph_adversarial_tests);
    test_step.dependOn(&run_graph_adversarial_tests.step);

    const fuse_lowerer_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("tests/zig/graph/fuse_lowerer_test.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "mathzig", .module = mathzig_module },
            },
        }),
    });
    const run_fuse_lowerer_tests = b.addRunArtifact(fuse_lowerer_tests);
    test_step.dependOn(&run_fuse_lowerer_tests.step);

    // ==========================================================================
    // Benchmarks (Only for native targets)
    // ==========================================================================
    if (build_perf_tools and target.result.os.tag != .freestanding) {
        const ts_benchmark_exe = b.addExecutable(.{
            .name = "ts_benchmark",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/performance/timeseries_benchmark.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(ts_benchmark_exe);

        const run_ts_benchmark = b.addRunArtifact(ts_benchmark_exe);
        const benchmark_step = b.step("benchmark", "Run Time-Series Benchmarks");
        benchmark_step.dependOn(&run_ts_benchmark.step);

        const perf_runner_exe = b.addExecutable(.{
            .name = "perf_runner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/performance/perf_runner.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(perf_runner_exe);

        const run_perf_runner = b.addRunArtifact(perf_runner_exe);
        const perf_step = b.step("perf", "Run General Performance Benchmarks");
        perf_step.dependOn(&run_perf_runner.step);

        const vm_micro_bench_exe = b.addExecutable(.{
            .name = "vm_micro_bench",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/performance/vm_micro_bench.zig"),
                .target = target,
                .optimize = .ReleaseFast,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(vm_micro_bench_exe);

        const run_vm_micro_bench = b.addRunArtifact(vm_micro_bench_exe);
        const perf_micro_step = b.step("perf-micro", "Run VM/compiler micro-benchmarks (general execute loop, user calls, compile throughput)");
        perf_micro_step.dependOn(&run_vm_micro_bench.step);

        const bench_refs_mod = b.createModule(.{
            .root_source_file = b.path("tests/performance/bench_refs.zig"),
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench_refs_mod.link_libc = true;
        const bench_refs_exe = b.addExecutable(.{
            .name = "bench_refs",
            .root_module = bench_refs_mod,
        });
        b.installArtifact(bench_refs_exe);

        const bench_refs_c_mandelbrot_mod = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench_refs_c_mandelbrot_mod.addCSourceFiles(.{
            .root = b.path("bench/refs"),
            .files = &.{"mandelbrot.c"},
            .flags = &.{"-std=c11", "-O3"},
        });
        bench_refs_c_mandelbrot_mod.link_libc = true;
        const bench_refs_c_mandelbrot_exe = b.addExecutable(.{
            .name = "bench_refs_c_mandelbrot",
            .root_module = bench_refs_c_mandelbrot_mod,
        });
        b.installArtifact(bench_refs_c_mandelbrot_exe);

        const bench_refs_c_binarytree_mod = b.createModule(.{
            .target = target,
            .optimize = .ReleaseFast,
        });
        bench_refs_c_binarytree_mod.addCSourceFiles(.{
            .root = b.path("bench/refs"),
            .files = &.{"binarytree.c"},
            .flags = &.{"-std=c11", "-O3"},
        });
        bench_refs_c_binarytree_mod.link_libc = true;
        const bench_refs_c_binarytree_exe = b.addExecutable(.{
            .name = "bench_refs_c_binarytree",
            .root_module = bench_refs_c_binarytree_mod,
        });
        b.installArtifact(bench_refs_c_binarytree_exe);

        const run_bench_refs = b.addRunArtifact(bench_refs_exe);
        const bench_refs_step = b.step("bench-refs", "Run reference benchmarks (Zig/C mandelbrot, binarytree)");
        bench_refs_step.dependOn(&run_bench_refs.step);

        const fuzz_runner_exe = b.addExecutable(.{
            .name = "fuzz_runner",
            .root_module = b.createModule(.{
                .root_source_file = b.path("tests/zig/fuzz/fuzz_runner.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "mathzig", .module = mathzig_module },
                },
            }),
        });
        b.installArtifact(fuzz_runner_exe);

        const run_fuzz_runner = b.addRunArtifact(fuzz_runner_exe);
        if (b.args) |args| {
            run_fuzz_runner.addArgs(args);
        }
        const fuzz_step = b.step("fuzz", "Run the Grammar-Based Fuzzer");
        fuzz_step.dependOn(&run_fuzz_runner.step);
    }
}
