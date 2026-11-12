//! A Oficina de hardware: uma ideia vira um pacote de projeto (requisitos,
//! pesquisa, mapa elétrico, peças, modelo 3D, simulações e montagem) feito por
//! um agente da Fábrica. Tudo é texto ou código que uma ferramenta confere.
//!
//! Os agentes não têm shell livre: só `oficinad hw …`, que roda as
//! simulações, o modelo em build123d e a checagem elétrica.

pub mod sim;

use crate::engine::Engine;
use crate::factory::AgentSpec;
use serde::{Deserialize, Serialize};
use sim::{Check, Report, Spec};
use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Stdio},
    sync::{Arc, Mutex},
    time::{Duration, Instant},
};

pub const CAD_HELPER: &str = include_str!("oficina_cad.py");

#[derive(Clone, Debug, Serialize, Deserialize)]
pub struct Project {
    pub id: String,
    pub name: String,
    pub idea: String,
    pub created: u64,
    #[serde(default)]
    pub agent: Option<String>,
}

#[derive(Serialize)]
pub struct ProjectView {
    #[serde(flatten)]
    pub project: Project,
    pub dir: String,
    pub files: Vec<String>,
    pub report: Option<Report>,
    /// rodando, aguardando, concluida, bloqueada, falhou, cancelada
    pub mission: Option<String>,
    pub stage: Option<usize>,
}

#[derive(Serialize)]
pub struct Overview {
    /// ausente, instalando, pronto ou "erro: …"
    pub setup: String,
    pub root: String,
    pub projects: Vec<ProjectView>,
}

pub struct Hardware {
    pub root: PathBuf,
    setup: Mutex<String>,
}

fn env_dir(root: &Path) -> PathBuf {
    root.join(".env")
}

fn python(root: &Path) -> PathBuf {
    env_dir(root).join("bin/python")
}

fn slug(name: &str) -> String {
    let s: String = name
        .to_lowercase()
        .chars()
        .map(|c| match c {
            'á' | 'à' | 'â' | 'ã' => 'a',
            'é' | 'ê' => 'e',
            'í' => 'i',
            'ó' | 'ô' | 'õ' => 'o',
            'ú' => 'u',
            'ç' => 'c',
            c if c.is_ascii_alphanumeric() => c.to_ascii_lowercase(),
            _ => '-',
        })
        .collect();
    let s = s.split('-').filter(|p| !p.is_empty()).collect::<Vec<_>>().join("-");
    s.chars().take(32).collect()
}

const SKELETON: &[(&str, &str)] = &[
    ("requisitos.md", "# Requisitos\n\nO agente preenche: o que o produto faz, para quem, limites de peso, autonomia, custo e segurança.\n"),
    ("pesquisa.md", "# Pesquisa\n\nProdutos e projetos parecidos, componentes candidatos e o que aprender com cada um.\n"),
    ("eletrica/diagrama.mmd", "flowchart LR\n  ideia[Ideia] --> projeto[Projeto]\n"),
    ("eletrica/mapa.md", "# Mapa elétrico\n\n| De | Pino | Para | Pino | Sinal | Observação |\n|---|---|---|---|---|---|\n"),
    ("montagem.md", "# Montagem\n\nPasso a passo, com ferramentas e o teste de cada passo.\n"),
    ("firmware/README.md", "# Firmware\n\nCódigo inicial que liga as peças.\n"),
    ("simulacoes/.keep", ""),
];

impl Hardware {
    pub fn open(root: PathBuf) -> Self {
        let _ = fs::create_dir_all(&root);
        let setup = if python(&root).exists() { "pronto" } else { "ausente" };
        Self { root, setup: Mutex::new(setup.into()) }
    }

    fn dir(&self, id: &str) -> Option<PathBuf> {
        let ok = !id.is_empty() && !id.starts_with('.') && id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-');
        ok.then(|| self.root.join(id)).filter(|d| d.join("projeto.json").exists())
    }

