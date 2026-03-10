#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include "esp_wifi.h"
#include "esp_event.h"
#include "esp_log.h"
#include "nvs_flash.h"

#include "esp_netif.h"
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

#define WIFI_SSID "The Crib 2.0"
#define WIFI_PASS "21capecod"

float pending_carbs = 0; // carb input from mobile
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

// -------- insulin controller -------- (This is where the control algorithm would be implemented?)

float compute_insulin(float glucose)
{
    float target = 110.0;

    float insulin = 0.002 * (glucose - target);

    if(insulin < 0) insulin = 0;
    if(insulin > 0.05) insulin = 0.05;

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

    // compute insulin
    float insulin = compute_insulin(glucose);
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

void wifi_init_sta(void)
{
    esp_netif_init();
    esp_event_loop_create_default();
    esp_netif_create_default_wifi_sta();

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