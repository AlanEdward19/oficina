//! Lê o diagrama de blocos em Mermaid (`flowchart`) e calcula onde cada bloco
//! fica, para o app desenhar sem navegador nem JavaScript. Cobre o que os
//! agentes escrevem: blocos com rótulo, setas cheias, tracejadas e grossas,
//! com ou sem texto. O resto (estilos, subgrafos) é ignorado.

use serde::Serialize;
use std::collections::HashMap;

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Node {
    pub id: String,
    pub label: String,
    /// Coluna (LR) ou linha (TD) a partir das fontes.
    pub layer: usize,
    /// Posição dentro da camada.
    pub row: usize,
    /// rect, round, circle, diamond
    pub shape: String,
}

#[derive(Clone, Debug, PartialEq, Serialize)]
pub struct Edge {
    pub from: String,
    pub to: String,
    pub label: Option<String>,
    pub dashed: bool,
    pub thick: bool,
}

#[derive(Clone, Debug, Default, PartialEq, Serialize)]
pub struct Diagram {
    /// "LR" ou "TD"
    pub direction: String,
    pub nodes: Vec<Node>,
    pub edges: Vec<Edge>,
    pub layers: usize,
}

const OPS: &[&str] = &["-.->", "-.-", "==>", "===", "-->", "---", "--x", "--o", "<-->"];
const CLOSERS: &[&str] = &["-->", "---", "==>", "===", ".->", "-.-"];

fn id_char(c: char) -> bool {
    c.is_alphanumeric() || c == '_'
}

fn clean_label(s: &str) -> String {
    let s = s.trim().trim_matches('"').trim();
    s.replace("<br/>", "\n").replace("<br>", "\n").replace("<br />", "\n")
}

struct Scanner<'a> {
    s: &'a str,
    i: usize,
}

impl<'a> Scanner<'a> {
    fn rest(&self) -> &'a str {
        &self.s[self.i..]
    }

    fn skip_ws(&mut self) {
        while let Some(c) = self.rest().chars().next() {
            if c.is_whitespace() {
                self.i += c.len_utf8();
            } else {
                break;
            }
        }
    }

    /// `id`, `id[rótulo]`, `id(rótulo)`, `id((rótulo))`, `id{rótulo}`…
    fn node(&mut self) -> Option<(String, Option<String>, &'static str)> {
        self.skip_ws();
        let start = self.i;
        while let Some(c) = self.rest().chars().next() {
            if id_char(c) || (c == '-' && !self.rest().starts_with("--") && !self.rest().starts_with("-.")) {
                self.i += c.len_utf8();
            } else {
                break;
            }
        }
        if self.i == start {
            return None;
        }
        let id = self.s[start..self.i].to_string();
        let rest = self.rest();
        let open: String = rest.chars().take_while(|c| "[({>".contains(*c)).collect();
        if open.is_empty() {
            return Some((id, None, "rect"));
        }
        let close: String = open
            .chars()
            .rev()
            .map(|c| match c {
                '[' => ']',
                '(' => ')',
                '{' => '}',
                _ => ']',
            })
            .collect();
        let body = &rest[open.len()..];
        let end = body.find(&close)?;
        let label = clean_label(&body[..end]);
        self.i += open.len() + end + close.len();
        let shape = match open.as_str() {
            "((" => "circle",
            "(" | "([" | "[(" => "round",
            "{" | "{{" => "diamond",
            _ => "rect",
        };
        Some((id, Some(label), shape))
    }

    /// Uma seta, com o texto dela se houver.
    fn edge(&mut self) -> Option<(Option<String>, bool, bool)> {
        self.skip_ws();
        let rest = self.rest();
        // Texto no meio: `-- texto -->`, `-. texto .->`, `== texto ==>`.
        for open in ["-- ", "-. ", "== "] {
            if rest.starts_with(open) {
                let after = &rest[open.len()..];
                let (pos, closer) = CLOSERS.iter().filter_map(|c| after.find(c).map(|p| (p, *c))).min_by_key(|(p, _)| *p)?;
                let label = clean_label(&after[..pos]);
                self.i += open.len() + pos + closer.len();
                // Setas mais longas (`--->`): engole o resto.
                while self.rest().starts_with('-') || self.rest().starts_with('>') {
                    self.i += 1;
                }
                return Some((Some(label).filter(|l| !l.is_empty()), open.contains('.'), open.starts_with('=')));
            }
        }
        let op = OPS.iter().filter(|o| rest.starts_with(**o)).max_by_key(|o| o.len())?;
        self.i += op.len();
        while self.rest().starts_with('-') || self.rest().starts_with('>') || self.rest().starts_with('=') {
            self.i += 1;
        }
        let mut label = None;
        self.skip_ws();
        if self.rest().starts_with('|') {
            let body = &self.rest()[1..];
            if let Some(end) = body.find('|') {
                label = Some(clean_label(&body[..end])).filter(|l| !l.is_empty());
                self.i += end + 2;
            }
        }
        Some((label, op.contains('.'), op.contains('=')))
    }
}

