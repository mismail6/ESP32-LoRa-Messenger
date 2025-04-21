#include "Arduino.h"
#include "WiFi.h"
#include "images.h"
#include "LoRaWan_APP.h"
#include <Wire.h>  
#include "HT_SSD1306Wire.h"
#include <BLEDevice.h>
#include <BLEUtils.h>
#include <BLEServer.h>
#include <BLE2902.h>
/********************************* lora  *********************************************/
#define RF_FREQUENCY                                906800000 // Hz

#define TX_OUTPUT_POWER                             20        // dBm

#define LORA_BANDWIDTH                              0         // [0: 125 kHz,
                                                              //  1: 250 kHz,
                                                              //  2: 500 kHz,
                                                              //  3: Reserved]
#define LORA_SPREADING_FACTOR                       12         // [SF7..SF12]
#define LORA_CODINGRATE                             1         // [1: 4/5,
                                                              //  2: 4/6,
                                                              //  3: 4/7,
                                                              //  4: 4/8]
#define LORA_PREAMBLE_LENGTH                        12         // Same for Tx and Rx
#define LORA_SYMBOL_TIMEOUT                         0         // Symbols
#define LORA_FIX_LENGTH_PAYLOAD_ON                  false
#define LORA_IQ_INVERSION_ON                        false


#define RX_TIMEOUT_VALUE                            1000
#define BUFFER_SIZE                                 30 // Define the payload size here

#define SERVICE_UUID "6E400001-B5A3-F393-E0A9-E50E24DCCA9E"  // UART service UUID
#define CHARACTERISTIC_UUID_RX "6E400002-B5A3-F393-E0A9-E50E24DCCA9E"  // RX characteristic
#define CHARACTERISTIC_UUID_TX "6E400003-B5A3-F393-E0A9-E50E24DCCA9E"  // TX characteristic

char txpacket[BUFFER_SIZE];
char rxpacket[BUFFER_SIZE];

static RadioEvents_t RadioEvents;
void OnTxDone( void );
void OnTxTimeout( void );
void OnRxDone( uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr );

typedef enum
{
    LOWPOWER,
    STATE_RX,
    STATE_TX
}States_t;

int16_t txNumber;
int16_t rxNumber;
States_t state;
bool sleepMode = false;
int16_t Rssi,rxSize;

String rssi = "RSSI --";
String packSize = "--";
String packet;
String send_num;
String show_lora = "Show LoRa data";
String bluetooth_name = "Your BLE name";
String update_msg = "Initiaiting LoRa";

unsigned int counter = 0;
bool receiveflag = false; // software flag for LoRa receiver, received data makes it true.
long lastSendTime = 0;        // last send time
int interval = 1000;          // interval between sends
uint64_t chipid;
int16_t RssiDetection = 0;

BLEServer *pServer = NULL;
BLECharacteristic *pTxCharacteristic;
bool deviceConnected = false;
bool oldDeviceConnected = false;
int messageCount = 0;
String btStatus = "Disconnected";


String receivedMessage = "No message";


class MyServerCallbacks : public BLEServerCallbacks {
    void onConnect(BLEServer* pServer) {
        deviceConnected = true;
    }

    void onDisconnect(BLEServer* pServer) {
        deviceConnected = false;
        BLEDevice::startAdvertising();  // Restart advertising when disconnected
    }
};

class MyCallbacks : public BLECharacteristicCallbacks {
    void onWrite(BLECharacteristic *pCharacteristic) {
        String value = pCharacteristic->getValue();
        if (value.length() > 0) {
            receivedMessage = String(value.c_str());
        }
        state = STATE_TX;
    }
};

void OnTxDone( void )
{
	state=STATE_RX;
}

void OnTxTimeout( void )
{
  Radio.Sleep( );
	state=STATE_TX;
}

void OnRxDone( uint8_t *payload, uint16_t size, int16_t rssi, int8_t snr )
{
	rxNumber++;
  Rssi=rssi;
  rxSize=size;
  memcpy(rxpacket, payload, size );
  rxpacket[size]='\0';
  //Radio.Sleep( );

	receiveflag = true;
  state=STATE_RX;
}


