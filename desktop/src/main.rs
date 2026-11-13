//! A Faísca no Windows e no Linux.
//!
//! Ao abrir, procura a Faísca no Wi-Fi (broadcast UDP "oficina?").
//! - Achou outra Oficina (o Mac): este computador vira um corpo da mesma
//!   Faísca. O pet aparece aqui quando ela vem para cá; a conversa vai para a
//!   mente dela, lá no Mac. Uma Faísca só.
//! - Não achou: este computador é a casa dela, com o próprio `oficinad`.
//!
//! As telas são páginas servidas pelo core (`/ui/…`), abertas em janelas
//! nativas: o pet numa janela transparente sempre no topo, a conversa numa
//! janela comum e um ícone na bandeja.

#![cfg_attr(windows, windows_subsystem = "windows")]

mod dock;

use std::{
    fs,
    io::{Read, Write},
    net::{TcpStream, ToSocketAddrs, UdpSocket},
    path::PathBuf,
    process::Command,
    time::{Duration, Instant},
};
use tao::{
    dpi::{LogicalPosition, LogicalSize},
    event::{Event, StartCause, WindowEvent},
    event_loop::{ControlFlow, EventLoopBuilder},
    window::{Window, WindowBuilder},
};
use tray_icon::{
    Icon, TrayIcon, TrayIconBuilder,
    menu::{CheckMenuItem, Menu, MenuEvent, MenuItem, PredefinedMenuItem},
};
use wry::{WebView, WebViewBuilder};

const MAIN_PORT: u16 = 7878;
const DEVICE_PORT: u16 = 7879;

// MARK: Onde a Faísca está

/// Como este computador participa.
#[derive(Clone)]
enum Mode {
    /// A mente mora aqui.
    Home { token: String },
    /// Corpo da Faísca de outro computador.
    Body { host: String, port: u16, token: String, home: String },
}

impl Mode {
    fn base(&self) -> String {
        match self {
            Mode::Home { .. } => format!("http://127.0.0.1:{MAIN_PORT}"),
            Mode::Body { host, port, .. } => format!("http://{host}:{port}"),
        }
    }

    fn script(&self) -> String {
        let (mode, token, home) = match self {
            Mode::Home { token } => ("casa", token.clone(), String::new()),
            Mode::Body { token, home, .. } => ("corpo", token.clone(), home.clone()),
        };
        format!("window.OFICINA = {};", serde_json::json!({"mode": mode, "token": token, "home": home}))
    }

    fn label(&self) -> String {
        match self {
            Mode::Home { .. } => "Faísca neste computador".into(),
            Mode::Body { home, .. } => format!("Conectado à Faísca do {home}"),
        }
    }
}

fn data_dir() -> PathBuf {
    let base = if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_default()
    } else {
        std::env::var_os("XDG_DATA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(|| PathBuf::from(std::env::var_os("HOME").unwrap_or_default()).join(".local/share"))
    };
    base.join(if cfg!(windows) { "Oficina" } else { "oficina" })
}

fn hostname() -> String {
    std::env::var("COMPUTERNAME")
        .ok()
        .or_else(|| fs::read_to_string("/etc/hostname").ok().map(|s| s.trim().to_string()))
        .filter(|s| !s.is_empty())
        .unwrap_or_else(|| "Notebook".into())
}

/// Identidade deste computador como corpo, guardada na primeira vez.
fn device_id() -> String {
    let path = data_dir().join("dispositivo");
    if let Ok(id) = fs::read_to_string(&path) {
        if id.trim().len() >= 6 {
            return id.trim().to_string();
        }
    }
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_nanos()).unwrap_or(0);
    let id = format!("pc-{:x}{:x}", nanos, std::process::id());
    let _ = fs::create_dir_all(data_dir());
    let _ = fs::write(&path, &id);
    id
}

