
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "esp_err.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "driver/gpio.h"

#include "esp_netif.h"
#include "esp_netif_ip_addr.h"
#include "esp_http_server.h"


#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"

#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/ble_gatt.h"
#include "host/ble_gap.h"

#include "esp_nimble_hci.h"

#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"

static const char *TAG = "cgm_server";

#define WIFI_SSID "EmmasiPhone"
#define WIFI_PASS "12345678"

float pending_carbs = 0; // carb input from mobile

// ------- pump configuration -------

// Pump control on GPIO 5.
// On the current hardware, HIGH turns the pump ON and LOW turns it OFF.
#define PUMP_GPIO        GPIO_NUM_5
#define PUMP_ON_LEVEL    0
#define PUMP_OFF_LEVEL   1

// ------- improved closed-loop controller configuration -------

// Glucose targets and safety limits (mg/dL)
//static const float TARGET_GLUCOSE_MGDL           = 110.0f;
static const float LOW_GLUCOSE_CUTOFF_MGDL       = 80.0f;
static const float CORRECTION_START_MGDL         = 155.0f;
static const float TREND_SUSPEND_GLUCOSE_MGDL    = 100.0f;
static const float STRONG_SUSPEND_GLUCOSE_MGDL   = 90.0f;

// Insulin parameters
static const float CARB_RATIO_G_PER_U             = 10.0f;
static const float INSULIN_SENSITIVITY_MGDL_PER_U = 80.0f;

// Basal per 5-minute control step
static const float BASAL_PER_STEP_U = 0.02f;

// Safety limits
static const float MAX_INSULIN_PER_STEP_U      = 1.0f;   // reduced from 2.0
static const float MAX_MEAL_PORTION_PER_STEP_U = 0.75f;  // meal spread limit
static const float CORRECTION_GAIN             = 0.5f;   // softer correction

// Meal insulin spreading
static float pending_meal_insulin_u = 0.0f;

// Trend tracking
static bool have_prev_glucose = false;
static float prev_glucose_mgdl = 0.0f;

// ------- improved insulin-on-board tracking -------

// 48 steps = 4 hours if each step is 5 minutes
#define IOB_HISTORY_STEPS 48

static float recent_insulin[IOB_HISTORY_STEPS] = {0};
static int recent_idx = 0;
static int recent_count = 0;

// Simple pump driver helpers
static void pump_init(void)
{
    gpio_config_t io_conf = {
        .pin_bit_mask = 1ULL << PUMP_GPIO,
        .mode = GPIO_MODE_OUTPUT,
        .pull_up_en = GPIO_PULLUP_DISABLE,
        .pull_down_en = GPIO_PULLDOWN_DISABLE,
        .intr_type = GPIO_INTR_DISABLE,
    };
    gpio_config(&io_conf);

    // Start safe: pump OFF
    gpio_set_level(PUMP_GPIO, PUMP_OFF_LEVEL);
}

// Very simple translation from insulin units to pump-on time.
// Assumptions (tunable):
//  - U100 insulin: 1 U ~= 0.01 mL
//  - Pump flow ~ 4 mL/s at full ON
// So 1 U ~= 2.5 ms of ON time.
static void pump_deliver_insulin(float insulin_units)
{
    if (insulin_units <= 0.0f) {
        return;
    }

    const float ML_PER_UNIT      = 0.01f;  // 100 U/mL
    const float FLOW_ML_PER_SEC  = 4.0f;   // from prototype note

    float volume_ml = insulin_units * ML_PER_UNIT;
    float seconds   = volume_ml / FLOW_ML_PER_SEC * 100;

    // Constrain to a reasonable pulse window for safety and responsiveness.
    if (seconds < 0.3f) {
        seconds = 0.3f;
    }
    if (seconds > 2.0f) {
        seconds = 2.0f;
    }

    uint32_t ms = (uint32_t)(seconds * 1000.0f);

    gpio_set_level(PUMP_GPIO, PUMP_ON_LEVEL);
    vTaskDelay(pdMS_TO_TICKS(ms));
    gpio_set_level(PUMP_GPIO, PUMP_OFF_LEVEL);
}