void lora_init(void)
{
  Mcu.begin(HELTEC_BOARD,SLOW_CLK_TPYE);
  txNumber=0;
  Rssi=0;
  rxNumber = 0;
  RadioEvents.TxDone = OnTxDone;
  RadioEvents.TxTimeout = OnTxTimeout;
  RadioEvents.RxDone = OnRxDone;

  Radio.Init( &RadioEvents );
  Radio.SetChannel( RF_FREQUENCY );
  Radio.SetTxConfig( MODEM_LORA, TX_OUTPUT_POWER, 0, LORA_BANDWIDTH,
                                 LORA_SPREADING_FACTOR, LORA_CODINGRATE,
                                 LORA_PREAMBLE_LENGTH, LORA_FIX_LENGTH_PAYLOAD_ON,
                                 true, 0, 0, LORA_IQ_INVERSION_ON, 3000 );

  Radio.SetRxConfig( MODEM_LORA, LORA_BANDWIDTH, LORA_SPREADING_FACTOR,
                                 LORA_CODINGRATE, 0, LORA_PREAMBLE_LENGTH,
                                 LORA_SYMBOL_TIMEOUT, LORA_FIX_LENGTH_PAYLOAD_ON,
                                 0, true, 0, 0, LORA_IQ_INVERSION_ON, true );
	state=STATE_RX;
}


/********************************* lora  *********************************************/

SSD1306Wire  factory_display(0x3c, 500000, SDA_OLED, SCL_OLED, GEOMETRY_128_64, RST_OLED); // addr , freq , i2c group , resolution , rst


void logo(){
	factory_display.clear();
	factory_display.drawXbm(0,5,logo_width,logo_height,(const unsigned char *)logo_bits);
	factory_display.display();
}

bool resendflag=false;
bool deepsleepflag=false;
bool interrupt_flag = false;
void interrupt_GPIO0()
{
	interrupt_flag = true;
}
void interrupt_handle(void)
{
	if(interrupt_flag)
	{
		interrupt_flag = false;
		if(digitalRead(0)==0)
		{
			if(rxNumber <=2)
			{
				resendflag=true;
			}
			else
			{
				deepsleepflag=true;
			}
		}
	}

}
void VextON(void)
{
  pinMode(Vext,OUTPUT);
  digitalWrite(Vext, LOW);
  
}

void VextOFF(void) //Vext default OFF
{
  pinMode(Vext,OUTPUT);
  digitalWrite(Vext, HIGH);
}
void setup()
{
	Serial.begin(115200);
	VextON();
	delay(100);
	factory_display.init();
	factory_display.clear();
	factory_display.display();
	logo();
	delay(300);
	factory_display.clear();

  factory_display.drawString(0, 10, update_msg);
  factory_display.display();
  delay(1000);
  factory_display.clear();

	WiFi.disconnect(); //
	WiFi.mode(WIFI_OFF);
	delay(100);

  factory_display.drawString(0, 10, "Starting Bluetooth...");
  factory_display.display();
  // BLUETOOTH
  BLEDevice::init(bluetooth_name);
  pServer = BLEDevice::createServer();
  pServer->setCallbacks(new MyServerCallbacks());
  BLEService *pService = pServer->createService(SERVICE_UUID);
  pTxCharacteristic = pService->createCharacteristic(
      CHARACTERISTIC_UUID_TX,
      BLECharacteristic::PROPERTY_READ   |
      // BLECharacteristic::PROPERTY_WRITE  |
      BLECharacteristic::PROPERTY_NOTIFY
      // BLECharacteristic::PROPERTY_INDICATE
  );
  pTxCharacteristic->addDescriptor(new BLE2902()); // Add CCCD descriptor
  BLECharacteristic *pRxCharacteristic = pService->createCharacteristic(
      CHARACTERISTIC_UUID_RX,
      // BLECharacteristic::PROPERTY_READ   |
      BLECharacteristic::PROPERTY_WRITE
      // BLECharacteristic::PROPERTY_NOTIFY |
      // BLECharacteristic::PROPERTY_INDICATE
  );
  pRxCharacteristic->setCallbacks(new MyCallbacks());
  pService->start();

  BLEAdvertising *pAdvertising = BLEDevice::getAdvertising();
  pAdvertising->addServiceUUID(SERVICE_UUID);
  pAdvertising->setScanResponse(true);
  pAdvertising->setMinPreferred(0x06);  // helps with iPhone connections issue
  pAdvertising->setMinPreferred(0x12);
  BLEDevice::startAdvertising();
  // pServer->getAdvertising()->start();

  delay(100);
  factory_display.clear();

	chipid=ESP.getEfuseMac();//The chip ID is essentially its MAC address(length: 6 bytes).
	// Serial.printf("ESP32ChipID=%04X",(uint16_t)(chipid>>32));//print High 2 bytes
	// Serial.printf("%08X\n",(uint32_t)chipid);//print Low 4bytes.

	attachInterrupt(0,interrupt_GPIO0,FALLING);
	lora_init();
	packet ="waiting lora data!";

}


