//! A Dock da Faísca no Windows (e no Linux): ambientes com apps fixados,
//! os ícones de verdade de cada programa e a casinha dela no fim da barra.
//! O estado fica em `dock.json`, na pasta de dados da Oficina.

use serde::{Deserialize, Serialize};
use std::{
    collections::HashSet,
    fs,
    path::{Path, PathBuf},
};

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq)]
pub struct App {
    pub name: String,
    pub path: String,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Env {
    pub name: String,
    pub apps: Vec<App>,
}

#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(default)]
pub struct Dock {
    pub envs: Vec<Env>,
    pub active: usize,
    pub visible: bool,
}

impl Default for Dock {
    fn default() -> Self {
        Self { envs: Vec::new(), active: 0, visible: true }
    }
}

fn file(dir: &Path) -> PathBuf {
    dir.join("dock.json")
}

impl Dock {
    /// Abre a Dock salva; na primeira vez monta Trabalho e Pessoal com o que achar.
    pub fn open(dir: &Path) -> Self {
        if let Some(d) = fs::read(file(dir)).ok().and_then(|b| serde_json::from_slice::<Dock>(&b).ok()) {
            if !d.envs.is_empty() {
                return d;
            }
        }
        let all = installed();
        let pick = |names: &[&str]| -> Vec<App> {
            names.iter().filter_map(|n| all.iter().find(|a| a.name.to_lowercase().contains(n)).cloned()).collect()
        };
        let mut work = pick(&["terminal", "visual studio code", "explorador", "explorer", "chrome", "edge", "outlook", "teams"]);
        work.dedup_by(|a, b| a.path == b.path);
        let mut home = pick(&["spotify", "whatsapp", "discord", "chrome", "edge", "firefox", "fotos", "photos"]);
        home.dedup_by(|a, b| a.path == b.path);
        Dock { envs: vec![Env { name: "Trabalho".into(), apps: work }, Env { name: "Pessoal".into(), apps: home }], active: 0, visible: true }
    }

    pub fn save(&self, dir: &Path) {
        let _ = fs::create_dir_all(dir);
        let _ = fs::write(file(dir), serde_json::to_vec_pretty(self).unwrap_or_default());
    }

    pub fn current(&self) -> Option<&Env> {
        self.envs.get(self.active)
    }

    pub fn add(&mut self, app: App) {
        let active = self.active;
        if let Some(e) = self.envs.get_mut(active) {
            if !e.apps.iter().any(|a| a.path == app.path) {
                e.apps.push(app);
            }
        }
    }

    pub fn remove(&mut self, path: &str) {
        let active = self.active;
        if let Some(e) = self.envs.get_mut(active) {
            e.apps.retain(|a| a.path != path);
        }
    }

    pub fn switch(&mut self, i: usize) {
        if i < self.envs.len() {
            self.active = i;
        }
    }
}

/// Programas instalados: atalhos do Menu Iniciar (Windows) ou .desktop (Linux).
pub fn installed() -> Vec<App> {
    let mut roots: Vec<PathBuf> = Vec::new();
    if cfg!(windows) {
        if let Some(p) = std::env::var_os("ProgramData") {
            roots.push(PathBuf::from(p).join("Microsoft/Windows/Start Menu/Programs"));
        }
        if let Some(p) = std::env::var_os("APPDATA") {
            roots.push(PathBuf::from(p).join("Microsoft/Windows/Start Menu/Programs"));
        }
    } else {
        roots.push(PathBuf::from("/usr/share/applications"));
        if let Some(h) = std::env::var_os("HOME") {
            roots.push(PathBuf::from(h).join(".local/share/applications"));
        }
    }
    let ext = if cfg!(windows) { "lnk" } else { "desktop" };
    let mut out = Vec::new();
    let mut seen = HashSet::new();
    for r in roots {
        walk(&r, ext, 0, &mut out, &mut seen);
    }
    out.sort_by_key(|a| a.name.to_lowercase());
    out
}

fn walk(dir: &Path, ext: &str, depth: usize, out: &mut Vec<App>, seen: &mut HashSet<String>) {
    if depth > 3 {
        return;
    }
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let p = e.path();
        if p.is_dir() {
            walk(&p, ext, depth + 1, out, seen);
            continue;
        }
        if p.extension().and_then(|x| x.to_str()) != Some(ext) {
            continue;
        }
        let name = if ext == "desktop" { desktop_name(&p) } else { p.file_stem().map(|s| s.to_string_lossy().into_owned()) };
        let Some(name) = name else { continue };
        let lower = name.to_lowercase();
        // Desinstaladores e ajudas não são apps de uso.
        if ["uninstall", "desinstalar", "readme", "leia-me", "help", "ajuda", "website"].iter().any(|w| lower.contains(w)) {
            continue;
        }
        if seen.insert(lower) {
            out.push(App { name, path: p.to_string_lossy().into_owned() });
        }
    }
}