    pub fn get(&self, id: &str) -> Option<Project> {
        serde_json::from_slice(&fs::read(self.dir(id)?.join("projeto.json")).ok()?).ok()
    }

    pub fn list(&self) -> Vec<Project> {
        let mut v: Vec<Project> = fs::read_dir(&self.root)
            .into_iter()
            .flatten()
            .flatten()
            .filter_map(|e| fs::read(e.path().join("projeto.json")).ok())
            .filter_map(|b| serde_json::from_slice(&b).ok())
            .collect();
        v.sort_by_key(|p: &Project| std::cmp::Reverse(p.created));
        v
    }

    fn save(&self, p: &Project) {
        let _ = fs::write(self.root.join(&p.id).join("projeto.json"), serde_json::to_vec_pretty(p).unwrap_or_default());
    }

    /// Cria a pasta com o esqueleto do pacote.
    pub fn create(&self, name: &str, idea: &str, now: u64) -> Result<Project, String> {
        let name: String = name.trim().chars().filter(|c| !c.is_control()).take(80).collect();
        let idea: String = idea.trim().chars().take(4000).collect();
        if name.is_empty() || idea.is_empty() {
            return Err("Dê um nome e descreva a ideia.".into());
        }
        let base = { let s = slug(&name); if s.is_empty() { "projeto".to_string() } else { s } };
        let mut id = base.clone();
        let mut n = 2;
        while self.root.join(&id).exists() {
            id = format!("{base}-{n}");
            n += 1;
        }
        let dir = self.root.join(&id);
        for (path, content) in SKELETON {
            let file = dir.join(path);
            fs::create_dir_all(file.parent().unwrap()).map_err(|e| e.to_string())?;
            fs::write(file, content).map_err(|e| e.to_string())?;
        }
        fs::create_dir_all(dir.join("mecanica")).map_err(|e| e.to_string())?;
        fs::write(dir.join("oficina_cad.py"), CAD_HELPER).map_err(|e| e.to_string())?;
        let spec = Spec { nome: name.clone(), ..Default::default() };
        fs::write(dir.join("especificacao.json"), serde_json::to_vec_pretty(&spec).unwrap_or_default()).map_err(|e| e.to_string())?;
        let p = Project { id, name, idea, created: now, agent: None };
        self.save(&p);
        Ok(p)
    }

    pub fn set_agent(&self, id: &str, agent: Option<String>) {
        if let Some(mut p) = self.get(id) {
            p.agent = agent;
            self.save(&p);
        }
    }

    pub fn delete(&self, id: &str) -> Option<Project> {
        let p = self.get(id)?;
        fs::remove_dir_all(self.dir(id)?).ok()?;
        Some(p)
    }

    /// Arquivos do pacote, relativos à pasta, sem os ocultos.
    pub fn files(&self, id: &str) -> Vec<String> {
        let Some(dir) = self.dir(id) else { return Vec::new() };
        let mut out = Vec::new();
        walk(&dir, &dir, 0, &mut out);
        out.sort();
        out
    }

    pub fn report(&self, id: &str) -> Option<Report> {
        serde_json::from_slice(&fs::read(self.dir(id)?.join("simulacoes/resultado.json")).ok()?).ok()
    }

    pub fn setup_state(&self) -> String {
        self.setup.lock().unwrap().clone()
    }

    /// Instala build123d (e, se der, atopile) num ambiente só da Oficina.
    /// Bloqueia por minutos: chame fora do runtime.
    pub fn setup(&self) {
        *self.setup.lock().unwrap() = "instalando".into();
        let result = setup_env(&self.root);
        *self.setup.lock().unwrap() = match result {
            Ok(()) => "pronto".into(),
            Err(e) => format!("erro: {e}"),
        };
    }
}

