//! Root component. Owns the shared API client (once configured) and the
//! `AdwNavigationView` that pushes/pops Library / Scene / Settings pages.

use relm4::prelude::*;
use relm4::adw;

use adw::prelude::*;

use stash_player_core::Config;

use crate::pages::library::{LibraryInit, LibraryMsg, LibraryOutput, LibraryPage};
use crate::pages::scene::{SceneInit, SceneNavContext, SceneOutput, ScenePage};
use crate::pages::settings::{SettingsInit, SettingsOutput, SettingsPage};

pub(crate) struct AppInit {
    pub config: Config,
    /// If set (e.g. via `.env` or the keyring), pre-fill the API key field
    /// and skip the secret-service load.
    pub api_key_override: Option<String>,
}

pub(crate) struct AppModel {
    config: Config,
    api_key: String,
    library: Controller<LibraryPage>,
    settings: Controller<SettingsPage>,
    scene: Option<Controller<ScenePage>>,
    client: Option<stash_api::Client>,
}

#[derive(Debug)]
pub(crate) struct Configured {
    pub client: stash_api::Client,
    pub config: Config,
    pub api_key: String,
}

#[derive(Debug)]
pub(crate) enum AppMsg {
    OpenSettings,
    OpenScene {
        id: String,
        context: Option<SceneNavContext>,
    },
    /// User navigated back: a `NavigationPage` was popped off the stack.
    /// We use this to drop the scene controller (and its video player)
    /// when its page is no longer visible — otherwise the `MediaFile`
    /// keeps playing audio in the background.
    NavPopped(adw::NavigationPage),
    SetAutoplay(bool),
    /// Player reported a volume/mute change — write through to disk so the
    /// next scene + next launch start at this level.
    SetVolume { volume: f64, muted: bool },
    /// Library toggled "Hide interactive" — persist so the choice survives
    /// app restarts.
    SetHideInteractive(bool),
    Configured(Box<Configured>),
    SecretsLoaded(Option<String>),
}

#[derive(Debug)]
pub(crate) enum AppCmd {
    Secrets(Result<Option<String>, String>),
}

#[relm4::component(pub)]
impl Component for AppModel {
    type Init = AppInit;
    type Input = AppMsg;
    type Output = ();
    type CommandOutput = AppCmd;

    view! {
        adw::ApplicationWindow {
            set_title: Some("stash-player"),
            set_default_width: 1100,
            set_default_height: 720,

            #[name = "nav"]
            adw::NavigationView {
                add: model.library.widget(),
                connect_popped[sender] => move |_, page| {
                    sender.input(AppMsg::NavPopped(page.clone()));
                },
            },
        }
    }

    fn init(
        init: Self::Init,
        root: Self::Root,
        sender: ComponentSender<Self>,
    ) -> ComponentParts<Self> {
        let library = LibraryPage::builder()
            .launch(LibraryInit {
                client: None,
                hide_interactive: init.config.hide_interactive,
            })
            .forward(sender.input_sender(), |out| match out {
                LibraryOutput::OpenSettings => AppMsg::OpenSettings,
                LibraryOutput::OpenScene { id, index, filter, total } => AppMsg::OpenScene {
                    id,
                    context: Some(SceneNavContext { filter, index, total }),
                },
                LibraryOutput::HideInteractiveChanged(on) => AppMsg::SetHideInteractive(on),
            });

        let settings = SettingsPage::builder()
            .launch(SettingsInit {
                config: init.config.clone(),
                api_key: init.api_key_override.clone().unwrap_or_default(),
            })
            .forward(sender.input_sender(), |out| match out {
                SettingsOutput::Configured { client, config, api_key } => {
                    AppMsg::Configured(Box::new(Configured {
                        client,
                        config,
                        api_key,
                    }))
                }
            });

        let model = AppModel {
            config: init.config,
            api_key: init.api_key_override.unwrap_or_default(),
            library,
            settings,
            scene: None,
            client: None,
        };

        let widgets = view_output!();

        // Try to load a saved API key from the keyring. If we already have
        // an override (env var, etc.), skip the lookup.
        if model.api_key.is_empty() {
            sender.oneshot_command(async {
                AppCmd::Secrets(
                    stash_player_core::secrets::load_api_key()
                        .await
                        .map_err(|e| e.to_string()),
                )
            });
        } else {
            sender.input(AppMsg::SecretsLoaded(Some(model.api_key.clone())));
        }

        ComponentParts { model, widgets }
    }

