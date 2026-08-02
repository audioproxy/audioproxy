# Examples

Small, dependency-free things to try the proxy with. Nothing here is part of the release image.

## `player.html`

A one-file browser player. Pick a preset or edit the URL, and watch what the browser makes of the response.

It exists because the difference between a render in progress and a cached variant is hard to see from `curl` and obvious in a player: a variant still encoding reports `Infinity` for duration and refuses to seek, while a cached one reports a real duration and scrubs. Presets cover the formats and option combinations from the README.

### Running it

The proxy needs to be up with a file called `track.wav` under `AP_LOCAL_ROOT` (the [Quick start](../README.md#quick-start) sets exactly that up), then:

```bash
cd examples
ruby -run -e httpd . -p 8097 --bind-address 127.0.0.1
# open http://127.0.0.1:8097/player.html
```

Any static server will do; `python3 -m http.server 8097` is the same thing.

### It has to be served, not opened

Opening the file directly (`file://`, or pasting a `data:` URL) gives the page an **opaque origin**, and Chrome will not let a non-secure origin make requests into the `loopback` address space. The failure is reported as a CORS error naming a "more-private address space", which reads as though the proxy is misconfigured. It is not: serving the page from `http://localhost` makes the origin loopback itself, and it works.

The same rule is why the proxy sends no `Access-Control-Allow-Origin`. It does not need to — `<audio>` plays cross-origin media without CORS. Anything that *reads* the bytes (`fetch`, Web Audio, `<audio crossorigin>`) would need headers the proxy does not currently send.

### Reading the diagnostics

| Field | On a render in progress | On a cached variant |
|---|---|---|
| `duration` | `Infinity` — no `Content-Length` to derive it from | the real duration |
| `seekable` | empty — nothing to seek into yet | the full range |
| `buffered` | grows as the encoder produces bytes | grows as the file transfers |

Playback starts almost immediately either way. That is the design: bytes leave as they are encoded rather than after the whole file exists. Seeking is what waits for the variant cache, and until then every request is a first request. See the [Roadmap](../README.md#roadmap).