fn walk(base: &Path, dir: &Path, depth: usize, out: &mut Vec<String>) {
    if depth > 3 || out.len() > 300 {
        return;
    }
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        let name = e.file_name().to_string_lossy().into_owned();
        if name.starts_with('.') || name == "__pycache__" || name == "build" {
            continue;
        }
        let path = e.path();
        if path.is_dir() {
            walk(base, &path, depth + 1, out);
        } else if let Ok(rel) = path.strip_prefix(base) {
            out.push(rel.to_string_lossy().into_owned());
        }
    }
}

fn setup_env(root: &Path) -> Result<(), String> {
    let env = env_dir(root);
    if !python(root).exists() {
        let ok = Command::new("python3").arg("-m").arg("venv").arg(&env).stdin(Stdio::null()).status().map_err(|e| format!("python3 não encontrado ({e})"))?;
        if !ok.success() {
            return Err("não consegui criar o ambiente Python".into());
        }
    }
    let pip = |pkgs: &[&str]| {
        Command::new(python(root)).args(["-m", "pip", "install", "--quiet", "--upgrade"]).args(pkgs).stdin(Stdio::null()).stdout(Stdio::null()).status()
    };
    if !pip(&["build123d"]).map_err(|e| e.to_string())?.success() {
        return Err("a instalação do build123d falhou".into());
    }
    // atopile é opcional: sem ele, a checagem elétrica usa o KiCad, se houver.
    let _ = pip(&["atopile"]);
    Ok(())
}

// MARK: Agente

/// O comando que os agentes podem rodar.
fn exe() -> String {
    std::env::current_exe().map(|p| p.to_string_lossy().into_owned()).unwrap_or_else(|_| "oficinad".into())
}

pub fn tools(read_only: bool) -> Vec<String> {
    let exe = exe();
    if read_only {
        vec!["WebSearch".into(), "WebFetch".into(), format!("Bash({exe} hw sim *)")]
    } else {
        vec![format!("Bash({exe} hw *)")]
    }
}

pub fn role(dir: &Path) -> String {
    let exe = exe();
    let dir = dir.display();
    format!(
        "Você é a Oficina de hardware: pesquisa, eletrônica, mecânica, simulação, montagem e compras de um protótipo. \
Trabalhe só na pasta do projeto ({dir}). Tudo é texto ou código que uma ferramenta confere.\n\
Arquivos do pacote:\n\
- requisitos.md: o que o produto faz, limites (peso, autonomia, custo, temperatura) e segurança.\n\
- pesquisa.md: produtos e projetos abertos parecidos, componentes candidatos com link para o datasheet.\n\
- eletrica/diagrama.mmd: diagrama de blocos em Mermaid (flowchart LR), com alimentação e barramentos (I2C, SPI, I2S, PDM...).\n\
- eletrica/mapa.md: tabela de ligações pino a pino, com tensões. Se fizer esquemático, use atopile (eletrica/*.ato).\n\
- especificacao.json: requisitos {{autonomia_h, peso_max_g, temp_max_c, custo_max_brl}}, bateria {{capacidade_mah, margem}}, \
modos [{{nome, corrente_ma, fracao}}] com frações que somam 1, pecas [{{nome, funcao, qtd, preco_brl, link, alternativa, massa_g, posicao_mm: [x,y,z]}}] \
e termica {{potencia_w, area_cm2}}. Correntes e massas vêm do datasheet; diga a fonte em pesquisa.md.\n\
- mecanica/modelo.py: modelo paramétrico em build123d, com medidas reais das peças compradas como variáveis no topo. \
Termine com `from oficina_cad import exportar` e `exportar({{\"Nome\": (parte, \"PETG\"), \"Peça comprada\": (volume_dela, None)}})`. \
Use os mesmos nomes de peças da especificação. Peças compradas entram como volumes simples para checar encaixe.\n\
- montagem.md: passo a passo numerado, ferramentas, cuidados (LiPo sempre com proteção) e o teste de cada passo.\n\
- firmware/: código inicial que liga as peças.\n\
Ferramentas: `{exe} hw sim .` (autonomia, peso, custo, calor; gera simulacoes/ e bom.csv), \
`{exe} hw build .` (roda o modelo, exporta STL/STEP, checa interferências e roda as simulações) e `{exe} hw erc .` (checagem elétrica). \
Rode exatamente assim, sem aspas, de dentro da pasta.\n\
Etapas: em Investigar, pesquise e leia o que já existe na pasta. Em Propor, compare 2 ou 3 arquiteturas e recomende uma, \
com números. Em Executar, escreva todos os arquivos e rode `hw build` (ou `hw sim`, se o CAD não estiver instalado). \
Em Verificar, rode `hw sim .`, leia simulacoes/resultado.md e reprove se alguma checagem reprovou. \
Como evidência, cite os arquivos e os números das simulações. Nunca compre nada nem envie dados para fora."
    )
}

