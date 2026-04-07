from datetime import datetime, timedelta
import time
import requests
import matplotlib.pyplot as plt

from simglucose.simulation.env import T1DSimEnv
from simglucose.patient.t1dpatient import T1DPatient
from simglucose.sensor.cgm import CGMSensor
from simglucose.actuator.pump import InsulinPump
from simglucose.simulation.scenario import CustomScenario
from simglucose.controller.base import Action


# ----------------------------
# Setup simulator
# ----------------------------

patient = T1DPatient.withName("adult#003")
sensor = CGMSensor.withName("Dexcom")
pump = InsulinPump.withName("Insulet")

# Start simulation at 8 AM
now = datetime.now()
start_time = now.replace(hour=8, minute=0, second=0, microsecond=0)

scenario = CustomScenario(start_time=start_time, scenario=[])

env = T1DSimEnv(patient, sensor, pump, scenario)
obs = env.reset()

print("Simulator started")
print("Start time:", start_time.strftime("%H:%M"))
print("Each step = 5 minutes of simulated time\n")


ESP_IP = "192.168.0.251"


# ----------------------------
# Simulation settings
# ----------------------------

MINUTES_PER_STEP = 5
TOTAL_HOURS = 24
TOTAL_STEPS = int((TOTAL_HOURS * 60) / MINUTES_PER_STEP)

# Reduced delay
STEP_DELAY = 0.7


# ----------------------------
# Storage for plotting
# ----------------------------

times = []
glucose_values = []
insulin_values = []
carb_events = []


# ----------------------------
# Function to get ESP control
# ----------------------------

def get_control(glucose):

    r = requests.get(
        f"http://{ESP_IP}/cgm",
        params={"glucose": glucose},
        timeout=3
    )

    data = r.json()

    insulin = float(data.get("insulin", 0))
    carbs = float(data.get("carbs", 0))

    print("ESP → insulin:", insulin, "carbs:", carbs)

    return insulin, carbs


# ----------------------------
# Main simulation loop
# ----------------------------

for step in range(TOTAL_STEPS):

    sim_time = start_time + timedelta(minutes=step * MINUTES_PER_STEP)

    cgm = obs.observation.CGM
    print(f"[{sim_time.strftime('%H:%M')}] CGM:", round(cgm, 2), "mg/dL")

    insulin, carbs = get_control(cgm)

    # Inject meal if carbs received
    if carbs > 0:
        scenario.scenario.append((sim_time, carbs))
        carb_events.append((sim_time, carbs))
        print("Meal injected:", carbs, "g")

    # Store data
    times.append(sim_time)
    glucose_values.append(cgm)
    insulin_values.append(insulin)

    action = Action(basal=insulin, bolus=0)
    obs = env.step(action)

    print()

    time.sleep(STEP_DELAY)


# ----------------------------
# Plot results
# ----------------------------

fig, (ax1, ax2) = plt.subplots(2, 1, figsize=(12, 8), sharex=True)

# Glucose plot
ax1.plot(times, glucose_values, label="CGM Glucose")
ax1.axhline(70, linestyle="--", label="70 mg/dL")
ax1.axhline(180, linestyle="--", label="180 mg/dL")
ax1.set_ylabel("Glucose (mg/dL)")
ax1.set_title("24 Hour Glucose Profile")
ax1.legend()
ax1.grid(True)

# Mark meal events
for event_time, carbs in carb_events:
    ax1.axvline(event_time, linestyle=":")
    ax1.text(event_time, max(glucose_values), f"{int(carbs)}g", rotation=90,
             va="top", fontsize=8)

# Insulin plot
ax2.step(times, insulin_values, where="post", label="Insulin Delivered")
ax2.set_ylabel("Insulin")
ax2.set_xlabel("Time")
ax2.set_title("Insulin Delivery")
ax2.legend()
ax2.grid(True)

plt.tight_layout()
plt.show()