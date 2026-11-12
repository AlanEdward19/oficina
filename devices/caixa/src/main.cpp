// Caixa de som da Faísca.
//
// Um corpo da Faísca: quando ela está aqui, o anel acende na cor dela, a caixa
// fala o que o Mac sintetizou e grava a resposta para o Mac transcrever. Quando
// ela vai embora, apaga. O botão chama a Faísca para cá.
//
// Protocolo (porta dos dispositivos da Oficina, token próprio):
//   POST /v1/body/pair    {code, room, name, kind}  -> {token}
//   GET  /v1/body/next?wait=4                        -> {commands: [...], here}
//   GET  /v1/body/audio/<id>                         -> WAV 16 kHz mono
//   POST /v1/body/audio   (WAV)                      -> o que ouviu
//   POST /v1/body/call                               -> botão

#include <Arduino.h>
#include <Adafruit_NeoPixel.h>
#include <ArduinoJson.h>
#include <HTTPClient.h>
#include <Preferences.h>
#include <WiFi.h>
#include <driver/i2s.h>

#include "config.h"

// XIAO ESP32-S3 Sense: microfone PDM na placa de expansão.
static const int PIN_PDM_CLK = 42;
static const int PIN_PDM_DATA = 41;
// MAX98357A.
static const int PIN_BCLK = 7;  // D8
static const int PIN_LRC = 8;   // D9
static const int PIN_DOUT = 9;  // D10
// Botão (para o GND) e anel de LED.
static const int PIN_BUTTON = 1;  // D0
static const int PIN_LED = 2;     // D1

static const int RATE = 16000;
static const i2s_port_t MIC = I2S_NUM_0;  // PDM só existe na I2S0
static const i2s_port_t SPEAKER = I2S_NUM_1;

static Preferences prefs;
static Adafruit_NeoPixel ring(LED_COUNT, PIN_LED, NEO_GRB + NEO_KHZ800);
static String token;
static volatile bool pressed = false;

// Cores: laranja da Faísca, azul ouvindo, branco falando, vermelho problema.
static const uint32_t ORANGE = Adafruit_NeoPixel::Color(255, 120, 20);
static const uint32_t BLUE = Adafruit_NeoPixel::Color(30, 90, 255);
static const uint32_t WHITE = Adafruit_NeoPixel::Color(180, 180, 180);
static const uint32_t RED = Adafruit_NeoPixel::Color(200, 0, 0);
static uint32_t idle = 0;

static void paint(uint32_t c) {
  ring.fill(c);
  ring.show();
}

static void IRAM_ATTR onButton() { pressed = true; }

static String url(const String& path) { return String("http://") + CORE_HOST + ":" + CORE_PORT + path; }

static void setupMic() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_RX | I2S_MODE_PDM);
  cfg.sample_rate = RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_ONLY_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.dma_buf_count = 8;
  cfg.dma_buf_len = 256;
  i2s_pin_config_t pins = {};
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
  pins.bck_io_num = I2S_PIN_NO_CHANGE;
  pins.ws_io_num = PIN_PDM_CLK;
  pins.data_out_num = I2S_PIN_NO_CHANGE;
  pins.data_in_num = PIN_PDM_DATA;
  i2s_driver_install(MIC, &cfg, 0, nullptr);
  i2s_set_pin(MIC, &pins);
}

static void setupSpeaker() {
  i2s_config_t cfg = {};
  cfg.mode = (i2s_mode_t)(I2S_MODE_MASTER | I2S_MODE_TX);
  cfg.sample_rate = RATE;
  cfg.bits_per_sample = I2S_BITS_PER_SAMPLE_16BIT;
  cfg.channel_format = I2S_CHANNEL_FMT_RIGHT_LEFT;
  cfg.communication_format = I2S_COMM_FORMAT_STAND_I2S;
  cfg.dma_buf_count = 8;
  cfg.dma_buf_len = 256;
  cfg.tx_desc_auto_clear = true;
  i2s_pin_config_t pins = {};
  pins.mck_io_num = I2S_PIN_NO_CHANGE;
  pins.bck_io_num = PIN_BCLK;
  pins.ws_io_num = PIN_LRC;
  pins.data_out_num = PIN_DOUT;
  pins.data_in_num = I2S_PIN_NO_CHANGE;
  i2s_driver_install(SPEAKER, &cfg, 0, nullptr);
  i2s_set_pin(SPEAKER, &pins);
}