/// Grita "oficina?" na rede; responde quem tem a mente da Faísca.
fn discover() -> Option<(String, u16, String)> {
    let me = hostname();
    let sock = UdpSocket::bind("0.0.0.0:0").ok()?;
    sock.set_broadcast(true).ok()?;
    sock.set_read_timeout(Some(Duration::from_millis(400))).ok()?;
    let until = Instant::now() + Duration::from_millis(2000);
    let _ = sock.send_to(b"oficina?", ("255.255.255.255", DEVICE_PORT));
    let mut buf = [0u8; 128];
    while Instant::now() < until {
        let Ok((n, from)) = sock.recv_from(&mut buf) else { continue };
        let reply = String::from_utf8_lossy(&buf[..n]).to_string();
        let mut parts = reply.splitn(3, ':');
        if parts.next() != Some("oficina") {
            continue;
        }
        let port = parts.next().and_then(|p| p.parse().ok()).unwrap_or(DEVICE_PORT);
        let name = parts.next().unwrap_or("Mac").to_string();
        // A própria Oficina deste computador não conta.
        if name.eq_ignore_ascii_case(&me) || from.ip().is_loopback() {
            continue;
        }
        return Some((from.ip().to_string(), port, name));
    }
    None
}

/// HTTP mínimo (sem dependências): só o que o app precisa.
fn http(host: &str, port: u16, method: &str, path: &str, body: Option<&str>) -> Option<(u16, String)> {
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(3)).ok()?;
    s.set_read_timeout(Some(Duration::from_secs(5))).ok()?;
    let body = body.unwrap_or("");
    let req = format!(
        "{method} {path} HTTP/1.1\r\nHost: {host}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
        body.len()
    );
    s.write_all(req.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    let code = out.split_whitespace().nth(1)?.parse().ok()?;
    let body = out.split_once("\r\n\r\n").map(|(_, b)| b.to_string()).unwrap_or_default();
    Some((code, body))
}

/// A Faísca do Mac aceita este computador como corpo (sem pareamento).
fn join(host: &str, port: u16, home: &str) -> Option<Mode> {
    let me = hostname();
    let req = serde_json::json!({"device": device_id(), "name": me, "room": me, "kind": "pc"}).to_string();
    let (code, body) = http(host, port, "POST", "/v1/body/hello", Some(&req))?;
    if code != 200 {
        return None;
    }
    let v: serde_json::Value = serde_json::from_str(&body).ok()?;
    Some(Mode::Body { host: host.into(), port, token: v["token"].as_str()?.to_string(), home: home.into() })
}

/// Sem outra Oficina na rede: liga o `oficinad` deste computador.
fn start_home() -> Option<Mode> {
    let healthy = || http("127.0.0.1", MAIN_PORT, "GET", "/v1/health", None).is_some_and(|(c, _)| c == 200);
    if !healthy() {
        let exe = std::env::current_exe().ok()?.with_file_name(if cfg!(windows) { "oficinad.exe" } else { "oficinad" });
        let mut cmd = Command::new(exe);
        #[cfg(windows)]
        {
            use std::os::windows::process::CommandExt;
            cmd.creation_flags(0x0800_0000); // sem janela de console
        }
        cmd.spawn().ok()?;
        let until = Instant::now() + Duration::from_secs(8);
        while !healthy() && Instant::now() < until {
            std::thread::sleep(Duration::from_millis(150));
        }
    }
    let token = fs::read_to_string(data_dir().join("token")).ok()?.trim().to_string();
    Some(Mode::Home { token })
}

fn find_faisca() -> Option<Mode> {
    discover().and_then(|(host, port, name)| join(&host, port, &name)).or_else(start_home)
}

// MARK: Janelas

enum UserEvent {
    Pet(String),
    Dock(String),
    /// Ícone pronto: caminho do app e PNG em base64.
    DockIcon(String, String),
    /// Lista de apps instalados, em JSON, para o "+" da Dock.
    DockApps(String),
    Menu(tray_icon::menu::MenuId),
}

