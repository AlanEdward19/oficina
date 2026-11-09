//! Casinhas: a caminha onde a Faísca dorme, com manta e um enfeite. Como nas
//! roupinhas, o Claude escolhe de um vocabulário fixo e cores; o app desenha.

use super::outfit::Piece;
use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Decor {
    pub id: String,
    pub name: String,
    pub theme: String,
    pub bed: Piece,
    pub blanket: Piece,
    pub extra: Piece,
    pub created_at: u64,
}

pub const BEDS: &[&str] = &["cushion", "basket", "nest", "cloud", "box"];
pub const BLANKETS: &[&str] = &["none", "plain", "stripes", "dots", "stars"];
pub const EXTRAS: &[&str] = &["none", "pillow", "moon", "plant", "lamp", "bone"];

/// A caminha que vem de fábrica, sem gastar tokens.
pub fn default_decor() -> Decor {
    Decor {
        id: "padrao".into(),
        name: "Caminha fofinha".into(),
        theme: "padrão".into(),
        bed: Piece { shape: "cushion".into(), color: "#8FA8C8".into() },
        blanket: Piece { shape: "dots".into(), color: "#F2E9DC".into() },
        extra: Piece { shape: "pillow".into(), color: "#F7D6E0".into() },
        created_at: 0,
    }
}

pub fn prompt(theme: &str, suggestion: Option<&str>) -> String {
    let wish = suggestion
        .map(|s| format!(" O usuário sugeriu: \"{}\".", s.chars().take(200).collect::<String>()))
        .unwrap_or_default();
    format!(
        "Você decora a casinha da Faísca, uma mascote em forma de gota laranja que dorme numa caminha \
dentro da Dock do Mac. Crie uma caminha com o tema \"{theme}\".{wish} Responda SOMENTE com um objeto JSON, \
sem texto antes ou depois, neste formato:\n\
{{\"name\": \"nome curto\", \
\"bed\": {{\"shape\": \"<{beds}>\", \"color\": \"#RRGGBB\"}}, \
\"blanket\": {{\"shape\": \"<{blankets}>\", \"color\": \"#RRGGBB\"}}, \
\"extra\": {{\"shape\": \"<{extras}>\", \"color\": \"#RRGGBB\"}}}}\n\
Use só as formas listadas e cores aconchegantes que combinem entre si.",
        beds = BEDS.join("|"),
        blankets = BLANKETS.join("|"),
        extras = EXTRAS.join("|"),
    )
}

fn color(v: &serde_json::Value, fallback: &str) -> String {
    let s = v.as_str().unwrap_or("");
    let ok = s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit());
    if ok { s.to_uppercase() } else { fallback.to_string() }
}

fn piece(v: &serde_json::Value, allowed: &[&str], fallback_shape: &str, fallback_color: &str) -> Piece {
    let shape = v["shape"].as_str().filter(|s| allowed.contains(s)).unwrap_or(fallback_shape);
    Piece { shape: shape.to_string(), color: color(&v["color"], fallback_color) }
}

/// Lê a resposta do modelo, aceitando texto em volta do JSON.
pub fn parse(text: &str, theme: &str, id: String, now: u64) -> Result<Decor, String> {
    let start = text.find('{').ok_or("O Claude não devolveu uma casinha.")?;
    let end = text.rfind('}').ok_or("O Claude não devolveu uma casinha.")?;
    let v: serde_json::Value = serde_json::from_str(&text[start..=end]).map_err(|_| "A casinha veio num formato inválido.")?;
    if !v["bed"].is_object() {
        return Err("A casinha veio sem caminha.".into());
    }
    let name: String = v["name"].as_str().unwrap_or(theme).trim().chars().take(30).collect();
    Ok(Decor {
        id,
        name: if name.is_empty() { theme.to_string() } else { name },
        theme: theme.to_string(),
        bed: piece(&v["bed"], BEDS, "cushion", "#8FA8C8"),
        blanket: piece(&v["blanket"], BLANKETS, "none", "#F2E9DC"),
        extra: piece(&v["extra"], EXTRAS, "none", "#FFFFFF"),
        created_at: now,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_e_valida() {
        let raw = r##"Pronto: {"name":"Pirata","bed":{"shape":"box","color":"#8b5a2b"},
            "blanket":{"shape":"skulls","color":"#000000"},"extra":{"shape":"moon","color":"#FFEE88"}}"##;
        let d = parse(raw, "pirata", "d1".into(), 3).unwrap();
        assert_eq!(d.name, "Pirata");
        assert_eq!(d.bed, Piece { shape: "box".into(), color: "#8B5A2B".into() });
        assert_eq!(d.blanket.shape, "none");
        assert_eq!(d.extra.shape, "moon");
    }

    #[test]
    fn recusa_sem_caminha() {
        assert!(parse(r#"{"name":"x"}"#, "t", "d".into(), 0).is_err());
        assert!(parse("nada", "t", "d".into(), 0).is_err());
    }

    #[test]
    fn prompt_leva_a_sugestao() {
        let p = prompt("aconchegante", Some("tema de praia"));
        assert!(p.contains("tema de praia") && p.contains("basket") && p.contains("moon"));
    }
}
