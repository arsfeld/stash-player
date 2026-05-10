//! Chromecast integration. Stub crate — real implementation lands in
//! milestone 4. The shape we're aiming for:
//!
//! ```ignore
//! pub trait Caster {
//!     async fn discover(&self) -> impl Stream<Item = Device>;
//!     async fn connect(&self, device: Device) -> Result<Session>;
//! }
//!
//! pub trait Session {
//!     async fn load(&mut self, url: &str, mime: &str) -> Result<()>;
//!     async fn play(&mut self) -> Result<()>;
//!     async fn pause(&mut self) -> Result<()>;
//!     async fn seek(&mut self, position: Duration) -> Result<()>;
//!     fn status(&self) -> watch::Receiver<MediaStatus>;
//! }
//! ```
//!
//! Implementation will use `mdns-sd` for discovery (`_googlecast._tcp.local`)
//! and `rust_cast` (or a hand-rolled protobuf client) for the receiver
//! protocol.
