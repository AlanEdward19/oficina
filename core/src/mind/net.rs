//! Rede de neurônios de disparo (integra e dispara, com vazamento).
//!
//! Canais de entrada viram trens de pulsos; interneurônios agrupados por
//! impulso integram esses pulsos e disparam; neurônios motores leem os grupos.
//! Os pesos iniciais seguem afinidades desenhadas à mão (carinho → alegria,
//! ser ignorada → carência) mais ruído. O que ela aprende fica nos pesos
//! interneurônio → motor, ajustados por recompensa com traços de elegibilidade.

pub const INPUTS: [&str; 12] = [
    "trabalhando", "ia", "ociosidade", "tarefa", "sucesso", "falha",
    "carinho", "cutucada", "ignorada", "noite", "novidade", "troca",
];
pub const MOTORS: [&str; 7] = ["alegria", "curiosidade", "tedio", "cansaco", "carencia", "foco", "iniciativa"];

pub const N_IN: usize = INPUTS.len();
pub const N_OUT: usize = MOTORS.len();
pub const N_HID: usize = 49;

const STEP: f32 = 0.1;
const RATE_TAU: f32 = 3.0;
const TRACE_TAU: f32 = 10.0;
const LEARN_RATE: f32 = 0.02;

/// Afinidade de cada canal com cada impulso: (canal, impulso, peso).
const PRIORS: &[(usize, usize, f32)] = &[
    (0, 5, 0.9), (0, 3, 0.25),
    (1, 1, 0.75), (1, 6, 0.3),
    (2, 2, 0.8), (2, 3, 0.35),
    (3, 5, 0.45), (3, 1, 0.3),
    (4, 0, 1.0), (4, 6, 0.2),
    (5, 0, -0.9), (5, 4, 0.35),
    (6, 0, 0.95), (6, 4, -0.9),
    (7, 1, 0.55), (7, 0, 0.25),
    (8, 4, 0.9), (8, 2, 0.4),
    (9, 3, 0.85),
    (10, 1, 0.9), (10, 6, 0.4),
    (11, 1, 0.35),
];

/// Ligações entre grupos e motores além do próprio impulso.
const CROSS: &[(usize, usize, f32)] = &[
    (2, 6, 0.3),   // tédio puxa iniciativa
    (1, 6, 0.3),   // curiosidade também
    (4, 6, 0.25),  // carência quer chamar atenção
    (5, 6, -0.6),  // foco do usuário segura a iniciativa
    (3, 6, -0.4),  // cansaço também
];

struct Rng(u64);

impl Rng {
    fn next(&mut self) -> f32 {
        self.0 ^= self.0 << 13;
        self.0 ^= self.0 >> 7;
        self.0 ^= self.0 << 17;
        (self.0 >> 40) as f32 / (1u64 << 24) as f32
    }
    fn signed(&mut self, scale: f32) -> f32 {
        (self.next() * 2.0 - 1.0) * scale
    }
}

pub struct Net {
    w_ih: Vec<f32>,
    w_hh: Vec<f32>,
    pub w_ho: Vec<f32>,
    v_h: Vec<f32>,
    v_o: Vec<f32>,
    spikes_h: Vec<bool>,
    spikes_o: Vec<bool>,
    pub rate_h: Vec<f32>,
    pub rate_o: Vec<f32>,
    trace: Vec<f32>,
    rng: Rng,
}

pub fn group(h: usize) -> usize {
    h % N_OUT
}

