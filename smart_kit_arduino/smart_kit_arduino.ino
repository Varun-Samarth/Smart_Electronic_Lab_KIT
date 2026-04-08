#include <Wire.h>
#include <Adafruit_ADS1X15.h>

#define voltPin A7

Adafruit_ADS1115 ads;

float Rshunt = 0.8;   // measured shunt resistance

const String SIGNATURE = "vimlesh_kit_0001";

bool sendData = false;
bool sweepMode = false;

float sweepStart = 0.0;
float sweepEnd   = 50.0;
float sweepStep  = 0.1;

float currentVoltage = 0.0;   //  Added missing variable

String inputCommand = "";

//  Custom float mapping function
float mapfloat(float x, float in_min, float in_max, float out_min, float out_max)
{
  return (x - in_min) * (out_max - out_min) / (in_max - in_min) + out_min;
}

void setup() {
  Serial.begin(115200);
  ads.setGain(GAIN_SIXTEEN);   // ±0.256 V range
  ads.begin();

  pinMode(LED_BUILTIN, OUTPUT);
  Serial.println(SIGNATURE);
}

void loop() {

  while (Serial.available() > 0) {
    char inChar = Serial.read();
    if (inChar == '\n' || inChar == '\r') {
      if (inputCommand.length() > 0) {
        processCommand(inputCommand);
        inputCommand = "";
      }
    } else {
      inputCommand += inChar;
    }
  }

  // Keep sending signature when idle
  if (!sendData && !sweepMode) {
    static unsigned long lastSig = 0;
    if (millis() - lastSig > 2000) {
      Serial.println(SIGNATURE);
      lastSig = millis();
    }
  }

  // Simple DC data mode (optional)
  if (sendData && !sweepMode) {
  int16_t adc = ads.readADC_Differential_0_1();

  float shuntVoltage = adc * 0.0000078125;   // 7.8125 µV per bit
  float shuntcurrent = shuntVoltage / Rshunt;

   float current_mA = shuntcurrent * 1000 * 2.35 ; // 2.35 is correction factor++++++++++

  float Vadc =  analogRead(voltPin);
  float volt  = mapfloat(Vadc, 512, 592, 0, 9.03); // V

    float voltage = volt;
    float current = current_mA;

    Serial.print("{\"voltage\":");
    Serial.print(voltage, 3);
    Serial.print(",\"current\":");
    Serial.print(current, 3);
    Serial.println("}");

    delay(100);
  }

   // ---------------- SWEEP MODE ----------------
  if (sweepMode) {

    if (currentVoltage > sweepEnd) {

      sweepMode = false;
      digitalWrite(LED_BUILTIN, LOW);
      Serial.println("SWEEP_COMPLETE");
    } 
    else {

      float voltage = currentVoltage;
      float current = currentVoltage;   // Linear sweep relation

      Serial.print("{\"voltage\":");
      Serial.print(voltage, 3);
      Serial.print(",\"current\":");
      Serial.print(current, 3);
      Serial.println("}");

      currentVoltage += sweepStep;
      delay(200);
    }
  }
}

void processCommand(String cmd) {

  cmd.trim();

  if (cmd == "START_DATA") {

    sendData = true;
    sweepMode = false;
    currentVoltage = 0.0;

    digitalWrite(LED_BUILTIN, HIGH);
    Serial.println("ACK_START");
  }

  else if (cmd == "STOP_DATA") {

    sendData = false;

    digitalWrite(LED_BUILTIN, LOW);
    Serial.println("ACK_STOP");
  }

  else if (cmd == "DC_SWEEP") {

    sweepStart = 0.0;
    sweepEnd   = 50.0;
    sweepStep  = 0.1;

    sweepMode = true;
    sendData = false;
    currentVoltage = sweepStart;

    digitalWrite(LED_BUILTIN, HIGH);
    Serial.println("ACK_SWEEP_START");
  }

  else if (cmd == "STOP_SWEEP") {

    sweepMode = false;

    digitalWrite(LED_BUILTIN, LOW);
    Serial.println("ACK_SWEEP_STOP");
  }
}