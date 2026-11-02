These files are a vendored copy of
`hindsight-extensions/static-keys-tenant/hindsight_ext_static_keys_tenant`
from https://github.com/vectorize-io/hindsight (MIT License, see LICENSE).

They are mounted read-only at /app/extensions and loaded through PYTHONPATH,
which is exactly what upstream's Dockerfile does when it copies them into a
derived image — we just avoid maintaining the derived image.

Upgrade by re-copying the directory from the matching Hindsight release tag.
