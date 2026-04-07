from datetime import datetime
import random

import matplotlib.pyplot as plt

from simglucose.simulation.env import T1DSimEnv
from simglucose.patient.t1dpatient import T1DPatient
from simglucose.sensor.cgm import CGMSensor
from simglucose.actuator.pump import InsulinPump
from simglucose.simulation.scenario import CustomScenario
from simglucose.controller.base import Action


# -----------------------------
# create simulator
# -----------------------------

patient = T1DPatient.withName("adult#001")
sensor = CGMSensor.withName("Dexcom")
pump = InsulinPump.withName("Insulet")

start_time = datetime.now()

# realistic meal schedule
meals = [
    (60, random.randint(40,60)),   # breakfast
    (120, random.randint(10,20)),  # snack
    (300, random.randint(50,70)),  # lunch
    (480, random.randint(10,20)),  # snack
    (720, random.randint(60,80))   # dinner
]

scenario = CustomScenario(start_time=start_time, scenario=meals)

env = T1DSimEnv(patient, sensor, pump, scenario)

obs = env.reset()


# -----------------------------
# logging
# -----------------------------

cgm_log = []
insulin_log = []
time_log = []

steps = 288   # 24 hours (5 min per step)

for step in range(steps):

    cgm = obs.observation.CGM

    # simple glucose controller
    target = 110

    insulin = 0.002 * (cgm - target)

    insulin = max(0, min(insulin, 0.05))

    action = Action(basal=insulin, bolus=0)

    obs = env.step(action)

    cgm_log.append(cgm)
    insulin_log.append(insulin)
    time_log.append(step*5/60)


# -----------------------------
# plot results
# -----------------------------

plt.figure(figsize=(12,6))

plt.subplot(2,1,1)
plt.plot(time_log, cgm_log)
plt.axhline(70, linestyle="--")
plt.axhline(180, linestyle="--")
plt.ylabel("CGM (mg/dL)")
plt.title("24 Hour Glucose Simulation")

plt.subplot(2,1,2)
plt.plot(time_log, insulin_log)
plt.ylabel("Insulin (U/min)")
plt.xlabel("Hours")

plt.tight_layout()
plt.show()