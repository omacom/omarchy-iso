#!/usr/bin/env python3
"""Write signed PK/KEK/db .auth files for systemd-boot's secure-boot-enroll.

systemd-boot enrolls $ESP/loader/keys/<name>/{db,KEK,PK}.auth when the
firmware is in Setup Mode. `bootctl install --secure-boot-auto-enroll` writes
the same files, but it probes the real ESP block device and so needs root;
this writes them for a disk image instead, using only openssl.

Each file is an EFI_VARIABLE_AUTHENTICATION_2 header (time-based, PKCS#7
detached signature over name||guid||attributes||timestamp||data) followed by
an EFI_SIGNATURE_LIST holding one X.509 certificate.

Usage: mkauth.py CERT.pem KEY.pem OUTDIR
"""

import datetime
import os
import struct
import subprocess
import sys
import tempfile
import uuid

EFI_GLOBAL_VARIABLE = uuid.UUID("8be4df61-93ca-11d2-aa0d-00e098032b8c")
EFI_IMAGE_SECURITY_DATABASE = uuid.UUID("d719b2cb-3d3a-4596-a3bc-dad00e67656f")
EFI_CERT_X509 = uuid.UUID("a5c059a1-94e4-4aa7-87b5-ab155c2bf072")
EFI_CERT_TYPE_PKCS7 = uuid.UUID("4aafd29d-68df-49ee-8aa9-347d375665a7")
# Owner GUID recorded beside the certificate; any fixed value works.
OWNER = uuid.UUID("0a4ac0fe-0000-4d4a-9a3e-4f4d41524348")

ATTRS = 0x01 | 0x02 | 0x04 | 0x20  # NV | BS | RT | TIME_BASED_AUTHENTICATED_WRITE


def efi_time(now):
    return struct.pack("<HBBBBBBIhBB", now.year, now.month, now.day, now.hour, now.minute, now.second, 0, 0, 0, 0, 0)


def signature_list(cert_der):
    entry = OWNER.bytes_le + cert_der
    return EFI_CERT_X509.bytes_le + struct.pack("<III", 28 + len(entry), 0, len(entry)) + entry


def sign(payload, cert, key):
    with tempfile.NamedTemporaryFile() as f:
        f.write(payload)
        f.flush()
        return subprocess.run(
            ["openssl", "cms", "-sign", "-binary", "-noattr", "-md", "sha256", "-outform", "DER",
             "-in", f.name, "-signer", cert, "-inkey", key],
            check=True, capture_output=True,
        ).stdout


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    cert, key, outdir = sys.argv[1:]
    cert_der = subprocess.run(["openssl", "x509", "-in", cert, "-outform", "DER"], check=True, capture_output=True).stdout
    data = signature_list(cert_der)
    timestamp = efi_time(datetime.datetime.now(datetime.timezone.utc))
    os.makedirs(outdir, exist_ok=True)

    for name, guid in (("PK", EFI_GLOBAL_VARIABLE), ("KEK", EFI_GLOBAL_VARIABLE), ("db", EFI_IMAGE_SECURITY_DATABASE)):
        signed = name.encode("utf-16-le") + guid.bytes_le + struct.pack("<I", ATTRS) + timestamp + data
        pkcs7 = sign(signed, cert, key)
        win_cert = struct.pack("<IHH", 24 + len(pkcs7), 0x0200, 0x0EF1) + EFI_CERT_TYPE_PKCS7.bytes_le + pkcs7
        with open(os.path.join(outdir, f"{name}.auth"), "wb") as f:
            f.write(timestamp + win_cert + data)


if __name__ == "__main__":
    main()
