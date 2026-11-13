use serde::{Deserialize, Serialize};
use std::{fs, path::PathBuf};

/// Outra máquina da Oficina, alcançável pela rede.
#[derive(Clone, Serialize, Deserialize)]
pub struct Peer {
    pub name: String,
    pub url: String,
    pub token: String,
}

#[derive(Clone, Serialize, Deserialize)]
#[serde(default)]
pub struct Config {
    pub listen: String,
    pub brain_model: String,
    /// Esta máquina aceita executar tarefas locais?
    pub execute_local: bool,
    pub max_local_tasks: usize,
    /// Ferramentas liberadas para agentes que rodam nesta máquina.
    pub allowed_tools: Vec<String>,
    pub machines: Vec<Peer>,
    /// Repositório da Oficina no GitHub ("dono/nome"), para pedidos de melhoria.
    pub repo: Option<String>,
    /// Porta só para dispositivos (caixa de som, celular), aberta quando você liga
    /// "Aceitar dispositivos na rede". A API principal continua só no localhost.
    pub body_listen: String,
}

impl Default for Config {
    fn default() -> Self {
        Self {
            listen: "127.0.0.1:7878".into(),
            brain_model: "haiku".into(),
            execute_local: true,
            max_local_tasks: 2,
            allowed_tools: [
                "Read",
                "Grep",
                "Glob",
                "Edit",
                "Write",
                "WebSearch",
                "WebFetch",
                "Bash(ls *)",
                "Bash(git status *)",
                "Bash(git diff *)",
                "Bash(git log *)",
            ]
            .map(String::from)
            .to_vec(),
            machines: vec![],
            repo: None,
            body_listen: "0.0.0.0:7879".into(),
        }
    }
}

#[derive(Clone)]
pub struct Paths {
    pub home: PathBuf,
}

impl Paths {
    pub fn resolve() -> Self {
        let home = std::env::var_os("OFICINA_HOME")
            .map(PathBuf::from)
            .unwrap_or_else(crate::platform::data_dir);
        Self { home }
    }
    pub fn state(&self) -> PathBuf {
        self.home.join("state.json")
    }
    pub fn workspace(&self) -> PathBuf {
        self.home.join("workspace")
    }
    pub fn brain_dir(&self) -> PathBuf {
        self.home.join("brain")
    }
}

/// Lê (ou cria) a configuração e o token de acesso.
pub fn load(paths: &Paths) -> std::io::Result<(Config, String)> {
    for dir in [paths.home.clone(), paths.workspace(), paths.brain_dir()] {
        fs::create_dir_all(&dir)?;
    }
    crate::platform::private_dir(&paths.home)?;

    let cfg_path = paths.home.join("config.json");
    let mut cfg: Config = match fs::read(&cfg_path) {
        Ok(bytes) => serde_json::from_slice(&bytes)
            .map_err(|e| std::io::Error::other(format!("config.json inválido: {e}")))?,
        Err(_) => {
            let cfg = Config::default();
            fs::write(&cfg_path, serde_json::to_vec_pretty(&cfg)?)?;
            cfg
        }
    };
    if let Ok(listen) = std::env::var("OFICINA_LISTEN") {
        cfg.listen = listen;
    }
    if let Ok(listen) = std::env::var("OFICINA_BODY_LISTEN") {
        cfg.body_listen = listen;
    }

    let token_path = paths.home.join("token");
    let token = match fs::read_to_string(&token_path) {
        Ok(t) if !t.trim().is_empty() => t.trim().to_string(),
        _ => {
            let t = random_hex(32)?;
            crate::platform::write_private(&token_path, t.as_bytes())?;
            t
        }
    };
    Ok((cfg, token))
}

/// Bytes aleatórios do sistema, em hexadecimal.
pub fn random_hex(n: usize) -> std::io::Result<String> {
    Ok(crate::platform::random_bytes(n)?.iter().map(|b| format!("{b:02x}")).collect())
}