impl Net {
    pub fn new(seed: u64) -> Self {
        let mut rng = Rng(seed | 1);
        let mut w_ih = vec![0.0; N_IN * N_HID];
        for h in 0..N_HID {
            for c in 0..N_IN {
                w_ih[c * N_HID + h] = rng.signed(0.08);
            }
            for &(c, g, w) in PRIORS {
                if group(h) == g {
                    w_ih[c * N_HID + h] += w * 1.2;
                }
            }
        }
        let mut w_hh = vec![0.0; N_HID * N_HID];
        for a in 0..N_HID {
            for b in 0..N_HID {
                if a != b {
                    let same = group(a) == group(b);
                    w_hh[a * N_HID + b] = if same { 0.06 } else { rng.signed(0.03) };
                }
            }
        }
        Self {
            w_ih,
            w_hh,
            w_ho: Self::initial_readout(&mut rng),
            v_h: vec![0.0; N_HID],
            v_o: vec![0.0; N_OUT],
            spikes_h: vec![false; N_HID],
            spikes_o: vec![false; N_OUT],
            rate_h: vec![0.0; N_HID],
            rate_o: vec![0.0; N_OUT],
            trace: vec![0.0; N_HID * N_OUT],
            rng,
        }
    }

    fn initial_readout(rng: &mut Rng) -> Vec<f32> {
        let mut w = vec![0.0; N_HID * N_OUT];
        for h in 0..N_HID {
            for o in 0..N_OUT {
                let mut v = if group(h) == o { 0.45 } else { 0.0 };
                for &(g, m, x) in CROSS {
                    if group(h) == g && m == o {
                        v += x;
                    }
                }
                w[h * N_OUT + o] = v + rng.signed(0.03);
            }
        }
        w
    }

    /// Restaura o que foi aprendido, se o formato bater.
    pub fn load_readout(&mut self, w: &[f32]) {
        if w.len() == self.w_ho.len() && w.iter().all(|x| x.is_finite()) {
            self.w_ho.copy_from_slice(w);
        }
    }

    /// Avança `secs` segundos em passos de 100 ms.
    pub fn run(&mut self, input: &[f32; N_IN], secs: f32) {
        let steps = (secs / STEP).round().max(1.0) as usize;
        for _ in 0..steps.min(50) {
            self.step(input);
        }
    }

    fn step(&mut self, input: &[f32; N_IN]) {
        let fired_in: Vec<bool> = input.iter().map(|&r| self.rng.next() < r.clamp(0.0, 1.0) * 0.5).collect();
        let prev = self.spikes_h.clone();
        for h in 0..N_HID {
            let mut i = self.rng.signed(0.05);
            for (c, &f) in fired_in.iter().enumerate() {
                if f {
                    i += self.w_ih[c * N_HID + h];
                }
            }
            for (a, &f) in prev.iter().enumerate() {
                if f {
                    i += self.w_hh[a * N_HID + h];
                }
            }
            let v = self.v_h[h] * 0.6 + i;
            self.spikes_h[h] = v > 0.9;
            self.v_h[h] = if self.spikes_h[h] { 0.0 } else { v.max(-1.0) };
        }
        for o in 0..N_OUT {
            let mut i = 0.0;
            for h in 0..N_HID {
                if self.spikes_h[h] {
                    i += self.w_ho[h * N_OUT + o];
                }
            }
            let v = self.v_o[o] * 0.7 + i;
            self.spikes_o[o] = v > 1.0;
            self.v_o[o] = if self.spikes_o[o] { 0.0 } else { v.max(-1.0) };
        }
        let a = STEP / RATE_TAU;
        for h in 0..N_HID {
            self.rate_h[h] += a * (f32::from(u8::from(self.spikes_h[h])) - self.rate_h[h]);
        }
        for o in 0..N_OUT {
            self.rate_o[o] += a * (f32::from(u8::from(self.spikes_o[o])) - self.rate_o[o]);
        }
        let decay = 1.0 - STEP / TRACE_TAU;
        for h in 0..N_HID {
            for o in 0..N_OUT {
                let t = &mut self.trace[h * N_OUT + o];
                *t = *t * decay + if self.spikes_h[h] && self.spikes_o[o] { 1.0 } else { 0.0 };
            }
        }
    }

