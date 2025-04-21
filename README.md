# LoRa-ESP32-Messenger
This project implements a communication system using LoRa radio technology. 
It enables long-range, low-power messaging without reliance on cellular or Wi-Fi networks.

How it works:
 Phone <---> [ESP32] <-------------radio--------------------> [ESP32] <---> Phone

Both users hold the powered esp32 hardware with antenna. When one user sends a message, it transmits to their esp32 via bluetooth, then their esp32 sends that message to the other esp32 far away. Then finally, the second esp32 relays that message via bluetooth to the receiver. This way, both users can text bi-directionally over long distances (About 2-10 miles, depending on area).

You can play around with these values to change the range and power of transmission:
```cpp
#define TX_OUTPUT_POWER                             20        // dBm
#define LORA_SPREADING_FACTOR                       12         // [SF7..SF12]
#define LORA_PREAMBLE_LENGTH                        12         // Same for Tx and Rx
```
