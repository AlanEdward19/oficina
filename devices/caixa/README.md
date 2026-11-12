# Caixa de som da Faísca

Um corpo para a Faísca em outro cômodo. Existe uma Faísca só: quando ela vem para cá, o anel acende na cor dela,
a caixa fala e ouve a resposta; quando ela volta para o Mac, apaga. O botão chama a Faísca para cá.

A voz é feita no Mac: o app sintetiza a fala (WAV 16 kHz) e transcreve o que a caixa gravou, sem internet. A
caixa só toca, grava e conversa com o core pela porta dos dispositivos, com um token só dela.

## Peças

| Peça | Para quê | Observação |
|---|---|---|
| Seeed XIAO ESP32-S3 **Sense** | cérebro, Wi-Fi e microfone PDM (na placa de expansão) | precisa da versão Sense, com PSRAM de 8 MB |
| MAX98357A | amplificador I2S | módulo pronto |
| Alto-falante 4 Ω, 3 W, 40 mm | fala | quanto maior a caixa, melhor o grave |
| Anel WS2812 de 12 LEDs | mostra se ela está aqui, ouvindo ou falando | 5 V |
| Botão tátil | chamar a Faísca | ligado ao GND |
| Fonte USB-C 5 V / 2 A | energia | a caixa fica ligada na tomada |

## Ligações

| De | Pino | Para |
|---|---|---|
| XIAO D8 (GPIO7) | BCLK | MAX98357A BCLK |
| XIAO D9 (GPIO8) | LRC | MAX98357A LRC |
| XIAO D10 (GPIO9) | DIN | MAX98357A DIN |
| XIAO 5V / GND | | MAX98357A VIN / GND |
| XIAO D1 (GPIO2) | dados | anel WS2812 DIN (5 V e GND do anel na fonte) |
| XIAO D0 (GPIO1) | | botão; o outro lado do botão no GND |

O microfone já está na placa Sense (GPIO41/42). D8–D10 também vão para o cartão SD da Sense, que a caixa não usa.

## Montar e gravar

1. No Mac, abra **Dispositivos…** no menu da Faísca e toque em **Parear caixa de som**. Anote o código e a porta.
2. Copie `include/config.h.example` para `include/config.h` e preencha o Wi-Fi, o IP do Mac, a porta e o código.
3. Grave: `pio run -t upload` (o PlatformIO vem com o ambiente da Oficina de hardware, ou `pip install platformio`).
4. No primeiro boot ela troca o código por um token e aparece em Dispositivos. O código vale 10 minutos e uma vez;
   se vencer, gere outro e grave de novo.

## Luzes

| Cor | Quer dizer |
|---|---|
| apagada | a Faísca está em outro lugar |
| laranja | ela está aqui |
| branca | falando (piscando: chegou um texto sem voz, com o app do Mac fechado) |
| azul | ouvindo |
| vermelha | sem Wi-Fi, ou precisa parear de novo |

## Sem hardware

O simulador faz o papel da caixa no terminal, com o mesmo protocolo:

```bash
python3 devices/caixa/simulador.py --codigo 123456 --comodo Sala
```

O que você digita é o que alguém na sala disse; `/chamar` aperta o botão; `--tocar` toca as falas.