/// Ícone da bandeja: uma gota laranja, desenhada aqui (sem arquivo).
fn tray_icon_image() -> Icon {
    let size = 32u32;
    let mut rgba = vec![0u8; (size * size * 4) as usize];
    for y in 0..size {
        for x in 0..size {
            let (fx, fy) = (x as f32 - 15.5, y as f32 - 18.0);
            // Círculo embaixo + ponta em cima: uma gota.
            let inside = fx * fx + fy * fy <= 110.0 || (y < 18 && fx.abs() <= (y as f32 - 3.0).max(0.0) * 0.7);
            if inside {
                let i = ((y * size + x) * 4) as usize;
                rgba[i..i + 4].copy_from_slice(&[255, 158, 41, 255]);
            }
        }
    }
    Icon::from_rgba(rgba, size, size).expect("ícone")
}

fn place_pet(pet: &Window) {
    if let Some(m) = pet.current_monitor() {
        let scale = m.scale_factor();
        let size = m.size().to_logical::<f64>(scale);
        let origin = m.position().to_logical::<f64>(scale);
        pet.set_outer_position(LogicalPosition::new(origin.x + size.width - 210.0, origin.y + size.height - 290.0));
    }
}

/// Área útil do monitor principal (sem a barra de tarefas), em pixels lógicos:
/// (x, y, largura, altura). No Windows vem do próprio sistema; nos outros, a tela
/// inteira menos uma faixa para o painel.
fn work_area(win: &Window) -> Option<(f64, f64, f64, f64)> {
    let m = win.primary_monitor().or_else(|| win.current_monitor())?;
    let scale = m.scale_factor();
    #[cfg(windows)]
    {
        use windows_sys::Win32::{
            Foundation::{POINT, RECT},
            Graphics::Gdi::{GetMonitorInfoW, MONITOR_DEFAULTTOPRIMARY, MONITORINFO, MonitorFromPoint},
        };
        // SAFETY: MONITORINFO zerada com cbSize preenchido, como a API pede.
        unsafe {
            let mon = MonitorFromPoint(POINT { x: 0, y: 0 }, MONITOR_DEFAULTTOPRIMARY);
            let mut info: MONITORINFO = std::mem::zeroed();
            info.cbSize = std::mem::size_of::<MONITORINFO>() as u32;
            if GetMonitorInfoW(mon, &mut info) != 0 {
                let RECT { left, top, right, bottom } = info.rcWork;
                return Some((left as f64 / scale, top as f64 / scale, (right - left) as f64 / scale, (bottom - top) as f64 / scale));
            }
        }
    }
    let size = m.size().to_logical::<f64>(scale);
    let origin = m.position().to_logical::<f64>(scale);
    Some((origin.x, origin.y, size.width, size.height - 48.0))
}

/// A Dock fica no centro da área útil, colada embaixo, como no Mac. A página
/// mede a barra e manda o tamanho exato: a janela nunca é maior que a barra
/// (não rouba cliques) e fica centralizada em qualquer tela, até num ultrawide.
fn place_dock(win: &Window, width: f64, height: f64) {
    win.set_inner_size(LogicalSize::new(width, height));
    if let Some((x, y, w, h)) = work_area(win) {
        win.set_outer_position(LogicalPosition::new((x + (w - width) / 2.0).round(), (y + h - height).round()));
    }
}

/// O estado que a página da Dock desenha.
fn dock_state(d: &dock::Dock) -> String {
    let apps = d.current().map(|e| e.apps.clone()).unwrap_or_default();
    serde_json::json!({
        "envs": d.envs.iter().map(|e| e.name.clone()).collect::<Vec<_>>(),
        "active": d.active,
        "apps": apps,
    })
    .to_string()
}

