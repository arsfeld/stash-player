//! Settings page — Stash URL + API key entry, "test connection" round-trip.
//! Emits `Configured` upward when the test succeeds so the root component
//! can build a shared API client and navigate to the library.

use relm4::prelude::*;
use relm4::{adw, gtk};

use adw::prelude::*;

use stash_player_core::Config;

#[derive(Debug)]
pub struct SettingsInit {
    pub config: Config,
    /// Pre-fill the API key field (e.g. from a `.env` override or the keyring).
    pub api_key: String,
}

pub struct SettingsPage {
    config: Config,
    api_key: String,
    status: Status,
}

#[derive(Debug, Clone)]
enum Status {
    Idle,
    Connecting,
    Connected(String),
    Failed(String),
}

#[derive(Debug)]
pub enum SettingsMsg {
    UrlChanged(String),
    ApiKeyChanged(String),
    TestConnection,
}

#[derive(Debug)]
pub enum SettingsCmd {
    Connection(Result<(stash_api::Client, String), String>),
    Saved(Result<(), String>),
}

#[derive(Debug)]
pub enum SettingsOutput {
    /// Server reachable. The root component should adopt this client and
    /// navigate to the library.
    Configured {
        client: stash_api::Client,
        config: Config,
        api_key: String,
    },
}

#[relm4::component(pub)]
impl Component for SettingsPage {
    type Init = SettingsInit;
    type Input = SettingsMsg;
    type Output = SettingsOutput;
    type CommandOutput = SettingsCmd;

    view! {
        adw::NavigationPage {
            set_title: "Stash server",
            set_tag: Some("settings"),

            #[wrap(Some)]
            set_child = &adw::ToolbarView {
                add_top_bar = &adw::HeaderBar {},

                #[wrap(Some)]
                set_content = &gtk::ScrolledWindow {
                    set_hscrollbar_policy: gtk::PolicyType::Never,

                    adw::Clamp {
                        set_maximum_size: 540,
                        set_margin_top: 24,
                        set_margin_bottom: 24,
                        set_margin_start: 12,
                        set_margin_end: 12,

                        gtk::Box {
                            set_orientation: gtk::Orientation::Vertical,
                            set_spacing: 18,

                            adw::PreferencesGroup {
                                set_title: "Connection",
                                set_description: Some(
                                    "Where to find your Stash server. The API key is \
                                     stored in your Linux Secret Service keyring."
                                ),

                                #[name = "url_row"]
                                adw::EntryRow {
                                    set_title: "URL",
                                    connect_changed[sender] => move |entry| {
                                        sender.input(SettingsMsg::UrlChanged(entry.text().to_string()));
                                    },
                                },

                                #[name = "key_row"]
                                adw::PasswordEntryRow {
                                    set_title: "API key",
                                    connect_changed[sender] => move |entry| {
                                        sender.input(SettingsMsg::ApiKeyChanged(entry.text().to_string()));
                                    },
                                },
                            },

                            gtk::Box {
                                set_halign: gtk::Align::End,

                                gtk::Button {
                                    set_label: "Test connection",
                                    add_css_class: "suggested-action",
                                    add_css_class: "pill",
                                    #[watch]
                                    set_sensitive: !matches!(model.status, Status::Connecting),
                                    connect_clicked => SettingsMsg::TestConnection,
                                },
                            },

                            gtk::Label {
                                set_halign: gtk::Align::Start,
                                set_wrap: true,
                                set_selectable: true,
                                #[watch]
                                set_label: &status_line(&model.status),
                                #[watch]
                                set_visible: !matches!(model.status, Status::Idle),
                            },
                        },
                    },
                },
            },
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let model = SettingsPage {
            config: init.config,
            api_key: init.api_key,
            status: Status::Idle,
        };

        let widgets = view_output!();

        widgets.url_row.set_text(&model.config.stash_url);
        widgets.key_row.set_text(&model.api_key);

        ComponentParts { model, widgets }
    }

    fn update(&mut self, msg: SettingsMsg, sender: ComponentSender<Self>, _root: &Self::Root) {
        match msg {
            SettingsMsg::UrlChanged(s) => self.config.stash_url = s,
            SettingsMsg::ApiKeyChanged(s) => self.api_key = s,
            SettingsMsg::TestConnection => {
                self.status = Status::Connecting;
                let url = self.config.stash_url.clone();
                let key = self.api_key.clone();
                sender.oneshot_command(async move {
                    let result = match stash_api::Client::new(&url, &key) {
                        Ok(client) => match client.version().await {
                            Ok(version) => Ok((client, version)),
                            Err(e) => Err(e.to_string()),
                        },
                        Err(e) => Err(e.to_string()),
                    };
                    SettingsCmd::Connection(result)
                });
            }
        }
    }

    fn update_cmd(
        &mut self,
        msg: SettingsCmd,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            SettingsCmd::Connection(Ok((client, version))) => {
                self.status = Status::Connected(version);
                if let Err(e) = self.config.save() {
                    tracing::warn!("config save failed: {e}");
                }
                let key = self.api_key.clone();
                let config = self.config.clone();
                let _ = sender.output(SettingsOutput::Configured {
                    client,
                    config,
                    api_key: key.clone(),
                });
                sender.oneshot_command(async move {
                    SettingsCmd::Saved(
                        stash_player_core::secrets::store_api_key(&key)
                            .await
                            .map_err(|e| e.to_string()),
                    )
                });
            }
            SettingsCmd::Connection(Err(e)) => {
                self.status = Status::Failed(e);
            }
            SettingsCmd::Saved(Ok(())) => {
                tracing::debug!("api key saved to keyring");
            }
            SettingsCmd::Saved(Err(e)) => {
                tracing::warn!("could not save api key to keyring: {e}");
            }
        }
    }
}

fn status_line(status: &Status) -> String {
    match status {
        Status::Idle => String::new(),
        Status::Connecting => "Connecting…".into(),
        Status::Connected(v) => format!("✓ Connected to Stash {v}"),
        Status::Failed(e) => format!("✗ {e}"),
    }
}