    /// Recompensa (positiva ou negativa) reforça o que acabou de acontecer.
    pub fn reward(&mut self, r: f32) {
        for (w, t) in self.w_ho.iter_mut().zip(&self.trace) {
            *w = (*w + LEARN_RATE * r * t).clamp(-1.0, 1.0);
        }
    }

    pub fn motor(&self, name: &str) -> f32 {
        MOTORS.iter().position(|m| *m == name).map(|i| self.rate_o[i]).unwrap_or(0.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn input(pairs: &[(&str, f32)]) -> [f32; N_IN] {
        let mut x = [0.0; N_IN];
        for (name, v) in pairs {
            x[INPUTS.iter().position(|n| n == name).unwrap()] = *v;
        }
        x
    }

    fn dominant(net: &Net) -> &'static str {
        let i = (0..N_OUT - 1).max_by(|a, b| net.rate_o[*a].total_cmp(&net.rate_o[*b])).unwrap();
        MOTORS[i]
    }

    #[test]
    fn sem_estimulo_fica_quieta() {
        let mut n = Net::new(7);
        n.run(&input(&[]), 20.0);
        assert!(n.rate_o.iter().all(|r| *r < 0.1), "{:?}", n.rate_o);
    }

    #[test]
    fn cada_estimulo_puxa_seu_impulso() {
        for (canal, esperado) in [("carinho", "alegria"), ("ignorada", "carencia"), ("novidade", "curiosidade"),
                                  ("trabalhando", "foco"), ("noite", "cansaco"), ("ociosidade", "tedio")] {
            let mut n = Net::new(7);
            n.run(&input(&[(canal, 1.0)]), 15.0);
            assert_eq!(dominant(&n), esperado, "{canal}: {:?}", n.rate_o);
            assert!(n.motor(esperado) > 0.3, "{canal}: {:?}", n.rate_o);
        }
    }

    #[test]
    fn foco_segura_a_iniciativa() {
        let mut livre = Net::new(7);
        livre.run(&input(&[("ociosidade", 1.0), ("novidade", 1.0)]), 15.0);
        let mut focada = Net::new(7);
        focada.run(&input(&[("ociosidade", 1.0), ("novidade", 1.0), ("trabalhando", 1.0)]), 15.0);
        assert!(livre.motor("iniciativa") > focada.motor("iniciativa") + 0.1,
                "{} vs {}", livre.motor("iniciativa"), focada.motor("iniciativa"));
    }

    #[test]
    fn falha_apaga_a_alegria() {
        let mut n = Net::new(7);
        n.run(&input(&[("carinho", 1.0), ("falha", 1.0)]), 15.0);
        let mut so_carinho = Net::new(7);
        so_carinho.run(&input(&[("carinho", 1.0)]), 15.0);
        assert!(n.motor("alegria") < so_carinho.motor("alegria"));
    }

    #[test]
    fn recompensa_muda_os_pesos_que_estavam_ativos() {
        let mut n = Net::new(7);
        n.run(&input(&[("novidade", 1.0)]), 10.0);
        let before = n.w_ho.clone();
        n.reward(1.0);
        let curiosity = MOTORS.iter().position(|m| *m == "curiosidade").unwrap();
        let grew = (0..N_HID).filter(|h| group(*h) == curiosity).any(|h| n.w_ho[h * N_OUT + curiosity] > before[h * N_OUT + curiosity]);
        assert!(grew);
        let fear = MOTORS.iter().position(|m| *m == "carencia").unwrap();
        assert!((0..N_HID).all(|h| (n.w_ho[h * N_OUT + fear] - before[h * N_OUT + fear]).abs() < 1e-6));
    }

    #[test]
    fn mesma_semente_mesmo_cerebro() {
        let (mut a, mut b) = (Net::new(42), Net::new(42));
        a.run(&input(&[("carinho", 1.0)]), 5.0);
        b.run(&input(&[("carinho", 1.0)]), 5.0);
        assert_eq!(a.rate_o, b.rate_o);
    }
}
