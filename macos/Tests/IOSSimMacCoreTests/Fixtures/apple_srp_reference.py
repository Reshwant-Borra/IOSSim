#!/usr/bin/env python3
"""Deterministic Apple GrandSlam SRP reference fixture.

This is a stdlib-only transcription of the data flow used by:

* Apple corecrypto ccsrp with CCSRP_OPTION_SRP6a_HASH and
  noUsernameInX=true (apple/corecrypto 9612a959abb6eac0aac3ee6a7245c46365c9d81b)
* AltSign's GrandSlam adapter
  (rileytestut/AltSign 1c44cfdcafc1ef301c9a0a20a96be0983bb5a003)
* cocagne/pysrp with rfc5054_enable() and no_username_in_x()
  (2f0211d7965290664af1537a0164dbb82a7270ff)

It emits only lengths and SHA-256 fingerprints of synthetic fixture values so
test failures cannot print reusable authentication material.
"""

import hashlib
import json


N = int(
    "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A"
    "37329CBB4A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8"
    "083969EDB767B0CF6095179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F"
    "97993EC975EEAA80D740ADBF4FF747359D041D5C33EA71D281E446B14773BCA97"
    "B43A23FB801676BD207A436C6481F1D2B9078717461A5B9D32E688F8774854452"
    "3B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB3786160279004E57AE6AF874E"
    "7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DBFBB694B5C8"
    "03D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73",
    16,
)
G = 2
WIDTH = 256


def h(value: bytes) -> bytes:
    return hashlib.sha256(value).digest()


def minimal(value: int) -> bytes:
    if value == 0:
        return b""
    return value.to_bytes((value.bit_length() + 7) // 8, "big")


def pad(value: int) -> bytes:
    return value.to_bytes(WIDTH, "big")


def fingerprint(value: bytes) -> dict[str, object]:
    return {"length": len(value), "sha256": hashlib.sha256(value).hexdigest()}


def trace(scheme: str) -> dict[str, object]:
    username = "fixture@example.invalid"
    username_bytes = username.encode("utf-8")
    password = b"synthetic-password"
    salt = bytes([0x5A]) * 16
    iterations = 20_000
    private_bytes = bytes(range(1, 33))
    a = int.from_bytes(private_bytes, "big", signed=False)
    B_bytes = bytes([0x7B]) * WIDTH
    B = int.from_bytes(B_bytes, "big", signed=False)

    password_digest = h(password)
    password_preprocessing = (
        password_digest if scheme == "s2k" else password_digest.hex().encode("ascii")
    )
    password_key = hashlib.pbkdf2_hmac(
        "sha256", password_preprocessing, salt, iterations, dklen=32
    )

    # corecrypto ccsrp_generate_x with noUsernameInX=true still hashes the
    # leading colon and then hashes salt || inner_digest.
    x_inner = h(b":" + password_key)
    x_bytes = h(salt + x_inner)
    x = int.from_bytes(x_bytes, "big", signed=False)

    n_bytes = pad(N)
    g_bytes = minimal(G)
    padded_g = pad(G)
    h_n = h(n_bytes)
    h_g = h(padded_g)
    h_xor = bytes(left ^ right for left, right in zip(h_n, h_g))
    k_bytes = h(n_bytes + padded_g)
    k = int.from_bytes(k_bytes, "big", signed=False)
    A = pow(G, a, N)
    A_bytes = pad(A)
    padded_B = pad(B)
    u_bytes = h(A_bytes + padded_B)
    u = int.from_bytes(u_bytes, "big", signed=False)
    verifier = pow(G, x, N)
    product = k * verifier
    base = (B - (product % N)) % N
    exponent = a + u * x
    shared = pow(base, exponent, N)
    shared_bytes = pad(shared)
    session_key = h(shared_bytes)
    username_hash = h(username_bytes)
    m1_input = h_xor + username_hash + salt + A_bytes + padded_B + session_key
    m1 = h(m1_input)
    m2_input = A_bytes + m1 + session_key
    m2 = h(m2_input)

    values = {
        "username_utf8": username_bytes,
        "password_input": password,
        "password_sha256": password_digest,
        "password_preprocessing_output": password_preprocessing,
        "pbkdf2_input": password_preprocessing,
        "pbkdf2_salt": salt,
        "derived_password_key": password_key,
        "N": n_bytes,
        "g": g_bytes,
        "PAD_g": padded_g,
        "H_N": h_n,
        "H_PAD_g": h_g,
        "H_N_xor_H_PAD_g": h_xor,
        "k": k_bytes,
        "a": private_bytes,
        "A": A_bytes,
        "encoded_A": A_bytes,
        "decoded_B": minimal(B),
        "padded_B": padded_B,
        "u": u_bytes,
        "x_inner_hash": x_inner,
        "x": x_bytes,
        "g_pow_x": pad(verifier),
        "k_times_g_pow_x": minimal(product),
        "B_minus_k_times_g_pow_x": pad(base),
        "exponent_a_plus_u_times_x": minimal(exponent),
        "S": shared_bytes,
        "S_encoding": shared_bytes,
        "session_key_derivation_input": shared_bytes,
        "K": session_key,
        "H_username": username_hash,
        "M1_input": m1_input,
        "M1": m1,
        "M2_input": m2_input,
        "M2": m2,
    }
    return {
        "metadata": {
            "username_before_normalization": username,
            "username_after_normalization": username,
            "scheme": scheme,
            "pbkdf2_iterations": str(iterations),
            "pbkdf2_prf": "HMAC-SHA256",
            "pbkdf2_output_length": "32",
            "N_byte_width": str(WIDTH),
            "integer_encoding": "unsigned-big-endian",
            "group_element_encoding": "fixed-256-byte",
        },
        "values": {name: fingerprint(value) for name, value in values.items()},
    }


print(json.dumps({scheme: trace(scheme) for scheme in ("s2k", "s2k_fo")}, sort_keys=True))