static float compute_current_iob(void)
{
    float iob = 0.0f;

    int steps_to_consider = recent_count < IOB_HISTORY_STEPS ? recent_count : IOB_HISTORY_STEPS;

    for (int age = 0; age < steps_to_consider; age++) {
        int idx = recent_idx - 1 - age;
        if (idx < 0) {
            idx += IOB_HISTORY_STEPS;
        }

        // Linear decay: newest dose weight ~1.0, oldest dose weight -> 0.0
        float weight = 1.0f - ((float)age / (float)IOB_HISTORY_STEPS);
        if (weight < 0.0f) {
            weight = 0.0f;
        }

        iob += recent_insulin[idx] * weight;
    }

    return iob;
}

static void store_insulin_dose(float dose)
{
    recent_insulin[recent_idx] = dose;
    recent_idx = (recent_idx + 1) % IOB_HISTORY_STEPS;
    if (recent_count < IOB_HISTORY_STEPS) {
        recent_count++;
    }
}

static uint16_t current_conn_handle = BLE_HS_CONN_HANDLE_NONE;

void ble_app_on_sync(void);
static int ble_gap_event(struct ble_gap_event *event, void *arg)
{
    switch (event->type) {

        case BLE_GAP_EVENT_CONNECT:
            if (event->connect.status == 0) {
                current_conn_handle = event->connect.conn_handle;
                ESP_LOGI("BLE", "Device connected! handle=%d", current_conn_handle);
            } else {
                ESP_LOGI("BLE", "Connection failed");
            }
            break;

        case BLE_GAP_EVENT_DISCONNECT:

            ESP_LOGI("BLE", "Device disconnected");

            current_conn_handle = BLE_HS_CONN_HANDLE_NONE;

            ble_app_on_sync();  // restart advertising
            break;

        case BLE_GAP_EVENT_ADV_COMPLETE:
            ESP_LOGI("BLE", "Advertising stopped");
            break;

        default:
            break;
    }

    return 0;
}

// BLE write handler
static int carb_write(uint16_t conn_handle,
                      uint16_t attr_handle,
                      struct ble_gatt_access_ctxt *ctxt,
                      void *arg)
{
    char buf[32];
    int len = ctxt->om->om_len;

    memcpy(buf, ctxt->om->om_data, len);
    buf[len] = 0;

    pending_carbs = atof(buf);

    ESP_LOGI("BLE", "Received carbs: %.1f g", pending_carbs);

    return 0;
}

/* NimBLE requires access_cb for every characteristic; CGM is notify-only so read can return empty. */
static int cgm_chr_access(uint16_t conn_handle,
                          uint16_t attr_handle,
                          struct ble_gatt_access_ctxt *ctxt,
                          void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        /* Notify-only; no stored value. Return empty or client will get nothing. */
        return 0;
    }
    return 0;
}

static uint16_t notify_handle;

static const struct ble_gatt_svc_def gatt_svcs[] = {
{
.type = BLE_GATT_SVC_TYPE_PRIMARY,
.uuid = BLE_UUID16_DECLARE(0x1234),

.characteristics = (struct ble_gatt_chr_def[]) {

{
.uuid = BLE_UUID16_DECLARE(0x5678),   // carbs input
.access_cb = carb_write,
.flags = BLE_GATT_CHR_F_WRITE,
},

{
.uuid = BLE_UUID16_DECLARE(0x5679),   // CGM data
.access_cb = cgm_chr_access,
.val_handle = &notify_handle,
.flags = BLE_GATT_CHR_F_NOTIFY,
},

{0}
}
},

{0}
};

// init bluetooth
void ble_app_on_sync(void)
{
    uint8_t addr_type;

    ble_hs_id_infer_auto(0, &addr_type);

    // advertising data
    struct ble_hs_adv_fields fields = {0};

    fields.name = (uint8_t *)"ESP32-CGM";
    fields.name_len = strlen("ESP32-CGM");
    fields.name_is_complete = 1;

    // advertise service UUID
    ble_uuid16_t svc_uuid = BLE_UUID16_INIT(0x1234);
    fields.uuids16 = &svc_uuid;
    fields.num_uuids16 = 1;
    fields.uuids16_is_complete = 1;

    ble_gap_adv_set_fields(&fields);

    struct ble_gap_adv_params adv_params = {0};
    adv_params.conn_mode = BLE_GAP_CONN_MODE_UND;
    adv_params.disc_mode = BLE_GAP_DISC_MODE_GEN;

    ble_gap_adv_start(addr_type, NULL, BLE_HS_FOREVER, &adv_params, ble_gap_event, NULL);

    ESP_LOGI("BLE", "Advertising started");
}