    fn update_with_view(
        &mut self,
        widgets: &mut Self::Widgets,
        msg: AppMsg,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            AppMsg::OpenSettings => {
                widgets.nav.push(self.settings.widget());
            }
            AppMsg::OpenScene { id, context } => {
                let Some(client) = self.client.clone() else {
                    return;
                };
                let scene = ScenePage::builder()
                    .launch(SceneInit {
                        client,
                        scene_id: id,
                        context,
                        autoplay: self.config.autoplay,
                        volume: self.config.volume,
                        muted: self.config.muted,
                    })
                    .forward(sender.input_sender(), |out| match out {
                        SceneOutput::SetAutoplay(on) => AppMsg::SetAutoplay(on),
                        SceneOutput::SetVolume { volume, muted } => {
                            AppMsg::SetVolume { volume, muted }
                        }
                    });
                widgets.nav.push(scene.widget());
                self.scene = Some(scene);
            }
            AppMsg::NavPopped(page) => {
                // Drop the scene controller when its page is popped so the
                // video player's `MediaFile` is torn down (which pauses
                // playback in the player's `shutdown`). Settings is owned
                // long-term by AppModel and is intentionally not dropped.
                if self
                    .scene
                    .as_ref()
                    .is_some_and(|s| s.widget() == &page)
                {
                    self.scene = None;
                }
            }
            AppMsg::SetAutoplay(on) => {
                if self.config.autoplay != on {
                    self.config.autoplay = on;
                    if let Err(e) = self.config.save() {
                        tracing::warn!("could not save config: {e}");
                    }
                }
            }
            AppMsg::SetHideInteractive(on) => {
                if self.config.hide_interactive != on {
                    self.config.hide_interactive = on;
                    if let Err(e) = self.config.save() {
                        tracing::warn!("could not save config: {e}");
                    }
                }
            }
            AppMsg::SetVolume { volume, muted } => {
                // Bit-equality is fine here: the source is our own slider/
                // keyboard handler which sends discrete values; we're only
                // trying to avoid re-saving when the polled volume races
                // and reports the same value back.
                let volume_changed = self.config.volume.to_bits() != volume.to_bits();
                let muted_changed = self.config.muted != muted;
                if volume_changed || muted_changed {
                    self.config.volume = volume;
                    self.config.muted = muted;
                    if let Err(e) = self.config.save() {
                        tracing::warn!("could not save config: {e}");
                    }
                }
            }
            AppMsg::Configured(boxed) => {
                let Configured { client, config, api_key } = *boxed;
                self.config = config;
                self.api_key = api_key;
                self.client = Some(client.clone());
                self.library.emit(LibraryMsg::SetClient(client));
                widgets.nav.pop_to_tag("library");
            }
            AppMsg::SecretsLoaded(Some(key)) => {
                self.api_key = key.clone();
                match stash_api::Client::new(&self.config.stash_url, &key) {
                    Ok(client) => {
                        self.client = Some(client.clone());
                        self.library.emit(LibraryMsg::SetClient(client));
                    }
                    Err(e) => tracing::warn!("could not build client: {e}"),
                }
            }
            AppMsg::SecretsLoaded(None) => {
                if self.config.has_custom_stash_url() {
                    match stash_api::Client::new(&self.config.stash_url, "") {
                        Ok(client) => {
                            self.client = Some(client.clone());
                            self.library.emit(LibraryMsg::SetClient(client));
                        }
                        Err(e) => {
                            tracing::warn!("could not build client: {e}");
                            widgets.nav.push(self.settings.widget());
                        }
                    }
                } else {
                    widgets.nav.push(self.settings.widget());
                }
            }
        }
        self.update_view(widgets, sender);
    }

    fn update_cmd(
        &mut self,
        msg: AppCmd,
        sender: ComponentSender<Self>,
        _root: &Self::Root,
    ) {
        match msg {
            AppCmd::Secrets(Ok(key)) => sender.input(AppMsg::SecretsLoaded(key)),
            AppCmd::Secrets(Err(e)) => {
                tracing::warn!("could not read keyring: {e}");
                sender.input(AppMsg::SecretsLoaded(None));
            }
        }
    }
}
