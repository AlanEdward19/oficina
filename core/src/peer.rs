//! Cliente HTTP mínimo para falar com outras máquinas da Oficina.
//!
//! As máquinas conversam por HTTP/1.1 simples (numa rede como o Tailscale,
//! que já cifra o tráfego). Um cliente completo trazia dezenas de crates; este
//! cobre só o que o core usa: GET e POST com JSON e token.

use std::time::Duration;
use tokio::{
    io::{AsyncReadExt, AsyncWriteExt},
    net::TcpStream,
};

const MAX_BODY: u64 = 4 * 1024 * 1024;

pub struct Reply {
    pub status: u16,
    pub body: Vec<u8>,
}

impl Reply {
    pub fn ok(&self) -> bool {
        (200..300).contains(&self.status)
    }
}

/// `http://host:porta/caminho` → ("host:porta", "/caminho").
fn split(url: &str) -> Result<(String, String), String> {
    let rest = url.strip_prefix("http://").ok_or("Só endereços http:// são aceitos entre máquinas.")?;
    let (host, path) = match rest.find('/') {
        Some(i) => (&rest[..i], &rest[i..]),
        None => (rest, "/"),
    };
    if host.is_empty() {
        return Err("Endereço sem host.".into());
    }
    let host = if host.contains(':') { host.to_string() } else { format!("{host}:80") };
    Ok((host, path.to_string()))
}

fn find(hay: &[u8], needle: &[u8]) -> Option<usize> {
    hay.windows(needle.len()).position(|w| w == needle)
}

/// Desfaz `Transfer-Encoding: chunked`.
fn dechunk(mut data: &[u8]) -> Vec<u8> {
    let mut out = Vec::new();
    while let Some(end) = find(data, b"\r\n") {
        let size_hex = String::from_utf8_lossy(&data[..end]);
        let size = usize::from_str_radix(size_hex.split(';').next().unwrap_or("").trim(), 16).unwrap_or(0);
        data = &data[end + 2..];
        if size == 0 || data.len() < size {
            break;
        }
        out.extend_from_slice(&data[..size]);
        data = data.get(size + 2..).unwrap_or(&[]);
    }
    out
}

fn parse(raw: &[u8]) -> Result<Reply, String> {
    let head_end = find(raw, b"\r\n\r\n").ok_or("Resposta HTTP incompleta.")?;
    let head = String::from_utf8_lossy(&raw[..head_end]).to_string();
    let status = head
        .lines()
        .next()
        .and_then(|l| l.split_whitespace().nth(1))
        .and_then(|c| c.parse().ok())
        .ok_or("Resposta HTTP inválida.")?;
    let body = &raw[head_end + 4..];
    let chunked = head.lines().any(|l| {
        let l = l.to_ascii_lowercase();
        l.starts_with("transfer-encoding:") && l.contains("chunked")
    });
    Ok(Reply { status, body: if chunked { dechunk(body) } else { body.to_vec() } })
}

pub async fn call(url: &str, method: &str, token: Option<&str>, body: Option<&[u8]>, timeout: Duration) -> Result<Reply, String> {
    let (host, path) = split(url)?;
    let work = async {
        let mut stream = TcpStream::connect(&host).await.map_err(|e| format!("Sem conexão com {host}: {e}"))?;
        let mut req = format!("{method} {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\nAccept: application/json\r\n");
        if let Some(t) = token {
            req.push_str(&format!("Authorization: Bearer {t}\r\n"));
        }
        match body {
            Some(b) => req.push_str(&format!("Content-Type: application/json\r\nContent-Length: {}\r\n", b.len())),
            None if method != "GET" => req.push_str("Content-Length: 0\r\n"),
            None => {}
        }
        req.push_str("\r\n");
        stream.write_all(req.as_bytes()).await.map_err(|e| e.to_string())?;
        if let Some(b) = body {
            stream.write_all(b).await.map_err(|e| e.to_string())?;
        }
        let mut raw = Vec::new();
        stream.take(MAX_BODY).read_to_end(&mut raw).await.map_err(|e| e.to_string())?;
        parse(&raw)
    };
    tokio::time::timeout(timeout, work).await.map_err(|_| format!("{host} não respondeu a tempo."))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn separa_endereco() {
        assert_eq!(split("http://10.0.0.2:7878/v1/health").unwrap(), ("10.0.0.2:7878".into(), "/v1/health".into()));
        assert_eq!(split("http://mac.local").unwrap(), ("mac.local:80".into(), "/".into()));
        assert!(split("https://x").is_err());
    }

    #[test]
    fn le_resposta_simples_e_chunked() {
        let r = parse(b"HTTP/1.1 201 Created\r\ncontent-length: 2\r\n\r\n{}").unwrap();
        assert_eq!((r.status, r.body.as_slice()), (201, &b"{}"[..]));
        assert!(r.ok());
        let c = parse(b"HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n3\r\nabc\r\n2\r\nde\r\n0\r\n\r\n").unwrap();
        assert_eq!(c.body, b"abcde");
        assert!(parse(b"lixo").is_err());
    }
}
