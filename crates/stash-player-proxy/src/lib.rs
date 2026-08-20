//! Loopback HTTP server that fronts every media byte the app plays.
//!
//! GStreamer and AVPlayer fetch video URLs themselves, outside the
//! `reqwest` client that carries our `ApiKey` header and any upstream
//! proxy. Neither can be pointed at a SOCKS proxy portably, and
//! AVFoundation has no per-asset proxy API at all. So rather than teach
//! two media stacks about proxies, we hand them a `127.0.0.1` URL and
//! re-issue the request here with the client that already knows how to
//! reach Stash.
//!
//! The hop is unconditional, even when no proxy is configured, so the
//! proxied path cannot quietly diverge from the unproxied one.

use std::net::SocketAddr;
use std::sync::Arc;

use parking_lot::Mutex;
use stash_api::Client;
use tokio::net::TcpListener;
use url::Url;

mod handler;

#[derive(Debug, thiserror::Error)]
pub enum Error {
    #[error("io: {0}")]
    Io(#[from] std::io::Error),
    #[error("no Stash client configured")]
    NotConfigured,
    #[error("url: {0}")]
    Url(#[from] url::ParseError),
    #[error("stash api: {0}")]
    Api(#[from] stash_api::Error),
}

pub type Result<T> = std::result::Result<T, Error>;

/// Everything the request handler needs, shared with the accept loop.
#[derive(Debug)]
pub(crate) struct State {
    pub(crate) token: String,
    pub(crate) client: Mutex<Option<Client>>,
}

impl State {
    pub(crate) fn client(&self) -> Option<Client> {
        self.client.lock().clone()
    }
}

/// A running loopback media proxy. Dropping it does not stop the server;
/// it is expected to live for the process lifetime.
#[derive(Debug)]
pub struct MediaProxy {
    addr: SocketAddr,
    state: Arc<State>,
}

impl MediaProxy {
    /// Bind an ephemeral loopback port and start serving. Call this once
    /// at startup, before any client exists: a stable port means a later
    /// settings change can swap the client without invalidating a URL a
    /// player is already streaming from.
    pub async fn bind() -> Result<Self> {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await?;
        let addr = listener.local_addr()?;
        let state = Arc::new(State {
            token: random_token(),
            client: Mutex::new(None),
        });
        tokio::spawn(handler::serve(listener, Arc::clone(&state)));
        tracing::info!("media proxy listening on http://{addr}");
        Ok(Self { addr, state })
    }

    /// Install or replace the client used for upstream requests. Call on
    /// every credential or proxy change.
    pub fn set_client(&self, client: Option<Client>) {
        *self.state.client.lock() = client;
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Rewrite an upstream media URL into the loopback URL to hand to a
    /// media stack.
    pub fn playback_url(&self, upstream: &str) -> Result<String> {
        let client = self.state.client().ok_or(Error::NotConfigured)?;
        let mut target = client.absolute_url(upstream)?;
        strip_apikey(&mut target);

        let mut out = Url::parse(&format!("http://{}/{}/media", self.addr, self.state.token))?;
        out.query_pairs_mut().append_pair("u", target.as_str());
        Ok(out.into())
    }
}

/// Stash returns `paths.stream` with `apikey=` already baked in. We
/// authenticate upstream with the header instead, so drop it here: it
/// keeps the key out of GStreamer logs and AVPlayer error strings, which
/// are not places a credential should end up.
fn strip_apikey(url: &mut Url) {
    let kept: Vec<(String, String)> = url
        .query_pairs()
        .filter(|(k, _)| !k.eq_ignore_ascii_case("apikey"))
        .map(|(k, v)| (k.into_owned(), v.into_owned()))
        .collect();
    if kept.is_empty() {
        url.set_query(None);
    } else {
        url.query_pairs_mut().clear().extend_pairs(kept);
    }
}

/// Unguessable path segment. Without it any local process could stream
/// the user's library off a port it can find by scanning loopback.
fn random_token() -> String {
    use rand::RngCore;
    let mut bytes = [0u8; 16];
    rand::rng().fill_bytes(&mut bytes);
    use std::fmt::Write;
    let mut out = String::with_capacity(32);
    for b in bytes {
        let _ = write!(out, "{b:02x}");
    }
    out
}