static void connectWifi() {
  if (WiFi.status() == WL_CONNECTED) return;
  WiFi.mode(WIFI_STA);
  WiFi.begin(WIFI_SSID, WIFI_PASS);
  for (int i = 0; i < 60 && WiFi.status() != WL_CONNECTED; i++) {
    paint(i % 2 ? RED : 0);
    delay(250);
  }
  paint(idle);
}

/// Primeiro boot: troca o código de pareamento por um token só desta caixa.
static bool pair() {
  HTTPClient http;
  http.begin(url("/v1/body/pair"));
  http.addHeader("Content-Type", "application/json");
  JsonDocument req;
  req["code"] = PAIR_CODE;
  req["room"] = ROOM;
  req["name"] = NAME;
  req["kind"] = "caixa";
  String body;
  serializeJson(req, body);
  int code = http.POST(body);
  if (code != 200) {
    Serial.printf("pareamento recusado (%d): gere outro código e grave de novo\n", code);
    http.end();
    return false;
  }
  JsonDocument res;
  deserializeJson(res, http.getString());
  http.end();
  token = res["token"].as<String>();
  prefs.putString("token", token);
  Serial.printf("pareada: %s\n", res["name"].as<const char*>());
  return true;
}

/// Toca o WAV que o Mac sintetizou (16 kHz, mono, 16 bits), em estéreo para o MAX98357A.
static void play(const String& path) {
  HTTPClient http;
  http.begin(url(path));
  http.addHeader("Authorization", "Bearer " + token);
  if (http.GET() != 200) {
    http.end();
    return;
  }
  WiFiClient* s = http.getStreamPtr();
  int left = http.getSize();
  // Pula o cabeçalho até o bloco "data".
  uint8_t head[44];
  if (s->readBytes(head, sizeof head) != sizeof head) {
    http.end();
    return;
  }
  left -= sizeof head;
  paint(WHITE);
  static int16_t mono[256];
  static int16_t stereo[512];
  unsigned long last = millis();
  while (http.connected() && (left > 0 || left == -1)) {
    size_t avail = s->available();
    if (!avail) {
      if (millis() - last > 3000) break;
      delay(2);
      continue;
    }
    last = millis();
    size_t want = min(avail, sizeof mono);
    if (left > 0) want = min(want, (size_t)left);
    want &= ~(size_t)1;
    if (!want) break;
    size_t got = s->readBytes((uint8_t*)mono, want);
    size_t n = got / 2;
    for (size_t i = 0; i < n; i++) stereo[2 * i] = stereo[2 * i + 1] = mono[i];
    size_t written;
    i2s_write(SPEAKER, stereo, n * 4, &written, portMAX_DELAY);
    if (left > 0) left -= got;
  }
  i2s_zero_dma_buffer(SPEAKER);
  http.end();
  paint(idle);
}

static void wavHeader(uint8_t* h, uint32_t bytes) {
  auto u32 = [&](int at, uint32_t v) { memcpy(h + at, &v, 4); };
  auto u16 = [&](int at, uint16_t v) { memcpy(h + at, &v, 2); };
  memcpy(h, "RIFF", 4);
  u32(4, 36 + bytes);
  memcpy(h + 8, "WAVEfmt ", 8);
  u32(16, 16);
  u16(20, 1);
  u16(22, 1);
  u32(24, RATE);
  u32(28, RATE * 2);
  u16(32, 2);
  u16(34, 16);
  memcpy(h + 36, "data", 4);
  u32(40, bytes);
}

