//! O que muda de um sistema para outro: pastas, aleatoriedade, hora local,
//! processos e nomes. O resto do core não pergunta em que sistema está.

use std::{
    fs,
    path::{Path, PathBuf},
};

/// A pasta pessoal: HOME no macOS e no Linux, USERPROFILE no Windows.
pub fn home_dir() -> PathBuf {
    std::env::var_os("HOME")
        .or_else(|| std::env::var_os("USERPROFILE"))
        .map(PathBuf::from)
        .unwrap_or_default()
}

/// Onde a Oficina guarda o estado dela.
pub fn data_dir() -> PathBuf {
    if cfg!(target_os = "macos") {
        home_dir().join("Library/Application Support/Oficina")
    } else if cfg!(windows) {
        std::env::var_os("APPDATA").map(PathBuf::from).unwrap_or_else(|| home_dir().join("AppData/Roaming")).join("Oficina")
    } else {
        std::env::var_os("XDG_DATA_HOME").map(PathBuf::from).unwrap_or_else(|| home_dir().join(".local/share")).join("oficina")
    }
}

/// Bytes aleatórios do sistema.
pub fn random_bytes(n: usize) -> std::io::Result<Vec<u8>> {
    let mut raw = vec![0u8; n];
    #[cfg(unix)]
    {
        use std::io::Read;
        fs::File::open("/dev/urandom")?.read_exact(&mut raw)?;
    }
    #[cfg(windows)]
    {
        #[link(name = "advapi32")]
        unsafe extern "system" {
            #[link_name = "SystemFunction036"]
            fn rtl_gen_random(buffer: *mut u8, length: u32) -> u8;
        }
        // SAFETY: o buffer tem exatamente `n` bytes.
        if unsafe { rtl_gen_random(raw.as_mut_ptr(), raw.len() as u32) } == 0 {
            return Err(std::io::Error::other("RtlGenRandom falhou"));
        }
    }
    Ok(raw)
}

/// Hora local quebrada em partes.
pub struct LocalTime {
    pub year: i32,
    pub month: u32,
    pub day: u32,
    pub hour: u32,
    pub minute: u32,
    /// Segundos a leste de UTC.
    pub offset: i64,
}

pub fn local_time(ts: u64) -> LocalTime {
    let t = ts as libc::time_t;
    // SAFETY: `tm` é preenchida pela função do sistema antes de ser lida.
    let mut tm: libc::tm = unsafe { std::mem::zeroed() };
    #[cfg(unix)]
    unsafe {
        libc::localtime_r(&t, &mut tm);
    }
    #[cfg(windows)]
    unsafe {
        libc::localtime_s(&mut tm, &t);
    }
    #[cfg(unix)]
    let offset = tm.tm_gmtoff as i64;
    #[cfg(windows)]
    let offset = {
        let mut utc: libc::tm = unsafe { std::mem::zeroed() };
        // SAFETY: idem.
        unsafe { libc::gmtime_s(&mut utc, &t) };
        civil_secs(&tm) - civil_secs(&utc)
    };
    LocalTime {
        year: tm.tm_year + 1900,
        month: (tm.tm_mon + 1) as u32,
        day: tm.tm_mday as u32,
        hour: tm.tm_hour.clamp(0, 23) as u32,
        minute: tm.tm_min.clamp(0, 59) as u32,
        offset,
    }
}

