//! Limpeza de disco. Varrer só lê e mede. Remover aceita apenas ids da última
//! varredura, confere de novo cada caminho e manda para a Lixeira: a tela nunca
//! escolhe um caminho, então um pedido errado não alcança nada fora da lista.

use serde::{Deserialize, Serialize};
use std::{
    collections::{HashMap, HashSet},
    fs,
    io::Read,
    path::{Component, Path, PathBuf},
    process::Command,
    sync::Mutex,
    time::{SystemTime, UNIX_EPOCH},
};

const LARGE_BYTES: u64 = 100 * 1024 * 1024;
const LARGE_LIMIT: usize = 200;
const DUPLICATE_MIN: u64 = 1024 * 1024;
const HEAD_BYTES: usize = 64 * 1024;
const MAP_LIMIT: usize = 40;
const DAY: u64 = 86_400;

/// Caches que só forçam nova sincronização: não vale limpar.
const KEEP_CACHES: &[&str] = &["CloudKit", "com.apple.bird", "com.apple.akd", "com.apple.HomeKit", "com.apple.nsurlsessiond", "dev.oficina.app"];
const PARTIAL: &[&str] = &["download", "crdownload", "part", "partial", "opdownload"];
const DEV_CACHES: &[&str] = &[".npm/_cacache", ".npm/_npx", "Library/pnpm/store", ".bun/install/cache", ".gradle/caches", ".cargo/registry/cache"];
const LEFTOVER_DIRS: &[&str] = &[
    "Library/Application Support", "Library/Caches", "Library/Containers", "Library/HTTPStorages", "Library/Logs", "Library/Preferences",
    "Library/Saved Application State", "Library/WebKit", "Library/Cookies",
];
/// Onde arquivos pessoais vivem: grandes e duplicados procuram aqui.
const PERSONAL: &[&str] = &["Downloads", "Documents", "Desktop", "Movies", "Music"];
const SKIP_DIRS: &[&str] = &["node_modules", "Pods", "venv", ".venv", "target", ".git", ".build", "DerivedData"];
const PACKAGES: &[&str] = &["app", "photoslibrary", "fcpbundle", "logicx", "bundle", "framework", "musiclibrary", "tvlibrary"];
/// Nunca, nem que peçam. Relativo à pasta do usuário.
const NEVER: &[&str] = &[
    "Library/Keychains", "Library/Mail", "Library/Messages", "Library/Mobile Documents", "Library/CloudStorage", "Library/Group Containers",
    "Library/Application Support/Oficina", ".ssh", ".gnupg", ".claude", ".Trash",
];

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash, Serialize, Deserialize)]
#[serde(rename_all = "lowercase")]
pub enum Mode {
    Junk,
    Large,
    Duplicates,
    Leftovers,
    Uninstall,
}

#[derive(Clone, Debug, Serialize)]
pub struct Item {
    pub id: u32,
    pub name: String,
    pub path: String,
    pub size: u64,
    /// Já vem marcado: só o que os apps recriam sozinhos.
    pub checked: bool,
    pub note: String,
}

#[derive(Clone, Debug, Serialize)]
pub struct Group {
    pub title: String,
    pub note: String,
    pub items: Vec<Item>,
}

#[derive(Debug, Serialize)]
pub struct Scan {
    pub mode: Mode,
    pub groups: Vec<Group>,
    pub total: u64,
}

#[derive(Debug, Default, Serialize)]
pub struct Outcome {
    pub moved: usize,
    pub bytes: u64,
    pub failed: Vec<String>,
}

#[derive(Debug, Serialize)]
pub struct AppEntry {
    pub name: String,
    pub bundle: String,
    pub path: String,
    pub size: u64,
}

#[derive(Debug, Serialize)]
pub struct MapEntry {
    pub name: String,
    pub path: String,
    pub size: u64,
    pub dir: bool,
}

#[derive(Debug, Serialize)]
pub struct StartupItem {
    pub label: String,
    pub program: String,
    pub place: String,
    pub orphan: bool,
}

struct Allowed {
    path: PathBuf,
    size: u64,
}

