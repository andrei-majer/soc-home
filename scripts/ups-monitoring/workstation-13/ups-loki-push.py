#!/usr/bin/env python3
r"""
.13 (Windows workstation) Richcomm UPS collector  ->  Loki on .120 (host="13").

The UPS is a Cypress 0665:5161 (Megatec/Q1), same chip as .15/.1, but on Windows
its firmware can only be driven via raw USB control+interrupt transfers -- the
Windows HID stack can't issue those. So the device is bound to **WinUSB** (one-time,
via Zadig) and this collector talks to it with libusb (pyusb), replicating NUT
nutdrv_qx's 'cypress' subdriver framing. One logfmt line per run, same schema as
the .15/.1 collectors, pushed to Loki.

Deps (global C:\Python):  pip install pyusb libusb-package
Run:  python ups-loki-push.py            # push one sample to Loki
      python ups-loki-push.py --print    # also print parsed values (no errors swallowed)
Scheduled every minute as SYSTEM (see install-task.ps1).
"""
import os, sys, json, time, urllib.request, traceback

VID, PID = 0x0665, 0x5161
LOKI = "http://192.168.1.120:3100/loki/api/v1/push"
HOST = "13"
LOG = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "soc-ups", "ups-collect.log")

def log(msg):
    try:
        os.makedirs(os.path.dirname(LOG), exist_ok=True)
        with open(LOG, "a", encoding="utf-8") as f:
            f.write("%s %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass

# --- USB: nutdrv_qx 'cypress' subdriver framing over libusb ------------------
def open_dev():
    import usb.core, usb.util, libusb_package
    dev = libusb_package.find(idVendor=VID, idProduct=PID)
    if dev is None:
        raise RuntimeError("UPS 0665:5161 not found (bound to WinUSB?)")
    try:
        dev.set_configuration()
    except Exception:
        pass  # WinUSB auto-configures
    intf = dev.get_active_configuration()[(0, 0)]
    ep_in = usb.util.find_descriptor(
        intf, custom_match=lambda e:
        usb.util.endpoint_direction(e.bEndpointAddress) == usb.util.ENDPOINT_IN
        and usb.util.endpoint_type(e.bmAttributes) == usb.util.ENDPOINT_TYPE_INTR)
    return dev, intf.bInterfaceNumber, (ep_in.bEndpointAddress if ep_in else 0x81)

def cypress_query(dev, ifnum, ep_in, cmd, read_tmo=1000):
    import usb.core
    b = cmd.encode()
    for i in range(0, len(b), 8):                       # write 8-byte Set_Report chunks
        dev.ctrl_transfer(0x21, 0x09, 0x0200, ifnum, b[i:i+8].ljust(8, b"\x00"), timeout=1000)
    out = bytearray()
    for _ in range(16):                                 # read interrupt-IN until CR
        try:
            out.extend(bytes(dev.read(ep_in, 8, timeout=read_tmo)))
        except usb.core.USBError:
            break
        if 0x0d in out:
            break
    return bytes(out).split(b"\r", 1)[0] if b"\r" in out else bytes(out).rstrip(b"\x00")

# --- Megatec Q1 parse --------------------------------------------------------
def parse_q1(raw):
    s = raw.decode("ascii", "replace").strip()
    if not s.startswith("("):
        raise ValueError("bad Q1 reply: %r" % raw)
    f = s[1:].split()
    if len(f) < 8:
        raise ValueError("short Q1 reply: %r" % raw)
    bits = f[7]
    util_fail = bits[0] == "1"   # b7: on battery
    batt_low  = bits[1] == "1"   # b6: battery low
    return {
        "battery_voltage": f[5], "input_voltage": f[0], "output_voltage": f[2],
        "load": f[3].lstrip("0") or "0", "temperature": f[6], "frequency": f[4],
        "status": ("OB" if util_fail else "OL") + ("_LB" if batt_low else ""),
        "ol": 0 if util_fail else 1, "ob": 1 if util_fail else 0, "lb": 1 if batt_low else 0,
    }

def logfmt(d):
    return (f"battery_voltage={d['battery_voltage']} input_voltage={d['input_voltage']} "
            f"output_voltage={d['output_voltage']} load={d['load']} temperature={d['temperature']} "
            f"frequency={d['frequency']} status={d['status']} ol={d['ol']} ob={d['ob']} lb={d['lb']}")

def push(line):
    payload = json.dumps({"streams": [{"stream": {"job": "ups", "host": HOST, "ups": "ted"},
                                       "values": [[str(time.time_ns()), line]]}]}).encode()
    req = urllib.request.Request(LOKI, data=payload,
                                 headers={"Content-Type": "application/json"}, method="POST")
    urllib.request.urlopen(req, timeout=5).read()

def sample():
    import usb.util
    dev, ifnum, ep_in = open_dev()
    try:
        cypress_query(dev, ifnum, ep_in, "Q1\r")      # warm-up (first cmd often dropped)
        time.sleep(0.2)
        raw = cypress_query(dev, ifnum, ep_in, "Q1\r")
    finally:
        usb.util.dispose_resources(dev)
    return parse_q1(raw), raw

def main():
    do_print = "--print" in sys.argv
    try:
        d, raw = sample()
        if do_print:
            print("raw:", raw); print("parsed:", d); print("logfmt:", logfmt(d))
        push(logfmt(d))
        if do_print:
            print("pushed to Loki host=%s" % HOST)
    except Exception as e:
        log("ERROR: %s" % e)
        if do_print:
            traceback.print_exc()
        return 1
    return 0

if __name__ == "__main__":
    sys.exit(main())
