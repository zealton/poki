//! Local USB access to the same native-services worker used by the iOS app.
//! JSON requests on stdin, JSON replies on stdout. Clipboard operations are refused.
//! EOF, Ctrl-C and 180 seconds without a request explicitly reset/detach before exit.
use poki_launcher::{
    PokiNativeClient, poki_native_client_call, poki_native_client_free, poki_native_client_new,
};
use serde_json::{Value, json};
use std::{
    ffi::{CStr, CString, c_char, c_void},
    io::{BufRead, Write},
    time::Duration,
};
use tokio::sync::{mpsc, oneshot};

extern "C" fn reply(context: *mut c_void, value: *const c_char) {
    let sender = unsafe { Box::from_raw(context as *mut oneshot::Sender<String>) };
    let text = unsafe { CStr::from_ptr(value) }
        .to_string_lossy()
        .into_owned();
    let _ = sender.send(text);
}

async fn call(client: *mut PokiNativeClient, request: &str) -> Result<String, String> {
    let request = CString::new(request).map_err(|e| e.to_string())?;
    let (tx, rx) = oneshot::channel::<String>();
    let context = Box::into_raw(Box::new(tx));
    if unsafe { poki_native_client_call(client, request.as_ptr(), reply, context.cast()) } != 0 {
        drop(unsafe { Box::from_raw(context) });
        return Err("request was rejected before dispatch".into());
    }
    rx.await.map_err(|e| e.to_string())
}

#[tokio::main(flavor = "current_thread")]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    let udid = std::env::args().nth(1).ok_or("usage: native_usb UDID")?;
    let config = CString::new(json!({"usb_udid": udid}).to_string())?;
    let client = unsafe { poki_native_client_new(config.as_ptr()) };
    if client.is_null() {
        return Err("cannot start native worker".into());
    }
    let (tx, mut rx) = mpsc::channel(1);
    std::thread::spawn(move || {
        for line in std::io::stdin().lock().lines() {
            if tx.blocking_send(line).is_err() {
                break;
            }
        }
    });
    loop {
        let line = tokio::select! {
            line = rx.recv() => line,
            _ = tokio::signal::ctrl_c() => None,
            _ = tokio::time::sleep(Duration::from_secs(180)) => None,
        };
        let Some(Ok(line)) = line else {
            break;
        };
        let result = match serde_json::from_str::<Value>(&line) {
            Ok(request) if matches!(request["op"].as_str(), Some("type_text" | "pasteboard_get" | "pasteboard_set")) =>
                json!({"ok": false, "error": "clipboard operations are disabled in this USB helper"}).to_string(),
            Ok(_) => match call(client, &line).await {
                Ok(value) => value,
                Err(error) => json!({"ok": false, "error": error}).to_string(),
            },
            Err(error) => json!({"ok": false, "error": error.to_string()}).to_string(),
        };
        let mut stdout = std::io::stdout().lock();
        if writeln!(stdout, "{result}")
            .and_then(|_| stdout.flush())
            .is_err()
        {
            break;
        }
    }
    // Await the reset reply: dropping the C handle alone doesn't wait for removal.
    let cleanup = call(client, r#"{"op":"reset"}"#).await;
    unsafe { poki_native_client_free(client) };
    let cleanup = cleanup?;
    let value: Value = serde_json::from_str(&cleanup)?;
    if value["ok"] != true {
        return Err(format!("keyboard cleanup failed: {cleanup}").into());
    }
    eprintln!("native USB session reset; keyboard removal acknowledged");
    Ok(())
}
