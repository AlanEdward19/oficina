//! Roupinhas: o Claude escolhe peças de um vocabulário fixo e cores; o app
//! desenha. Nada do que vem do modelo é executado ou desenhado sem validação.

use serde::{Deserialize, Serialize};

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Piece {
    pub shape: String,
    pub color: String,
}

#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Outfit {
    pub id: String,
    pub name: String,
    pub theme: String,
    pub body: String,
    pub head: Piece,
    pub face: Piece,
    pub neck: Piece,
    pub badge: Option<Piece>,
    pub prop: String,
    pub created_at: u64,
}

pub const HEADS: &[&str] = &["none", "cap", "beanie", "headset", "crown", "hardhat", "wizard"];
pub const FACES: &[&str] = &["none", "glasses_round", "glasses_square", "visor", "monocle"];
pub const NECKS: &[&str] = &["none", "bowtie", "scarf", "lanyard", "tie"];
pub const PROPS: &[&str] = &["none", "laptop", "wrench", "coffee", "flask"];

pub fn prompt(theme: &str) -> String {
    format!(
        "Você desenha roupinhas para a Faísca, uma mascote em forma de gota laranja com antena. \
Crie uma roupinha com o tema \"{theme}\". Responda SOMENTE com um objeto JSON, sem texto antes ou depois, \
neste formato:\n\
{{\"name\": \"nome curto\", \"body\": \"#RRGGBB\", \
\"head\": {{\"shape\": \"<{heads}>\", \"color\": \"#RRGGBB\"}}, \
\"face\": {{\"shape\": \"<{faces}>\", \"color\": \"#RRGGBB\"}}, \
\"neck\": {{\"shape\": \"<{necks}>\", \"color\": \"#RRGGBB\"}}, \
\"badge\": {{\"shape\": \"até 3 letras\", \"color\": \"#RRGGBB\"}}, \
\"prop\": \"<{props}>\"}}\n\
Use só as formas listadas. \"body\" é a cor do corpo e deve continuar quente e amigável. \
\"badge\" pode ser null. Escolha cores que combinem entre si.",
        heads = HEADS.join("|"),
        faces = FACES.join("|"),
        necks = NECKS.join("|"),
        props = PROPS.join("|"),
    )
}

fn color(v: &serde_json::Value, fallback: &str) -> String {
    let s = v.as_str().unwrap_or("");
    let ok = s.len() == 7 && s.starts_with('#') && s[1..].chars().all(|c| c.is_ascii_hexdigit());
    if ok { s.to_uppercase() } else { fallback.to_string() }
}

fn piece(v: &serde_json::Value, allowed: &[&str]) -> Piece {
    let shape = v["shape"].as_str().filter(|s| allowed.contains(s)).unwrap_or("none");
    Piece { shape: shape.to_string(), color: color(&v["color"], "#333333") }
}

/// Lê a resposta do modelo, aceitando texto em volta do JSON.
pub fn parse(text: &str, theme: &str, id: String, now: u64) -> Result<Outfit, String> {
    let start = text.find('{').ok_or("O Claude não devolveu uma roupinha.")?;
    let end = text.rfind('}').ok_or("O Claude não devolveu uma roupinha.")?;
    let v: serde_json::Value = serde_json::from_str(&text[start..=end]).map_err(|_| "A roupinha veio num formato inválido.")?;
    let name: String = v["name"].as_str().unwrap_or(theme).chars().take(30).collect();
    let badge = v["badge"]["shape"].as_str().map(|t| {
        let text: String = t.chars().filter(|c| c.is_alphanumeric()).take(3).collect::<String>().to_uppercase();
        Piece { shape: text, color: color(&v["badge"]["color"], "#FFFFFF") }
    }).filter(|b| !b.shape.is_empty());
    let outfit = Outfit {
        id,
        name: if name.trim().is_empty() { theme.to_string() } else { name.trim().to_string() },
        theme: theme.to_string(),
        body: color(&v["body"], "#FF9E29"),
        head: piece(&v["head"], HEADS),
        face: piece(&v["face"], FACES),
        neck: piece(&v["neck"], NECKS),
        badge,
        prop: v["prop"].as_str().filter(|p| PROPS.contains(p)).unwrap_or("none").to_string(),
        created_at: now,
    };
    let pieces = [&outfit.head, &outfit.face, &outfit.neck].iter().filter(|p| p.shape != "none").count();
    if pieces == 0 && outfit.prop == "none" && outfit.badge.is_none() {
        return Err("A roupinha veio vazia.".into());
    }
    Ok(outfit)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn le_json_com_texto_em_volta_e_valida_tudo() {
        let raw = r##"Aqui está: {"name":"AI Engineer","body":"#ff9e29","head":{"shape":"headset","color":"#222222"},
            "face":{"shape":"laser_eyes","color":"#00FF00"},"neck":{"shape":"lanyard","color":"zzz"},
            "badge":{"shape":"A.I!","color":"#00AAFF"},"prop":"laptop"} pronto"##;
        let o = parse(raw, "AI Engineer", "o1".into(), 9).unwrap();
        assert_eq!(o.name, "AI Engineer");
        assert_eq!(o.body, "#FF9E29");
        assert_eq!(o.head, Piece { shape: "headset".into(), color: "#222222".into() });
        assert_eq!(o.face.shape, "none");
        assert_eq!(o.neck.color, "#333333");
        assert_eq!(o.badge.unwrap().shape, "AI");
        assert_eq!(o.prop, "laptop");
    }

    #[test]
    fn recusa_resposta_sem_json_ou_vazia() {
        assert!(parse("não sei", "x", "o".into(), 0).is_err());
        assert!(parse(r#"{"name":"nada"}"#, "x", "o".into(), 0).is_err());
    }

    #[test]
    fn prompt_lista_o_vocabulario() {
        let p = prompt("AI Engineer");
        assert!(p.contains("headset") && p.contains("laptop") && p.contains("AI Engineer"));
    }
}
