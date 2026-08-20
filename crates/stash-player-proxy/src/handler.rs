//! Request handling for the loopback media proxy: validate, forward
//! upstream with the authenticated client, stream the response back.

use std::convert::Infallible;
use std::sync::Arc;

use bytes::Bytes;
use futures_util::TryStreamExt;
use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Full, StreamBody};
use hyper::body::{Frame, Incoming};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode, header};
use hyper_util::rt::TokioIo;
use stash_api::Client;
use tokio::net::TcpListener;
use url::Url;

use crate::State;

type Body = BoxBody<Bytes, std::io::Error>;

/// Accept loop. Runs until the process exits.
pub(crate) async fn serve(listener: TcpListener, state: Arc<State>) {
    loop {
        let stream = match listener.accept().await {
            Ok((stream, _)) => stream,
            Err(e) => {
                tracing::warn!("media proxy accept failed: {e}");
                continue;
            }
        };

        let state = Arc::clone(&state);
        tokio::spawn(async move {
            let io = TokioIo::new(stream);
            let service = service_fn(move |req| handle(req, Arc::clone(&state)));
            if let Err(e) = http1::Builder::new().serve_connection(io, service).await {
                // Routine: AVPlayer abandons range reads constantly while
                // the user scrubs. Not worth a warning.
                tracing::debug!("media proxy connection ended: {e}");
            }
        });
    }
}

async fn handle(
    req: Request<Incoming>,
    state: Arc<State>,
) -> std::result::Result<Response<Body>, Infallible> {
    Ok(match route(&req, &state) {
        Ok((client, target)) => forward(&req, target, client).await,
        Err(response) => *response,
    })
}

/// Validate the request and resolve what to fetch.
///
/// Both guards matter and they defend different things: the token stops
/// another local process streaming the library off a port it found by
/// scanning loopback, and the origin check stops a leaked token turning
/// this into an open relay to arbitrary hosts through the user's proxy.
fn route(
    req: &Request<Incoming>,
    state: &State,
) -> std::result::Result<(Client, Url), Box<Response<Body>>> {
    if !matches!(*req.method(), Method::GET | Method::HEAD) {
        return Err(Box::new(status(
            StatusCode::METHOD_NOT_ALLOWED,
            "only GET and HEAD",
        )));
    }

    if req.uri().path() != format!("/{}/media", state.token) {
        return Err(Box::new(status(StatusCode::NOT_FOUND, "not found")));
    }

    let client = state.client().ok_or_else(|| {
        Box::new(status(
            StatusCode::SERVICE_UNAVAILABLE,
            "no stash client configured",
        ))
    })?;

    let target = upstream_target(req)?;

    let base = client.base_url();
    let same_origin = target.scheme() == base.scheme()
        && target.host_str() == base.host_str()
        && target.port_or_known_default() == base.port_or_known_default();
    if !same_origin {
        tracing::warn!("media proxy refused foreign upstream {target}");
        return Err(Box::new(status(
            StatusCode::FORBIDDEN,
            "upstream host not allowed",
        )));
    }

    Ok((client, target))
}

/// Pull the `u` query parameter out of the request and parse it as the
/// upstream URL to fetch.
fn upstream_target(req: &Request<Incoming>) -> std::result::Result<Url, Box<Response<Body>>> {
    let raw = req
        .uri()
        .query()
        .and_then(|q| {
            url::form_urlencoded::parse(q.as_bytes())
                .find(|(k, _)| k == "u")
                .map(|(_, v)| v.into_owned())
        })
        .ok_or_else(|| Box::new(status(StatusCode::BAD_REQUEST, "missing upstream url")))?;

    Url::parse(&raw)
        .map_err(|_| Box::new(status(StatusCode::BAD_REQUEST, "unparseable upstream url")))
}

async fn forward(req: &Request<Incoming>, target: Url, client: Client) -> Response<Body> {
    let mut upstream = client.http().request(req.method().clone(), target.as_str());

    // Range and If-Range are what make seeking work: the media stack asks
    // for a byte window and expects a 206 back. Nothing else is forwarded;
    // the client's own headers (ApiKey, user-agent) are already correct.
    for name in [header::RANGE, header::IF_RANGE] {
        if let Some(value) = req.headers().get(&name) {
            upstream = upstream.header(name, value);
        }
    }

    match upstream.send().await {
        Ok(resp) => map_response(resp),
        Err(e) => {
            // Transport failure, not an error status: the host is
            // unreachable or the proxy refused the connection.
            tracing::warn!("media proxy upstream request failed: {e}");
            status(StatusCode::BAD_GATEWAY, "upstream request failed")
        }
    }
}

/// Copy the status verbatim plus the headers a media stack actually
/// needs. Verbatim status is what preserves 206 for range requests, and
/// what lets an upstream 404 or 500 reach the player as itself.
fn map_response(resp: reqwest::Response) -> Response<Body> {
    let mut out = Response::builder().status(resp.status());
    for name in [
        header::CONTENT_TYPE,
        header::CONTENT_LENGTH,
        header::CONTENT_RANGE,
        header::ACCEPT_RANGES,
        header::ETAG,
        header::LAST_MODIFIED,
    ] {
        if let Some(value) = resp.headers().get(&name) {
            out = out.header(name, value);
        }
    }

    // Streamed, not buffered: these bodies are whole video files.
    let stream = resp
        .bytes_stream()
        .map_ok(Frame::data)
        .map_err(std::io::Error::other);
    let body = StreamBody::new(stream).boxed();

    out.body(body).unwrap_or_else(|e| {
        tracing::warn!("media proxy could not build response: {e}");
        status(StatusCode::BAD_GATEWAY, "bad upstream response")
    })
}

fn status(code: StatusCode, message: &str) -> Response<Body> {
    let body = Full::new(Bytes::from(message.to_owned()))
        .map_err(|never: Infallible| match never {})
        .boxed();
    Response::builder()
        .status(code)
        .body(body)
        .expect("status response always builds")
}