// nimble host
void host_task(void *param)
{
    nimble_port_run();
    nimble_port_freertos_deinit();
}

// -------- closed-loop insulin controller --------

float compute_insulin(float glucose, float carbs)
{
    float trend = 0.0f;
    if (have_prev_glucose) {
        trend = glucose - prev_glucose_mgdl;   // mg/dL per 5-minute step
    }

    // If new carbs are announced, convert to meal insulin and add to queue
    if (carbs > 0.0f) {
        pending_meal_insulin_u += carbs / CARB_RATIO_G_PER_U;
    }

    // Hard low-glucose safety stop
    if (glucose < LOW_GLUCOSE_CUTOFF_MGDL) {
        prev_glucose_mgdl = glucose;
        have_prev_glucose = true;
        store_insulin_dose(0.0f);
        return 0.0f;
    }

    float insulin = 0.0f;

    // Basal delivery
    insulin += BASAL_PER_STEP_U;

    // Deliver meal insulin gradually over multiple steps
    float meal_portion = 0.0f;
    if (pending_meal_insulin_u > 0.0f) {
        meal_portion = pending_meal_insulin_u;
        if (meal_portion > MAX_MEAL_PORTION_PER_STEP_U) {
            meal_portion = MAX_MEAL_PORTION_PER_STEP_U;
        }
        insulin += meal_portion;
    }

    // More conservative correction: only start above correction threshold
    float correction = 0.0f;
    if (glucose > CORRECTION_START_MGDL) {
        correction = CORRECTION_GAIN *
                     ((glucose - CORRECTION_START_MGDL) / INSULIN_SENSITIVITY_MGDL_PER_U);
        if (correction < 0.0f) {
            correction = 0.0f;
        }
        insulin += correction;
    }

    // Trend-based safety reduction
    // If glucose is already falling and is near the lower range, reduce insulin
    if (have_prev_glucose) {
        if (glucose < TREND_SUSPEND_GLUCOSE_MGDL && trend < -2.0f) {
            insulin *= 0.5f;
        }

        if (glucose < STRONG_SUSPEND_GLUCOSE_MGDL && trend < -1.0f) {
            insulin = 0.0f;
        }
    }

    // Subtract decaying IOB to reduce stacking
    float current_iob = compute_current_iob();
    insulin -= 0.6f * current_iob;   // partial subtraction works better than full subtraction

    // Clamp
    if (insulin < 0.0f) {
        insulin = 0.0f;
    }

    if (insulin > MAX_INSULIN_PER_STEP_U) {
        insulin = MAX_INSULIN_PER_STEP_U;
    }

    // Only subtract from pending meal insulin what was actually delivered
    float delivered_for_meal = insulin - BASAL_PER_STEP_U - correction;
    if (delivered_for_meal < 0.0f) {
        delivered_for_meal = 0.0f;
    }
    if (delivered_for_meal > pending_meal_insulin_u) {
        delivered_for_meal = pending_meal_insulin_u;
    }
    pending_meal_insulin_u -= delivered_for_meal;
    if (pending_meal_insulin_u < 0.0f) {
        pending_meal_insulin_u = 0.0f;
    }

    // Store and update trend state
    store_insulin_dose(insulin);
    prev_glucose_mgdl = glucose;
    have_prev_glucose = true;

    ESP_LOGI(TAG,
             "Controller | G=%.1f trend=%.1f carbs=%.1f meal_pending=%.2f corr=%.2f IOB=%.2f -> insulin=%.3f",
             glucose, trend, carbs, pending_meal_insulin_u, correction, current_iob, insulin);

    return insulin;
}

// ------- broadcast cgm data for app --------
void send_cgm_update(float glucose, float insulin, float carbs)
{
    if(current_conn_handle == BLE_HS_CONN_HANDLE_NONE)
    {
        ESP_LOGI("BLE", "No device connected, skipping notify");
        return;
    }

    char msg[64];

    sprintf(msg,
    "{\"glucose\":%.1f,\"insulin\":%.3f,\"carbs\":%.1f}",
    glucose,
    insulin,
    carbs);

    struct os_mbuf *om = ble_hs_mbuf_from_flat(msg, strlen(msg));

    ble_gatts_notify_custom(current_conn_handle, notify_handle, om);

    ESP_LOGI("BLE", "Sent update: %s", msg);
}

