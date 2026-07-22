# GoodCloud live validation

Hardware dependency: replacement GL-X3000 running Wattline/wattlined.

1. Sign in and associate the X3000 by exact MAC/device ID.
2. Leave the router LAN and provision `remoteAccess(deviceID: association.goodCloudDeviceID, port: 8377)`.
3. Send `GET /api/v1/status` with the Wattline bearer. Expect HTTP 200 and wattlined JSON.
4. Send one reversible JSON mutation. Confirm authorization and exact JSON body reach wattlined once.
5. Open `GET /api/v1/events` with `Accept: text/event-stream`. Expect live SSE frames.
6. Rejoin LAN, force an SSE reconnect, and confirm the active route returns to Local.
7. Log into GoodCloud elsewhere. Expect API -1010 to show Wattline's login surface while LAN/BLE credentials remain intact.

Until these checks pass, client-side tests prove request construction and pass-through only; they do not prove the deployed GL.iNet relay forwards headers/body/SSE end-to-end.