/// Grava até `secs` segundos: espera alguém falar e para depois de 1,2 s de silêncio.
static void listen(int secs) {
  secs = constrain(secs, 1, 15);
  size_t cap = 44 + (size_t)RATE * 2 * secs;
  uint8_t* wav = (uint8_t*)ps_malloc(cap);
  if (!wav) return;
  paint(BLUE);
  int16_t* pcm = (int16_t*)(wav + 44);
  size_t samples = 0, maxSamples = (size_t)RATE * secs;
  bool spoke = false;
  unsigned long quietSince = millis(), start = millis();
  i2s_zero_dma_buffer(MIC);
  while (samples < maxSamples) {
    int16_t chunk[256];
    size_t got = 0;
    i2s_read(MIC, chunk, sizeof chunk, &got, 100);
    size_t n = got / 2;
    long energy = 0;
    for (size_t i = 0; i < n && samples < maxSamples; i++) {
      pcm[samples++] = chunk[i];
      energy += abs(chunk[i]);
    }
    bool loud = n && energy / (long)n > 600;
    if (loud) {
      spoke = true;
      quietSince = millis();
    }
    if (spoke && millis() - quietSince > 1200) break;
    if (!spoke && millis() - start > 4000) break;  // ninguém respondeu
  }
  paint(idle);
  if (spoke) {
    uint32_t bytes = samples * 2;
    wavHeader(wav, bytes);
    HTTPClient http;
    http.begin(url("/v1/body/audio"));
    http.addHeader("Authorization", "Bearer " + token);
    http.addHeader("Content-Type", "audio/wav");
    http.POST(wav, 44 + bytes);
    http.end();
  }
  free(wav);
}

/// Sem voz do Mac: pisca no lugar de falar.
static void blink() {
  for (int i = 0; i < 3; i++) {
    paint(WHITE);
    delay(180);
    paint(idle);
    delay(180);
  }
}

static void call() {
  HTTPClient http;
  http.begin(url("/v1/body/call"));
  http.addHeader("Authorization", "Bearer " + token);
  http.addHeader("Content-Type", "application/json");
  http.POST("{}");
  http.end();
}

static void poll() {
  HTTPClient http;
  http.setTimeout(10000);
  http.begin(url("/v1/body/next?wait=4"));
  http.addHeader("Authorization", "Bearer " + token);
  int code = http.GET();
  if (code == 401) {
    // Esquecida na Oficina: precisa de um novo código.
    http.end();
    prefs.remove("token");
    token = "";
    paint(RED);
    return;
  }
  if (code != 200) {
    http.end();
    delay(2000);
    return;
  }
  JsonDocument res;
  deserializeJson(res, http.getString());
  http.end();
  idle = res["here"] | false ? ORANGE : 0;
  paint(idle);
  for (JsonObject c : res["commands"].as<JsonArray>()) {
    String kind = c["kind"] | "";
    if (kind == "arrive") {
      idle = ORANGE;
      paint(idle);
    } else if (kind == "leave") {
      idle = 0;
      paint(idle);
    } else if (kind == "say") {
      const char* audio = c["audio"];
      if (audio) play(audio);
      else blink();
    } else if (kind == "listen") {
      listen(c["secs"] | 8);
    }
  }
}

void setup() {
  Serial.begin(115200);
  ring.begin();
  ring.setBrightness(60);
  paint(0);
  pinMode(PIN_BUTTON, INPUT_PULLUP);
  attachInterrupt(PIN_BUTTON, onButton, FALLING);
  setupMic();
  setupSpeaker();
  prefs.begin("faisca", false);
  token = prefs.getString("token", "");
  connectWifi();
}

void loop() {
  connectWifi();
  if (token.isEmpty() && !pair()) {
    paint(RED);
    delay(10000);
    return;
  }
  if (pressed) {
    pressed = false;
    call();
  }
  poll();
}