/// Segundos desde 1970 de uma data quebrada (algoritmo de Hinnant).
#[cfg(windows)]
fn civil_secs(tm: &libc::tm) -> i64 {
    let (y, m, d) = (tm.tm_year as i64 + 1900, tm.tm_mon as i64 + 1, tm.tm_mday as i64);
    let y2 = if m <= 2 { y - 1 } else { y };
    let era = y2.div_euclid(400);
    let yoe = y2 - era * 400;
    let doy = (153 * (m + if m > 2 { -3 } else { 9 }) + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    (era * 146097 + doe - 719468) * 86400 + tm.tm_hour as i64 * 3600 + tm.tm_min as i64 * 60 + tm.tm_sec as i64
}

/// O nome da máquina, como a pessoa conhece.
pub fn hostname() -> String {
    #[cfg(target_os = "macos")]
    {
        // O hostname do Mac muda com a rede (pode virar o IP do DHCP).
        let named = std::process::Command::new("/usr/sbin/scutil")
            .args(["--get", "ComputerName"])
            .output()
            .ok()
            .filter(|o| o.status.success())
            .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
            .filter(|s| !s.is_empty());
        if let Some(name) = named {
            return name;
        }
    }
    #[cfg(windows)]
    {
        if let Some(n) = std::env::var_os("COMPUTERNAME") {
            return n.to_string_lossy().into_owned();
        }
    }
    #[cfg(unix)]
    {
        let mut buf = [0u8; 256];
        // SAFETY: o buffer é nosso e tem o tamanho informado.
        let ok = unsafe { libc::gethostname(buf.as_mut_ptr().cast(), buf.len()) } == 0;
        if ok {
            let end = buf.iter().position(|b| *b == 0).unwrap_or(buf.len());
            let name = String::from_utf8_lossy(&buf[..end]).trim_end_matches(".local").to_string();
            if !name.is_empty() {
                return name;
            }
        }
    }
    "este computador".into()
}

/// Acha um programa: caminhos comuns e depois o PATH (no Windows, com .exe/.cmd).
pub fn find_program(name: &str, extra: &[PathBuf]) -> PathBuf {
    if let Some(p) = extra.iter().find(|p| p.exists()) {
        return p.clone();
    }
    let exts: &[&str] = if cfg!(windows) { &[".exe", ".cmd", ".bat", ""] } else { &[""] };
    if let Some(path) = std::env::var_os("PATH") {
        for dir in std::env::split_paths(&path) {
            for ext in exts {
                let p = dir.join(format!("{name}{ext}"));
                if p.is_file() {
                    return p;
                }
            }
        }
    }
    PathBuf::from(name)
}

/// O processo filho vira líder do próprio grupo, para ser encerrado inteiro.
pub fn own_group(cmd: &mut tokio::process::Command) {
    #[cfg(unix)]
    {
        cmd.process_group(0);
    }
    #[cfg(windows)]
    {
        const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        cmd.creation_flags(CREATE_NEW_PROCESS_GROUP | CREATE_NO_WINDOW);
    }
}

/// Pede para o grupo parar (`hard` = sem negociar).
pub fn stop_group(pid: i32, hard: bool) {
    #[cfg(unix)]
    {
        let sig = if hard { libc::SIGKILL } else { libc::SIGINT };
        // SAFETY: `pid` lidera um grupo criado por nós (`own_group`).
        unsafe { libc::kill(-pid, sig) };
    }
    #[cfg(windows)]
    {
        // O Windows não tem SIGINT para outro console: encerra a árvore.
        let _ = hard;
        let _ = std::process::Command::new("taskkill").args(["/PID", &pid.to_string(), "/T", "/F"]).output();
    }
}

/// Arquivo só para o dono (no Windows, a pasta do usuário já é só dele).
pub fn write_private(path: &Path, bytes: &[u8]) -> std::io::Result<()> {
    use std::io::Write;
    let mut o = fs::OpenOptions::new();
    o.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        o.mode(0o600);
    }
    o.open(path)?.write_all(bytes)
}

pub fn private_dir(path: &Path) -> std::io::Result<()> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    let _ = path;
    Ok(())
}

/// Espaço que o arquivo ocupa no disco.
pub fn disk_size(m: &fs::Metadata) -> u64 {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        m.blocks() * 512
    }
    #[cfg(not(unix))]
    {
        m.len()
    }
}

/// Identidade do arquivo no disco, para não contar o mesmo duas vezes.
pub fn file_id(m: &fs::Metadata) -> Option<(u64, u64)> {
    #[cfg(unix)]
    {
        use std::os::unix::fs::MetadataExt;
        Some((m.dev(), m.ino()))
    }
    #[cfg(not(unix))]
    {
        let _ = m;
        None
    }
}

/// Programas de um ambiente Python: `bin/` no macOS e no Linux, `Scripts\` no Windows.
pub fn venv_bin(env: &Path, name: &str) -> PathBuf {
    if cfg!(windows) { env.join("Scripts").join(format!("{name}.exe")) } else { env.join("bin").join(name) }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn aleatorio_muda() {
        assert_ne!(random_bytes(16).unwrap(), random_bytes(16).unwrap());
    }

    #[test]
    fn hora_local_coerente() {
        let t = local_time(1_700_000_000);
        assert!(t.year >= 2023 && (1..=12).contains(&t.month) && t.hour < 24);
        assert!(t.offset.abs() <= 14 * 3600);
    }

    #[test]
    fn acha_programa_no_path() {
        assert!(find_program("sh", &[]).is_absolute() || cfg!(windows));
        assert_eq!(find_program("nao-existe-oficina", &[]), PathBuf::from("nao-existe-oficina"));
    }
}
