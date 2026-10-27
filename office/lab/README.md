# 可替換觀測後端的隔離實驗

這個實驗把同一套 Office 任務執行與 OTLP exporter 分別接到 **Phoenix 20.26.0** 與
**Jaeger 2.22.0**，再從兩個後端查回資料，確認換後端後仍保有任務、Agent 與工具的
關係。Office 使用自己的 `TracePort`；OpenTelemetry／OpenInference 位於可選的
追蹤轉接器，兩個產品的查詢 API 只出現在本目錄的驗證程式。

實驗只使用本機合成任務、暫存 SQLite 與假 CLI，不需要模型帳號。它仍會執行真正的
`Office.execute`、`CodexAgent.run`、事件正規化與 OTLP HTTP/protobuf 傳輸。
這個切片驗收觀測後端替換；正式任務的排程、儲存與多 Agent 協作是其他切片。

## 固定版本與邊界

| 元件 | 固定版本 | 實驗中的角色與儲存 |
| --- | --- | --- |
| Phoenix | 20.26.0；Compose 固定 multi-architecture image digest | AI trace viewer；獨立 `phoenix-data` volume，使用 SQLite |
| Jaeger | 2.22.0；Compose 固定 multi-architecture image digest | 通用 trace viewer；記憶體最多 1,000 traces，重啟會消失 |
| OpenTelemetry SDK／OTLP HTTP exporter | 1.45.1 | Office 的可選轉接器；依賴由 `requirements-observability.txt` 鎖定版本與 hash |
| OpenInference semantic conventions | 0.1.42 | 標示 `CHAIN`、`AGENT`、`TOOL`；不使用產品專用 SDK |

