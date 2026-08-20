//! Request handling for the loopback media proxy.

use std::sync::Arc;

use tokio::net::TcpListener;

use crate::State;

/// Accept loop. Runs until the process exits.
pub(crate) async fn serve(listener: TcpListener, state: Arc<State>) {
    let _ = (listener, state);
}
