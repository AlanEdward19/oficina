//! Simulações que não precisam de ferramenta nenhuma: autonomia, peso e
//! equilíbrio, calor. Rodam em microssegundos e não gastam tokens.

use serde::{Deserialize, Serialize};

/// `especificacao.json`: o que os agentes escrevem e as simulações leem.
#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Spec {
    pub nome: String,
    pub requisitos: Requirements,
    pub bateria: Option<Battery>,
    pub modos: Vec<Mode>,
    pub pecas: Vec<Part>,
    pub termica: Option<Thermal>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Requirements {
    pub autonomia_h: Option<f64>,
    pub peso_max_g: Option<f64>,
    pub temp_max_c: Option<f64>,
    pub custo_max_brl: Option<f64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Battery {
    pub capacidade_mah: f64,
    /// Fração utilizável (0,8 por padrão).
    pub margem: Option<f64>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Mode {
    pub nome: String,
    pub corrente_ma: f64,
    /// Fração do tempo de uso (somam 1).
    pub fracao: f64,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Part {
    pub nome: String,
    pub funcao: String,
    pub qtd: Option<u32>,
    pub preco_brl: Option<f64>,
    pub link: String,
    pub alternativa: String,
    pub massa_g: Option<f64>,
    /// Centro da peça no modelo, em mm (x para a direita, y para cima, z para frente).
    pub posicao_mm: Option<[f64; 3]>,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Thermal {
    /// Potência dissipada perto da pele, em W.
    pub potencia_w: f64,
    /// Área da superfície que troca calor com o ar, em cm².
    pub area_cm2: f64,
    /// Coeficiente de convecção, W/(m²·K). Ar parado: ~10.
    pub h: Option<f64>,
    pub ambiente_c: Option<f64>,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Check {
    pub nome: String,
    pub valor: String,
    pub limite: String,
    /// true passou, false reprovou, None sem limite para comparar.
    pub ok: Option<bool>,
    pub detalhe: String,
}

#[derive(Clone, Debug, Default, Serialize, Deserialize)]
pub struct Report {
    pub checks: Vec<Check>,
    pub avisos: Vec<String>,
}

impl Report {
    pub fn passed(&self) -> bool {
        self.checks.iter().all(|c| c.ok != Some(false))
    }
}

pub struct BatteryResult {
    pub avg_ma: f64,
    pub hours: f64,
    pub share: f64,
}

pub fn battery(b: &Battery, modes: &[Mode]) -> Option<BatteryResult> {
    let share: f64 = modes.iter().map(|m| m.fracao.max(0.0)).sum();
    if b.capacidade_mah <= 0.0 || share <= 0.0 {
        return None;
    }
    // Frações que não somam 1 são normalizadas: o que importa é a proporção.
    let avg_ma: f64 = modes.iter().map(|m| m.corrente_ma.max(0.0) * m.fracao.max(0.0)).sum::<f64>() / share;
    if avg_ma <= 0.0 {
        return None;
    }
    let usable = b.capacidade_mah * b.margem.unwrap_or(0.8).clamp(0.1, 1.0);
    Some(BatteryResult { avg_ma, hours: usable / avg_ma, share })
}

pub struct MassResult {
    pub total_g: f64,
    pub center: Option<[f64; 3]>,
    pub missing: Vec<String>,
}

pub fn mass(parts: &[Part]) -> MassResult {
    let mut total = 0.0;
    let mut moment = [0.0; 3];
    let mut placed = 0.0;
    let mut missing = Vec::new();
    for p in parts {
        let Some(m) = p.massa_g else {
            missing.push(p.nome.clone());
            continue;
        };
        let m = m * p.qtd.unwrap_or(1) as f64;
        total += m;
        if let Some(pos) = p.posicao_mm {
            for i in 0..3 {
                moment[i] += pos[i] * m;
            }
            placed += m;
        }
    }
    let center = (placed > 0.0).then(|| moment.map(|v| v / placed));
    MassResult { total_g: total, center, missing }
}

/// Elevação de temperatura em regime: ΔT = P / (h · A).
pub fn thermal(t: &Thermal) -> Option<(f64, f64)> {
    let area_m2 = t.area_cm2 / 10_000.0;
    if area_m2 <= 0.0 || t.potencia_w < 0.0 {
        return None;
    }
    let rise = t.potencia_w / (t.h.unwrap_or(10.0).max(1.0) * area_m2);
    Some((rise, t.ambiente_c.unwrap_or(25.0) + rise))
}

fn n(v: f64) -> String {
    let s = if v >= 100.0 { format!("{v:.0}") } else if v >= 10.0 { format!("{v:.1}") } else { format!("{v:.2}") };
    s.replace('.', ",")
}

pub fn run(spec: &Spec) -> Report {
    let mut r = Report::default();
    let req = &spec.requisitos;
    match (&spec.bateria, spec.modos.is_empty()) {
        (Some(b), false) => match battery(b, &spec.modos) {
            Some(res) => {
                if (res.share - 1.0).abs() > 0.02 {
                    r.avisos.push(format!("As frações dos modos somam {}; usei a proporção entre elas.", n(res.share)));
                }
                let worst = spec.modos.iter().max_by(|a, b| (a.corrente_ma * a.fracao).total_cmp(&(b.corrente_ma * b.fracao)));
                r.checks.push(Check {
                    nome: "Autonomia".into(),
                    valor: format!("{} h", n(res.hours)),
                    limite: req.autonomia_h.map(|h| format!("≥ {} h", n(h))).unwrap_or_else(|| "—".into()),
                    ok: req.autonomia_h.map(|h| res.hours >= h),
                    detalhe: format!(
                        "{} mAh × {} ÷ {} mA de média. Quem mais gasta: {}.",
                        n(b.capacidade_mah),
                        n(b.margem.unwrap_or(0.8)),
                        n(res.avg_ma),
                        worst.map(|m| m.nome.as_str()).unwrap_or("—")
                    ),
                });
            }
            None => r.avisos.push("Bateria ou modos sem números válidos.".into()),
        },
        _ => r.avisos.push("Sem bateria ou modos de consumo: a autonomia não foi calculada.".into()),
    }
    if !spec.pecas.is_empty() {
        let m = mass(&spec.pecas);
        let center = m.center.map(|c| format!(" Centro de massa em ({}, {}, {}) mm.", n(c[0]), n(c[1]), n(c[2]))).unwrap_or_default();
        r.checks.push(Check {
            nome: "Peso".into(),
            valor: format!("{} g", n(m.total_g)),
            limite: req.peso_max_g.map(|g| format!("≤ {} g", n(g))).unwrap_or_else(|| "—".into()),
            ok: req.peso_max_g.map(|g| m.total_g <= g),
            detalhe: format!("Soma de {} peça(s).{center}", spec.pecas.len() - m.missing.len()),
        });
        if !m.missing.is_empty() {
            r.avisos.push(format!("Sem massa: {}.", m.missing.join(", ")));
        }
        let priced: Vec<&Part> = spec.pecas.iter().filter(|p| p.preco_brl.is_some()).collect();
        if !priced.is_empty() {
            let cost: f64 = priced.iter().map(|p| p.preco_brl.unwrap_or(0.0) * p.qtd.unwrap_or(1) as f64).sum();
            r.checks.push(Check {
                nome: "Custo".into(),
                valor: format!("R$ {}", n(cost)),
                limite: req.custo_max_brl.map(|c| format!("≤ R$ {}", n(c))).unwrap_or_else(|| "—".into()),
                ok: req.custo_max_brl.map(|c| cost <= c),
                detalhe: format!("{} de {} peça(s) com preço.", priced.len(), spec.pecas.len()),
            });
        }
    }
    if let Some(t) = &spec.termica {
        if let Some((rise, surface)) = thermal(t) {
            let limit = req.temp_max_c.unwrap_or(41.0);
            r.checks.push(Check {
                nome: "Calor".into(),
                valor: format!("{} °C", n(surface)),
                limite: format!("≤ {} °C", n(limit)),
                ok: Some(surface <= limit),
                detalhe: format!("{} W em {} cm² sobem {} °C acima do ambiente.", n(t.potencia_w), n(t.area_cm2), n(rise)),
            });
        }
    }
    r
}

pub fn markdown(spec: &Spec, r: &Report) -> String {
    let mut out = format!("# Simulações · {}\n\n", if spec.nome.is_empty() { "projeto" } else { &spec.nome });
    out.push_str("| Checagem | Valor | Limite | Resultado |\n|---|---|---|---|\n");
    for c in &r.checks {
        let res = match c.ok {
            Some(true) => "passou",
            Some(false) => "**reprovou**",
            None => "sem limite",
        };
        out.push_str(&format!("| {} | {} | {} | {res} |\n", c.nome, c.valor, c.limite));
    }
    out.push('\n');
    for c in &r.checks {
        out.push_str(&format!("- **{}**: {}\n", c.nome, c.detalhe));
    }
    if !r.avisos.is_empty() {
        out.push_str("\n## Avisos\n\n");
        for a in &r.avisos {
            out.push_str(&format!("- {a}\n"));
        }
    }
    out.push_str(&format!("\nVeredito: {}\n", if r.passed() { "passou" } else { "reprovou" }));
    out
}

fn csv(s: &str) -> String {
    if s.contains([',', '"', '\n']) { format!("\"{}\"", s.replace('"', "\"\"")) } else { s.to_string() }
}

/// A lista de materiais em CSV, a partir das peças.
pub fn bom(spec: &Spec) -> String {
    let mut out = String::from("peca,funcao,qtd,preco_brl,massa_g,link,alternativa\n");
    for p in &spec.pecas {
        out.push_str(&format!(
            "{},{},{},{},{},{},{}\n",
            csv(&p.nome),
            csv(&p.funcao),
            p.qtd.unwrap_or(1),
            p.preco_brl.map(|v| format!("{v:.2}")).unwrap_or_default(),
            p.massa_g.map(|v| format!("{v}")).unwrap_or_default(),
            csv(&p.link),
            csv(&p.alternativa)
        ));
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    fn oculos() -> Spec {
        serde_json::from_str(
            r#"{
            "nome": "Óculos com IA",
            "requisitos": {"autonomia_h": 4, "peso_max_g": 50, "custo_max_brl": 500},
            "bateria": {"capacidade_mah": 300, "margem": 0.8},
            "modos": [
                {"nome": "BLE parado", "corrente_ma": 20, "fracao": 0.85},
                {"nome": "Foto + Wi-Fi", "corrente_ma": 200, "fracao": 0.10},
                {"nome": "Áudio", "corrente_ma": 80, "fracao": 0.05}
            ],
            "pecas": [
                {"nome": "XIAO ESP32-S3 Sense", "massa_g": 4, "preco_brl": 120, "posicao_mm": [60, 0, 0]},
                {"nome": "LiPo 300 mAh", "massa_g": 6, "preco_brl": 40, "posicao_mm": [-60, 0, -40]},
                {"nome": "Armação", "massa_g": 25, "posicao_mm": [0, 0, 0]},
                {"nome": "Parafuso", "qtd": 4}
            ],
            "termica": {"potencia_w": 0.25, "area_cm2": 20}
        }"#,
        )
        .unwrap()
    }

    #[test]
    fn autonomia_do_exemplo_do_estudo() {
        let s = oculos();
        let b = battery(s.bateria.as_ref().unwrap(), &s.modos).unwrap();
        assert!((b.avg_ma - 41.0).abs() < 1e-9);
        assert!((b.hours - 240.0 / 41.0).abs() < 1e-9);
    }

    #[test]
    fn relatorio_passa_e_reprova() {
        let mut s = oculos();
        let r = run(&s);
        assert!(r.passed(), "{r:?}");
        assert_eq!(r.checks.iter().map(|c| c.nome.as_str()).collect::<Vec<_>>(), vec!["Autonomia", "Peso", "Custo", "Calor"]);
        assert!(r.avisos.iter().any(|a| a.contains("Parafuso")));
        // Wi-Fi ligado 30% do tempo: a autonomia cai abaixo de 4 h.
        s.modos[0].fracao = 0.65;
        s.modos[1].fracao = 0.30;
        let r = run(&s);
        assert!(!r.passed());
        assert_eq!(r.checks[0].ok, Some(false));
        assert!(markdown(&s, &r).contains("**reprovou**"));
    }

    #[test]
    fn centro_de_massa_e_calor() {
        let s = oculos();
        let m = mass(&s.pecas);
        assert_eq!(m.total_g, 35.0);
        let c = m.center.unwrap();
        assert!((c[0] - (240.0 - 360.0) / 35.0).abs() < 1e-9);
        let (rise, surface) = thermal(s.termica.as_ref().unwrap()).unwrap();
        assert!((rise - 0.25 / (10.0 * 0.002)).abs() < 1e-9);
        assert!((surface - 25.0 - rise).abs() < 1e-9);
    }

    #[test]
    fn bom_escapa_virgulas() {
        let s = Spec { pecas: vec![Part { nome: "Fio, 30 AWG".into(), qtd: Some(2), ..Default::default() }], ..Default::default() };
        assert_eq!(bom(&s).lines().nth(1).unwrap(), "\"Fio, 30 AWG\",,2,,,,");
    }

    #[test]
    fn especificacao_vazia_nao_quebra() {
        let r = run(&Spec::default());
        assert!(r.checks.is_empty());
        assert!(r.passed());
        assert_eq!(r.avisos.len(), 1);
    }
}
