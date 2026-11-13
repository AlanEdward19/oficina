# Caixa de som da Faísca

Um corpo para a Faísca em outro cômodo. Existe uma Faísca só: quando ela vem para cá, o anel acende na cor dela,
a caixa fala e ouve a resposta; quando ela volta para o Mac, apaga. O botão chama a Faísca para cá.

Não tem pareamento nem código. A caixa acha o Mac na rede sozinha, se apresenta e a Faísca avisa: "Nova caixa na
rede". A voz é feita no Mac: o app sintetiza a fala (WAV 16 kHz) e transcreve o que a caixa gravou, sem internet.

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

## Montar e ligar

1. Grave uma vez: `pio run -t upload` (o PlatformIO vem com o ambiente da Oficina de hardware, ou `pip install platformio`).
   Não há nada para configurar no código.
2. Ligue a caixa. No primeiro uso o anel fica azul e ela abre a rede **Faísca-Caixa**. Entre pelo celular, escolha o
   seu Wi-Fi e digite o cômodo.
3. Ela procura a Oficina na rede (broadcast UDP `oficina?`, respondido pelo core na porta 7879), se apresenta com o
   próprio endereço MAC e recebe um token só dela. Aparece em **Dispositivos…** e a Faísca te avisa.
4. Para mudar de Wi-Fi ou começar do zero, segure o botão por 5 segundos.

Se "Aceitar dispositivos sozinha" estiver desligado em Dispositivos, a caixa fica vermelha até você ligar.

## Luzes

| Cor | Quer dizer |
|---|---|
| apagada | a Faísca está em outro lugar |
| laranja | ela está aqui |
| branca | falando (piscando: chegou um texto sem voz, com o app do Mac fechado) |
| azul | ouvindo |
| azul fixa no começo | rede "Faísca-Caixa" aberta, esperando o Wi-Fi |
| vermelha | sem Wi-Fi, sem achar a Oficina, ou aceite automático desligado |

## Sem hardware

O simulador faz o papel da caixa no terminal, com o mesmo protocolo:

```bash
python3 devices/caixa/simulador.py --comodo Sala
```

O que você digita é o que alguém na sala disse; `/chamar` aperta o botão; `--tocar` toca as falas.