pub fn goal(p: &Project) -> String {
    format!("Projeto de hardware \"{}\": {}", p.name, p.idea)
}

// MARK: Linha de comando (`oficinad hw …`)

fn inside(root: &Path, dir: &Path) -> Result<PathBuf, String> {
    let root = root.canonicalize().map_err(|e| e.to_string())?;
    let dir = dir.canonicalize().map_err(|_| format!("pasta {} não existe", dir.display()))?;
    if !dir.starts_with(&root) || !dir.join("projeto.json").exists() {
        return Err("rode dentro da pasta de um projeto da Oficina de hardware".into());
    }
    Ok(dir)
}

fn read_spec(dir: &Path) -> Result<Spec, String> {
    let bytes = fs::read(dir.join("especificacao.json")).map_err(|_| "especificacao.json não existe".to_string())?;
    serde_json::from_slice(&bytes).map_err(|e| format!("especificacao.json inválida: {e}"))
}

/// O relatório do CAD, se o modelo já rodou.
fn cad(dir: &Path) -> Option<serde_json::Value> {
    serde_json::from_slice(&fs::read(dir.join("mecanica/relatorio.json")).ok()?).ok()
}

pub fn simulate(dir: &Path) -> Result<(Report, String), String> {
    let mut spec = read_spec(dir)?;
    let cad = cad(dir);
    // Peças impressas: a massa vem do volume do CAD.
    if let Some(parts) = cad.as_ref().and_then(|c| c["pecas"].as_array()) {
        for c in parts {
            let Some(name) = c["nome"].as_str() else { continue };
            let mass = c["massa_g"].as_f64();
            let center: Option<[f64; 3]> = serde_json::from_value(c["centro_mm"].clone()).ok();
            match spec.pecas.iter_mut().find(|p| p.nome == name) {
                Some(p) => {
                    p.massa_g = p.massa_g.or(mass);
                    p.posicao_mm = p.posicao_mm.or(center);
                }
                None if mass.is_none() => {}
                None => spec.pecas.push(sim::Part {
                    nome: name.into(),
                    funcao: "impressa".into(),
                    massa_g: mass,
                    posicao_mm: center,
                    ..Default::default()
                }),
            }
        }
    }
    let mut report = sim::run(&spec);
    if let Some(c) = &cad {
        let clashes: Vec<String> = c["interferencias"].as_array().into_iter().flatten()
            .map(|i| format!("{} × {}", i[0].as_str().unwrap_or("?"), i[1].as_str().unwrap_or("?")))
            .collect();
        report.checks.push(Check {
            nome: "Encaixe".into(),
            valor: if clashes.is_empty() { "sem interferência".into() } else { format!("{} interferência(s)", clashes.len()) },
            limite: "nenhuma".into(),
            ok: Some(clashes.is_empty()),
            detalhe: if clashes.is_empty() { "Nenhuma peça ocupa o espaço de outra.".into() } else { clashes.join("; ") },
        });
    }
    let md = sim::markdown(&spec, &report);
    let out = dir.join("simulacoes");
    fs::create_dir_all(&out).map_err(|e| e.to_string())?;
    fs::write(out.join("resultado.json"), serde_json::to_vec_pretty(&report).unwrap_or_default()).map_err(|e| e.to_string())?;
    fs::write(out.join("resultado.md"), &md).map_err(|e| e.to_string())?;
    fs::write(dir.join("bom.csv"), sim::bom(&spec)).map_err(|e| e.to_string())?;
    Ok((report, md))
}

