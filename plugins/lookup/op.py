# -*- coding: utf-8 -*-
# Port of modules/modules/onepassword.py (read) for Ansible.

DOCUMENTATION = r"""
name: op
short_description: Read secrets from 1Password with C(op read)
description:
  - Resolves 1Password secret references (C(op://vault/item/[section/]field), optionally
    with a query such as C(?ssh-format=openssh)) with the 1Password CLI.
  - Runs on the control node only. Authenticates with a service account token from
    E(OP_SERVICE_ACCOUNT_TOKEN), or from O(token_file) if that variable is not set.
  - Every failure fails the task, so an empty password is never deployed. Values are
    never logged. Like every lookup result, they are not templated again, so a
    secret containing C({{) stays literal.
  - "Rate limits: lookups in variables are evaluated each time the variable is used.
    Roles should resolve them once per run with set_fact (the quadlets role does).
    References by ID (C(op://<vault-id>/<item-id>/...)) cost 1 read, by name 3."
options:
  _terms:
    description: Secret references.
    required: true
    type: list
    elements: str
  op_bin:
    description: Path or name of the C(op) binary.
    type: str
    default: op
    env:
      - name: OP_BIN
  token_file:
    description: File holding the service account token (used when E(OP_SERVICE_ACCOUNT_TOKEN) is unset).
    type: path
    default: /run/secrets/op-token
    env:
      - name: OP_SERVICE_ACCOUNT_TOKEN_FILE
  timeout:
    description: Seconds per C(op) call.
    type: int
    default: 30
  allow_empty:
    description: Return an empty value instead of failing.
    type: bool
    default: false
"""

EXAMPLES = r"""
wifi_psk: "{{ lookup('op', 'op://infra/schnorchel-surfer/password') }}"
"""

RETURN = r"""
_raw:
  description: The secret values, one per reference.
  type: list
  elements: str
"""

import os
import shutil
import subprocess

from ansible.errors import AnsibleLookupError
from ansible.plugins.lookup import LookupBase

# Per worker process. Ansible forks a worker per task and host, so this only
# saves reads within one task (loops); see the rate limit note above.
_CACHE = {}


def _check_reference(term):
    if not isinstance(term, str):
        raise AnsibleLookupError("op: a secret reference must be a string")
    ref = term.strip()
    path = ref[len("op://"):].split("?", 1)[0]
    if not ref.startswith("op://") or len([p for p in path.split("/") if p]) < 3 or any(c in ref for c in "\r\n\0"):
        raise AnsibleLookupError(f"op: expected a secret reference like op://vault/item/field, got {ref!r}")
    return ref


class LookupModule(LookupBase):
    def run(self, terms, variables=None, **kwargs):
        self.set_options(var_options=variables, direct=kwargs)
        env = dict(os.environ)
        if not env.get("OP_SERVICE_ACCOUNT_TOKEN") and not env.get("OP_CONNECT_HOST"):
            token_file = self.get_option("token_file")
            try:
                with open(token_file, encoding="utf-8") as fh:
                    token = fh.read().strip()
            except OSError as exc:
                raise AnsibleLookupError(
                    f"op: no 1Password credentials: OP_SERVICE_ACCOUNT_TOKEN is unset and {token_file} "
                    f"is not readable ({exc.strerror})"
                )
            if not token:
                raise AnsibleLookupError(f"op: {token_file} is empty")
            env["OP_SERVICE_ACCOUNT_TOKEN"] = token

        op_bin = shutil.which(self.get_option("op_bin"))
        if not op_bin:
            raise AnsibleLookupError(f"op: 1Password CLI '{self.get_option('op_bin')}' not found")
        timeout = self.get_option("timeout")

        values = []
        for term in terms:
            ref = _check_reference(term)
            if ref not in _CACHE:
                try:
                    proc = subprocess.run(
                        [op_bin, "read", "--no-newline", ref],
                        stdin=subprocess.DEVNULL,  # never let op prompt
                        capture_output=True,
                        env=env,
                        timeout=timeout,
                        check=False,
                    )
                except subprocess.TimeoutExpired:
                    raise AnsibleLookupError(f"op: 'op read {ref}' timed out after {timeout}s")
                except OSError as exc:
                    raise AnsibleLookupError(f"op: cannot execute {op_bin}: {exc.strerror}")
                if proc.returncode != 0:
                    err = proc.stderr.decode("utf-8", "replace").strip() or f"exit code {proc.returncode}"
                    raise AnsibleLookupError(f"op: 'op read {ref}' failed: {err}")
                try:
                    value = proc.stdout.decode("utf-8")
                except UnicodeDecodeError:
                    raise AnsibleLookupError(f"op: {ref} is not UTF-8 text (binary file attachment?)")
                if value == "" and not self.get_option("allow_empty"):
                    raise AnsibleLookupError(f"op: {ref} is empty")
                _CACHE[ref] = value
            values.append(_CACHE[ref])
        return values