void loop()
{
  if (deviceConnected) {
    btStatus = "Connected";
  }
  else {
    btStatus = "Disconnected";
  }
    // Handle connection status changes
  if (!deviceConnected && oldDeviceConnected) {
    // Restart advertising
    pServer->startAdvertising();
    oldDeviceConnected = deviceConnected;
  }
  
  // Connection established
  if (deviceConnected && !oldDeviceConnected) {
    oldDeviceConnected = deviceConnected;
  }
  
  factory_display.drawString(0, 0, "Bluetooth: " + btStatus);

  factory_display.drawString(0, 20, "Sent: " + receivedMessage);
  
  interrupt_handle();
  if(deepsleepflag)
  {
    VextOFF();
    Radio.Sleep();
    SPI.end();
    pinMode(RADIO_DIO_1,ANALOG);
    pinMode(RADIO_NSS,ANALOG);
    pinMode(RADIO_RESET,ANALOG);
    pinMode(RADIO_BUSY,ANALOG);
    pinMode(LORA_CLK,ANALOG);
    pinMode(LORA_MISO,ANALOG);
    pinMode(LORA_MOSI,ANALOG);
    esp_sleep_enable_timer_wakeup(600*1000*(uint64_t)1000);
    esp_deep_sleep_start();
  }

  if(resendflag)
  {
    state = STATE_TX;
    resendflag = false;
  }

  if(receiveflag && (state==LOWPOWER) )
  {
    packet = "Rcvd:";
    receiveflag = false;   
    int i = 0;
    while(i < rxSize)
    {
      packet += rxpacket[i];
      i++;
    }

    // esp32 to phone
    if (deviceConnected) {
      messageCount++;
      //String message = "ESP32 ismail " + String(messageCount);
      pTxCharacteristic->setValue(packet.c_str());
      pTxCharacteristic->notify(); // Send the message via BLE
      // Serial.println("Message sent via BLE: " + message);
    }

    
    
  }

  packSize = "R_Size: ";
  packSize += String(rxSize,DEC);
  packSize += " R_rssi: ";
  packSize += String(Rssi,DEC);
  // distance
  // float P_t = -68;  // RSSI at 1m, needs calibration
  // float n = 2.7;      // Path loss exponent (adjust based on environment)
  // float distance = pow(10, (P_t - Rssi) / (10.0 * n));
  // String distanceStr = "Dist: " + String(distance, 2) + "m"; 
  
  factory_display.drawString(0, 40, packSize);
  
  switch(state)
  {
    case STATE_TX:
      factory_display.drawString(0, 10, "State: TX");
      delay(500);
      txNumber++;
      sprintf(txpacket," %s", receivedMessage);
      //Serial.printf("\r\nsending packet \"%s\" , length %d\r\n",txpacket, strlen(txpacket));
      Radio.Send( (uint8_t *)txpacket, strlen(txpacket) );
      state=LOWPOWER;
      break;
    case STATE_RX:
      factory_display.drawString(0, 10, "State: RX");
      Serial.println("into RX mode");
      Radio.Rx( 0 );
      state=LOWPOWER;
      break;
    case LOWPOWER:
      factory_display.drawString(0, 10, "State: LOWPOWER");
      Radio.IrqProcess( );
      break;
    default:
      break;
  }

  factory_display.drawString(0, 30, packet);
  factory_display.display();
  delay(1000); // Adjust the delay as needed
  factory_display.clear();
}