fn desktop_name(p: &Path) -> Option<String> {
    let text = fs::read_to_string(p).ok()?;
    if text.lines().any(|l| l.trim() == "NoDisplay=true") {
        return None;
    }
    text.lines().find_map(|l| l.strip_prefix("Name=")).map(|s| s.trim().to_string())
}

/// Abre o app como se fosse clicado no Menu Iniciar.
pub fn launch(path: &str) {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        let _ = std::process::Command::new("cmd").args(["/C", "start", "", path]).creation_flags(0x0800_0000).spawn();
    }
    #[cfg(not(windows))]
    {
        let _ = std::process::Command::new("gtk-launch").arg(Path::new(path).file_stem().unwrap_or_default()).spawn();
    }
}

// MARK: Ícones

/// O ícone do programa em PNG 32×32, como o Explorer mostra.
#[cfg(windows)]
pub fn icon_png(path: &str) -> Option<Vec<u8>> {
    use std::mem::{size_of, zeroed};
    use windows_sys::Win32::{
        Graphics::Gdi::{BI_RGB, BITMAPINFO, BITMAPINFOHEADER, CreateCompatibleDC, DIB_RGB_COLORS, DeleteDC, DeleteObject, GetDIBits},
        UI::{
            Shell::{SHFILEINFOW, SHGFI_ICON, SHGFI_LARGEICON, SHGetFileInfoW},
            WindowsAndMessaging::{DestroyIcon, GetIconInfo, ICONINFO},
        },
    };
    let wide: Vec<u16> = path.encode_utf16().chain(Some(0)).collect();
    // SAFETY: estruturas zeradas e tamanhos informados como a API pede; tudo que é
    // criado aqui é liberado antes de sair.
    unsafe {
        let mut info: SHFILEINFOW = zeroed();
        if SHGetFileInfoW(wide.as_ptr(), 0, &mut info, size_of::<SHFILEINFOW>() as u32, SHGFI_ICON | SHGFI_LARGEICON) == 0 || info.hIcon.is_null() {
            return None;
        }
        let mut ii: ICONINFO = zeroed();
        if GetIconInfo(info.hIcon, &mut ii) == 0 {
            DestroyIcon(info.hIcon);
            return None;
        }
        let dc = CreateCompatibleDC(std::ptr::null_mut());
        let mut bmi: BITMAPINFO = zeroed();
        bmi.bmiHeader.biSize = size_of::<BITMAPINFOHEADER>() as u32;
        bmi.bmiHeader.biWidth = 32;
        bmi.bmiHeader.biHeight = -32;
        bmi.bmiHeader.biPlanes = 1;
        bmi.bmiHeader.biBitCount = 32;
        bmi.bmiHeader.biCompression = BI_RGB;
        let mut px = vec![0u8; 32 * 32 * 4];
        let rows = GetDIBits(dc, ii.hbmColor, 0, 32, px.as_mut_ptr().cast(), &mut bmi, DIB_RGB_COLORS);
        DeleteDC(dc);
        DeleteObject(ii.hbmColor);
        DeleteObject(ii.hbmMask);
        DestroyIcon(info.hIcon);
        if rows == 0 {
            return None;
        }
        // BGRA → RGBA; ícone antigo sem alfa fica opaco.
        let opaque = px.chunks(4).all(|c| c[3] == 0);
        for c in px.chunks_mut(4) {
            c.swap(0, 2);
            if opaque {
                c[3] = 255;
            }
        }
        Some(png(32, 32, &px))
    }
}