pub fn parse(text: &str) -> Option<Diagram> {
    let mut lines = text.lines().map(|l| l.split("%%").next().unwrap_or("").trim()).filter(|l| !l.is_empty());
    let header = lines.next()?;
    let mut words = header.split_whitespace();
    if !matches!(words.next(), Some("flowchart" | "graph")) {
        return None;
    }
    let direction = match words.next().unwrap_or("TD") {
        "LR" | "RL" => "LR",
        _ => "TD",
    };
    let mut nodes: Vec<Node> = Vec::new();
    let mut edges: Vec<Edge> = Vec::new();
    let add = |nodes: &mut Vec<Node>, id: String, label: Option<String>, shape: &str| {
        match nodes.iter_mut().find(|n| n.id == id) {
            Some(n) => {
                if let Some(l) = label {
                    n.label = l;
                    n.shape = shape.to_string();
                }
            }
            None => nodes.push(Node { label: label.unwrap_or_else(|| id.clone()), id, layer: 0, row: 0, shape: shape.to_string() }),
        }
    };
    for line in lines {
        let first = line.split_whitespace().next().unwrap_or("");
        if ["subgraph", "end", "classDef", "class", "style", "linkStyle", "click", "direction"].contains(&first) {
            continue;
        }
        for stmt in line.split(';') {
            let mut sc = Scanner { s: stmt, i: 0 };
            let Some((mut from, label, shape)) = sc.node() else { continue };
            add(&mut nodes, from.clone(), label, shape);
            while let Some((elabel, dashed, thick)) = sc.edge() {
                let Some((to, label, shape)) = sc.node() else { break };
                add(&mut nodes, to.clone(), label, shape);
                edges.push(Edge { from: from.clone(), to: to.clone(), label: elabel, dashed, thick });
                from = to;
            }
        }
    }
    if nodes.is_empty() {
        return None;
    }
    layout(&mut nodes, &edges);
    let layers = nodes.iter().map(|n| n.layer + 1).max().unwrap_or(0);
    Some(Diagram { direction: direction.into(), nodes, edges, layers })
}

/// Camada = maior caminho desde uma fonte (ciclos não passam do número de
/// blocos). Dentro da camada, ordena pela média das posições dos vizinhos.
fn layout(nodes: &mut [Node], edges: &[Edge]) {
    let index: HashMap<String, usize> = nodes.iter().enumerate().map(|(i, n)| (n.id.clone(), i)).collect();
    let pairs: Vec<(usize, usize)> = edges.iter().filter_map(|e| Some((index[&e.from], index[&e.to]))).filter(|(a, b)| a != b).collect();
    let n = nodes.len();
    let mut layer = vec![0usize; n];
    for _ in 0..n {
        let mut changed = false;
        for &(a, b) in &pairs {
            if layer[b] < layer[a] + 1 && layer[a] + 1 < n {
                layer[b] = layer[a] + 1;
                changed = true;
            }
        }
        if !changed {
            break;
        }
    }
    let max = layer.iter().copied().max().unwrap_or(0);
    let mut row = vec![0f64; n];
    let mut by_layer: Vec<Vec<usize>> = vec![Vec::new(); max + 1];
    for i in 0..n {
        by_layer[layer[i]].push(i);
    }
    for l in &by_layer {
        for (r, &i) in l.iter().enumerate() {
            row[i] = r as f64;
        }
    }
    for l in 1..=max {
        let mut order: Vec<(f64, usize)> = by_layer[l]
            .iter()
            .map(|&i| {
                let parents: Vec<f64> = pairs.iter().filter(|(_, b)| *b == i).map(|(a, _)| row[*a]).collect();
                let key = if parents.is_empty() { row[i] } else { parents.iter().sum::<f64>() / parents.len() as f64 };
                (key, i)
            })
            .collect();
        order.sort_by(|a, b| a.0.total_cmp(&b.0).then(a.1.cmp(&b.1)));
        for (r, (_, i)) in order.iter().enumerate() {
            row[*i] = r as f64;
        }
    }
    for i in 0..n {
        nodes[i].layer = layer[i];
        nodes[i].row = row[i] as usize;
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const OCULOS: &str = "flowchart LR
  USB[USB-C 5 V] --> CHG[Carregador LiPo<br/>na XIAO]
  CHG <--> BAT[LiPo 3,7 V]
  CHG --> MCU[ESP32-S3]
  MCU -- DVP --> CAM[Câmera]
  MCU -- I2S --> AMP[MAX98357A] --> SPK[Alto-falante]
  MCU -->|I2C| IMU((IMU))
  MCU -. BLE .-> PHONE{Celular}
  %% comentário
  style MCU fill:#f96
";

    #[test]
    fn le_o_diagrama_do_estudo() {
        let d = parse(OCULOS).unwrap();
        assert_eq!(d.direction, "LR");
        let get = |id: &str| d.nodes.iter().find(|n| n.id == id).unwrap();
        assert_eq!(get("CHG").label, "Carregador LiPo\nna XIAO");
        assert_eq!(get("IMU").shape, "circle");
        assert_eq!(get("PHONE").shape, "diamond");
        assert_eq!(d.nodes.len(), 9);
        let ble = d.edges.iter().find(|e| e.to == "PHONE").unwrap();
        assert_eq!((ble.label.as_deref(), ble.dashed), (Some("BLE"), true));
        assert_eq!(d.edges.iter().find(|e| e.to == "IMU").unwrap().label.as_deref(), Some("I2C"));
        assert!(d.edges.iter().any(|e| e.from == "AMP" && e.to == "SPK"));
        assert_eq!(get("USB").layer, 0);
        assert_eq!(get("MCU").layer, 2);
        assert_eq!(get("SPK").layer, 4);
        assert_eq!(d.layers, 5);
    }

    #[test]
    fn ciclo_nao_trava_e_camadas_nao_colidem() {
        let d = parse("graph TD\nA --> B\nB --> C\nC --> A\nA --> D").unwrap();
        assert_eq!(d.direction, "TD");
        assert!(d.layers <= 4);
        let mut seen = std::collections::HashSet::new();
        for n in &d.nodes {
            assert!(seen.insert((n.layer, n.row)), "dois blocos no mesmo lugar");
        }
    }

    #[test]
    fn nao_e_flowchart() {
        assert!(parse("sequenceDiagram\nA->>B: oi").is_none());
        assert!(parse("").is_none());
    }
}