fn run_limited(mut cmd: Command, limit: Duration) -> Result<(bool, String), String> {
    let mut child = cmd.stdin(Stdio::null()).stdout(Stdio::piped()).stderr(Stdio::piped()).spawn().map_err(|e| e.to_string())?;
    let start = Instant::now();
    loop {
        if child.try_wait().map_err(|e| e.to_string())?.is_some() {
            break;
        }
        if start.elapsed() > limit {
            let _ = child.kill();
            return Err(format!("passou de {} s e foi interrompido", limit.as_secs()));
        }
        std::thread::sleep(Duration::from_millis(200));
    }
    let out = child.wait_with_output().map_err(|e| e.to_string())?;
    let text = format!("{}{}", String::from_utf8_lossy(&out.stdout), String::from_utf8_lossy(&out.stderr));
    let tail: String = text.chars().rev().take(3000).collect::<Vec<_>>().into_iter().rev().collect();
    Ok((out.status.success(), tail))
}

pub fn build(root: &Path, dir: &Path) -> Result<String, String> {
    let model = dir.join("mecanica/modelo.py");
    if !model.exists() {
        return Err("mecanica/modelo.py ainda não existe".into());
    }
    if !python(root).exists() {
        return Err("o ambiente de CAD não está instalado: peça para instalar na tela da Oficina de hardware. \
Enquanto isso, rode `hw sim .`".into());
    }
    let _ = fs::write(dir.join("oficina_cad.py"), CAD_HELPER);
    let mut cmd = Command::new(python(root));
    cmd.current_dir(dir).arg("mecanica/modelo.py").env("PYTHONPATH", dir).env("PYTHONDONTWRITEBYTECODE", "1");
    let (ok, out) = run_limited(cmd, Duration::from_secs(300))?;
    if !ok {
        return Err(format!("o modelo falhou:\n{out}"));
    }
    let (_, md) = simulate(dir)?;
    Ok(format!("{out}\n{md}"))
}

fn kicad_cli() -> Option<PathBuf> {
    let app = PathBuf::from("/Applications/KiCad/KiCad.app/Contents/MacOS/kicad-cli");
    if app.exists() {
        return Some(app);
    }
    Command::new("kicad-cli").arg("--version").stdout(Stdio::null()).stderr(Stdio::null()).status().ok()?.success().then(|| "kicad-cli".into())
}

pub fn erc(root: &Path, dir: &Path) -> Result<String, String> {
    let ele = dir.join("eletrica");
    let has = |ext: &str| fs::read_dir(&ele).into_iter().flatten().flatten().any(|e| e.path().extension().is_some_and(|x| x == ext));
    let ato = env_dir(root).join("bin/ato");
    if has("ato") && ato.exists() {
        let mut cmd = Command::new(ato);
        cmd.current_dir(&ele).arg("build");
        let (ok, out) = run_limited(cmd, Duration::from_secs(300))?;
        return if ok { Ok(format!("atopile compilou o esquemático.\n{out}")) } else { Err(format!("atopile encontrou problemas:\n{out}")) };
    }
    let sch = fs::read_dir(&ele).into_iter().flatten().flatten().map(|e| e.path()).find(|p| p.extension().is_some_and(|x| x == "kicad_sch"));
    if let (Some(sch), Some(kicad)) = (sch, kicad_cli()) {
        let _ = fs::create_dir_all(dir.join("simulacoes"));
        let mut cmd = Command::new(&kicad);
        cmd.args(["sch", "erc", "--exit-code-violations", "-o"]).arg(dir.join("simulacoes/erc.rpt")).arg(&sch);
        let (ok, out) = run_limited(cmd, Duration::from_secs(120))?;
        let mut svg = Command::new(&kicad);
        svg.args(["sch", "export", "svg", "-o"]).arg(&ele).arg(&sch);
        let _ = run_limited(svg, Duration::from_secs(120));
        return if ok { Ok("ERC do KiCad sem violações.".into()) } else { Err(format!("ERC do KiCad com violações (simulacoes/erc.rpt):\n{out}")) };
    }
    Err("sem esquemático para checar: escreva eletrica/*.ato (atopile) ou eletrica/*.kicad_sch. \
Sem atopile nem KiCad instalados, a checagem fica pelo mapa elétrico.".into())
}