/// Ícones de verdade, tirados em segundo plano para a Dock abrir na hora.
fn load_icons(apps: Vec<dock::App>, proxy: tao::event_loop::EventLoopProxy<UserEvent>) {
    if apps.is_empty() {
        return;
    }
    std::thread::spawn(move || {
        for a in apps {
            if let Some(png) = dock::icon_png(&a.path) {
                let _ = proxy.send_event(UserEvent::DockIcon(a.path, dock::base64(&png)));
            }
        }
    });
}

fn main() {
    let Some(mode) = find_faisca() else {
        eprintln!("Não achei a Faísca na rede nem consegui ligar o oficinad.");
        return;
    };
    let event_loop = EventLoopBuilder::<UserEvent>::with_user_event().build();
    let proxy = event_loop.create_proxy();

    let mut pet_builder = WindowBuilder::new()
        .with_title("Faísca")
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .with_resizable(false)
        .with_inner_size(LogicalSize::new(200.0, 240.0));
    #[cfg(windows)]
    {
        use tao::platform::windows::WindowBuilderExtWindows;
        pet_builder = pet_builder.with_skip_taskbar(true);
    }
    let pet = pet_builder.build(&event_loop).expect("janela do pet");
    place_pet(&pet);

    let chat = WindowBuilder::new()
        .with_title("Faísca")
        .with_visible(false)
        .with_inner_size(LogicalSize::new(440.0, 640.0))
        .build(&event_loop)
        .expect("janela da conversa");

    let p = proxy.clone();
    let pet_view: WebView = WebViewBuilder::new()
        .with_transparent(true)
        .with_initialization_script(&mode.script())
        .with_url(format!("{}/ui/pet.html", mode.base()))
        .with_ipc_handler(move |req| {
            let _ = p.send_event(UserEvent::Pet(req.body().clone()));
        })
        .build(&pet)
        .expect("pet");
    let chat_view: WebView = WebViewBuilder::new()
        .with_initialization_script(&mode.script())
        .with_url(format!("{}/ui/chat.html", mode.base()))
        .build(&chat)
        .expect("conversa");

    // A Dock, como no Mac: ambientes, apps fixados e a casinha da Faísca.
    let mut dock_data = dock::Dock::open(&data_dir());
    let mut dock_builder = WindowBuilder::new()
        .with_title("Dock da Faísca")
        .with_decorations(false)
        .with_transparent(true)
        .with_always_on_top(true)
        .with_resizable(false)
        .with_inner_size(LogicalSize::new(600.0, 150.0))
        // Aparece quando a página medir a barra, já no lugar certo.
        .with_visible(false);
    #[cfg(windows)]
    {
        use tao::platform::windows::WindowBuilderExtWindows;
        dock_builder = dock_builder.with_skip_taskbar(true);
    }
    let dock_win = dock_builder.build(&event_loop).expect("janela da Dock");
    let mut dock_icons: std::collections::HashMap<String, String> = std::collections::HashMap::new();
    let mut dock_size = (600.0, 150.0);
    let mut dock_shown = false;
    let mut dock_area = work_area(&dock_win);
    let p = proxy.clone();
    let dock_view: WebView = WebViewBuilder::new()
        .with_transparent(true)
        .with_html(include_str!("dock.html"))
        .with_ipc_handler(move |req| {
            let _ = p.send_event(UserEvent::Dock(req.body().clone()));
        })
        .build(&dock_win)
        .expect("Dock");

    let status = MenuItem::new(mode.label(), false, None);
    let show_dock = CheckMenuItem::new("Mostrar Dock", true, dock_data.visible, None);
    let talk = MenuItem::new("Conversar", true, None);
    let call = MenuItem::new("Chamar a Faísca para cá", matches!(mode, Mode::Body { .. }), None);
    let search = MenuItem::new("Procurar a Faísca na rede de novo", true, None);
    let quit = MenuItem::new("Sair", true, None);
    let menu = Menu::new();
    let _ = menu.append_items(&[&status, &PredefinedMenuItem::separator(), &talk, &call, &show_dock, &search, &PredefinedMenuItem::separator(), &quit]);
    let p = proxy.clone();
    MenuEvent::set_event_handler(Some(move |e: MenuEvent| {
        let _ = p.send_event(UserEvent::Menu(e.id));
    }));
    let mut tray: Option<TrayIcon> = None;
    let mut menu = Some(menu);

    let show_chat = |chat: &Window, view: &WebView| {
        chat.set_visible(true);
        chat.set_focus();
        let _ = view.evaluate_script("Oficina.focus()");
    };

    event_loop.run(move |event, _, flow| {
        // Acorda a cada 3 s para conferir a área útil (resolução ou barra de tarefas mudaram).
        *flow = ControlFlow::WaitUntil(Instant::now() + Duration::from_secs(3));
        match event {
            Event::NewEvents(StartCause::ResumeTimeReached { .. }) => {
                let area = work_area(&dock_win);
                if area != dock_area {
                    dock_area = area;
                    place_dock(&dock_win, dock_size.0, dock_size.1);
                }
            }
            Event::NewEvents(StartCause::Init) => {
                // A bandeja nasce com o laço de eventos rodando.
                tray = menu.take().and_then(|m| {
                    TrayIconBuilder::new().with_menu(Box::new(m)).with_tooltip("Faísca").with_icon(tray_icon_image()).build().ok()
                });
            }
            // Resolução, escala ou monitor mudaram: volta para o centro.
            Event::WindowEvent { window_id, event: WindowEvent::ScaleFactorChanged { .. }, .. } if window_id == dock_win.id() => {
                place_dock(&dock_win, dock_size.0, dock_size.1);
            }
            Event::WindowEvent { window_id, event: WindowEvent::CloseRequested, .. } => {
                // Fechar a conversa só esconde; a Faísca continua aqui.
                if window_id == chat.id() {
                    chat.set_visible(false);
                }
            }
            Event::UserEvent(UserEvent::Pet(msg)) => match msg.as_str() {
                "chat" | "listen" => show_chat(&chat, &chat_view),
                "drag" => {
                    let _ = pet.drag_window();
                }
                "show" => pet.set_visible(true),
                "hide" => pet.set_visible(false),
                "forgotten" => {
                    // Esquecida no Mac: procura de novo na próxima vez que abrir.
                }
                m if m.starts_with("relay:") => {
                    let _ = chat_view.evaluate_script(&format!("Oficina.receive({})", &m[6..]));
                }
                _ => {}
            },
            Event::UserEvent(UserEvent::Dock(msg)) => {
                let (cmd, arg) = msg.split_once(':').unwrap_or((msg.as_str(), ""));
                let mut changed = false;
                match cmd {
                    "ready" => {
                        if let Mode::Home { token } = &mode {
                            if let Some(c) = settings_tint(token) {
                                let _ = dock_view.evaluate_script(&format!("Dock.tint({})", serde_json::json!(c)));
                            }
                        }
                        changed = true;
                    }
                    "open" => dock::launch(arg),
                    "remove" => {
                        dock_data.remove(arg);
                        changed = true;
                    }
                    "switch" => {
                        dock_data.switch(arg.parse().unwrap_or(0));
                        changed = true;
                    }
                    "add" => {
                        if let Ok(app) = serde_json::from_str::<dock::App>(arg) {
                            dock_data.add(app);
                            changed = true;
                        }
                    }
                    "size" => {
                        let mut it = arg.split(',').filter_map(|v| v.parse::<f64>().ok());
                        if let (Some(w), Some(h)) = (it.next(), it.next()) {
                            dock_size = (w.clamp(120.0, 4000.0), h.clamp(60.0, 900.0));
                            place_dock(&dock_win, dock_size.0, dock_size.1);
                            if !dock_shown {
                                dock_shown = true;
                                dock_win.set_visible(dock_data.visible);
                            }
                        }
                    }
                    "picker" => {
                        let p = proxy.clone();
                        std::thread::spawn(move || {
                            let list = serde_json::to_string(&dock::installed()).unwrap_or_default();
                            let _ = p.send_event(UserEvent::DockApps(list));
                        });
                    }
                    "faisca" => show_chat(&chat, &chat_view),
                    _ => {}
                }
                if changed {
                    dock_data.save(&data_dir());
                    let apps = dock_data.current().map(|e| e.apps.clone()).unwrap_or_default();
                    let _ = dock_view.evaluate_script(&format!("Dock.render({})", dock_state(&dock_data)));
                    // Ícones já tirados vão do cache; só os novos passam pelo Shell.
                    for a in &apps {
                        if let Some(url) = dock_icons.get(&a.path) {
                            let _ = dock_view.evaluate_script(&format!("Dock.icon({}, {})", serde_json::json!(a.path), serde_json::json!(url)));
                        }
                    }
                    load_icons(apps.into_iter().filter(|a| !dock_icons.contains_key(&a.path)).collect(), proxy.clone());
                }
            }
            Event::UserEvent(UserEvent::DockIcon(path, b64)) => {
                let url = format!("data:image/png;base64,{b64}");
                let _ = dock_view.evaluate_script(&format!("Dock.icon({}, {})", serde_json::json!(path), serde_json::json!(url)));
                dock_icons.insert(path, url);
            }
            Event::UserEvent(UserEvent::DockApps(list)) => {
                let _ = dock_view.evaluate_script(&format!("Dock.picker({list})"));
            }
            Event::UserEvent(UserEvent::Menu(id)) => {
                if id == *show_dock.id() {
                    dock_data.visible = show_dock.is_checked();
                    dock_win.set_visible(dock_data.visible);
                    if dock_data.visible {
                        place_dock(&dock_win, dock_size.0, dock_size.1);
                    }
                    dock_data.save(&data_dir());
                } else if id == *talk.id() {
                    show_chat(&chat, &chat_view);
                } else if id == *call.id() {
                    if let Mode::Body { host, port, token, .. } = &mode {
                        let (host, port, token) = (host.clone(), *port, token.clone());
                        std::thread::spawn(move || {
                            let _ = http_auth(&host, port, "/v1/body/call", &token);
                        });
                    }
                } else if id == *search.id() {
                    // Recomeça: procura de novo e decide entre casa e corpo.
                    if let Ok(exe) = std::env::current_exe() {
                        let _ = Command::new(exe).spawn();
                    }
                    *flow = ControlFlow::Exit;
                } else if id == *quit.id() {
                    let _ = &tray;
                    let _ = &pet_view;
                    *flow = ControlFlow::Exit;
                }
            }
            _ => {}
        }
    });
}

fn http_auth(host: &str, port: u16, path: &str, token: &str) -> Option<u16> {
    let addr = (host, port).to_socket_addrs().ok()?.next()?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(3)).ok()?;
    let req = format!(
        "POST {path} HTTP/1.1\r\nHost: {host}\r\nAuthorization: Bearer {token}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"
    );
    s.write_all(req.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    out.split_whitespace().nth(1)?.parse().ok()
}

/// A cor da Faísca, para a Dock combinar (só quando a mente mora aqui).
fn settings_tint(token: &str) -> Option<String> {
    let addr = ("127.0.0.1", MAIN_PORT).to_socket_addrs().ok()?.next()?;
    let mut s = TcpStream::connect_timeout(&addr, Duration::from_secs(2)).ok()?;
    let req = format!("GET /v1/settings HTTP/1.1\r\nHost: 127.0.0.1\r\nAuthorization: Bearer {token}\r\nConnection: close\r\n\r\n");
    s.write_all(req.as_bytes()).ok()?;
    let mut out = String::new();
    s.read_to_string(&mut out).ok()?;
    let body = out.split_once("\r\n\r\n")?.1;
    let v: serde_json::Value = serde_json::from_str(body).ok()?;
    v["body_color"].as_str().map(String::from)
}