Image digest 寫在 [compose.yaml](compose.yaml)，對應官方
[Phoenix 20.26.0 release](https://github.com/Arize-ai/phoenix/releases/tag/arize-phoenix-v20.26.0)
與 [Jaeger 2.22.0 release](https://github.com/jaegertracing/jaeger/releases/tag/v2.22.0)。
本實驗的 SQLite 與記憶體設定用於小型驗證；它們不是正式環境容量或持久性的驗收。

Phoenix 的主要授權為
[Elastic License 2.0](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v20.26.0/LICENSE)，
含提供託管服務等限制；Jaeger 為
[Apache-2.0](https://github.com/jaegertracing/jaeger/blob/v2.22.0/LICENSE)。
兩者可自部署，但授權條件不同。這也是保留標準 OTLP 接口與第二套可用後端的原因。

## 啟動與驗證

以下命令從 repository 根目錄執行，需要 Docker Compose v2 與 Python 3.11 以上。
兩個 profile 可以單獨啟動；執行替換驗證時同時啟動。

```sh
python3 -m venv office/.venv-observability
office/.venv-observability/bin/python -m pip install --require-hashes -r office/requirements-observability.txt
docker compose -f office/lab/compose.yaml --profile phoenix --profile jaeger up -d --wait --wait-timeout 180
office/.venv-observability/bin/python -I office/lab/verify_backends.py --check-ui --output /tmp/nekonode-portability.json
```

| 服務 | 本機地址 | 用途 |
| --- | --- | --- |
| Phoenix | `http://127.0.0.1:6006` | Viewer、查詢 API |
| Phoenix OTLP | `http://127.0.0.1:6006/v1/traces` | HTTP/protobuf 寫入 |
| Jaeger | `http://127.0.0.1:16686` | Viewer、查詢 API |
| Jaeger OTLP | `http://127.0.0.1:4318/v1/traces` | HTTP/protobuf 寫入 |

Compose 只向 host 的 `127.0.0.1` 發布上述 ports，容器使用獨立的標準 bridge network，
讓宿主機上的 Office 與驗證程式能連線。這項設定限制對外發布的入口，沒有封鎖容器主動連外。
Phoenix 關閉 agent assistant、MCP server、外部資源、產品 telemetry 與 Prometheus。
Jaeger 使用明確的最小 pipeline，未設定對外 exporter、AI/MCP 或自身追蹤。
兩個後端不掛載 Office 的正式資料庫。

如需改 port，可設定 `PHOENIX_LAB_PORT`、`JAEGER_LAB_UI_PORT`、
`JAEGER_LAB_OTLP_PORT` 後啟動 Compose，再傳給驗證程式三個 **base URL**：

```sh
office/.venv-observability/bin/python -I office/lab/verify_backends.py \
  --phoenix-url http://127.0.0.1:16006 \
  --jaeger-query-url http://127.0.0.1:26686 \
  --jaeger-otlp-url http://127.0.0.1:14318 \
  --output /tmp/nekonode-portability.json
```

CLI 只接受字面值 loopback IP，例如 `127.0.0.1` 或 `[::1]`；不接受主機名稱、
帳密、path、query 或 fragment。查詢停用 proxy 與 redirect。驗證程式的合成執行會
清除繼承的環境變數，明確使用 `always_on`，避免 host 的抽樣率、SDK 關閉設定、
exporter headers、代理伺服器或 API keys 影響實驗。它不列印 host 環境。

關閉本實驗：

```sh
docker compose -f office/lab/compose.yaml --profile phoenix --profile jaeger down
```

這會保留 Phoenix 的實驗 volume；Jaeger 的記憶體 trace 會消失。要刪除 Phoenix
實驗資料，可明確在上述命令加 `--volumes`。

## 什麼才算通過

驗證程式會對兩個後端執行相同合成任務，唯一更換的追蹤設定是 OTLP endpoint。
每次使用獨立暫存 Store，並讓假 CLI 輸出 reasoning、web search、完成與 token usage
事件。fixture 的 prompt、檔案與工具查詢包含特定 sentinel，供檢查內容是否誤送到追蹤。

程式從 SDK 的 in-memory processor 取得這次產生的 trace/span ID，作為預期集合；
驗收資料必須由真正後端查回：

1. Phoenix：`GET /v1/projects/nekonode-replacement-lab/spans?trace_id=…&limit=100`。
2. Jaeger：`GET /api/v3/traces/{trace_id}`，使用 stable v3 API。

每次查詢的 timeout 最多 3 秒，每個後端的讀回輪詢預算 30 秒。收到寫入 HTTP 200
不算通過；Phoenix 的寫入會排入背景處理，因此必須等查詢能看到 span。

讀回後確認：

- 恰好三個 spans：`office.task` → `codex.run` → `codex.web_search`。
- 三者共用同一 trace，span ID 與父子關係符合真正執行時產生的資料。
- Task 與 Agent 保有同一 Office task ID，各 span 的完成狀態正確。
- 起訖時間與 SDK 觀察值一致；Phoenix 的微秒時間格式允許最多 2 微秒的取整差異。
- 送出的 spans、後端原始查詢與解碼屬性中沒有 fixture sentinel。
- 換後端前後，Office 的已保存成果 hash 與持久事件狀態序列一致。

`--output` 的 JSON 保存實際查回的標準化 span ID、父子關係、狀態與屬性，亦保留
後端回傳的起迄時間。程式成功時 exit 0，輸出 `Backend replacement verification: PASS`。
`--check-ui` 另外確認首頁回傳 HTTP 200 與 HTML；報告明確標記
`visually_verified: false`，它不代表已經目視操作 UI。

## 手動切換 Office 的觀測後端

已有可選追蹤依賴的隔離 Office 執行環境，可使用相同設定，只改 endpoint：

```sh
NEKO_TRACE_ENABLED=1
OTEL_TRACES_SAMPLER=always_on
OTEL_RESOURCE_ATTRIBUTES=openinference.project.name=nekonode-replacement-lab
OTEL_EXPORTER_OTLP_TRACES_ENDPOINT=http://127.0.0.1:6006/v1/traces
```

Jaeger 改成 `http://127.0.0.1:4318/v1/traces`。以上列的是程序啟動設定，套用方式請看
[觀測開發文件](../docs/observability.md)；合成驗證程式會自行設定，不需要手動 export。

通過驗收代表 **新的標準 trace 能切換後端**。它不保證 Phoenix 已有的 annotation、
evaluation、dataset 或所有歷史儲存欄位能完整搬到 Jaeger。任務、事件與成果的持久資料
仍由 Office 擁有；正式歷史資料的可攜備份與重新匯入需另行驗收。

## 不使用 Docker 的本機驗證

同一支驗證程式可指向獨立啟動的 Phoenix Python server 與 Jaeger 官方 binary。
Phoenix 應安裝在另一個 Python venv，避免其 server dependencies 混入 Office。
本次本機實驗使用 `arize-phoenix==20.26.0` 與下列固定 Jaeger artifact：

```text
https://github.com/jaegertracing/jaeger/releases/download/v2.22.0/jaeger-2.22.0-linux-amd64.tar.gz
SHA256 cb0c0be9a4b8fba424bbbc6217b0feb0adeea3bca5b73a83db1af31bb7d34389
```

Phoenix 啟動命令為 `python -m phoenix.server.main serve`，使用 Compose 內相同的
`PHOENIX_*` 設定，將 `PHOENIX_HOST` 改為 `127.0.0.1`、工作目錄設為獨立暫存目錄。
`PHOENIX_PORT` 與 `PHOENIX_GRPC_PORT` 可選未佔用的 port。
`GET /healthz` 是基本存活檢查，`GET /readyz` 另外檢查資料庫連線。

Jaeger 啟動命令為 `jaeger --config=office/lab/jaeger.yaml`；本設定原生執行時預設
loopback。可設定 `JAEGER_LAB_UI_PORT`、`JAEGER_LAB_OTLP_PORT`、
`JAEGER_LAB_QUERY_GRPC_PORT`、`JAEGER_LAB_HEALTH_PORT`，使用各自獨立 port。
此方式驗證 server package／binary 與 OTLP 相容性；固定 container image 與 Compose
啟動則由 `office-tests.yml` 的 `backend-portability` job 另行驗收。

## 上游依據

- [Docker Compose 的標準 bridge、host ports 與 internal network 邊界](https://docs.docker.com/compose/how-tos/networking/)
- [Phoenix 固定版本配置與環境變數](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v20.26.0/src/phoenix/config.py)
- [Phoenix 固定版本 OTLP 接收路由](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v20.26.0/src/phoenix/server/api/routers/v1/traces.py)
- [Phoenix 固定版本 spans 查詢路由](https://github.com/Arize-ai/phoenix/blob/arize-phoenix-v20.26.0/src/phoenix/server/api/routers/v1/spans.py)
- [Jaeger 2.22 API 與穩定性說明](https://www.jaegertracing.io/docs/2.22/architecture/apis/)
- [Jaeger 固定版本最小 memory pipeline 範例](https://github.com/jaegertracing/jaeger/blob/v2.22.0/cmd/jaeger/config-ocb-smoketest.yaml)