pub struct Cleaner {
    home: PathBuf,
    app_roots: Vec<PathBuf>,
    /// Liberada ao remover: a lista só ocupa memória entre varrer e limpar.
    allowed: Mutex<HashMap<Mode, HashMap<u32, Allowed>>>,
}

/// Espaço de verdade em disco, não o tamanho lógico.
fn disk_bytes(m: &fs::Metadata) -> u64 {
    crate::platform::disk_size(m)
}

fn walk(root: &Path, skip: &dyn Fn(&Path, &str) -> bool, visit: &mut dyn FnMut(&Path, &fs::Metadata)) {
    let mut stack = vec![root.to_path_buf()];
    while let Some(dir) = stack.pop() {
        let Ok(entries) = fs::read_dir(&dir) else { continue };
        for entry in entries.flatten() {
            let path = entry.path();
            let Ok(meta) = fs::symlink_metadata(&path) else { continue };
            if meta.file_type().is_symlink() {
                continue;
            }
            let name = entry.file_name();
            if skip(&path, &name.to_string_lossy()) {
                continue;
            }
            if meta.is_dir() {
                stack.push(path);
            } else {
                visit(&path, &meta);
            }
        }
    }
}

pub fn size_of(path: &Path) -> u64 {
    let Ok(meta) = fs::symlink_metadata(path) else { return 0 };
    if !meta.is_dir() {
        return disk_bytes(&meta);
    }
    let mut total = disk_bytes(&meta);
    walk(path, &|_, _| false, &mut |_, m| total += disk_bytes(m));
    total
}

fn children(dir: &Path) -> Vec<PathBuf> {
    let mut out: Vec<PathBuf> = fs::read_dir(dir).map(|e| e.flatten().map(|x| x.path()).collect()).unwrap_or_default();
    out.sort();
    out
}

fn file_name(p: &Path) -> String {
    p.file_name().map(|n| n.to_string_lossy().into_owned()).unwrap_or_default()
}

