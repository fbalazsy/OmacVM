# Offline USB composition regressions

Run on macOS with Swift and a compatible SDK. Set `TMPDIR` to an owned scratch
folder and, if needed, `SDKROOT` to the chosen SDK. Each output directory must
be new; logs, fixture usb.json files and socket transcripts stay there.

```sh
python3 app/tests/usb-lifecycle/run.py /absolute/owned/ui-output
python3 app/tests/usb-lifecycle/sockets.py /absolute/owned/socket-output
```

- `run.py`: real `USBListBefore` and `USBRun.setPlan/forget`, exact/wildcard
  ordinary seeds, both set-first and Forget-first, Mac/Omarchy/Ask and reload.
  A target matches only its raw `hidSerial`; it must never borrow an ordinary
  key. Both inventories include an ordinary device with the same normalized
  serial. The runner copies app sources, expands the unavailable `@Entry`
  macro and exposes only the private session field in that copy. It replaces
  the entrypoint, never instantiates AppDelegate, starts no watcher and prohibits
  app activation. This fixture build is **not an official full-app build**.
- `sockets.py`: exact production `USBQMPSocket`, `USBQMPMachine`,
  `QMPConnection`, `USBSession` and startup model against inert Unix peers.
  Covers distinct raw serials with equal normalized serial, same-raw replug,
  both parent/HID snapshot completion orders through the real state tracker,
  valid/ambiguous/rejected deletes and rollbacks, and successful Disconnect
  retry without another add. Retained fake QOM ownership is independent of
  empty `info usb`. No test connects to a live QMP socket or enumerates USB.
- `swift run --jobs 1 usb-tests --offline` (from `app/app`): the existing
  broader unit suite, including raw identity and notification-order regressions.

- Raw HID comparisons use an ASCII encoding of the exact UTF-8 bytes, not
  Swift's canonical String equality. `hidSerial` in JSON and `serial` on QMP
  stay raw; ordinary serial cleaning and canonical equality stay unchanged.
  The fixtures cover composed/decomposed Unicode, display collisions, equal
  choices, entry equality/firstIndex, key sets, decode dedupe and both UI paths.
- Late publication distinguishes an automatic ordinary route from an explicit
  question answer or list Connect/Disconnect. The Mac/Ask/Omarchy matrix uses
  both tracker completion orders; an already-connected parent retains its
  existing transition. Keep/Always and next-plug picker choices remain separate
  through repeated incomplete snapshots. Production socket transcripts assert
  raw serials, HID registry generations and absence of ordinary fallback args.

These gates do not establish policy parity with native code, physical IOHID
access, guest transfers, first-use signing/TCC, deployment or hardware acceptance.
No runtime dependency or parallel persistence/lifecycle implementation is added.