/// `oficinad hw <sim|build|erc|bom|setup> [pasta]`. Devolve o código de saída.
pub fn cli(home: &Path, args: &[String]) -> i32 {
    let root = home.join("hardware");
    let _ = fs::create_dir_all(&root);
    let cmd = args.first().map(String::as_str).unwrap_or("");
    if cmd == "setup" {
        return match setup_env(&root) {
            Ok(()) => { println!("Ambiente de CAD pronto."); 0 }
            Err(e) => { eprintln!("{e}"); 1 }
        };
    }
    let dir = PathBuf::from(args.get(1).map(String::as_str).unwrap_or("."));
    let dir = match inside(&root, &dir) {
        Ok(d) => d,
        Err(e) => { eprintln!("{e}"); return 2 }
    };
    let result = match cmd {
        "sim" => simulate(&dir).map(|(_, md)| md),
        "bom" => read_spec(&dir).and_then(|s| fs::write(dir.join("bom.csv"), sim::bom(&s)).map_err(|e| e.to_string())).map(|_| "bom.csv gerado.".into()),
        "build" => build(&root, &dir),
        "erc" => erc(&root, &dir),
        _ => Err("uso: oficinad hw <sim|build|erc|bom|setup> [pasta]".into()),
    };
    match result {
        Ok(out) => { println!("{out}"); 0 }
        Err(e) => { eprintln!("{e}"); 1 }
    }
}

// MARK: Engine

impl Engine {
    pub fn hardware_overview(&self) -> Overview {
        Overview {
            setup: self.hardware.setup_state(),
            root: self.hardware.root.to_string_lossy().into_owned(),
            projects: self.hardware.list().into_iter().map(|p| self.hardware_view(p)).collect(),
        }
    }

    pub fn hardware_view(&self, p: Project) -> ProjectView {
        let mission = p.agent.as_deref().and_then(|a| self.factory.agent(a)).and_then(|a| a.mission);
        ProjectView {
            dir: self.hardware.root.join(&p.id).to_string_lossy().into_owned(),
            files: self.hardware.files(&p.id),
            report: self.hardware.report(&p.id),
            mission: mission.as_ref().map(|m| m.status.clone()),
            stage: mission.map(|m| m.stage),
            project: p,
        }
    }

    /// Cria o projeto, o agente dele e começa a missão. Gasta tokens:
    /// a tela pergunta antes.
    pub fn create_hardware(self: &Arc<Self>, name: &str, idea: &str) -> Result<ProjectView, String> {
        let p = self.hardware.create(name, idea, crate::usage::now())?;
        let dir = self.hardware.root.join(&p.id);
        let base: String = format!("HW-{}", p.id).chars().take(24).collect();
        let mut agent_name = base.clone();
        let mut n = 2;
        while self.factory.agent_by_name(&agent_name).is_some() {
            agent_name = format!("{}{n}", &base[..base.len().min(22)]);
            n += 1;
        }
        let spec = AgentSpec {
            name: agent_name,
            role: role(&dir),
            model: "auto".into(),
            effort: "auto".into(),
            place: "mac".into(),
            project: Some(dir.to_string_lossy().into_owned()),
            team: None,
        };
        let agent = match self.create_agent(spec) {
            Ok(a) => a,
            Err(e) => {
                self.hardware.delete(&p.id);
                return Err(e);
            }
        };
        self.hardware.set_agent(&p.id, Some(agent.id.clone()));
        self.start_mission(&agent.id, &goal(&p))?;
        Ok(self.hardware_view(self.hardware.get(&p.id).unwrap_or(p)))
    }