/// `com.empresa.app`, sem o final de arquivo que alguns lugares acrescentam.
fn bundle_like(name: &str) -> Option<&str> {
    let stem = name.strip_suffix(".plist").or(name.strip_suffix(".savedState")).or(name.strip_suffix(".binarycookies")).unwrap_or(name);
    let parts: Vec<&str> = stem.split('.').collect();
    let tld = ["com", "org", "net", "io", "dev", "app", "co", "me", "ai", "de", "br"].contains(&parts[0]);
    let clean = parts.iter().all(|p| !p.is_empty() && p.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_'));
    (parts.len() >= 3 && tld && clean).then_some(stem)
}

/// O app existe, é parte dele, ou é do sistema.
fn belongs(bundle: &str, installed: &HashSet<String>) -> bool {
    let b = bundle.to_lowercase();
    b.starts_with("com.apple.") || installed.iter().any(|i| b == *i || b.starts_with(&format!("{i}.")) || i.starts_with(&format!("{b}.")))
}

fn days_since(m: &fs::Metadata) -> u64 {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    now.saturating_sub(unix_secs(m.accessed()).max(unix_secs(m.modified())) as u64) / DAY
}

fn fnv(bytes: &[u8]) -> u64 {
    bytes.iter().fold(0xcbf2_9ce4_8422_2325u64, |h, b| (h ^ *b as u64).wrapping_mul(0x0100_0000_01b3))
}

/// Enche o buffer até o fim do arquivo; devolve quanto leu.
fn fill(f: &mut fs::File, buf: &mut [u8]) -> Option<usize> {
    let mut read = 0;
    while read < buf.len() {
        match f.read(&mut buf[read..]).ok()? {
            0 => break,
            n => read += n,
        }
    }
    Some(read)
}

fn head_hash(path: &Path) -> Option<u64> {
    let mut f = fs::File::open(path).ok()?;
    let mut buf = vec![0u8; HEAD_BYTES];
    let n = fill(&mut f, &mut buf)?;
    Some(fnv(&buf[..n]))
}

/// Comparação byte a byte: igual de verdade, sem depender de hash.
fn same_content(a: &Path, b: &Path) -> bool {
    let (Ok(mut fa), Ok(mut fb)) = (fs::File::open(a), fs::File::open(b)) else { return false };
    let (mut ba, mut bb) = (vec![0u8; HEAD_BYTES], vec![0u8; HEAD_BYTES]);
    loop {
        match (fill(&mut fa, &mut ba), fill(&mut fb, &mut bb)) {
            (Some(0), Some(0)) => return true,
            (Some(na), Some(nb)) if na == nb && ba[..na] == bb[..nb] => {}
            _ => return false,
        }
    }
}

fn personal_skip(_: &Path, name: &str) -> bool {
    name.starts_with('.') || SKIP_DIRS.contains(&name) || name.rsplit('.').next().is_some_and(|e| name.contains('.') && PACKAGES.contains(&e))
}

/// Processos abertos: o cache deles aparece, mas vem desmarcado.
fn running_names() -> HashSet<String> {
    let out = Command::new("/bin/ps").args(["-axo", "comm="]).output().map(|o| o.stdout).unwrap_or_default();
    String::from_utf8_lossy(&out).lines().filter_map(|l| l.trim().rsplit('/').next().map(str::to_lowercase)).collect()
}

fn is_open(name: &str, running: &HashSet<String>) -> bool {
    let last = name.rsplit('.').next().unwrap_or(name).to_lowercase();
    running.contains(&last)
}

fn bundle_id(app: &Path) -> Option<String> {
    let out = Command::new("/usr/bin/plutil").args(["-extract", "CFBundleIdentifier", "raw", "-o", "-"]).arg(app.join("Contents/Info.plist")).output().ok()?;
    let id = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (out.status.success() && !id.is_empty()).then_some(id)
}

impl Cleaner {
    pub fn new(home: PathBuf) -> Self {
        let app_roots = vec![PathBuf::from("/Applications"), home.join("Applications")];
        Self { home, app_roots, allowed: Mutex::new(HashMap::new()) }
    }

    fn apps_in_roots(&self) -> Vec<PathBuf> {
        let mut out = Vec::new();
        for root in &self.app_roots {
            for p in children(root) {
                if p.extension().is_some_and(|e| e == "app") {
                    out.push(p);
                } else if p.is_dir() {
                    out.extend(children(&p).into_iter().filter(|c| c.extension().is_some_and(|e| e == "app")));
                }
            }
        }
        out
    }

    pub fn apps(&self) -> Vec<AppEntry> {
        let mut out: Vec<AppEntry> = self
            .apps_in_roots()
            .into_iter()
            .filter_map(|p| {
                let bundle = bundle_id(&p)?;
                if bundle.starts_with("com.apple.") || bundle == "dev.oficina.app" {
                    return None;
                }
                Some(AppEntry { name: file_name(&p).trim_end_matches(".app").to_string(), size: size_of(&p), path: p.to_string_lossy().into_owned(), bundle })
            })
            .collect();
        out.sort_by(|a, b| a.name.to_lowercase().cmp(&b.name.to_lowercase()));
        out
    }

    /// Lê e mede. Guarda só a lista do que poderá ser removido.
    pub fn scan(&self, mode: Mode, app: Option<&str>) -> Result<Scan, String> {
        let groups = match mode {
            Mode::Junk => self.junk(),
            Mode::Large => self.large(),
            Mode::Duplicates => self.duplicates(),
            Mode::Leftovers => {
                let installed = self.apps_in_roots().iter().filter_map(|p| bundle_id(p)).map(|b| b.to_lowercase()).collect();
                self.leftovers(&installed)
            }
            Mode::Uninstall => self.uninstall(app.ok_or("Escolha um app.")?)?,
        };
        Ok(self.remember(mode, groups))
    }

    fn remember(&self, mode: Mode, mut groups: Vec<Group>) -> Scan {
        groups.retain(|g| !g.items.is_empty());
        let mut allowed = HashMap::new();
        let mut next = 1u32;
        let mut total = 0;
        for item in groups.iter_mut().flat_map(|g| g.items.iter_mut()) {
            item.id = next;
            allowed.insert(next, Allowed { path: PathBuf::from(&item.path), size: item.size });
            total += item.size;
            next += 1;
        }
        self.allowed.lock().unwrap().insert(mode, allowed);
        Scan { mode, groups, total }
    }

    fn item(&self, path: &Path, checked: bool, note: impl Into<String>) -> Item {
        Item { id: 0, name: file_name(path), path: path.to_string_lossy().into_owned(), size: size_of(path), checked, note: note.into() }
    }

    fn junk(&self) -> Vec<Group> {
        let h = &self.home;
        let running = running_names();
        let caches: Vec<Item> = children(&h.join("Library/Caches"))
            .iter()
            .filter(|p| !KEEP_CACHES.contains(&file_name(p).as_str()))
            .map(|p| {
                let open = is_open(&file_name(p), &running);
                self.item(p, !open, if open { "App aberto" } else { "" })
            })
            .filter(|i| i.size > 0)
            .collect();
        let logs = children(&h.join("Library/Logs")).iter().map(|p| self.item(p, true, "")).filter(|i| i.size > 0).collect();
        let mut xcode: Vec<Item> = children(&h.join("Library/Developer/Xcode/DerivedData")).iter().map(|p| self.item(p, true, "")).collect();
        for d in ["iOS DeviceSupport", "watchOS DeviceSupport", "macOS DeviceSupport", "visionOS DeviceSupport"] {
            xcode.extend(children(&h.join("Library/Developer/Xcode").join(d)).iter().map(|p| self.item(p, true, d)));
        }
        let sim = h.join("Library/Developer/CoreSimulator/Caches");
        if sim.is_dir() {
            xcode.push(self.item(&sim, true, "Simulador"));
        }
        let dev = DEV_CACHES.iter().map(|d| h.join(d)).filter(|p| p.is_dir()).map(|p| self.item(&p, true, "")).collect();
        let tools = children(&h.join(".cache")).iter().map(|p| self.item(p, false, "")).filter(|i| i.size > 0).collect();
        let partial = children(&h.join("Downloads"))
            .iter()
            .filter(|p| p.extension().is_some_and(|e| PARTIAL.contains(&e.to_string_lossy().as_ref())))
            .map(|p| self.item(p, true, ""))
            .collect();
        vec![
            Group { title: "Caches de apps".into(), note: "Cópias temporárias que os apps recriam.".into(), items: sorted(caches) },
            Group { title: "Logs".into(), note: "Registros antigos de apps.".into(), items: sorted(logs) },
            Group { title: "Xcode".into(), note: "Builds e suporte a dispositivos, recriados quando preciso.".into(), items: sorted(xcode) },
            Group { title: "Caches de desenvolvimento".into(), note: "npm, pnpm, bun, Gradle e Cargo baixam de novo.".into(), items: sorted(dev) },
            Group { title: "Ferramentas de terminal".into(), note: "Desmarcado: algumas guardam coisas demoradas de baixar.".into(), items: sorted(tools) },
            Group { title: "Downloads incompletos".into(), note: "Arquivos que nunca terminaram de baixar.".into(), items: sorted(partial) },
        ]
    }

    fn large(&self) -> Vec<Group> {
        let mut found: Vec<(PathBuf, u64, u64)> = Vec::new();
        for root in PERSONAL {
            walk(&self.home.join(root), &personal_skip, &mut |p, m| {
                if disk_bytes(m) >= LARGE_BYTES {
                    found.push((p.to_path_buf(), disk_bytes(m), days_since(m)));
                }
            });
        }
        found.sort_by(|a, b| b.1.cmp(&a.1));
        found.truncate(LARGE_LIMIT);
        let (old, recent): (Vec<_>, Vec<_>) = found.into_iter().partition(|f| f.2 >= 180);
        let make = |list: Vec<(PathBuf, u64, u64)>| -> Vec<Item> {
            list.into_iter()
                .map(|(p, size, days)| Item { id: 0, name: file_name(&p), path: p.to_string_lossy().into_owned(), size, checked: false, note: format!("Usado há {days} dias") })
                .collect()
        };
        vec![
            Group { title: "Sem uso há mais de 6 meses".into(), note: "Confira antes de marcar.".into(), items: make(old) },
            Group { title: "Grandes e recentes".into(), note: "Confira antes de marcar.".into(), items: make(recent) },
        ]
    }

    fn duplicates(&self) -> Vec<Group> {
        let mut by_size: HashMap<u64, Vec<(PathBuf, i64)>> = HashMap::new();
        let mut inodes = HashSet::new();
        for root in PERSONAL {
            walk(&self.home.join(root), &personal_skip, &mut |p, m| {
                if m.len() >= DUPLICATE_MIN && crate::platform::file_id(&m).is_none_or(|id| inodes.insert(id)) {
                    by_size.entry(m.len()).or_default().push((p.to_path_buf(), unix_secs(m.modified())));
                }
            });
        }
        let mut groups = Vec::new();
        for (size, files) in by_size.into_iter().filter(|(_, f)| f.len() > 1) {
            let mut by_head: HashMap<u64, Vec<(PathBuf, i64)>> = HashMap::new();
            for f in files {
                if let Some(h) = head_hash(&f.0) {
                    by_head.entry(h).or_default().push(f);
                }
            }
            for mut same_head in by_head.into_values().filter(|v| v.len() > 1) {
                same_head.sort_by_key(|f| f.1);
                while same_head.len() > 1 {
                    let keep = same_head.remove(0);
                    let (twins, rest): (Vec<_>, Vec<_>) = same_head.into_iter().partition(|f| same_content(&keep.0, &f.0));
                    same_head = rest;
                    if !twins.is_empty() {
                        let items = twins
                            .into_iter()
                            .map(|(p, _)| Item { id: 0, name: file_name(&p), path: p.to_string_lossy().into_owned(), size, checked: false, note: String::new() })
                            .collect();
                        groups.push(Group { title: file_name(&keep.0), note: format!("Fica: {}", keep.0.display()), items });
                    }
                }
            }
        }
        groups.sort_by_key(|g: &Group| std::cmp::Reverse(g.items.iter().map(|i| i.size).sum::<u64>()));
        groups
    }

    fn leftovers(&self, installed: &HashSet<String>) -> Vec<Group> {
        let mut by_app: HashMap<String, Vec<Item>> = HashMap::new();
        for dir in LEFTOVER_DIRS {
            for p in children(&self.home.join(dir)) {
                let name = file_name(&p);
                if let Some(b) = bundle_like(&name).filter(|b| !belongs(b, installed)) {
                    let place = dir.rsplit('/').next().unwrap_or(dir);
                    by_app.entry(b.to_string()).or_default().push(self.item(&p, false, place));
                }
            }
        }
        let mut groups: Vec<Group> = by_app.into_iter().map(|(title, items)| Group { title, note: "O app não está instalado.".into(), items }).collect();
        groups.sort_by_key(|g| std::cmp::Reverse(g.items.iter().map(|i| i.size).sum::<u64>()));
        groups
    }

    fn uninstall(&self, app: &str) -> Result<Vec<Group>, String> {
        let path = PathBuf::from(app);
        if !self.apps_in_roots().contains(&path) {
            return Err("Esse app não está na pasta Aplicativos.".into());
        }
        let bundle = bundle_id(&path).ok_or("Não consegui ler esse app.")?;
        if bundle.starts_with("com.apple.") || bundle == "dev.oficina.app" {
            return Err("Esse app não pode ser desinstalado.".into());
        }
        let mut rests = Vec::new();
        let name = file_name(&path).trim_end_matches(".app").to_string();
        let lower = bundle.to_lowercase();
        for dir in LEFTOVER_DIRS {
            for p in children(&self.home.join(dir)) {
                let n = file_name(&p);
                let by_id = bundle_like(&n).is_some_and(|b| b.to_lowercase() == lower || b.to_lowercase().starts_with(&format!("{lower}.")));
                let by_name = (*dir == "Library/Application Support" || *dir == "Library/Caches" || *dir == "Library/Logs") && n == name;
                if by_id || by_name {
                    rests.push(self.item(&p, true, dir.rsplit('/').next().unwrap_or(dir)));
                }
            }
        }
        Ok(vec![
            Group { title: name, note: "Saia do app antes de desinstalar.".into(), items: vec![self.item(&path, true, "Aplicativo")] },
            Group { title: "Arquivos do app".into(), note: "Ajustes, caches e dados encontrados pelo identificador.".into(), items: sorted(rests) },
        ])
    }

    fn safe_to_move(&self, mode: Mode, path: &Path) -> bool {
        if self.app_roots.iter().any(|r| path.parent() == Some(r) || path.parent().and_then(Path::parent) == Some(r)) {
            return mode == Mode::Uninstall && path.extension().is_some_and(|e| e == "app");
        }
        let Ok(rel) = path.strip_prefix(&self.home) else { return false };
        if rel.components().any(|c| matches!(c, Component::ParentDir)) || rel.components().count() < 2 {
            return false;
        }
        if NEVER.iter().any(|n| rel.starts_with(n)) || rel.components().any(|c| c.as_os_str().to_string_lossy().ends_with(".photoslibrary")) {
            return false;
        }
        // Pasta trocada por atalho depois da varredura não leva a outro lugar.
        let parent_ok = path.parent().and_then(|p| fs::canonicalize(p).ok()).zip(fs::canonicalize(&self.home).ok()).is_some_and(|(p, h)| p.starts_with(h));
        let personal = PERSONAL.iter().any(|p| rel.starts_with(p));
        parent_ok && (!personal || matches!(mode, Mode::Large | Mode::Duplicates) || (mode == Mode::Junk && rel.starts_with("Downloads")))
    }

    fn to_trash(&self, path: &Path) -> std::io::Result<()> {
        let trash = self.home.join(".Trash");
        fs::create_dir_all(&trash)?;
        let name = file_name(path);
        let mut target = trash.join(&name);
        let mut n = 1;
        while fs::symlink_metadata(&target).is_ok() {
            target = trash.join(format!("{name} {n}"));
            n += 1;
        }
        fs::rename(path, target)
    }

    /// Só o que a última varredura listou, e sempre para a Lixeira.
    pub fn run(&self, mode: Mode, ids: &[u32]) -> Outcome {
        let Some(allowed) = self.allowed.lock().unwrap().remove(&mode) else {
            return Outcome { failed: vec!["Faça uma nova varredura.".into()], ..Default::default() };
        };
        let mut out = Outcome::default();
        for id in ids {
            let Some(a) = allowed.get(id) else { continue };
            if !self.safe_to_move(mode, &a.path) {
                out.failed.push(format!("{}: protegido", a.path.display()));
                continue;
            }
            match self.to_trash(&a.path) {
                Ok(()) => {
                    out.moved += 1;
                    out.bytes += a.size;
                }
                Err(e) => out.failed.push(format!("{}: {e}", a.path.display())),
            }
        }
        out
    }

    /// Tamanho da Lixeira, se o macOS deixar olhar.
    pub fn trash_bytes(&self) -> Option<u64> {
        fs::read_dir(self.home.join(".Trash")).ok()?;
        Some(size_of(&self.home.join(".Trash")))
    }

    /// O que ocupa espaço numa pasta, do maior para o menor.
    pub fn map(&self, path: Option<&str>) -> Result<Vec<MapEntry>, String> {
        let dir = path.map(PathBuf::from).unwrap_or_else(|| self.home.clone());
        if dir.components().any(|c| matches!(c, Component::ParentDir)) || !dir.starts_with(&self.home) {
            return Err("Só dá para mapear a sua pasta de usuário.".into());
        }
        let mut out: Vec<MapEntry> = children(&dir)
            .into_iter()
            .filter(|p| fs::symlink_metadata(p).is_ok_and(|m| !m.file_type().is_symlink()))
            .map(|p| MapEntry { name: file_name(&p), size: size_of(&p), dir: p.is_dir(), path: p.to_string_lossy().into_owned() })
            .collect();
        out.sort_by_key(|e| std::cmp::Reverse(e.size));
        out.truncate(MAP_LIMIT);
        Ok(out)
    }

    /// Itens de início, com aviso quando o programa não existe mais.
    pub fn startup(&self) -> Vec<StartupItem> {
        let places = [(self.home.join("Library/LaunchAgents"), "Usuário"), (PathBuf::from("/Library/LaunchAgents"), "Todos"), (PathBuf::from("/Library/LaunchDaemons"), "Sistema")];
        let mut out = Vec::new();
        for (dir, place) in places {
            for p in children(&dir).into_iter().filter(|p| p.extension().is_some_and(|e| e == "plist")) {
                let Ok(o) = Command::new("/usr/bin/plutil").args(["-convert", "json", "-o", "-"]).arg(&p).output() else { continue };
                let v: serde_json::Value = serde_json::from_slice(&o.stdout).unwrap_or_default();
                let program = v["Program"].as_str().or(v["ProgramArguments"][0].as_str()).unwrap_or("").to_string();
                let label = v["Label"].as_str().map(String::from).unwrap_or_else(|| file_name(&p));
                out.push(StartupItem { orphan: !program.is_empty() && !Path::new(&program).exists(), label, program, place: place.into() });
            }
        }
        out
    }
}

fn sorted(mut items: Vec<Item>) -> Vec<Item> {
    items.sort_by_key(|i| std::cmp::Reverse(i.size));
    items
}

#[cfg(test)]
mod tests {
    use super::*;

    fn home(name: &str) -> PathBuf {
        let p = std::env::temp_dir().join(format!("oficina-clean-{}-{name}", std::process::id()));
        let _ = fs::remove_dir_all(&p);
        fs::create_dir_all(&p).unwrap();
        fs::canonicalize(p).unwrap()
    }

    fn write(p: &Path, bytes: &[u8]) {
        fs::create_dir_all(p.parent().unwrap()).unwrap();
        fs::write(p, bytes).unwrap();
    }

    fn ids(s: &Scan) -> Vec<u32> {
        s.groups.iter().flat_map(|g| g.items.iter().map(|i| i.id)).collect()
    }

    #[test]
    fn lixo_vai_para_a_lixeira_e_fica_recuperavel() {
        let h = home("lixo");
        write(&h.join("Library/Caches/com.foo.bar/x"), &[1; 5000]);
        write(&h.join("Library/Caches/CloudKit/y"), &[1; 5000]);
        write(&h.join("Downloads/filme.crdownload"), &[1; 5000]);
        write(&h.join("Downloads/foto.jpg"), &[1; 5000]);
        let c = Cleaner::new(h.clone());
        let s = c.scan(Mode::Junk, None).unwrap();
        let names: Vec<&str> = s.groups.iter().flat_map(|g| g.items.iter().map(|i| i.name.as_str())).collect();
        assert!(names.contains(&"com.foo.bar") && names.contains(&"filme.crdownload"));
        assert!(!names.contains(&"CloudKit") && !names.contains(&"foto.jpg"));
        let out = c.run(Mode::Junk, &ids(&s));
        assert_eq!((out.moved, out.failed.len()), (2, 0), "{:?}", out.failed);
        assert!(h.join(".Trash/com.foo.bar/x").exists() && h.join(".Trash/filme.crdownload").exists());
        assert!(h.join("Downloads/foto.jpg").exists());
    }

    #[test]
    fn so_aceita_o_que_a_varredura_listou() {
        let h = home("lista");
        write(&h.join("Library/Caches/com.foo.bar/x"), &[1; 10]);
        let c = Cleaner::new(h.clone());
        assert_eq!(c.run(Mode::Junk, &[1]).moved, 0);
        let s = c.scan(Mode::Junk, None).unwrap();
        assert_eq!(c.run(Mode::Junk, &[999]).moved, 0);
        assert!(h.join("Library/Caches/com.foo.bar/x").exists(), "id desconhecido não remove nada");
        // A lista vale uma vez só.
        assert_eq!(c.run(Mode::Junk, &ids(&s)).moved, 0);
    }

    #[test]
    fn protegidos_nunca_saem_do_lugar() {
        let c = Cleaner::new(home("guarda"));
        let h = c.home.clone();
        for p in ["Library/Keychains/a", "Library/Mail/a", "Library/Mobile Documents/a", ".ssh/id", ".claude/projects", "Pictures/F.photoslibrary/a", "Library/Application Support/Oficina/token"] {
            write(&h.join(p), b"x");
            assert!(!c.safe_to_move(Mode::Large, &h.join(p)), "{p}");
        }
        assert!(!c.safe_to_move(Mode::Junk, Path::new("/etc/hosts")));
        assert!(!c.safe_to_move(Mode::Junk, &h.join("Library/../.ssh/id")));
        assert!(!c.safe_to_move(Mode::Junk, &h.join("Library")), "pasta de primeiro nível");
        write(&h.join("Documents/a.txt"), b"x");
        assert!(!c.safe_to_move(Mode::Junk, &h.join("Documents/a.txt")), "limpeza de lixo não mexe em documentos");
        assert!(c.safe_to_move(Mode::Duplicates, &h.join("Documents/a.txt")));
        assert!(!c.safe_to_move(Mode::Junk, Path::new("/Applications/Foo.app")));
    }

    #[test]
    #[cfg(unix)]
    fn atalho_nao_leva_para_fora() {
        let h = home("atalho");
        let fora = home("atalho-fora");
        write(&fora.join("segredo"), b"x");
        fs::create_dir_all(h.join("Library")).unwrap();
        std::os::unix::fs::symlink(&fora, h.join("Library/Caches")).unwrap();
        let c = Cleaner::new(h.clone());
        assert!(!c.safe_to_move(Mode::Junk, &h.join("Library/Caches/segredo")));
        let s = c.scan(Mode::Junk, None).unwrap();
        assert_eq!(c.run(Mode::Junk, &ids(&s)).moved, 0);
        assert!(fora.join("segredo").exists());
    }

    #[test]
    fn duplicados_sao_iguais_de_verdade() {
        let h = home("dup");
        let big = vec![7u8; 2 * 1024 * 1024];
        let mut other = big.clone();
        *other.last_mut().unwrap() = 9;
        write(&h.join("Downloads/a.bin"), &big);
        write(&h.join("Documents/b.bin"), &big);
        write(&h.join("Desktop/c.bin"), &other);
        write(&h.join("Downloads/node_modules/d.bin"), &big);
        let c = Cleaner::new(h.clone());
        let s = c.scan(Mode::Duplicates, None).unwrap();
        assert_eq!(s.groups.len(), 1);
        assert_eq!(s.groups[0].items.len(), 1);
        assert!(!s.groups[0].items[0].checked);
        assert!(!s.groups[0].items[0].path.contains("c.bin"));
    }

    #[test]
    fn restos_so_de_apps_que_nao_existem() {
        let h = home("restos");
        write(&h.join("Library/Preferences/com.sumiu.app.plist"), b"x");
        write(&h.join("Library/Preferences/com.tem.app.plist"), b"x");
        write(&h.join("Library/Preferences/com.tem.app.helper.plist"), b"x");
        write(&h.join("Library/Preferences/com.apple.finder.plist"), b"x");
        write(&h.join("Library/Application Support/Google/x"), b"x");
        let c = Cleaner::new(h);
        let installed = HashSet::from(["com.tem.app".to_string()]);
        let g = c.leftovers(&installed);
        assert_eq!(g.len(), 1);
        assert_eq!(g[0].title, "com.sumiu.app");
        assert!(!g[0].items[0].checked);
    }

    #[test]
    fn nome_repetido_na_lixeira_nao_sobrescreve() {
        let h = home("repete");
        write(&h.join(".Trash/a"), b"velho");
        write(&h.join("Downloads/a"), b"novo");
        let c = Cleaner::new(h.clone());
        c.to_trash(&h.join("Downloads/a")).unwrap();
        assert_eq!(fs::read(h.join(".Trash/a")).unwrap(), b"velho");
        assert_eq!(fs::read(h.join(".Trash/a 1")).unwrap(), b"novo");
    }

    #[test]
    fn mapa_fica_na_pasta_do_usuario() {
        let h = home("mapa");
        write(&h.join("grande/x"), &[1; 90000]);
        write(&h.join("pequeno"), &[1; 10]);
        let c = Cleaner::new(h.clone());
        let m = c.map(None).unwrap();
        assert_eq!(m[0].name, "grande");
        assert!(c.map(Some("/etc")).is_err());
        assert!(c.map(Some(&format!("{}/../..", h.display()))).is_err());
    }
}

/// Data de acesso ou modificação em segundos Unix, em qualquer sistema.
fn unix_secs(t: std::io::Result<std::time::SystemTime>) -> i64 {
    t.ok().and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok()).map(|d| d.as_secs() as i64).unwrap_or(0)
}
