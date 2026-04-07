# group-18-capstone
# Closed-Loop Insulin Delivery System

## Overview
This project implements a prototype closed-loop insulin delivery system that integrates a glucose simulator, control algorithm, and hardware pump. The system uses simulated continuous glucose monitor (CGM) data to compute insulin dosing in real time and actuates a pump accordingly.

The goal of this project is to demonstrate a low-cost, end-to-end artificial pancreas system combining software simulation with physical hardware.

---

## Features
- Closed-loop glucose control using a custom algorithm  
- Integration with *simglucose* for realistic patient simulation  
- Real-time communication between simulator and ESP32  
- Bluetooth interface for manual carbohydrate input  
- Physical pump actuation (water-based prototype for safety)  

---

## System Architecture
The system consists of three main components:

### 1. Simulator (Python)
- Generates CGM readings using simglucose  
- Sends glucose values to ESP32 over WiFi  

### 2. Controller (ESP32 - C)
- Computes insulin delivery based on glucose + carb input  
- Implements safety constraints and insulin-on-board logic  

### 3. Pump + Mobile Interface
- Pump actuates insulin delivery (water in prototype)  
- Mobile app sends carbohydrate inputs via Bluetooth  

---

## How It Works
1. Simulator generates a glucose value every 5 minutes  
2. Value is sent to ESP32 via HTTP  
3. Controller calculates insulin dose  
4. Pump is activated based on computed dose  
5. System loops continuously (closed-loop control)  

---

## Testing
- 24-hour simulations using multiple virtual patients  
- Manual carbohydrate inputs at meal times  
- Evaluation of glucose response and insulin delivery  
- Hardware testing of pump accuracy and communication reliability  

---

## Technologies Used
- Python (*simglucose*, `requests`, `matplotlib`)  
- ESP32 (ESP-IDF, C)  
- Bluetooth Low Energy (BLE)  
- HTTP/WiFi communication  

---

## Notes
- This system is a **prototype** and is not intended for clinical use  
- Water is used instead of insulin for safe testing  
- Control parameters are tuned for simulation environments  

---