// -------- HTTP handler --------

esp_err_t cgm_handler(httpd_req_t *req)
{
    char query[100];
    char param[32];

    httpd_req_get_url_query_str(req, query, sizeof(query));
    httpd_query_key_value(query, "glucose", param, sizeof(param));

    float glucose = atof(param);

    // read carbs once
    float carbs = pending_carbs;

    // reset carbs immediately
    pending_carbs = 0;

    // compute insulin using closed-loop controller
    float insulin = compute_insulin(glucose, carbs);

    // Drive the physical pump whenever insulin is commanded.
    // Fractions of a second response are acceptable for this prototype.
    pump_deliver_insulin(insulin);
    ESP_LOGI(TAG, "Glucose: %.2f | Carbs used: %.1f | Insulin: %.3f",
         glucose, carbs, insulin);

    char response[64];
    sprintf(response, "{\"insulin\": %.3f, \"carbs\": %.1f}", insulin, carbs); //response over wifi

    send_cgm_update(glucose, insulin, carbs); //response over bluetooth

    ESP_LOGI(TAG, "CGM: %.2f -> insulin %.3f", glucose, insulin);

    httpd_resp_send(req, response, HTTPD_RESP_USE_STRLEN);

    return ESP_OK;
}


void ble_app_on_reset(int reason)
{
    ESP_LOGI("BLE", "Resetting state; reason=%d", reason);
}

// -------- start web server --------

httpd_handle_t start_server()
{
    httpd_config_t config = HTTPD_DEFAULT_CONFIG();

    httpd_handle_t server = NULL;

    if (httpd_start(&server, &config) == ESP_OK)
    {
        httpd_uri_t uri = {
            .uri = "/cgm",
            .method = HTTP_GET,
            .handler = cgm_handler,
            .user_ctx = NULL
        };

        httpd_register_uri_handler(server, &uri);
    }

    return server;
}


// -------- WiFi setup --------

static void wifi_on_got_ip(void *arg, esp_event_base_t event_base,
                          int32_t event_id, void *event_data)
{
    (void)arg;
    (void)event_base;
    if (event_id != IP_EVENT_STA_GOT_IP) {
        return;
    }
    ip_event_got_ip_t *event = (ip_event_got_ip_t *)event_data;
    ESP_LOGI(TAG, "Connected. IP: " IPSTR, IP2STR(&event->ip_info.ip));
}

void wifi_init_sta(void)
{
    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_sta();

    esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                        &wifi_on_got_ip, NULL, NULL);

    wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
    esp_wifi_init(&cfg);

    wifi_config_t wifi_config = {
        .sta = {
            .ssid = WIFI_SSID,
            .password = WIFI_PASS,
        },
    };

    esp_wifi_set_mode(WIFI_MODE_STA);
    esp_wifi_set_config(WIFI_IF_STA, &wifi_config);
    esp_wifi_start();
    esp_wifi_connect();

    ESP_LOGI(TAG, "Connecting to WiFi...");
}



// -------- main --------

void app_main(void)
{
    esp_err_t ret = nvs_flash_init();
    if (ret == ESP_ERR_NVS_NO_FREE_PAGES || ret == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_ERROR_CHECK(nvs_flash_erase());
        ret = nvs_flash_init();
    }
    ESP_ERROR_CHECK(ret);

    pump_init();

    /* nimble_port_init() initializes the BT controller and calls esp_nimble_hci_init() internally */
    ret = nimble_port_init();
    ESP_ERROR_CHECK(ret);

    ble_svc_gap_init();
    ble_svc_gap_device_name_set("ESP32-CGM");
    ble_svc_gatt_init();

    int rc = ble_gatts_count_cfg(gatt_svcs);
    ESP_ERROR_CHECK(rc == 0 ? ESP_OK : ESP_FAIL);

    rc = ble_gatts_add_svcs(gatt_svcs);
    ESP_ERROR_CHECK(rc == 0 ? ESP_OK : ESP_FAIL);

    ble_hs_cfg.reset_cb = ble_app_on_reset;
    ble_hs_cfg.sync_cb  = ble_app_on_sync;

    nimble_port_freertos_init(host_task);

    wifi_init_sta();
    vTaskDelay(pdMS_TO_TICKS(5000));
    start_server();

    ESP_LOGI(TAG, "HTTP server started");
}