#[cfg(not(windows))]
pub fn icon_png(_path: &str) -> Option<Vec<u8>> {
    None
}

/// PNG sem compressão (blocos "stored" do zlib): pequeno o bastante para 32×32.
pub fn png(w: u32, h: u32, rgba: &[u8]) -> Vec<u8> {
    fn crc(data: &[u8]) -> u32 {
        let mut c = 0xFFFF_FFFFu32;
        for b in data {
            c ^= *b as u32;
            for _ in 0..8 {
                c = if c & 1 != 0 { 0xEDB8_8320 ^ (c >> 1) } else { c >> 1 };
            }
        }
        !c
    }
    fn chunk(out: &mut Vec<u8>, kind: &[u8; 4], data: &[u8]) {
        out.extend((data.len() as u32).to_be_bytes());
        let mut body = kind.to_vec();
        body.extend_from_slice(data);
        out.extend(&body);
        out.extend(crc(&body).to_be_bytes());
    }
    let mut raw = Vec::with_capacity((w * h * 4 + h) as usize);
    for row in rgba.chunks((w * 4) as usize) {
        raw.push(0);
        raw.extend_from_slice(row);
    }
    let (mut a, mut b) = (1u32, 0u32);
    for x in &raw {
        a = (a + *x as u32) % 65521;
        b = (b + a) % 65521;
    }
    let mut z = vec![0x78, 0x01];
    let blocks: Vec<&[u8]> = raw.chunks(65535).collect();
    for (i, blk) in blocks.iter().enumerate() {
        z.push(if i + 1 == blocks.len() { 1 } else { 0 });
        let len = blk.len() as u16;
        z.extend(len.to_le_bytes());
        z.extend((!len).to_le_bytes());
        z.extend_from_slice(blk);
    }
    z.extend(((b << 16) | a).to_be_bytes());
    let mut out = vec![0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A];
    let mut ihdr = Vec::new();
    ihdr.extend(w.to_be_bytes());
    ihdr.extend(h.to_be_bytes());
    ihdr.extend([8, 6, 0, 0, 0]);
    chunk(&mut out, b"IHDR", &ihdr);
    chunk(&mut out, b"IDAT", &z);
    chunk(&mut out, b"IEND", &[]);
    out
}

pub fn base64(data: &[u8]) -> String {
    const T: &[u8; 64] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut s = String::with_capacity(data.len().div_ceil(3) * 4);
    for c in data.chunks(3) {
        let n = (c[0] as u32) << 16 | (*c.get(1).unwrap_or(&0) as u32) << 8 | *c.get(2).unwrap_or(&0) as u32;
        for i in 0..4 {
            if i <= c.len() {
                s.push(T[(n >> (18 - 6 * i) & 63) as usize] as char);
            } else {
                s.push('=');
            }
        }
    }
    s
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_valido() {
        let p = png(2, 2, &[255, 0, 0, 255, 0, 255, 0, 255, 0, 0, 255, 255, 255, 255, 255, 0]);
        assert_eq!(&p[..8], &[0x89, b'P', b'N', b'G', 0x0D, 0x0A, 0x1A, 0x0A]);
        assert_eq!(&p[12..16], b"IHDR");
        assert_eq!(&p[p.len() - 8..p.len() - 4], b"IEND");
    }

    #[test]
    fn base64_como_o_padrao() {
        assert_eq!(base64(b"Faisca"), "RmFpc2Nh");
        assert_eq!(base64(b"ab"), "YWI=");
        assert_eq!(base64(b"a"), "YQ==");
    }

    #[test]
    fn ambientes() {
        let mut d = Dock { envs: vec![Env { name: "Trabalho".into(), apps: vec![] }, Env { name: "Pessoal".into(), apps: vec![] }], active: 0, visible: true };
        let app = App { name: "Terminal".into(), path: "C:/t.lnk".into() };
        d.add(app.clone());
        d.add(app.clone());
        assert_eq!(d.current().unwrap().apps.len(), 1);
        d.switch(1);
        assert!(d.current().unwrap().apps.is_empty());
        d.switch(9);
        assert_eq!(d.active, 1);
        d.switch(0);
        d.remove("C:/t.lnk");
        assert!(d.current().unwrap().apps.is_empty());
    }
}
