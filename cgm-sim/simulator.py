from datetime import datetime, timedelta
import time
import requests

from simglucose.simulation.env import T1DSimEnv
from simglucose.patient.t1dpatient import T1DPatient
from simglucose.sensor.cgm import CGMSensor
from simglucose.actuator.pump import InsulinPump
from simglucose.simulation.scenario import CustomScenario
from simglucose.controller.base import Action

patient = T1DPatient.withName("adult#001")
sensor = CGMSensor.withName("Dexcom")
pump = InsulinPump.withName("Insulet")

start_time = datetime.now()

scenario = CustomScenario(start_time=start_time, scenario=[])

env = T1DSimEnv(patient, sensor, pump, scenario)

obs = env.reset()

print("Simulator started")
print("Each step = 5 minutes of simulated time\n")

ESP_IP = "192.168.2.61"


def get_control(glucose):

    r = requests.get(
        f"http://{ESP_IP}/cgm",
        params={"glucose": glucose}
    )

    data = r.json()

    insulin = float(data["insulin"])
    carbs = float(data["carbs"])

    print("ESP → insulin:", insulin, "carbs:", carbs)

    return insulin, carbs


step = 0

while True:

    cgm = obs.observation.CGM
    print("CGM:", round(cgm, 2), "mg/dL")

    insulin, carbs = get_control(cgm)

    # inject meal if carbs received
    if carbs > 0:
        meal_time = start_time + timedelta(minutes=step * 5)
        scenario.scenario.append((meal_time, carbs))
        print("Meal injected:", carbs, "g")

    action = Action(basal=insulin, bolus=0)

    obs = env.step(action)

    step += 1
    print()
    time.sleep(3)