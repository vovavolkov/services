# webhook

[adnanh/webhook](https://github.com/adnanh/webhook) HTTP endpoint that runs two small scripts. This directory is a documentation copy; the live files are elsewhere (below).

## Hooks

- `manage-mc` (`scripts/manage-mc.sh`): `start` or `stop` a Minecraft stack. Payload fields `action` and `service`; runs `docker compose up -d` / `docker compose down` in `/home/vova/services/mc-<service>/`. Working directory `/var/webhook`.
- `payload` (`scripts/HTTPtoMQTT.sh`): publishes the payload field `message` to the MQTT topic `to-poppy` with `mosquitto_pub`.

Hooks are called as `http://100.79.21.111:9000/hooks/<id>` (tailnet only).

## Service

Systemd unit `webhook` ([webhook.service](webhook.service)), runs as user `vova`: `webhook -verbose -ip 100.79.21.111 -hooks /etc/webhook/hooks.json`. The `-ip` flag binds it to the Tailscale address only, so it is unreachable from the public internet regardless of UFW. The unit starts after `tailscaled` and restarts on failure in case the Tailscale address is not up yet.

## Live file locations

| Copy here | Live |
|---|---|
| `hooks.json` | `/etc/webhook/hooks.json` |
| `scripts/manage-mc.sh`, `scripts/HTTPtoMQTT.sh` | `/var/scripts/` |
| `webhook.service` (output of `systemctl cat webhook`) | `/etc/systemd/system/webhook.service` |

Nothing was redacted: the files contain no passwords, tokens or MQTT credentials.

## Reinstall

The `# /etc/systemd/system/webhook.service` header line in `webhook.service` is a `systemctl cat` comment and can stay.

```
sudo mkdir -p /etc/webhook /var/scripts /var/webhook
sudo cp hooks.json /etc/webhook/
sudo cp scripts/*.sh /var/scripts/ && sudo chmod +x /var/scripts/*.sh
sudo cp webhook.service /etc/systemd/system/
sudo systemctl daemon-reload && sudo systemctl restart webhook
```