    pub fn delete_hardware(&self, id: &str) -> bool {
        let Some(p) = self.hardware.delete(id) else { return false };
        if let Some(a) = p.agent {
            self.delete_agent(&a);
        }
        true
    }

    pub fn is_hardware_dir(&self, dir: &Path) -> bool {
        dir.starts_with(&self.hardware.root)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn hw() -> Hardware {
        let dir = std::env::temp_dir().join(format!("oficina-hw-{}-{:?}", std::process::id(), std::thread::current().id()));
        let _ = fs::remove_dir_all(&dir);
        Hardware::open(dir)
    }

    #[test]
    fn cria_esqueleto_com_nome_seguro() {
        let h = hw();
        let p = h.create("Óculos com IA!", "câmera e microfone", 1).unwrap();
        assert_eq!(p.id, "oculos-com-ia");
        let again = h.create("Óculos com IA", "outro", 2).unwrap();
        assert_eq!(again.id, "oculos-com-ia-2");
        let files = h.files(&p.id);
        for f in ["especificacao.json", "eletrica/diagrama.mmd", "oficina_cad.py", "requisitos.md", "projeto.json"] {
            assert!(files.contains(&f.to_string()), "{f} em {files:?}");
        }
        assert!(!files.iter().any(|f| f.contains(".keep")));
        assert_eq!(h.list().len(), 2);
        assert!(h.get("../x").is_none());
        assert!(h.delete(&p.id).is_some());
        assert_eq!(h.list().len(), 1);
    }

    #[test]
    fn simulacao_le_a_especificacao_e_o_cad() {
        let h = hw();
        let p = h.create("Óculos", "ideia", 1).unwrap();
        let dir = h.root.join(&p.id);
        fs::write(dir.join("especificacao.json"), r#"{"nome":"Óculos","requisitos":{"autonomia_h":4,"peso_max_g":50},
            "bateria":{"capacidade_mah":300},"modos":[{"nome":"BLE","corrente_ma":40,"fracao":1}],
            "pecas":[{"nome":"XIAO","massa_g":4,"preco_brl":120},{"nome":"Armação"}]}"#).unwrap();
        fs::write(dir.join("mecanica/relatorio.json"), r#"{"pecas":[{"nome":"Armação","massa_g":20.5,"centro_mm":[0,0,0]}],
            "interferencias":[["XIAO","Armação",3.2]]}"#).unwrap();
        let (r, md) = simulate(&dir).unwrap();
        let peso = r.checks.iter().find(|c| c.nome == "Peso").unwrap();
        assert_eq!(peso.valor, "24,5 g");
        let encaixe = r.checks.iter().find(|c| c.nome == "Encaixe").unwrap();
        assert_eq!(encaixe.ok, Some(false));
        assert!(!r.passed());
        assert!(md.contains("Autonomia"));
        assert!(fs::read_to_string(dir.join("bom.csv")).unwrap().contains("XIAO"));
        assert!(h.report(&p.id).is_some());
        assert!(inside(&h.root, &dir).is_ok());
        assert!(inside(&h.root, &std::env::temp_dir()).is_err());
        assert!(build(&h.root, &dir).unwrap_err().contains("modelo.py"));
    }

    #[test]
    fn ferramentas_do_agente_sao_restritas() {
        assert!(tools(true).iter().any(|t| t.ends_with("hw sim *)")));
        assert!(tools(false).iter().all(|t| t.contains(" hw *)")));
        assert!(role(Path::new("/x")).contains("hw build ."));
    }
}
