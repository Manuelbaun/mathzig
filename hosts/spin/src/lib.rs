//! Spin HTTP component that hosts MathZig freestanding AOT modules via wasmi.
use anyhow::{anyhow, Context, Result};
use spin_sdk::http::{IntoResponse, Json, Request, StatusCode};
use spin_sdk::http_service;
use wasmi::{Engine, Linker, Module, Store};

static MUL_WASM: &[u8] = include_bytes!("../wasm/mul.wasm");
static MIN_WASM: &[u8] = include_bytes!("../wasm/min.wasm");

fn call_f64_1(bytes: &[u8], with_env: bool, x: f64) -> Result<f64> {
    let engine = Engine::default();
    let module = Module::new(&engine, bytes).context("parse wasm")?;
    let mut store = Store::new(&engine, ());
    let mut linker = Linker::new(&engine);
    if with_env {
        define_scalar_env(&mut linker)?;
    }
    let instance = linker
        .instantiate(&mut store, &module)
        .context("instantiate")?
        .start(&mut store)
        .context("start")?;
    let eval = instance
        .get_typed_func::<f64, f64>(&store, "eval")
        .context("typed eval(f64)->f64")?;
    eval.call(&mut store, x).map_err(|e| anyhow!("eval: {e}"))
}

fn call_f64_2(bytes: &[u8], with_env: bool, x: f64, y: f64) -> Result<f64> {
    let engine = Engine::default();
    let module = Module::new(&engine, bytes).context("parse wasm")?;
    let mut store = Store::new(&engine, ());
    let mut linker = Linker::new(&engine);
    if with_env {
        define_scalar_env(&mut linker)?;
    }
    let instance = linker
        .instantiate(&mut store, &module)
        .context("instantiate")?
        .start(&mut store)
        .context("start")?;
    let eval = instance
        .get_typed_func::<(f64, f64), f64>(&store, "eval")
        .context("typed eval(f64,f64)->f64")?;
    eval.call(&mut store, (x, y))
        .map_err(|e| anyhow!("eval: {e}"))
}

fn define_scalar_env(linker: &mut Linker<()>) -> Result<()> {
    // Same idea as browser createDefaultScalarWasmImports()
    linker.func_wrap("env", "min", |a: f64, b: f64| a.min(b))?;
    linker.func_wrap("env", "max", |a: f64, b: f64| a.max(b))?;
    linker.func_wrap("env", "pow", |a: f64, b: f64| a.powf(b))?;
    linker.func_wrap("env", "fmod", |a: f64, b: f64| a % b)?;
    linker.func_wrap("env", "sin", |a: f64| a.sin())?;
    linker.func_wrap("env", "cos", |a: f64| a.cos())?;
    linker.func_wrap("env", "tan", |a: f64| a.tan())?;
    linker.func_wrap("env", "sqrt", |a: f64| a.sqrt())?;
    linker.func_wrap("env", "abs", |a: f64| a.abs())?;
    linker.func_wrap("env", "floor", |a: f64| a.floor())?;
    linker.func_wrap("env", "ceil", |a: f64| a.ceil())?;
    linker.func_wrap("env", "exp", |a: f64| a.exp())?;
    linker.func_wrap("env", "log", |a: f64| a.ln())?;
    Ok(())
}

fn query_f64(req: &Request, key: &str, default: f64) -> f64 {
    let q = req.uri().query().unwrap_or("");
    for pair in q.split('&') {
        let mut it = pair.splitn(2, '=');
        if it.next() == Some(key) {
            if let Some(v) = it.next() {
                if let Ok(n) = v.parse::<f64>() {
                    return n;
                }
            }
        }
    }
    default
}

type Out = (StatusCode, Json<serde_json::Value>);

fn ok(v: serde_json::Value) -> Out {
    (StatusCode::OK, Json(v))
}

fn err(status: StatusCode, msg: impl ToString) -> Out {
    (
        status,
        Json(serde_json::json!({ "ok": false, "error": msg.to_string() })),
    )
}

#[http_service]
async fn handle(req: Request) -> Result<impl IntoResponse> {
    let path = req.uri().path();
    let out: Out = match path {
        "/" => ok(serde_json::json!({
            "ok": true,
            "runtime": "fermyon-spin",
            "host": "wasmi-inside-spin-component",
            "note": "MathZig freestanding AOT modules executed via wasmi",
            "endpoints": {
                "mul": "/mul?x=3",
                "min": "/min?x=3&y=1",
                "info": "/info"
            }
        })),
        "/info" => {
            let mul_ok = call_f64_1(MUL_WASM, false, 1.0).map(|y| (y - 2.0).abs() < 1e-12);
            let min_ok = call_f64_2(MIN_WASM, true, 3.0, 1.0).map(|r| (r - 1.0).abs() < 1e-12);
            match (mul_ok, min_ok) {
                (Ok(true), Ok(true)) => ok(serde_json::json!({
                    "ok": true,
                    "webassembly_host": "wasmi",
                    "modules": {
                        "mul": { "expr": "x * 2", "params": 1, "imports": [], "smoke": true },
                        "min": { "expr": "min(x,y)", "params": 2, "imports": ["env.min"], "smoke": true }
                    }
                })),
                (e1, e2) => (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    Json(serde_json::json!({
                        "ok": false,
                        "mul": format!("{e1:?}"),
                        "min": format!("{e2:?}")
                    })),
                ),
            }
        }
        "/mul" => {
            let x = query_f64(&req, "x", 0.0);
            match call_f64_1(MUL_WASM, false, x) {
                Ok(y) => ok(serde_json::json!({ "ok": true, "expr": "x * 2", "x": x, "y": y })),
                Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
            }
        }
        "/min" => {
            let x = query_f64(&req, "x", 0.0);
            let y = query_f64(&req, "y", 0.0);
            match call_f64_2(MIN_WASM, true, x, y) {
                Ok(r) => ok(serde_json::json!({
                    "ok": true, "expr": "min(x,y)", "x": x, "y": y, "r": r
                })),
                Err(e) => err(StatusCode::INTERNAL_SERVER_ERROR, format!("{e:#}")),
            }
        }
        _ => err(StatusCode::NOT_FOUND, "not found"),
    };
    Ok(out)
}
