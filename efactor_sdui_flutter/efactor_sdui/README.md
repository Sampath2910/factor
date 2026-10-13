# IoT SDUI 1.1 + 2.1 dynamic compatibility fix

This patch was built from the user's current `iot_sdui_current.zip`.

It does not change any server JSON schema.

Supported contracts:
- Legacy 1.0/1.1:
  - page.summary
  - page.components[].type=deviceGrid
  - deviceGrid.columns
  - card.fields[]
  - card.states
  - card.onTap {method,url,body}
  - deviceGrid.items[]
  - theme/header/dataSources may be absent
- Rich/current:
  - root or page theme
  - root/page dataSources
  - root components
  - root devices
  - card.zones[] + card.fields{} + card.states

When presentation values are absent, Flutter's active ThemeData is used.
No IoT-specific fallback colors, device names, models, nodes, or endpoints are invented.
